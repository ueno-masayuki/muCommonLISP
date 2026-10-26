// ContentView.swift
// Main (evaluation) window: the REPL only. Editor buffers and graphics
// live in their own windows.

#if os(macOS)

import SwiftUI
import MuLispCore

struct ContentView: View {
    @EnvironmentObject var model: InterpreterModel
    @EnvironmentObject var editor: EditorState

    var body: some View {
        REPLView()
            .frame(minWidth: 480, maxWidth: .infinity,
                   minHeight: 360, maxHeight: .infinity)
            .onAppear {
                EditorWindowManager.shared.configure(model: model,
                                                     editor: editor)
            }
            .toolbar {
                ToolbarItemGroup {
                    if model.isRunning {
                        Button {
                            model.interrupt()
                        } label: {
                            Label("中断", systemImage: "stop.circle")
                        }
                        .help("実行中の評価を中断します")
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button {
                        model.clearCanvas()
                    } label: {
                        Label("グラフィックス消去", systemImage: "paintbrush")
                    }
                    .help("メインのグラフィックスウィンドウを消去します")
                    Button {
                        model.clearTranscript()
                    } label: {
                        Label("履歴消去", systemImage: "trash")
                    }
                    .help("REPL の表示履歴を消去します")
                }
            }
    }
}

#endif
