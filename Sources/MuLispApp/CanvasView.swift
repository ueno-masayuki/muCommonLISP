// CanvasView.swift
// Renders a DrawCommand list with SwiftUI Canvas. Used by the graphics
// windows (both the automatic main canvas window and make-graphics-window).

#if os(macOS)

import SwiftUI
import MuLispCore

enum CanvasRenderer {
    static func render(_ commands: [DrawCommand],
                       context: inout GraphicsContext, size: CGSize) {
        var color = Color.black
        var lineWidth = 1.0

        for cmd in commands {
            switch cmd {
            case .clear:
                break   // the command list is already cleared upstream
            case .setColor(let c):
                color = Color(red: c.r, green: c.g, blue: c.b, opacity: c.a)
            case .setLineWidth(let w):
                lineWidth = w
            case .line(let x1, let y1, let x2, let y2):
                var path = Path()
                path.move(to: CGPoint(x: x1, y: y1))
                path.addLine(to: CGPoint(x: x2, y: y2))
                context.stroke(path, with: .color(color),
                               lineWidth: lineWidth)
            case .rect(let x, let y, let w, let h, let fill):
                let rect = CGRect(x: x, y: y, width: w, height: h)
                if fill {
                    context.fill(Path(rect), with: .color(color))
                } else {
                    context.stroke(Path(rect), with: .color(color),
                                   lineWidth: lineWidth)
                }
            case .circle(let x, let y, let r, let fill):
                let rect = CGRect(x: x - r, y: y - r,
                                  width: r * 2, height: r * 2)
                if fill {
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                } else {
                    context.stroke(Path(ellipseIn: rect), with: .color(color),
                                   lineWidth: lineWidth)
                }
            case .text(let x, let y, let string, let fontSize):
                let text = Text(string)
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundColor(color)
                context.draw(text, at: CGPoint(x: x, y: y), anchor: .topLeading)
            case .point(let x, let y):
                let r = max(0.75, lineWidth / 2)
                let rect = CGRect(x: x - r, y: y - r,
                                  width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
        }
    }
}

#endif
