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

    func registerGraphicsBuiltins() {

        func num(_ v: LispValue) throws -> Double {
            guard let d = v.firstValue.asDouble else {
                throw self.typeError(v, expected: "NUMBER")
            }
            return d
        }

        defBuiltin("CLEAR-GRAPHICS", 0, 0) { [unowned self] _ in
            self.graphics.append(.clear)
            return .null
        }

        defBuiltin("SET-COLOR", 3, 4) { [unowned self] args in
            let a = args.count == 4 ? try num(args[3]) : 1.0
            self.graphics.append(.setColor(LispColor(r: try num(args[0]),
                                                     g: try num(args[1]),
                                                     b: try num(args[2]),
                                                     a: a)))
            return .null
        }

        defBuiltin("SET-LINE-WIDTH", 1, 1) { [unowned self] args in
            self.graphics.append(.setLineWidth(try num(args[0])))
            return .null
        }

        defBuiltin("DRAW-LINE", 4, 4) { [unowned self] args in
            self.graphics.append(.line(x1: try num(args[0]),
                                       y1: try num(args[1]),
                                       x2: try num(args[2]),
                                       y2: try num(args[3])))
            return .null
        }

        defBuiltin("DRAW-RECT", 4, 5) { [unowned self] args in
            let fill = args.count == 5 && args[4].isTrue
            self.graphics.append(.rect(x: try num(args[0]),
                                       y: try num(args[1]),
                                       w: try num(args[2]),
                                       h: try num(args[3]),
                                       fill: fill))
            return .null
        }

        defBuiltin("DRAW-CIRCLE", 3, 4) { [unowned self] args in
            let fill = args.count == 4 && args[3].isTrue
            self.graphics.append(.circle(x: try num(args[0]),
                                         y: try num(args[1]),
                                         r: try num(args[2]),
                                         fill: fill))
            return .null
        }

        defBuiltin("DRAW-TEXT", 3, 4) { [unowned self] args in
            guard case .string(let s) = args[2].firstValue else {
                throw self.typeError(args[2], expected: "STRING")
            }
            let size = args.count == 4 ? try num(args[3]) : 14.0
            self.graphics.append(.text(x: try num(args[0]),
                                       y: try num(args[1]),
                                       string: s.string, size: size))
            return .null
        }

        defBuiltin("DRAW-POINT", 2, 2) { [unowned self] args in
            self.graphics.append(.point(x: try num(args[0]),
                                        y: try num(args[1])))
            return .null
        }

        defBuiltin("CANVAS-SIZE", 0, 0) { [unowned self] _ in
            return .values([.double(self.graphics.canvasWidth),
                            .double(self.graphics.canvasHeight)])
        }
    }
}
