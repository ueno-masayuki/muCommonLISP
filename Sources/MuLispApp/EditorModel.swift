// EditorModel.swift
// Buffers and file handling for the built-in editor.

#if os(macOS)

import SwiftUI
import AppKit
import MuLispCore

final class EditorDocument: ObservableObject, Identifiable {
    let id = UUID()
    @Published var url: URL?
    @Published var isDirty = false
    /// The authoritative text lives in the NSTextView while the document is
    /// displayed; `text` is kept in sync by the coordinator.
    @Published var text: String

    weak var textView: NSTextView?

    init(url: URL? = nil, text: String = "") {
        self.url = url
        self.text = text
    }

    var displayName: String {
        if let url = url {
            return url.lastPathComponent
        }
        return "無題"
    }
}

final class EditorState: ObservableObject {
    @Published var documents: [EditorDocument] = []
    @Published var selectedID: UUID?
    @Published var isVisible = true
    /// Buffers currently shown in their own window instead of the tab bar.
    @Published var detachedIDs: Set<UUID> = []

    init() {
        newDocument()
    }

    /// Buffers shown in the main window's tab bar.
    var tabbedDocuments: [EditorDocument] {
        return documents.filter { !detachedIDs.contains($0.id) }
    }

    var selectedDocument: EditorDocument? {
        if let id = selectedID, !detachedIDs.contains(id),
           let doc = documents.first(where: { $0.id == id }) {
            return doc
        }
        return tabbedDocuments.first
    }

    /// The buffer File-menu actions should operate on: the key detached
    /// window's buffer when one is key, else the selected tab.
    var menuTargetDocument: EditorDocument? {
        if let id = EditorWindowManager.shared.activeDetachedID,
           let doc = documents.first(where: { $0.id == id }) {
            return doc
        }
        return selectedDocument
    }

    // MARK: - Detached windows

    /// Move a buffer out of the tab bar into its own window.
    func detach(_ doc: EditorDocument) {
        guard !detachedIDs.contains(doc.id) else {
            EditorWindowManager.shared.focus(doc)
            return
        }
        syncFromTextView(doc)
        doc.textView = nil
        detachedIDs.insert(doc.id)
        if selectedID == doc.id {
            selectedID = tabbedDocuments.first?.id
        }
        EditorWindowManager.shared.open(doc)
    }

    /// Called when a detached window was closed by the user: the buffer
    /// returns to the tab bar.
    func reattach(_ doc: EditorDocument) {
        syncFromTextView(doc)
        doc.textView = nil
        detachedIDs.remove(doc.id)
        selectedID = doc.id
        isVisible = true
    }

    /// Button action: close the window and return the buffer to the tabs.
    func reattachToTabs(_ doc: EditorDocument) {
        EditorWindowManager.shared.close(doc)
        reattach(doc)
    }

    @discardableResult
    func newDocument() -> EditorDocument {
        let doc = EditorDocument(
            text: ";; muCommonLISP editor — ⌘E で評価, ⌘⇧E でバッファ全体を評価\n\n")
        documents.append(doc)
        selectedID = doc.id
        isVisible = true
        return doc
    }

    func openDocument() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            open(url: url)
        }
    }

    func open(url: URL) {
        isVisible = true
        if let existing = documents.first(where: { $0.url == url }) {
            if detachedIDs.contains(existing.id) {
                EditorWindowManager.shared.focus(existing)
            } else {
                selectedID = existing.id
            }
            return
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            NSSound.beep()
            return
        }
        let doc = EditorDocument(url: url, text: text)
        // Drop the pristine untitled buffer when a real file comes in.
        if documents.count == 1,
           let only = documents.first,
           only.url == nil, !only.isDirty {
            documents.removeAll()
        }
        documents.append(doc)
        selectedID = doc.id
    }

    func saveDocument(_ doc: EditorDocument?, as saveAs: Bool = false) {
        guard let doc = doc else { return }
        syncFromTextView(doc)
        var target = doc.url
        if target == nil || saveAs {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = doc.url?.lastPathComponent
                ?? "untitled.lisp"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            target = url
        }
        guard let url = target else { return }
        do {
            try doc.text.write(to: url, atomically: true, encoding: .utf8)
            doc.url = url
            doc.isDirty = false
            EditorWindowManager.shared.updateTitle(doc)
        } catch {
            NSSound.beep()
        }
    }

    func closeDocument(_ doc: EditorDocument) {
        if detachedIDs.contains(doc.id) {
            EditorWindowManager.shared.close(doc)
            detachedIDs.remove(doc.id)
        }
        documents.removeAll { $0.id == doc.id }
        if selectedID == doc.id {
            selectedID = tabbedDocuments.last?.id
        }
        if tabbedDocuments.isEmpty && detachedIDs.isEmpty {
            newDocument()
        }
    }

    func syncFromTextView(_ doc: EditorDocument) {
        if let tv = doc.textView {
            doc.text = tv.string
        }
    }

    // MARK: - Evaluation helpers

    /// The selected text, or the top-level form around the cursor.
    func textToEvaluate(_ doc: EditorDocument) -> String? {
        guard let tv = doc.textView else { return nil }
        let full = tv.string as NSString
        let sel = tv.selectedRange()
        if sel.length > 0 {
            return full.substring(with: sel)
        }
        if let range = EditorState.topLevelFormRange(in: tv.string,
                                                    around: sel.location) {
            let nsRange = NSRange(range, in: tv.string)
            return full.substring(with: nsRange)
        }
        return nil
    }

    /// Find the range of the top-level form containing `offset`.
    static func topLevelFormRange(in text: String,
                                  around offset: Int) -> Range<String.Index>? {
        let chars = Array(text)
        let position = min(offset, chars.count)
        var depth = 0
        var inString = false
        var inComment = false
        var formStart: Int? = nil
        var best: (Int, Int)? = nil     // [start, end)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inComment {
                if c == "\n" { inComment = false }
                i += 1
                continue
            }
            if inString {
                if c == "\\" { i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            switch c {
            case ";":
                inComment = true
            case "\"":
                inString = true
            case "\\":
                i += 1
            case "(":
                if depth == 0 { formStart = i }
                depth += 1
            case ")":
                depth -= 1
                if depth == 0, let start = formStart {
                    let end = i + 1
                    if position >= start && position <= end {
                        best = (start, end)
                    }
                    // Also remember the last form before the cursor as a
                    // fallback.
                    if best == nil && start <= position {
                        best = (start, end)
                    }
                    formStart = nil
                }
                if depth < 0 { depth = 0 }
            default:
                break
            }
            i += 1
        }
        guard let (s, e) = best else { return nil }
        let startIdx = text.index(text.startIndex, offsetBy: s)
        let endIdx = text.index(text.startIndex, offsetBy: min(e, chars.count))
        return startIdx..<endIdx
    }

    /// Search all open buffers for a definition of `name`.
    /// Returns (document, character offset).
    func findDefinition(of name: String) -> (EditorDocument, Int)? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "\\(def[a-zA-Z-]*\\s+(\\(setf\\s+)?\(escaped)[\\s)\\n]"
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        for doc in documents {
            syncFromTextView(doc)
            let ns = doc.text as NSString
            let m = regex.firstMatch(in: doc.text, options: [],
                                     range: NSRange(location: 0,
                                                    length: ns.length))
            if let match = m {
                return (doc, match.range.location)
            }
        }
        return nil
    }
}

#endif
