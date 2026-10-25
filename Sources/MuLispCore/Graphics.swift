// Graphics.swift
// Platform-independent drawing model. The GUI renders DrawCommands with
// SwiftUI; the CLI can export them as SVG.

import Foundation

public struct LispColor {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1.0) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }
}

public enum DrawCommand {
    case clear
    case setColor(LispColor)
    case setLineWidth(Double)
    case line(x1: Double, y1: Double, x2: Double, y2: Double)
    case rect(x: Double, y: Double, w: Double, h: Double, fill: Bool)
    case circle(x: Double, y: Double, r: Double, fill: Bool)
    case text(x: Double, y: Double, string: String, size: Double)
    case point(x: Double, y: Double)
}

public protocol GraphicsSink: AnyObject {
    /// Called whenever new commands were appended (or the canvas was cleared).
    func graphicsDidUpdate(_ context: GraphicsContext2D)
}

/// Holds the current command list for one interpreter.
public final class GraphicsContext2D {
    public private(set) var commands: [DrawCommand] = []
    public weak var sink: GraphicsSink?
    public var canvasWidth: Double = 600
    public var canvasHeight: Double = 600
    private let lock = NSLock()

    public init() {}

    public func append(_ cmd: DrawCommand) {
        lock.lock()
        if case .clear = cmd {
            commands.removeAll()
        } else {
            commands.append(cmd)
        }
        lock.unlock()
        sink?.graphicsDidUpdate(self)
    }

    public func snapshot() -> [DrawCommand] {
        lock.lock()
        defer { lock.unlock() }
        return commands
    }

    // MARK: - SVG export

    public func renderSVG() -> String {
        var body = ""
        var color = LispColor(r: 0, g: 0, b: 0)
        var lineWidth = 1.0

        func rgba(_ c: LispColor) -> String {
            let r = Int(max(0, min(1, c.r)) * 255)
            let g = Int(max(0, min(1, c.g)) * 255)
            let b = Int(max(0, min(1, c.b)) * 255)
            return "rgba(\(r),\(g),\(b),\(c.a))"
        }

        for cmd in snapshot() {
            switch cmd {
            case .clear:
                body = ""
            case .setColor(let c):
                color = c
            case .setLineWidth(let w):
                lineWidth = w
            case .line(let x1, let y1, let x2, let y2):
                body += "<line x1=\"\(x1)\" y1=\"\(y1)\" x2=\"\(x2)\" y2=\"\(y2)\" "
                body += "stroke=\"\(rgba(color))\" stroke-width=\"\(lineWidth)\"/>\n"
            case .rect(let x, let y, let w, let h, let fill):
                body += "<rect x=\"\(x)\" y=\"\(y)\" width=\"\(w)\" height=\"\(h)\" "
                if fill {
                    body += "fill=\"\(rgba(color))\"/>\n"
                } else {
                    body += "fill=\"none\" stroke=\"\(rgba(color))\" "
                    body += "stroke-width=\"\(lineWidth)\"/>\n"
                }
            case .circle(let x, let y, let r, let fill):
                body += "<circle cx=\"\(x)\" cy=\"\(y)\" r=\"\(r)\" "
                if fill {
                    body += "fill=\"\(rgba(color))\"/>\n"
                } else {
                    body += "fill=\"none\" stroke=\"\(rgba(color))\" "
                    body += "stroke-width=\"\(lineWidth)\"/>\n"
                }
            case .text(let x, let y, let s, let size):
                let escaped = s
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                body += "<text x=\"\(x)\" y=\"\(y)\" font-size=\"\(size)\" "
                body += "fill=\"\(rgba(color))\">\(escaped)</text>\n"
            case .point(let x, let y):
                body += "<circle cx=\"\(x)\" cy=\"\(y)\" r=\"\(max(0.5, lineWidth / 2))\" "
                body += "fill=\"\(rgba(color))\"/>\n"
            }
        }
        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(canvasWidth)" \
        height="\(canvasHeight)" viewBox="0 0 \(canvasWidth) \(canvasHeight)">
        \(body)</svg>
        """
    }
}

extension Interpreter {

    /// Split off an optional leading graphics-window argument and return the
    /// drawing target. All drawing builtins accept (draw-x win args...) or
    /// (draw-x args...), the latter targeting the main canvas.
    func graphicsTarget(_ args: [LispValue])
        throws -> (GraphicsContext2D, [LispValue]) {
        if case .graphicsWindow(let w) = args.first?.firstValue ?? .null {
            if w.isClosed {
                throw lispError("ERROR", "graphics window is closed")
            }
            return (w.context, Array(args.dropFirst()))
        }
        return (graphics, args)
    }

    func registerGraphicsBuiltins() {
        let lisp = registry.lisp

        func num(_ v: LispValue) throws -> Double {
            guard let d = v.firstValue.asDouble else {
                throw self.typeError(v, expected: "NUMBER")
            }
            return d
        }

        defBuiltin("MAKE-GRAPHICS-WINDOW", 0, nil) { [unowned self] args in
            let keys = try self.parseKeys(args, from: 0)
            var title = "Graphics"
            if case .string(let s)? = keys["TITLE"]?.firstValue {
                title = s.string
            }
            let width = keys["WIDTH"]?.asDouble ?? 400
            let height = keys["HEIGHT"]?.asDouble ?? 400
            let window = GraphicsWindow(title: title, width: width,
                                        height: height)
            self.graphicsWindows.append(window)
            self.windowOpener?(window)
            return .graphicsWindow(window)
        }

        defBuiltin("CLOSE-GRAPHICS-WINDOW", 1, 1) { [unowned self] args in
            guard case .graphicsWindow(let w) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "GRAPHICS-WINDOW")
            }
            if !w.isClosed {
                w.isClosed = true
                self.graphicsWindows.removeAll { $0 === w }
                self.windowCloser?(w)
            }
            return .null
        }

        defBuiltin("GRAPHICS-WINDOW-P", 1, 1) { [unowned self] args in
            if case .graphicsWindow = args[0].firstValue { return self.tValue }
            return .null
        }

        defBuiltin("GRAPHICS-WINDOW-TITLE", 1, 1) { [unowned self] args in
            guard case .graphicsWindow(let w) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "GRAPHICS-WINDOW")
            }
            return .str(w.title)
        }

        defBuiltin("CLEAR-GRAPHICS", 0, 1) { [unowned self] args in
            let (target, _) = try self.graphicsTarget(args)
            target.append(.clear)
            return .null
        }

        defBuiltin("SET-COLOR", 3, 5) { [unowned self] args in
            let (target, a) = try self.graphicsTarget(args)
            guard a.count >= 3 else {
                throw self.lispError("PROGRAM-ERROR", "set-color needs r g b")
            }
            let alpha = a.count >= 4 ? try num(a[3]) : 1.0
            target.append(.setColor(LispColor(r: try num(a[0]),
                                              g: try num(a[1]),
                                              b: try num(a[2]),
                                              a: alpha)))
            return .null
        }

        defBuiltin("SET-LINE-WIDTH", 1, 2) { [unowned self] args in
            let (target, a) = try self.graphicsTarget(args)
            guard a.count == 1 else {
                throw self.lispError("PROGRAM-ERROR",
                                     "set-line-width needs a width")
            }
            target.append(.setLineWidth(try num(a[0])))
            return .null
        }

        defBuiltin("DRAW-LINE", 4, 5) { [unowned self] args in
            let (target, a) = try self.graphicsTarget(args)
            guard a.count == 4 else {
                throw self.lispError("PROGRAM-ERROR",
                                     "draw-line needs x1 y1 x2 y2")
            }
            target.append(.line(x1: try num(a[0]), y1: try num(a[1]),
                                x2: try num(a[2]), y2: try num(a[3])))
            return .null
        }

        defBuiltin("DRAW-RECT", 4, 6) { [unowned self] args in
            let (target, a) = try self.graphicsTarget(args)
            guard a.count >= 4 else {
                throw self.lispError("PROGRAM-ERROR",
                                     "draw-rect needs x y w h")
            }
            let fill = a.count >= 5 && a[4].isTrue
            target.append(.rect(x: try num(a[0]), y: try num(a[1]),
                                w: try num(a[2]), h: try num(a[3]),
                                fill: fill))
            return .null
        }

        defBuiltin("DRAW-CIRCLE", 3, 5) { [unowned self] args in
            let (target, a) = try self.graphicsTarget(args)
            guard a.count >= 3 else {
                throw self.lispError("PROGRAM-ERROR",
                                     "draw-circle needs x y r")
            }
            let fill = a.count >= 4 && a[3].isTrue
            target.append(.circle(x: try num(a[0]), y: try num(a[1]),
                                  r: try num(a[2]), fill: fill))
            return .null
        }

        defBuiltin("DRAW-TEXT", 3, 5) { [unowned self] args in
            let (target, a) = try self.graphicsTarget(args)
            guard a.count >= 3, case .string(let s) = a[2].firstValue else {
                throw self.lispError("PROGRAM-ERROR",
                                     "draw-text needs x y string")
            }
            let size = a.count >= 4 ? try num(a[3]) : 14.0
            target.append(.text(x: try num(a[0]), y: try num(a[1]),
                                string: s.string, size: size))
            return .null
        }

        defBuiltin("DRAW-POINT", 2, 3) { [unowned self] args in
            let (target, a) = try self.graphicsTarget(args)
            guard a.count == 2 else {
                throw self.lispError("PROGRAM-ERROR", "draw-point needs x y")
            }
            target.append(.point(x: try num(a[0]), y: try num(a[1])))
            return .null
        }

        defBuiltin("CANVAS-SIZE", 0, 1) { [unowned self] args in
            let (target, _) = try self.graphicsTarget(args)
            return .values([.double(target.canvasWidth),
                            .double(target.canvasHeight)])
        }

        defBuiltin("SAVE-GRAPHICS-SVG", 1, 2) { [unowned self] args in
            // (save-graphics-svg path [window])
            guard case .string(let path) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "STRING")
            }
            let target: GraphicsContext2D
            if args.count == 2 {
                guard case .graphicsWindow(let w) = args[1].firstValue else {
                    throw self.typeError(args[1], expected: "GRAPHICS-WINDOW")
                }
                target = w.context
            } else {
                target = self.graphics
            }
            do {
                try target.renderSVG().write(toFile: path.string,
                                             atomically: true, encoding: .utf8)
            } catch {
                throw self.lispError("STREAM-ERROR",
                                     "cannot write \(path.string)")
            }
            return self.tValue
        }

        // with-graphics-window helper macro.
        defMacro("WITH-GRAPHICS-WINDOW") { [unowned self] forms in
            guard !forms.isEmpty, let spec = forms[0].asArray(),
                  !spec.isEmpty else {
                throw CompileError("malformed with-graphics-window")
            }
            let v = spec[0]
            let makeCall = LispValue.list(
                [self.sym("MAKE-GRAPHICS-WINDOW")] + spec.dropFirst())
            return self.lst(self.sym("LET"),
                            self.lst(self.lst(v, makeCall)),
                            LispValue.list([self.sym("PROGN")]
                                           + forms.dropFirst()),
                            v)
        }
        _ = lisp
    }
}
