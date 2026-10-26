// MuLispApp.swift
// muCommonLISP — GUI application entry point (macOS only).

import Foundation
import MuLispCore

#if os(macOS)
import SwiftUI
import AppKit

@main
struct MuLispApp: App {
    @StateObject private var model = InterpreterModel()
    @StateObject private var editor = EditorState()

    init() {
        // Allow running via `swift run muCommonLISP` (no app bundle):
        // promote the process to a regular GUI app and bring it forward.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup("muCommonLISP") {
            ContentView()
                .environmentObject(model)
                .environmentObject(editor)
                .frame(minWidth: 520, minHeight: 420)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新規バッファ") {
                    editor.newDocument()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("開く…") {
                    editor.openDocument()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                // These act on the key editor window's buffer.
                Button("保存") {
                    editor.saveDocument(editor.menuTargetDocument)
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("別名で保存…") {
                    editor.saveDocument(editor.menuTargetDocument, as: true)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Divider()

                Button("バッファを閉じる") {
                    if let doc = editor.menuTargetDocument {
                        editor.closeDocument(doc)
                    }
                }
                .keyboardShortcut("w", modifiers: [.command, .option])
            }
        }
    }
}

#else

@main
struct MuLispAppStub {
    static func main() {
        print("muCommonLISP GUI requires macOS.")
        print("Use the command line REPL instead: swift run mulisp")
    }
}

#endif
