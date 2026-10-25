// REPLView.swift
// Transcript + input area.

#if os(macOS)

import SwiftUI
import MuLispCore

struct REPLView: View {
    @EnvironmentObject var model: InterpreterModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.entries) { entry in
                            entryView(entry)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: model.entries.count) { _ in
                    if let last = model.entries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            VStack(spacing: 4) {
                TextEditor(text: $model.inputText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.4))
                    )
                HStack {
                    Text("⌘⏎ で評価 / ⌘↑⌘↓ で履歴")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("評価") {
                        model.evaluateInput()
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.isRunning)

                    // Hidden buttons providing history keyboard shortcuts.
                    Button("") { model.historyPrevious() }
                        .keyboardShortcut(.upArrow, modifiers: .command)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                    Button("") { model.historyNext() }
                        .keyboardShortcut(.downArrow, modifiers: .command)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func entryView(_ entry: TranscriptEntry) -> some View {
        switch entry.kind {
        case .banner:
            Text(entry.text)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
        case .input:
            Text("muCL> " + entry.text)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.blue)
                .textSelection(.enabled)
        case .output:
            Text(entry.text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        case .result:
            Text("=> " + entry.text)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.semibold)
                .textSelection(.enabled)
        case .error:
            Text(entry.text)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.red)
                .textSelection(.enabled)
        }
    }
}

#endif
