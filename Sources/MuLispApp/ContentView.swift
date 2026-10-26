// ContentView.swift
// Main window: editor above the REPL on the left, graphics canvas on the
// right.

#if os(macOS)

import SwiftUI
import MuLispCore

struct ContentView: View {
    @EnvironmentObject var model: InterpreterModel
    @EnvironmentObject var editor: EditorState

    var body: some View {
        HSplitView {
            VSplitView {
                // (onAppear below wires the detached-window manager.)
                if editor.isVisible {
                    EditorPaneView()
                        .frame(minHeight: 180, idealHeight: 340,
                               maxHeight: .infinity)
                }
                REPLView()
                    .frame(minHeight: 160, maxHeight: .infinity)
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)

            CanvasView()
                .frame(minWidth: 300, maxWidth: .infinity,
                       maxHeight: .infinity)
        }
        .onAppear {
            EditorWindowManager.shared.configure(model: model, editor: editor)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    editor.isVisible.toggle()
                } label: {
                    Label("エディタ",
                          systemImage: editor.isVisible
                          ? "rectangle.topthird.inset.filled"
                          : "rectangle")
                }
                .help("エディタペインの表示を切り替えます")

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
