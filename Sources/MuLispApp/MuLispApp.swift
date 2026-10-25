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
                .frame(minWidth: 980, minHeight: 620)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
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
