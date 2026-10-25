// Macro.swift
// Quasiquote (backquote) expansion.

import Foundation

public enum QuasiQuote {

    /// Expand (QUASIQUOTE form) templates into LIST / LIST* / APPEND calls.
    public static func expand(_ form: LispValue, lisp: LispPackage) throws -> LispValue {
        return try qq(form, depth: 1, lisp: lisp)
    }

    private static func sym(_ name: String, _ lisp: LispPackage) -> LispValue {
        return .symbol(lisp.intern(name))
    }

    private static func isCall(_ form: LispValue, _ name: String) -> Bool {
        guard let c = form.asCons, case .symbol(let s) = c.car else { return false }
        return s.name == name && s.package?.name == "COMMON-LISP"
    }

    private static func callArg(_ form: LispValue) throws -> LispValue {
        guard let c = form.asCons, let rest = c.cdr.asCons, rest.cdr.isNil else {
            throw CompileError("malformed unquote")
        }
        return rest.car
    }

    private static func quote(_ v: LispValue, _ lisp: LispPackage) -> LispValue {
        return LispValue.list([sym("QUOTE", lisp), v])
    }

    private static func qq(_ form: LispValue, depth: Int,
                           lisp: LispPackage) throws -> LispValue {
        if isCall(form, "UNQUOTE") {
            let inner = try callArg(form)
            if depth == 1 {
                return inner
            }
            return LispValue.list([sym("LIST", lisp),
                                   quote(sym("UNQUOTE", lisp), lisp),
                                   try qq(inner, depth: depth - 1, lisp: lisp)])
        }
        if isCall(form, "UNQUOTE-SPLICING") {
            throw CompileError(",@ not inside a list")
        }
        if isCall(form, "QUASIQUOTE") {
            let inner = try callArg(form)
            return LispValue.list([sym("LIST", lisp),
                                   quote(sym("QUASIQUOTE", lisp), lisp),
                                   try qq(inner, depth: depth + 1, lisp: lisp)])
        }

        switch form {
        case .cons:
            // Walk the (possibly dotted) list.
            var elements: [LispValue] = []
            var tail: LispValue = .null
            var cur = form
            loop: while true {
                switch cur {
                case .cons(let c):
                    if isCall(cur, "UNQUOTE") {
                        // Dotted unquote: (a . ,b)
                        tail = cur
                        break loop
                    }
                    elements.append(c.car)
                    cur = c.cdr
                case .null:
                    tail = .null
                    break loop
                default:
                    tail = cur
                    break loop
                }
            }

            var hasSplice = false
            for e in elements where isCall(e, "UNQUOTE-SPLICING") {
                hasSplice = true
                break
            }

            let tailExpr: LispValue
            if tail.isNil {
                tailExpr = .null
            } else if isCall(tail, "UNQUOTE") {
                tailExpr = depth == 1
                    ? try callArg(tail)
                    : try qq(tail, depth: depth, lisp: lisp)
            } else {
                tailExpr = try qq(tail, depth: depth, lisp: lisp)
            }

            if !hasSplice {
                var parts: [LispValue] = []
                for e in elements {
                    parts.append(try qq(e, depth: depth, lisp: lisp))
                }
                if tailExpr.isNil {
                    return LispValue.list([sym("LIST", lisp)] + parts)
                }
                return LispValue.list([sym("LIST*", lisp)] + parts + [tailExpr])
            }

            // With splices: build an APPEND form.
            var segments: [LispValue] = []
            for e in elements {
                if isCall(e, "UNQUOTE-SPLICING") {
                    if depth == 1 {
                        segments.append(try callArg(e))
                    } else {
                        segments.append(
                            LispValue.list([sym("LIST", lisp),
                                            LispValue.list([sym("LIST", lisp),
                                                            quote(sym("UNQUOTE-SPLICING", lisp), lisp),
                                                            try qq(try callArg(e),
                                                                   depth: depth - 1,
                                                                   lisp: lisp)])]))
                    }
                } else {
                    segments.append(
                        LispValue.list([sym("LIST", lisp),
                                        try qq(e, depth: depth, lisp: lisp)]))
                }
            }
            if !tailExpr.isNil {
                segments.append(tailExpr)
            }
            return LispValue.list([sym("APPEND", lisp)] + segments)

        case .symbol, .null:
            return quote(form, lisp)
        default:
            // Self-evaluating atoms.
            return form
        }
    }
}
