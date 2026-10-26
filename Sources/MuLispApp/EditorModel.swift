// EditorModel.swift
// Buffers for the editor. Every buffer lives in its own window; the main
// (evaluation) window holds only the REPL.

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

    @discardableResult
    func newDocument() -> EditorDocument {
        let doc = EditorDocument(
            text: ";; muCommonLISP editor — ⌘E で評価, ⌘⇧E でバッファ全体を評価\n\n")
        documents.append(doc)
        EditorWindowManager.shared.open(doc)
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
        if let existing = documents.first(where: { $0.url == url }) {
            EditorWindowManager.shared.open(existing)
            return
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            NSSound.beep()
            return
        }
        let doc = EditorDocument(url: url, text: text)
        documents.append(doc)
        EditorWindowManager.shared.open(doc)
    }

    /// The buffer File-menu actions operate on: the key editor window's.
    /// With no editor window key, only an unambiguous (single) buffer is
    /// targeted — never silently an arbitrary one.
    var menuTargetDocument: EditorDocument? {
        if let id = EditorWindowManager.shared.activeDetachedID,
           let doc = documents.first(where: { $0.id == id }) {
            return doc
        }
        return documents.count == 1 ? documents.first : nil
    }

    @discardableResult
    func saveDocument(_ doc: EditorDocument?, as saveAs: Bool = false) -> Bool {
        guard let doc = doc else { return false }
        syncFromTextView(doc)
        var target = doc.url
        if target == nil || saveAs {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = doc.url?.lastPathComponent
                ?? "untitled.lisp"
            guard panel.runModal() == .OK, let url = panel.url else {
                return false
            }
            target = url
        }
        guard let url = target else { return false }
        do {
            try doc.text.write(to: url, atomically: true, encoding: .utf8)
            doc.url = url
            doc.isDirty = false
            EditorWindowManager.shared.updateTitle(doc)
            return true
        } catch {
            NSSound.beep()
            return false
        }
    }

    /// Close a buffer (and its window), asking to save when dirty.
    func closeDocument(_ doc: EditorDocument) {
        if EditorWindowManager.shared.isDetachedWindowOpen(doc) {
            // The window's close path prompts and calls forget(_:).
            EditorWindowManager.shared.requestClose(doc)
        } else {
            forget(doc)
        }
    }

    /// Bookkeeping after a window is gone.
    func forget(_ doc: EditorDocument) {
        documents.removeAll { $0.id == doc.id }
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
        var containing: (Int, Int)? = nil   // form around the cursor
        var preceding: (Int, Int)? = nil    // last form ending before it
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
                        containing = (start, end)
                    } else if end <= position {
                        preceding = (start, end)
                    }
                    formStart = nil
                }
                if depth < 0 { depth = 0 }
            default:
                break
            }
            i += 1
        }
        guard let (s, e) = containing ?? preceding else { return nil }
        let startIdx = text.index(text.startIndex, offsetBy: s)
        let endIdx = text.index(text.startIndex, offsetBy: min(e, chars.count))
        return startIdx..<endIdx
    }

    /// Search all open buffers for a definition of `name`.
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

    /// Jump from `doc` to the definition of the symbol at its cursor.
    func jumpToDefinition(from doc: EditorDocument) {
        guard let tv = doc.textView else { return }
        let text = tv.string as NSString
        var range = tv.selectedRange()
        if range.length == 0 {
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
        guard let (targetDoc, offset) = findDefinition(of: name) else {
            NSSound.beep()
            return
        }
        EditorWindowManager.shared.open(targetDoc)
        DispatchQueue.main.async {
            if let targetTV = targetDoc.textView {
                targetTV.setSelectedRange(NSRange(location: offset, length: 0))
                targetTV.scrollRangeToVisible(
                    NSRange(location: offset, length: 1))
                targetTV.window?.makeFirstResponder(targetTV)
            }
        }
    }
}

#endif
