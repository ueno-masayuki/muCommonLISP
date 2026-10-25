// GraphicsWindows.swift
// NSWindow-backed graphics windows created from Lisp
// (make-graphics-window / close-graphics-window).

#if os(macOS)

import SwiftUI
import AppKit
import MuLispCore

/// Per-window observable command list.
final class WindowCanvasModel: ObservableObject, GraphicsSink {
    @Published var commands: [DrawCommand] = []
    let context: GraphicsContext2D

    init(context: GraphicsContext2D) {
        self.context = context
        self.commands = context.snapshot()
        context.sink = self
    }

    func graphicsDidUpdate(_ context: GraphicsContext2D) {
        let snapshot = context.snapshot()
        DispatchQueue.main.async {
            self.commands = snapshot
        }
    }
}

struct LispWindowCanvasView: View {
    @ObservedObject var model: WindowCanvasModel

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                CanvasRenderer.render(model.commands, context: &context,
                                      size: size)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: geo.size) { newSize in
                model.context.canvasWidth = Double(newSize.width)
                model.context.canvasHeight = Double(newSize.height)
            }
        }
    }
}

/// Creates and tracks the NSWindows behind Lisp graphics windows.
final class GraphicsWindowManager: NSObject, NSWindowDelegate {
    static let shared = GraphicsWindowManager()

    private var nsWindows: [UUID: NSWindow] = [:]
    private var models: [UUID: WindowCanvasModel] = [:]
    private var lispWindows: [UUID: GraphicsWindow] = [:]

    func open(_ gw: GraphicsWindow) {
        DispatchQueue.main.async {
            if self.nsWindows[gw.id] != nil { return }
            let model = WindowCanvasModel(context: gw.context)
            self.models[gw.id] = model
            self.lispWindows[gw.id] = gw

            let content = NSHostingView(
                rootView: LispWindowCanvasView(model: model))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0,
                                    width: gw.context.canvasWidth,
                                    height: gw.context.canvasHeight),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false)
            window.title = gw.title
            window.contentView = content
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.nsWindows[gw.id] = window
            window.makeKeyAndOrderFront(nil)
        }
    }

    func close(_ gw: GraphicsWindow) {
        DispatchQueue.main.async {
            if let window = self.nsWindows[gw.id] {
                window.delegate = nil
                window.close()
            }
            self.forget(gw.id)
        }
    }

    private func forget(_ id: UUID) {
        nsWindows.removeValue(forKey: id)
        models.removeValue(forKey: id)
        lispWindows.removeValue(forKey: id)
    }

    // User clicked the window's close button.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let (id, gw) = lispWindows.first(where: {
            nsWindows[$0.key] === window
        }).map({ ($0.key, $0.value) }) {
            gw.isClosed = true
            forget(id)
        }
    }
}

#endif
