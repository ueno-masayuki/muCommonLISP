// LispTextView.swift
// NSTextView wrapper with Lisp syntax highlighting, paren matching,
// auto-indent and symbol completion.

#if os(macOS)

import SwiftUI
import AppKit
import MuLispCore

struct LispTextView: NSViewRepresentable {
    @ObservedObject var document: EditorDocument
    let completionProvider: (String) -> [String]

    func makeCoordinator() -> Coordinator {
        return Coordinator(document: document,
                           completionProvider: completionProvider)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else {
            return scroll
        }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13,
                                                    weight: .regular)
        textView.textColor = NSColor.textColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        textView.string = document.text
        document.textView = textView
        context.coordinator.textView = textView
        context.coordinator.highlightAll()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        // Switch the view to another document when the binding changed.
        if context.coordinator.document !== document {
            context.coordinator.document = document
            textView.string = document.text
            document.textView = textView
            context.coordinator.highlightAll()
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate,
                             NSTextStorageDelegate {
        var document: EditorDocument
        weak var textView: NSTextView?
        let completionProvider: (String) -> [String]
        private var isHighlighting = false

        init(document: EditorDocument,
             completionProvider: @escaping (String) -> [String]) {
            self.document = document
            self.completionProvider = completionProvider
        }

        // MARK: Text changes

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            document.text = tv.string
            document.isDirty = true
            highlightAll()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            highlightMatchingParen()
        }

        // MARK: Auto-indent and completion commands

        func textView(_ textView: NSTextView,
                      doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let indent = computeIndent(for: textView)
                textView.insertText("\n" + String(repeating: " ", count: indent),
                                    replacementRange: textView.selectedRange())
                return true
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                // Tab completes when touching a symbol, else inserts spaces.
                let range = textView.selectedRange()
                if range.length == 0 && partialWordRange(in: textView).length > 0 {
                    textView.complete(nil)
                    return true
                }
                textView.insertText("  ",
                                    replacementRange: textView.selectedRange())
                return true
            }
            return false
        }

        // MARK: Completion

        private func partialWordRange(in textView: NSTextView) -> NSRange {
            let text = textView.string as NSString
            var location = textView.selectedRange().location
            if location > text.length { location = text.length }
            var start = location
            let symbolChars = CharacterSet(charactersIn:
                "abcdefghijklmnopqrstuvwxyz"
                + "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
                + "-+*/<>=!?%&_:.")
            while start > 0 {
                let c = text.character(at: start - 1)
                if let scalar = Unicode.Scalar(c),
                   symbolChars.contains(scalar) {
                    start -= 1
                } else {
                    break
                }
            }
            return NSRange(location: start, length: location - start)
        }

        func textView(_ textView: NSTextView,
                      completions words: [String],
                      forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?)
            -> [String] {
            let text = textView.string as NSString
            guard charRange.location != NSNotFound,
                  charRange.length > 0,
                  charRange.location + charRange.length <= text.length else {
                return []
            }
            let prefix = text.substring(with: charRange)
            return completionProvider(prefix)
        }

        func textView(_ textView: NSTextView,
                      willChangeSelectionFromCharacterRange old: NSRange,
                      toCharacterRange new: NSRange) -> NSRange {
            return new
        }

        // Use our own word range for completion.
        func textView(_ textView: NSTextView,
                      shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            return true
        }

        // MARK: Indentation

        private func computeIndent(for textView: NSTextView) -> Int {
            let text = Array(textView.string)
            let cursor = min(textView.selectedRange().location, text.count)
            var inString = false
            var inComment = false
            var stack: [Int] = []       // columns of unclosed open parens
            var column = 0
            var i = 0
            while i < cursor {
                let c = text[i]
                if c == "\n" {
                    column = 0
                    inComment = false
                    i += 1
                    continue
                }
                defer {
                    column += 1
                    i += 1
                }
                if inComment { continue }
                if inString {
                    if c == "\\" {
                        column += 1
                        i += 1
                    } else if c == "\"" {
                        inString = false
                    }
                    continue
                }
                switch c {
                case ";": inComment = true
                case "\"": inString = true
                case "\\":
                    column += 1
                    i += 1
                case "(": stack.append(column)
                case ")":
                    if !stack.isEmpty { stack.removeLast() }
                default: break
                }
            }
            guard let open = stack.last else { return 0 }
            return open + 2
        }

        // MARK: Syntax highlighting

        func highlightAll() {
            guard let tv = textView,
                  let storage = tv.textStorage,
                  !isHighlighting else { return }
            isHighlighting = true
            defer { isHighlighting = false }

            let text = Array(tv.string)
            let fullRange = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.removeAttribute(.foregroundColor, range: fullRange)
            storage.addAttribute(.foregroundColor, value: NSColor.textColor,
                                 range: fullRange)

            func color(_ start: Int, _ end: Int, _ color: NSColor) {
                guard start < end, end <= text.count else { return }
                storage.addAttribute(.foregroundColor, value: color,
                                     range: NSRange(location: start,
                                                    length: end - start))
            }

            var i = 0
            var afterOpenParen = false
            while i < text.count {
                let c = text[i]
                switch c {
                case ";":
                    var j = i
                    while j < text.count, text[j] != "\n" { j += 1 }
                    color(i, j, .systemGray)
                    i = j
                    afterOpenParen = false
                case "\"":
                    var j = i + 1
                    while j < text.count {
                        if text[j] == "\\" { j += 2; continue }
                        if text[j] == "\"" { j += 1; break }
                        j += 1
                    }
                    color(i, min(j, text.count), .systemRed)
                    i = j
                    afterOpenParen = false
                case "#":
                    if i + 1 < text.count, text[i + 1] == "\\" {
                        var j = i + 2
                        if j < text.count { j += 1 }
                        while j < text.count, text[j].isLetter { j += 1 }
                        color(i, j, .systemOrange)
                        i = j
                        afterOpenParen = false
                        continue
                    }
                    if i + 1 < text.count, text[i + 1] == "|" {
                        var j = i + 2
                        var depth = 1
                        while j + 1 < text.count, depth > 0 {
                            if text[j] == "#" && text[j + 1] == "|" {
                                depth += 1
                                j += 2
                            } else if text[j] == "|" && text[j + 1] == "#" {
                                depth -= 1
                                j += 2
                            } else {
                                j += 1
                            }
                        }
                        color(i, min(j, text.count), .systemGray)
                        i = j
                        afterOpenParen = false
                        continue
                    }
                    i += 1
                case ":":
                    var j = i + 1
                    while j < text.count, isSymbolChar(text[j]) { j += 1 }
                    if j > i + 1 {
                        color(i, j, .systemPurple)
                    }
                    i = j
                    afterOpenParen = false
                case "(":
                    afterOpenParen = true
                    i += 1
                case ")", " ", "\n", "\t", "'", "`", ",":
                    i += 1
                default:
                    var j = i
                    while j < text.count, isSymbolChar(text[j]) { j += 1 }
                    if j > i {
                        if afterOpenParen {
                            let word = String(text[i..<j]).uppercased()
                            if word.hasPrefix("DEF")
                                || Coordinator.specialWords.contains(word) {
                                color(i, j, .systemBlue)
                            }
                        }
                        i = j
                    } else {
                        i += 1
                    }
                    afterOpenParen = false
                }
            }
            storage.endEditing()
        }

        private func isSymbolChar(_ c: Character) -> Bool {
            return c.isLetter || c.isNumber
                || "-+*/<>=!?%&_.:".contains(c)
        }

        static let specialWords: Set<String> = [
            "LET", "LET*", "LAMBDA", "IF", "COND", "CASE", "WHEN", "UNLESS",
            "PROGN", "SETQ", "SETF", "QUOTE", "FUNCTION", "BLOCK",
            "RETURN", "RETURN-FROM", "LOOP", "DO", "DO*", "DOLIST", "DOTIMES",
            "AND", "OR", "NOT", "FLET", "LABELS", "MULTIPLE-VALUE-BIND",
            "HANDLER-CASE", "HANDLER-BIND", "RESTART-CASE", "UNWIND-PROTECT",
            "CATCH", "THROW", "TAGBODY", "GO", "WITH-SLOTS", "WITH-ACCESSORS",
            "WITH-OPEN-FILE", "WITH-OUTPUT-TO-STRING", "MAKE-INSTANCE",
            "ERROR", "FORMAT", "VALUES", "DECLARE", "THE",
        ]

        // MARK: Paren matching

        private func highlightMatchingParen() {
            guard let tv = textView,
                  let layoutManager = tv.layoutManager else { return }
            let text = Array(tv.string)
            layoutManager.removeTemporaryAttribute(
                .backgroundColor,
                forCharacterRange: NSRange(location: 0, length: text.count))

            let sel = tv.selectedRange()
            guard sel.length == 0, sel.location > 0,
                  sel.location <= text.count else { return }
            let pos = sel.location - 1
            let c = text[pos]
            var match: Int? = nil
            if c == ")" {
                var depth = 0
                var i = pos
                while i >= 0 {
                    if text[i] == ")" { depth += 1 }
                    if text[i] == "(" {
                        depth -= 1
                        if depth == 0 { match = i; break }
                    }
                    i -= 1
                }
            } else if c == "(" {
                var depth = 0
                var i = pos
                while i < text.count {
                    if text[i] == "(" { depth += 1 }
                    if text[i] == ")" {
                        depth -= 1
                        if depth == 0 { match = i; break }
                    }
                    i += 1
                }
            }
            if let m = match {
                let highlight = NSColor.selectedTextBackgroundColor
                    .withAlphaComponent(0.6)
                layoutManager.addTemporaryAttribute(
                    .backgroundColor, value: highlight,
                    forCharacterRange: NSRange(location: m, length: 1))
                layoutManager.addTemporaryAttribute(
                    .backgroundColor, value: highlight,
                    forCharacterRange: NSRange(location: pos, length: 1))
            }
        }
    }
}

#endif
