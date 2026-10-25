// Printer.swift
// Printing Lisp values (PRIN1 / PRINC).

import Foundation
import BigInt

public enum Printer {

    /// Render a value. escape=true corresponds to PRIN1, false to PRINC.
    /// `interp` is used to invoke PRINT-OBJECT for CLOS instances; may be nil.
    public static func toString(_ value: LispValue, escape: Bool,
                                interp: Interpreter? = nil) -> String {
        var out = ""
        write(value, escape: escape, interp: interp, depth: 0, into: &out)
        return out
    }

    private static let maxDepth = 512
    private static let maxLength = 100_000

    private static func write(_ value: LispValue, escape: Bool,
                              interp: Interpreter?, depth: Int,
                              into out: inout String) {
        if depth > maxDepth {
            out += "#<deep>"
            return
        }
        switch value {
        case .null:
            out += "NIL"
        case .int(let i):
            out += String(i)
        case .bignum(let b):
            out += String(b)
        case .ratio(let r):
            out += "\(r.num)/\(r.den)"
        case .double(let d):
            out += formatDouble(d)
        case .complex(let c):
            out += "#C("
            write(c.re, escape: escape, interp: interp, depth: depth + 1, into: &out)
            out += " "
            write(c.im, escape: escape, interp: interp, depth: depth + 1, into: &out)
            out += ")"
        case .string(let s):
            if escape {
                out += "\""
                for c in s.chars {
                    if c == "\"" || c == "\\" { out += "\\" }
                    out.append(c)
                }
                out += "\""
            } else {
                out += s.string
            }
        case .character(let c):
            if escape {
                out += characterName(c)
            } else {
                out.append(c)
            }
        case .symbol(let s):
            out += symbolName(s)
        case .cons(let c):
            writeCons(c, escape: escape, interp: interp, depth: depth, into: &out)
        case .vector(let v):
            if v.rank != 1 {
                out += "#\(v.rank)A"
                writeArraySlice(v, dim: 0, offset: 0, escape: escape,
                                interp: interp, depth: depth, into: &out)
            } else {
                out += "#("
                for (i, e) in v.activeElements.enumerated() {
                    if i > 0 { out += " " }
                    write(e, escape: escape, interp: interp,
                          depth: depth + 1, into: &out)
                }
                out += ")"
            }
        case .hashTable(let h):
            out += "#<HASH-TABLE :COUNT \(h.count)>"
        case .function(let f):
            if f is GenericFunction {
                out += "#<GENERIC-FUNCTION \(f.name)>"
            } else if f is Builtin {
                out += "#<BUILTIN-FUNCTION \(f.name)>"
            } else {
                out += "#<FUNCTION \(f.name)>"
            }
        case .instance(let inst):
            if let interp = interp {
                out += interp.printInstance(inst, escape: escape)
            } else {
                out += "#<\(inst.clazz.name.name)>"
            }
        case .lispClass(let cls):
            out += "#<CLASS \(cls.name.name)>"
        case .package(let p):
            out += "#<PACKAGE \(p.name)>"
        case .blockToken(let t):
            out += "#<BLOCK \(t.name)>"
        case .stream(let s):
            out += "#<STREAM \(s.kind)>"
        case .graphicsWindow(let w):
            out += "#<GRAPHICS-WINDOW \"\(w.title)\"\(w.isClosed ? " closed" : "")>"
        case .values(let vs):
            if vs.isEmpty {
                out += "#<no values>"
            } else {
                for (i, v) in vs.enumerated() {
                    if i > 0 { out += " ; " }
                    write(v, escape: escape, interp: interp, depth: depth + 1, into: &out)
                }
            }
        }
    }

    private static func writeArraySlice(_ v: LispVector, dim: Int, offset: Int,
                                        escape: Bool, interp: Interpreter?,
                                        depth: Int, into out: inout String) {
        if dim == v.dimensions.count {
            write(v.elements[offset], escape: escape, interp: interp,
                  depth: depth + 1, into: &out)
            return
        }
        let stride = v.dimensions[(dim + 1)...].reduce(1, *)
        out += "("
        for i in 0..<v.dimensions[dim] {
            if i > 0 { out += " " }
            writeArraySlice(v, dim: dim + 1, offset: offset + i * stride,
                            escape: escape, interp: interp, depth: depth,
                            into: &out)
        }
        out += ")"
    }

    public static func formatDouble(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d > 0 ? "+Inf" : "-Inf" }
        if d == d.rounded() && abs(d) < 1e15 {
            // Print whole doubles as "123.0"
            return String(format: "%.1f", d)
        }
        return "\(d)"
    }

    private static func characterName(_ c: Character) -> String {
        switch c {
        case " ": return "#\\Space"
        case "\n": return "#\\Newline"
        case "\t": return "#\\Tab"
        case "\r": return "#\\Return"
        default: return "#\\\(c)"
        }
    }

    private static func symbolName(_ s: Symbol) -> String {
        if s.isKeyword {
            return ":\(s.name)"
        }
        if s.package == nil {
            return "#:\(s.name)"
        }
        return s.name
    }

    private static func writeCons(_ cons: Cons, escape: Bool,
                                  interp: Interpreter?, depth: Int,
                                  into out: inout String) {
        // Abbreviate (QUOTE x) as 'x etc.
        if case .symbol(let head) = cons.car,
           head.package?.name == "COMMON-LISP",
           case .cons(let rest) = cons.cdr,
           rest.cdr.isNil {
            let abbrev: String?
            switch head.name {
            case "QUOTE": abbrev = "'"
            case "QUASIQUOTE": abbrev = "`"
            case "UNQUOTE": abbrev = ","
            case "UNQUOTE-SPLICING": abbrev = ",@"
            case "FUNCTION": abbrev = "#'"
            default: abbrev = nil
            }
            if let a = abbrev {
                out += a
                write(rest.car, escape: escape, interp: interp,
                      depth: depth + 1, into: &out)
                return
            }
        }

        out += "("
        var cur: LispValue = .cons(cons)
        var count = 0
        while true {
            switch cur {
            case .cons(let c):
                if count > 0 { out += " " }
                if count >= maxLength {
                    out += "..."
                    out += ")"
                    return
                }
                write(c.car, escape: escape, interp: interp,
                      depth: depth + 1, into: &out)
                cur = c.cdr
                count += 1
            case .null:
                out += ")"
                return
            default:
                out += " . "
                write(cur, escape: escape, interp: interp,
                      depth: depth + 1, into: &out)
                out += ")"
                return
            }
        }
    }
}
