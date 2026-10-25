// Format.swift
// FORMAT with a broad directive set:
//   ~A ~S ~D ~B ~O ~X ~R ~F ~E ~G ~$ ~C ~P ~T ~% ~& ~| ~~ ~* ~?
//   ~{ ~} ~[ ~; ~] ~( ~) ~^  with numeric/char parameters and :/@ modifiers.

import Foundation
import BigInt

private struct FormatStop: Error {}        // ~^

private final class FormatState {
    var args: [LispValue]
    var index = 0
    init(_ args: [LispValue]) { self.args = args }

    var hasMore: Bool { return index < args.count }

    func take() throws -> LispValue {
        guard index < args.count else {
            throw FormatArgsExhausted()
        }
        let v = args[index]
        index += 1
        return v
    }

    func peekPrevious() -> LispValue? {
        guard index >= 2 else { return index == 1 ? args[0] : nil }
        return args[index - 2]
    }
}

private struct FormatArgsExhausted: Error {}

private struct Directive {
    var params: [Int?] = []
    var colon = false
    var atSign = false
    var char: Character = " "

    func param(_ i: Int) -> Int? {
        return i < params.count ? params[i] : nil
    }
}

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
        let state = FormatState(args.map { $0.firstValue })
        var out = ""
        do {
            try formatRun(Array(control), state, &out)
        } catch is FormatStop {
            // ~^ at top level: stop, keep output.
        } catch is FormatArgsExhausted {
            throw lispError("ERROR", "not enough arguments for format string")
        }
        return out
    }

    // MARK: - Directive scanning

    private func parseDirective(_ chars: [Character], _ i: inout Int,
                                _ state: FormatState) throws -> Directive {
        var d = Directive()
        // Parameters: integers, 'c, v, # separated by commas.
        var expectingParam = true
        while i < chars.count {
            let c = chars[i]
            if expectingParam {
                if c.isNumber || c == "-" {
                    var numStr = String(c)
                    i += 1
                    while i < chars.count, chars[i].isNumber {
                        numStr.append(chars[i])
                        i += 1
                    }
                    d.params.append(Int(numStr))
                    expectingParam = false
                    continue
                }
                if c == "'" && i + 1 < chars.count {
                    // Character parameter: store its scalar value.
                    d.params.append(Int(chars[i + 1].unicodeScalars.first!.value))
                    i += 2
                    expectingParam = false
                    continue
                }
                if c == "v" || c == "V" {
                    let v = try state.take()
                    d.params.append(v.asInt)
                    i += 1
                    expectingParam = false
                    continue
                }
                if c == "#" {
                    d.params.append(state.args.count - state.index)
                    i += 1
                    expectingParam = false
                    continue
                }
            }
            if c == "," {
                if expectingParam {
                    d.params.append(nil)
                }
                i += 1
                expectingParam = true
                continue
            }
            break
        }
        // Modifiers.
        while i < chars.count {
            if chars[i] == ":" {
                d.colon = true
                i += 1
            } else if chars[i] == "@" {
                d.atSign = true
                i += 1
            } else {
                break
            }
        }
        guard i < chars.count else {
            throw lispError("ERROR", "format string ends inside a directive")
        }
        d.char = Character(String(chars[i]).uppercased())
        i += 1
        return d
    }

    /// Find the matching closer for a paired directive, honoring nesting.
    /// Returns (body segments split at top-level ~;, index after closer).
    private func scanPaired(_ chars: [Character], from: Int,
                            open: Character, close: Character)
        throws -> (segments: [[Character]], separatorColons: [Bool], after: Int) {
        var depth = 1
        var i = from
        var segments: [[Character]] = [[]]
        var separatorColons: [Bool] = []
        while i < chars.count {
            if chars[i] == "~" {
                // Scan past params/modifiers to the directive character.
                var j = i + 1
                while j < chars.count,
                      chars[j].isNumber || chars[j] == "," || chars[j] == ":"
                      || chars[j] == "@" || chars[j] == "-" || chars[j] == "'"
                      || chars[j] == "v" || chars[j] == "V" || chars[j] == "#" {
                    if chars[j] == "'" { j += 1 }
                    j += 1
                }
                if j < chars.count {
                    let dc = Character(String(chars[j]).uppercased())
                    if dc == open { depth += 1 }
                    if dc == close {
                        depth -= 1
                        if depth == 0 {
                            return (segments, separatorColons, j + 1)
                        }
                    }
                    if dc == ";" && depth == 1 {
                        separatorColons.append(chars[(i + 1)..<j].contains(":"))
                        segments.append([])
                        i = j + 1
                        continue
                    }
                }
                // Copy the whole directive into the current segment.
                let end = min(j + 1, chars.count)
                segments[segments.count - 1].append(contentsOf: chars[i..<end])
                i = end
                continue
            }
            segments[segments.count - 1].append(chars[i])
            i += 1
        }
        throw lispError("ERROR", "unmatched ~\(open) in format string")
    }

    private func currentColumn(_ out: String) -> Int {
        if let idx = out.lastIndex(of: "\n") {
            return out.distance(from: out.index(after: idx), to: out.endIndex)
        }
        return out.count
    }

    private func pad(_ s: String, to width: Int?, padChar: Int?,
                     left: Bool) -> String {
        guard let w = width, s.count < w else { return s }
        let padCharacter = padChar.flatMap { Unicode.Scalar($0) }
            .map { Character($0) } ?? " "
        let padding = String(repeating: padCharacter, count: w - s.count)
        return left ? padding + s : s + padding
    }

    // MARK: - Main loop

    private func formatRun(_ chars: [Character], _ state: FormatState,
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
            // ~<newline>: line continuation.
            if i < chars.count, chars[i] == "\n" {
                i += 1
                while i < chars.count, chars[i] == " " || chars[i] == "\t" {
                    i += 1
                }
                continue
            }
            let d = try parseDirective(chars, &i, state)
            try applyDirective(d, chars, &i, state, &out)
        }
    }

    private func applyDirective(_ d: Directive, _ chars: [Character],
                                _ i: inout Int, _ state: FormatState,
                                _ out: inout String) throws {
        switch d.char {
        case "A", "S":
            let v = try state.take()
            let s = Printer.toString(v, escape: d.char == "S", interp: self)
            out += pad(s, to: d.param(0), padChar: d.param(3), left: d.atSign)

        case "D", "B", "O", "X":
            let radix: Int
            switch d.char {
            case "B": radix = 2
            case "O": radix = 8
            case "X": radix = 16
            default: radix = 10
            }
            try formatInteger(radix: radix, d, state, &out,
                              mincolIndex: 0)

        case "R":
            if let radix = d.param(0) {
                var d2 = d
                d2.params = Array(d.params.dropFirst())
                try formatInteger(radix: radix, d2, state, &out, mincolIndex: 0)
            } else {
                let v = try state.take()
                guard let n = v.asInt else {
                    out += Printer.toString(v, escape: false, interp: self)
                    break
                }
                if d.atSign {
                    out += romanNumeral(n)
                } else {
                    out += englishCardinal(n)
                }
            }

        case "F":
            let v = try state.take()
            guard let dv = v.asDouble else {
                out += Printer.toString(v, escape: false, interp: self)
                break
            }
            var s = String(format: "%.\(d.param(1) ?? 6)f", dv)
            if d.atSign && dv >= 0 { s = "+" + s }
            out += pad(s, to: d.param(0), padChar: nil, left: true)

        case "E":
            let v = try state.take()
            guard let dv = v.asDouble else {
                out += Printer.toString(v, escape: false, interp: self)
                break
            }
            out += String(format: "%.\(d.param(1) ?? 6)e", dv)

        case "G":
            let v = try state.take()
            guard let dv = v.asDouble else {
                out += Printer.toString(v, escape: false, interp: self)
                break
            }
            out += String(format: "%g", dv)

        case "$":
            let v = try state.take()
            guard let dv = v.asDouble else {
                out += Printer.toString(v, escape: false, interp: self)
                break
            }
            out += String(format: "%.\(d.param(0) ?? 2)f", dv)

        case "C":
            let v = try state.take()
            if case .character(let ch) = v {
                if d.colon {
                    switch ch {
                    case " ": out += "Space"
                    case "\n": out += "Newline"
                    case "\t": out += "Tab"
                    default: out.append(ch)
                    }
                } else {
                    out.append(ch)
                }
            } else {
                out += Printer.toString(v, escape: false, interp: self)
            }

        case "P":
            let v: LispValue
            if d.colon {
                v = state.peekPrevious() ?? .int(1)
            } else {
                v = try state.take()
            }
            let isOne = (v.asDouble == 1)
            if d.atSign {
                out += isOne ? "y" : "ies"
            } else {
                out += isOne ? "" : "s"
            }

        case "%":
            out += String(repeating: "\n", count: d.param(0) ?? 1)

        case "&":
            if !out.isEmpty && !out.hasSuffix("\n") {
                out += "\n"
            }

        case "|":
            out += "\n"

        case "~":
            out += String(repeating: "~", count: d.param(0) ?? 1)

        case "T":
            let target = d.param(0) ?? 1
            let col = currentColumn(out)
            if col < target {
                out += String(repeating: " ", count: target - col)
            } else {
                out += " "
            }

        case "*":
            let n = d.param(0) ?? 1
            if d.atSign {
                state.index = max(0, min(state.args.count, d.param(0) ?? 0))
            } else if d.colon {
                state.index = max(0, state.index - n)
            } else {
                state.index = min(state.args.count, state.index + n)
            }

        case "?":
            let ctrl = try state.take()
            guard case .string(let controlStr) = ctrl else {
                throw lispError("ERROR", "~? needs a format string argument")
            }
            if d.atSign {
                // Use the current argument list in place.
                try formatRun(Array(controlStr.string), state, &out)
            } else {
                let sub = try state.take()
                let subState = FormatState((sub.asArray() ?? []).map { $0.firstValue })
                do {
                    try formatRun(Array(controlStr.string), subState, &out)
                } catch is FormatStop {}
            }

        case "^":
            if d.colon {
                // Terminate the whole iteration: approximated as plain stop.
                if !state.hasMore { throw FormatStop() }
            } else if !state.hasMore {
                throw FormatStop()
            }

        case "{":
            let (segments, _, after) = try scanPaired(chars, from: i,
                                                      open: "{", close: "}")
            i = after
            let body = segments.flatMap { $0 }
            let maxIterations = d.param(0) ?? Int.max
            if d.atSign {
                // Iterate over the remaining arguments.
                var count = 0
                while state.hasMore && count < maxIterations {
                    do {
                        try formatRun(body, state, &out)
                    } catch is FormatStop {
                        break
                    }
                    count += 1
                }
            } else {
                let listArg = try state.take()
                var items = (listArg.asArray() ?? []).map { $0.firstValue }
                if d.colon {
                    // Each element is itself a list of arguments.
                    var count = 0
                    for element in items {
                        if count >= maxIterations { break }
                        let subState = FormatState(
                            (element.asArray() ?? []).map { $0.firstValue })
                        do {
                            try formatRun(body, subState, &out)
                        } catch is FormatStop {
                            continue
                        }
                        count += 1
                    }
                } else {
                    let subState = FormatState(items)
                    var count = 0
                    while subState.hasMore && count < maxIterations {
                        do {
                            try formatRun(body, subState, &out)
                        } catch is FormatStop {
                            break
                        }
                        count += 1
                    }
                    items = []
                }
            }

        case "[":
            let (segments, colons, after) = try scanPaired(chars, from: i,
                                                           open: "[", close: "]")
            i = after
            if d.colon {
                // ~:[false~;true~]
                let v = try state.take()
                let idx = v.isTrue ? 1 : 0
                if idx < segments.count {
                    try formatRun(segments[idx], state, &out)
                }
            } else if d.atSign {
                // ~@[...~]: when the argument is true it stays available.
                guard state.hasMore else { break }
                let v = state.args[state.index]
                if v.isTrue {
                    try formatRun(segments[0], state, &out)
                } else {
                    state.index += 1
                }
            } else {
                let v = try state.take()
                var idx = d.param(0) ?? (v.asInt ?? -1)
                // An else clause is marked by ~:; before the last segment.
                var elseIndex: Int? = nil
                if let lastColon = colons.lastIndex(of: true) {
                    elseIndex = lastColon + 1
                }
                if idx < 0 || idx >= segments.count {
                    idx = elseIndex ?? -1
                }
                if idx >= 0 && idx < segments.count {
                    try formatRun(segments[idx], state, &out)
                }
            }

        case "(":
            let (segments, _, after) = try scanPaired(chars, from: i,
                                                      open: "(", close: ")")
            i = after
            var inner = ""
            try formatRun(segments.flatMap { $0 }, state, &inner)
            if d.colon && d.atSign {
                out += inner.uppercased()
            } else if d.colon {
                out += inner.capitalized
            } else if d.atSign {
                if let first = inner.first {
                    out += String(first).uppercased() + inner.dropFirst().lowercased()
                }
            } else {
                out += inner.lowercased()
            }

        case ";":
            // Only meaningful inside ~[ / ~<; ignore elsewhere.
            break

        default:
            throw lispError("ERROR",
                "unsupported format directive ~\(d.char)")
        }
    }

    private func formatInteger(radix: Int, _ d: Directive,
                               _ state: FormatState, _ out: inout String,
                               mincolIndex: Int) throws {
        let v = try state.take()
        var s: String
        var negative = false
        switch v {
        case .int(let n):
            negative = n < 0
            s = String(n.magnitude, radix: radix).uppercased()
        case .bignum(let b):
            negative = b < 0
            s = String(b.magnitude, radix: radix).uppercased()
        default:
            out += Printer.toString(v, escape: false, interp: self)
            return
        }
        if d.colon {
            // Comma grouping: ~mincol,padchar,commachar,commaintervalD
            let interval = d.param(mincolIndex + 3) ?? 3
            let commaScalar = d.param(mincolIndex + 2)
            let comma = commaScalar.flatMap { Unicode.Scalar($0) }
                .map { Character($0) } ?? ","
            var grouped = ""
            var count = 0
            for ch in s.reversed() {
                if count > 0 && count % interval == 0 {
                    grouped.append(comma)
                }
                grouped.append(ch)
                count += 1
            }
            s = String(grouped.reversed())
        }
        if negative {
            s = "-" + s
        } else if d.atSign {
            s = "+" + s
        }
        out += pad(s, to: d.param(mincolIndex),
                   padChar: d.param(mincolIndex + 1), left: true)
    }

    private func englishCardinal(_ n: Int) -> String {
        if n == 0 { return "zero" }
        if n < 0 { return "negative " + englishCardinal(-n) }
        let ones = ["", "one", "two", "three", "four", "five", "six", "seven",
                    "eight", "nine", "ten", "eleven", "twelve", "thirteen",
                    "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
                    "nineteen"]
        let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty",
                    "seventy", "eighty", "ninety"]
        func below1000(_ n: Int) -> String {
            var parts: [String] = []
            var n = n
            if n >= 100 {
                parts.append(ones[n / 100] + " hundred")
                n %= 100
            }
            if n >= 20 {
                let t = tens[n / 10]
                let o = n % 10
                parts.append(o > 0 ? "\(t)-\(ones[o])" : t)
            } else if n > 0 {
                parts.append(ones[n])
            }
            return parts.joined(separator: " ")
        }
        var result: [String] = []
        var n = n
        let scales = [(1_000_000_000_000, "trillion"),
                      (1_000_000_000, "billion"),
                      (1_000_000, "million"),
                      (1_000, "thousand")]
        for (value, name) in scales where n >= value {
            result.append(below1000(n / value) + " " + name)
            n %= value
        }
        if n > 0 {
            result.append(below1000(n))
        }
        return result.joined(separator: " ")
    }

    private func romanNumeral(_ n: Int) -> String {
        guard n > 0 && n < 4000 else { return String(n) }
        let table: [(Int, String)] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
            (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
            (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var n = n
        var result = ""
        for (value, numeral) in table {
            while n >= value {
                result += numeral
                n -= value
            }
        }
        return result
    }
}
