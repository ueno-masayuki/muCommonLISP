// ContentView.swift
// Main window: REPL pane on the left, graphics canvas on the right.

#if os(macOS)

import SwiftUI
import MuLispCore

struct ContentView: View {
    @EnvironmentObject var model: InterpreterModel

    var body: some View {
        HSplitView {
            REPLView()
                .frame(minWidth: 420, maxWidth: .infinity,
                       maxHeight: .infinity)
            CanvasView()
                .frame(minWidth: 320, maxWidth: .infinity,
                       maxHeight: .infinity)
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
                    Label("キャンバス消去", systemImage: "paintbrush")
                }
                .help("グラフィックスキャンバスを消去します")
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
