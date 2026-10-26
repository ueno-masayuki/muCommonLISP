// EditorPaneView.swift
// Tabbed editor pane with file handling and evaluation commands.

#if os(macOS)

import SwiftUI
import AppKit
import MuLispCore

struct EditorPaneView: View {
    @EnvironmentObject var model: InterpreterModel
    @EnvironmentObject var editor: EditorState

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            if let doc = editor.selectedDocument {
                LispTextView(document: doc,
                             completionProvider: model.completions)
                    .id(doc.id)
            } else {
                Text("ファイルがありません")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            commandBar
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(editor.tabbedDocuments) { doc in
                    tabButton(doc)
                }
                Button {
                    editor.newDocument()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("新規バッファ (⌘N)")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }

    private func tabButton(_ doc: EditorDocument) -> some View {
        HStack(spacing: 4) {
            Text(doc.displayName + (doc.isDirty ? " •" : ""))
                .font(.system(size: 12))
                .lineLimit(1)
            Button {
                editor.detach(doc)
            } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 8))
            }
            .buttonStyle(.borderless)
            .help("別ウィンドウで開く")
            Button {
                editor.closeDocument(doc)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8))
            }
            .buttonStyle(.borderless)
            .help("バッファを閉じる")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(editor.selectedID == doc.id
                    ? Color.accentColor.opacity(0.25)
                    : Color.clear)
        .cornerRadius(5)
        .contentShape(Rectangle())
        .onTapGesture {
            editor.selectedID = doc.id
        }
        .contextMenu {
            Button("別ウィンドウで開く") { editor.detach(doc) }
            Button("閉じる") { editor.closeDocument(doc) }
        }
    }

    private var commandBar: some View {
        HStack(spacing: 10) {
            // File operations are also in the File menu (⌘O / ⌘S / ⇧⌘S).
            Button("開く…") { editor.openDocument() }
            Button("保存") { editor.saveDocument(editor.selectedDocument) }
            Button("別名保存…") {
                editor.saveDocument(editor.selectedDocument, as: true)
            }
            Spacer()
            Button("定義へ ⌘J") { jumpToDefinition() }
                .keyboardShortcut("j", modifiers: .command)
            Button("式を評価 ⌘E") { evaluateFormOrSelection() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.isRunning)
            Button("バッファ評価 ⌘⇧E") { evaluateBuffer() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.isRunning)
        }
        .font(.system(size: 11))
        .buttonStyle(.borderless)
        .padding(6)
    }

    // MARK: - Actions

    private func evaluateFormOrSelection() {
        guard let doc = editor.selectedDocument,
              let code = editor.textToEvaluate(doc) else {
            NSSound.beep()
            return
        }
        model.evaluateCode(code, echo: firstLine(of: code))
    }

    private func evaluateBuffer() {
        guard let doc = editor.selectedDocument else { return }
        editor.syncFromTextView(doc)
        model.evaluateCode(doc.text, echo: ";; バッファ評価: \(doc.displayName)")
    }

    private func jumpToDefinition() {
        guard let doc = editor.selectedDocument,
              let tv = doc.textView else { return }
        let text = tv.string as NSString
        var range = tv.selectedRange()
        if range.length == 0 {
            // Expand to the symbol under the cursor.
            let symbolChars = CharacterSet(charactersIn:
                "abcdefghijklmnopqrstuvwxyz"
                + "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-+*/<>=!?%&_.")
            var start = min(range.location, text.length)
            var end = start
            while start > 0,
                  let s = Unicode.Scalar(text.character(at: start - 1)),
                  symbolChars.contains(s) {
                start -= 1
            }
            while end < text.length,
                  let s = Unicode.Scalar(text.character(at: end)),
                  symbolChars.contains(s) {
                end += 1
            }
            range = NSRange(location: start, length: end - start)
        }
        guard range.length > 0 else {
            NSSound.beep()
            return
        }
        let name = text.substring(with: range)
        guard let (targetDoc, offset) = editor.findDefinition(of: name) else {
            NSSound.beep()
            return
        }
        if editor.detachedIDs.contains(targetDoc.id) {
            EditorWindowManager.shared.focus(targetDoc)
        } else {
            editor.selectedID = targetDoc.id
        }
        DispatchQueue.main.async {
            if let targetTV = targetDoc.textView {
                let r = NSRange(location: offset, length: 0)
                targetTV.setSelectedRange(r)
                targetTV.scrollRangeToVisible(
                    NSRange(location: offset, length: 1))
                targetTV.window?.makeFirstResponder(targetTV)
            }
        }
    }

    private func firstLine(of code: String) -> String {
        let line = code.split(separator: "\n").first.map(String.init) ?? code
        return ";; 評価: " + (line.count > 60
                              ? String(line.prefix(60)) + "…" : line)
    }
}

#endif
