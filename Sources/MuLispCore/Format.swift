// Format.swift
// A practical subset of FORMAT:
//   ~A ~S ~D ~X ~O ~B ~F ~C ~% ~& ~~ ~{ ~} ~^
// with column prefixes (~10A, ~5D) and digit prefixes (~,2F).

import Foundation
import BigInt

extension Interpreter {

    func registerFormat() {
        defBuiltin("FORMAT", 2, nil) { [unowned self] args in
            guard case .string(let control) = args[1].firstValue else {
                throw self.typeError(args[1], expected: "STRING")
            }
            let text = try self.formatToString(control: control.string,
                                               args: Array(args.dropFirst(2)))
            switch args[0].firstValue {
            case .null:
                return .str(text)
            default:
                try self.writeTo(args[0], text)
                return .null
            }
        }
    }

    public func formatToString(control: String,
                               args: [LispValue]) throws -> String {
        var argIndex = 0
        let allArgs = args.map { $0.firstValue }

        struct EndOfIteration: Error {}

        func formatSegment(_ chars: [Character], _ take: () throws -> LispValue,
                           _ hasMore: () -> Bool,
                           _ out: inout String) throws {
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if c != "~" {
                    out.append(c)
                    i += 1
                    continue
                }
                i += 1
                guard i < chars.count else { break }

                // Parse numeric prefixes: ~10A or ~,2F
                var col: Int? = nil
                var digits: Int? = nil
                var numStr = ""
                while i < chars.count, chars[i].isNumber {
                    numStr.append(chars[i])
                    i += 1
                }
                if !numStr.isEmpty { col = Int(numStr) }
                if i < chars.count, chars[i] == "," {
                    i += 1
                    var dStr = ""
                    while i < chars.count, chars[i].isNumber {
                        dStr.append(chars[i])
                        i += 1
                    }
                    if !dStr.isEmpty { digits = Int(dStr) }
                }
                guard i < chars.count else { break }
                let directive = Character(String(chars[i]).uppercased())
                i += 1

                switch directive {
                case "A", "S":
                    let v = try take()
                    var s = Printer.toString(v, escape: directive == "S",
                                             interp: self)
                    if let c = col, s.count < c {
                        s += String(repeating: " ", count: c - s.count)
                    }
                    out += s
                case "D", "X", "O", "B":
                    let v = try take()
                    var s: String
                    switch v {
                    case .int(let n):
                        switch directive {
                        case "X": s = String(n, radix: 16).uppercased()
                        case "O": s = String(n, radix: 8)
                        case "B": s = String(n, radix: 2)
                        default: s = String(n)
                        }
                    case .bignum(let n):
                        switch directive {
                        case "X": s = String(n, radix: 16).uppercased()
                        case "O": s = String(n, radix: 8)
                        case "B": s = String(n, radix: 2)
                        default: s = String(n)
                        }
                    default:
                        s = Printer.toString(v, escape: false, interp: self)
                    }
                    if let c = col, s.count < c {
                        s = String(repeating: " ", count: c - s.count) + s
                    }
                    out += s
                case "F":
                    let v = try take()
                    guard let d = v.asDouble else {
                        throw lispError("ERROR", "~F needs a number")
                    }
                    var s = String(format: "%.\(digits ?? 6)f", d)
                    if let c = col, s.count < c {
                        s = String(repeating: " ", count: c - s.count) + s
                    }
                    out += s
                case "C":
                    let v = try take()
                    if case .character(let ch) = v {
                        out.append(ch)
                    } else {
                        out += Printer.toString(v, escape: false, interp: self)
                    }
                case "%":
                    out += String(repeating: "\n", count: col ?? 1)
                case "&":
                    if !out.isEmpty && !out.hasSuffix("\n") {
                        out += "\n"
                    }
                case "~":
                    out += "~"
                case "^":
                    if !hasMore() {
                        throw EndOfIteration()
                    }
                case "{":
                    // Find the matching ~}
                    var depth = 1
                    var j = i
                    var body: [Character] = []
                    while j < chars.count {
                        if chars[j] == "~", j + 1 < chars.count {
                            if chars[j + 1] == "{" { depth += 1 }
                            if chars[j + 1] == "}" {
                                depth -= 1
                                if depth == 0 { break }
                            }
                        }
                        body.append(chars[j])
                        j += 1
                    }
                    guard depth == 0 else {
                        throw lispError("ERROR", "unmatched ~{ in format string")
                    }
                    i = j + 2   // skip past ~}
                    let listVal = try take()
                    let items = listVal.asArray() ?? []
                    var iterIndex = 0
                    var stopped = false
                    while iterIndex < items.count && !stopped {
                        do {
                            try formatSegment(body, {
                                guard iterIndex < items.count else {
                                    throw EndOfIteration()
                                }
                                let v = items[iterIndex]
                                iterIndex += 1
                                return v
                            }, { iterIndex < items.count }, &out)
                        } catch is EndOfIteration {
                            stopped = true
                        }
                    }
                case "}":
                    throw lispError("ERROR", "unmatched ~} in format string")
                default:
                    throw lispError("ERROR",
                        "unsupported format directive ~\(directive)")
                }
            }
        }

        var result = ""
        do {
            try formatSegment(Array(control), {
                guard argIndex < allArgs.count else {
                    throw self.lispError("ERROR",
                        "not enough arguments for format string")
                }
                let v = allArgs[argIndex]
                argIndex += 1
                return v
            }, { argIndex < allArgs.count }, &result)
        } catch is EndOfIteration {
            // ~^ at top level: stop formatting, keep what we have.
        }
        return result
    }
}
