// InterpreterModel.swift
// Observable bridge between the Lisp interpreter and the SwiftUI views.

#if os(macOS)

import Foundation
import SwiftUI
import MuLispCore

struct TranscriptEntry: Identifiable {
    enum Kind {
        case banner, input, output, result, error
    }
    let id = UUID()
    let kind: Kind
    var text: String
}

final class InterpreterModel: ObservableObject, GraphicsSink {

    @Published var entries: [TranscriptEntry] = []
    @Published var isRunning = false
    @Published var inputText = ""

    let interp = Interpreter()

    private var history: [String] = []
    private var historyIndex = 0

    init() {
        interp.graphics.sink = self
        interp.outputHandler = { [weak self] text in
            DispatchQueue.main.async {
                self?.appendOutput(text)
            }
        }
        interp.windowOpener = { gw in
            GraphicsWindowManager.shared.open(gw)
        }
        interp.windowCloser = { gw in
            GraphicsWindowManager.shared.close(gw)
        }
        entries.append(TranscriptEntry(
            kind: .banner,
            text: "muCommonLISP — micro Common Lisp (bytecode compiler + CLOS)"))
        if let bootError = interp.bootError {
            entries.append(TranscriptEntry(
                kind: .error,
                text: ";; BOOTSTRAP WARNING: \(bootError)"))
        }
    }

    // MARK: - GraphicsSink

    /// First drawing command on the main canvas: open its window. The
    /// window's own model then takes over the context's sink; it comes
    /// back here when the window is closed.
    func graphicsDidUpdate(_ context: GraphicsContext2D) {
        guard !context.snapshot().isEmpty else { return }
        DispatchQueue.main.async {
            GraphicsWindowManager.shared.showMainCanvas(for: context,
                                                        fallbackSink: self)
        }
    }

    // MARK: - Transcript

    private func appendOutput(_ text: String) {
        if let last = entries.last, last.kind == .output {
            entries[entries.count - 1].text += text
        } else {
            entries.append(TranscriptEntry(kind: .output, text: text))
        }
    }

    func clearTranscript() {
        entries.removeAll()
    }

    // MARK: - History

    func historyPrevious() {
        guard !history.isEmpty else { return }
        historyIndex = max(0, historyIndex - 1)
        inputText = history[historyIndex]
    }

    func historyNext() {
        guard !history.isEmpty else { return }
        if historyIndex >= history.count - 1 {
            historyIndex = history.count
            inputText = ""
        } else {
            historyIndex += 1
            inputText = history[historyIndex]
        }
    }

    // MARK: - Evaluation

    func evaluateInput() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        inputText = ""
        history.append(text)
        historyIndex = history.count
        entries.append(TranscriptEntry(kind: .input, text: text))
        isRunning = true

        let thread = Thread { [weak self] in
            guard let self = self else { return }
            var resultEntries: [TranscriptEntry] = []
            do {
                let result = try self.interp.evalAll(text)
                resultEntries.append(TranscriptEntry(
                    kind: .result, text: self.interp.printString(result)))
            } catch let e as LispError {
                resultEntries.append(TranscriptEntry(
                    kind: .error, text: ";; ERROR: \(e.message)"))
            } catch is InterruptSignal {
                resultEntries.append(TranscriptEntry(
                    kind: .error, text: ";; Interrupted"))
            } catch is ExitSignal {
                resultEntries.append(TranscriptEntry(
                    kind: .output, text: ";; (exit) — close the window to quit"))
            } catch let t as LispThrowSignal {
                let tag = Printer.toString(t.tag, escape: true,
                                           interp: self.interp)
                resultEntries.append(TranscriptEntry(
                    kind: .error, text: ";; ERROR: uncaught throw to \(tag)"))
            } catch {
                resultEntries.append(TranscriptEntry(
                    kind: .error, text: ";; ERROR: \(error)"))
            }
            DispatchQueue.main.async {
                self.entries.append(contentsOf: resultEntries)
                self.isRunning = false
            }
        }
        // Deep Lisp recursion re-enters the VM through Swift frames; give the
        // evaluation thread a generous stack.
        thread.stackSize = 64 * 1024 * 1024
        thread.name = "mulisp-eval"
        thread.start()
    }

    /// Evaluate code coming from the editor pane.
    func evaluateCode(_ code: String, echo: String?) {
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        entries.append(TranscriptEntry(kind: .input, text: echo ?? text))
        isRunning = true

        let thread = Thread { [weak self] in
            guard let self = self else { return }
            var resultEntries: [TranscriptEntry] = []
            do {
                let result = try self.interp.evalAll(text)
                resultEntries.append(TranscriptEntry(
                    kind: .result, text: self.interp.printString(result)))
            } catch let e as LispError {
                resultEntries.append(TranscriptEntry(
                    kind: .error, text: ";; ERROR: \(e.message)"))
            } catch is InterruptSignal {
                resultEntries.append(TranscriptEntry(
                    kind: .error, text: ";; Interrupted"))
            } catch is ExitSignal {
                resultEntries.append(TranscriptEntry(
                    kind: .output, text: ";; (exit)"))
            } catch let t as LispThrowSignal {
                let tag = Printer.toString(t.tag, escape: true,
                                           interp: self.interp)
                resultEntries.append(TranscriptEntry(
                    kind: .error, text: ";; ERROR: uncaught throw to \(tag)"))
            } catch {
                resultEntries.append(TranscriptEntry(
                    kind: .error, text: ";; ERROR: \(error)"))
            }
            DispatchQueue.main.async {
                self.entries.append(contentsOf: resultEntries)
                self.isRunning = false
            }
        }
        thread.stackSize = 64 * 1024 * 1024
        thread.name = "mulisp-editor-eval"
        thread.start()
    }

    /// Symbol-name completions for the editor (case-insensitive prefix).
    func completions(_ prefix: String) -> [String] {
        let upper = prefix.uppercased()
        guard !upper.isEmpty else { return [] }
        var names = Set<String>()
        for pkg in interp.registry.allPackages() {
            for (name, _) in pkg.symbols where name.hasPrefix(upper) {
                names.insert(name)
            }
        }
        let lowercase = prefix == prefix.lowercased()
        return names.sorted().prefix(200).map {
            lowercase ? $0.lowercased() : $0
        }
    }

    func interrupt() {
        interp.requestInterrupt()
    }

    func clearCanvas() {
        interp.graphics.append(.clear)
    }
}

#endif
