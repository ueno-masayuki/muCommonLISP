// EditorWindows.swift
// Editor windows: every editor buffer lives in its own NSWindow.
// Closing the window closes the buffer (with a save prompt when dirty).

#if os(macOS)

import SwiftUI
import AppKit
import MuLispCore

/// Tracks the NSWindows hosting editor buffers.
final class EditorWindowManager: NSObject, NSWindowDelegate {
    static let shared = EditorWindowManager()

    private weak var model: InterpreterModel?
    private weak var editor: EditorState?
    private var windows: [UUID: NSWindow] = [:]
    /// Documents whose windows are being closed by code (no prompt, the
    /// caller does the bookkeeping).
    private var closingProgrammatically = Set<UUID>()
    /// The document whose window is currently key (for the File menu's
    /// save/close actions).
    private(set) var activeDetachedID: UUID?

    func configure(model: InterpreterModel, editor: EditorState) {
        self.model = model
        self.editor = editor
    }

    func open(_ doc: EditorDocument) {
        guard let model = model, let editor = editor else { return }
        if let existing = windows[doc.id] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let root = DetachedEditorView(document: doc, model: model,
                                      editor: editor)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = doc.displayName
        window.contentView = NSHostingView(rootView: root)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows[doc.id] = window
        window.makeKeyAndOrderFront(nil)
    }

    func focus(_ doc: EditorDocument) {
        windows[doc.id]?.makeKeyAndOrderFront(nil)
    }

    func isDetachedWindowOpen(_ doc: EditorDocument) -> Bool {
        return windows[doc.id] != nil
    }

    /// Close a document's window without the save prompt (the caller has
    /// already decided to discard the buffer).
    func close(_ doc: EditorDocument) {
        guard let window = windows[doc.id] else { return }
        closingProgrammatically.insert(doc.id)
        window.close()
    }

    /// Close a document's window the same way the close button does:
    /// with the save prompt when the buffer is dirty.
    func requestClose(_ doc: EditorDocument) {
        windows[doc.id]?.performClose(nil)
    }

    func updateTitle(_ doc: EditorDocument) {
        windows[doc.id]?.title = doc.displayName + (doc.isDirty ? " •" : "")
    }

    private func documentID(for window: NSWindow) -> UUID? {
        return windows.first(where: { $0.value === window })?.key
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let id = documentID(for: sender),
              !closingProgrammatically.contains(id),
              let editor = editor,
              let doc = editor.documents.first(where: { $0.id == id })
        else { return true }
        editor.syncFromTextView(doc)
        guard doc.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText =
            "“\(doc.displayName)” には未保存の変更があります。"
        alert.informativeText = "閉じる前に保存しますか？"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "保存しない")
        alert.addButton(withTitle: "キャンセル")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return editor.saveDocument(doc)
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = documentID(for: window) else { return }
        windows.removeValue(forKey: id)
        if activeDetachedID == id {
            activeDetachedID = nil
        }
        if closingProgrammatically.remove(id) != nil {
            return
        }
        // The user closed the window: the buffer is gone with it.
        if let editor = editor,
           let doc = editor.documents.first(where: { $0.id == id }) {
            DispatchQueue.main.async {
                editor.forget(doc)
            }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = documentID(for: window) else { return }
        activeDetachedID = id
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = documentID(for: window) else { return }
        if activeDetachedID == id {
            activeDetachedID = nil
        }
    }
}

/// Full editor for one buffer living in its own window. Evaluation results
/// go to the main window's REPL.
struct DetachedEditorView: View {
    @ObservedObject var document: EditorDocument
    @ObservedObject var model: InterpreterModel
    @ObservedObject var editor: EditorState

    var body: some View {
        VStack(spacing: 0) {
            LispTextView(document: document,
                         completionProvider: model.completions)
            Divider()
            HStack(spacing: 10) {
                Text(document.displayName + (document.isDirty ? " •" : ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("定義へ ⌘J") {
                    editor.jumpToDefinition(from: document)
                }
                .keyboardShortcut("j", modifiers: .command)
                Button("保存") {
                    editor.saveDocument(document)
                }
                Button("式を評価 ⌘E") {
                    if let code = editor.textToEvaluate(document) {
                        model.evaluateCode(code, echo: nil)
                    } else {
                        NSSound.beep()
                    }
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.isRunning)
                Button("バッファ評価 ⌘⇧E") {
                    editor.syncFromTextView(document)
                    model.evaluateCode(document.text,
                                       echo: ";; バッファ評価: \(document.displayName)")
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.isRunning)
            }
            .font(.system(size: 11))
            .buttonStyle(.borderless)
            .padding(6)
        }
        .frame(minWidth: 420, minHeight: 280)
    }
}

#endif
