// Printer.swift
// Printing Lisp values (PRIN1 / PRINC).

import Foundation

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
        case .double(let d):
            out += formatDouble(d)
        case .string(let s):
            if escape {
                out += "\""
                for c in s {
                    if c == "\"" || c == "\\" { out += "\\" }
                    out.append(c)
                }
                out += "\""
            } else {
                out += s
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
            out += "#("
            for (i, e) in v.elements.enumerated() {
                if i > 0 { out += " " }
                write(e, escape: escape, interp: interp, depth: depth + 1, into: &out)
            }
            out += ")"
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
        case .stream:
            out += "#<STREAM>"
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
