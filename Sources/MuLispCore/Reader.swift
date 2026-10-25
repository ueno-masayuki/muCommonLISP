// Reader.swift
// The Lisp reader: text -> LispValue forms.

import Foundation
import BigInt

public final class Reader {
    private let chars: [Character]
    private var pos: Int = 0
    private let registry: PackageRegistry
    private let currentPackage: () -> LispPackage
    /// Used by #. (read-time evaluation); nil disables it.
    public var evaluator: ((LispValue) throws -> LispValue)?
    /// User reader macros: returns a handler for a macro character, if any.
    public var macroCharacterHandler: ((Character) -> ((Reader, Character) throws -> LispValue?)?)?

    public init(source: String, registry: PackageRegistry,
                currentPackage: @escaping () -> LispPackage) {
        self.chars = Array(source)
        self.registry = registry
        self.currentPackage = currentPackage
    }

    // MARK: - Character helpers

    private var atEOF: Bool { return pos >= chars.count }

    private func peek() -> Character? {
        return atEOF ? nil : chars[pos]
    }

    private func next() -> Character? {
        if atEOF { return nil }
        let c = chars[pos]
        pos += 1
        return c
    }

    private func isWhitespace(_ c: Character) -> Bool {
        return c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0C}"
    }

    private func isTerminating(_ c: Character) -> Bool {
        return isWhitespace(c) || c == "(" || c == ")" || c == "'" || c == "`"
            || c == "," || c == "\"" || c == ";"
    }

    private func skipWhitespaceAndComments() throws {
        while let c = peek() {
            if isWhitespace(c) {
                pos += 1
            } else if c == ";" {
                while let c2 = peek(), c2 != "\n" { pos += 1 }
            } else if c == "#", pos + 1 < chars.count, chars[pos + 1] == "|" {
                pos += 2
                var depth = 1
                while depth > 0 {
                    guard let c2 = next() else {
                        throw ReaderError("unterminated #| comment", unexpectedEOF: true)
                    }
                    if c2 == "#", peek() == "|" {
                        pos += 1; depth += 1
                    } else if c2 == "|", peek() == "#" {
                        pos += 1; depth -= 1
                    }
                }
            } else {
                return
            }
        }
    }

    // MARK: - Public interface

    /// Read one form; returns nil at end of input.
    public func read() throws -> LispValue? {
        try skipWhitespaceAndComments()
        if atEOF { return nil }
        return try readForm()
    }

    /// Read all remaining forms.
    public func readAll() throws -> [LispValue] {
        var forms: [LispValue] = []
        while let f = try read() {
            forms.append(f)
        }
        return forms
    }

    // MARK: - Form dispatch

    private func readForm() throws -> LispValue {
        try skipWhitespaceAndComments()
        guard let c = peek() else {
            throw ReaderError("unexpected end of input", unexpectedEOF: true)
        }
        switch c {
        case "(":
            pos += 1
            return try readList()
        case ")":
            throw ReaderError("unmatched close parenthesis")
        case "'":
            pos += 1
            let form = try readForm()
            return wrap("QUOTE", form)
        case "`":
            pos += 1
            let form = try readForm()
            return wrap("QUASIQUOTE", form)
        case ",":
            pos += 1
            if peek() == "@" {
                pos += 1
                let form = try readForm()
                return wrap("UNQUOTE-SPLICING", form)
            }
            let form = try readForm()
            return wrap("UNQUOTE", form)
        case "\"":
            pos += 1
            return try readString()
        case "#":
            pos += 1
            return try readDispatch()
        default:
            if let lookup = macroCharacterHandler, let handler = lookup(c) {
                pos += 1
                if let v = try handler(self, c) {
                    return v
                }
                // Handler returned no value: read the next form instead.
                return try readForm()
            }
            return try readAtom()
        }
    }

    /// Public read for user reader-macro functions.
    public func readSubForm() throws -> LispValue {
        return try readForm()
    }

    public func readCharRaw() -> Character? {
        return next()
    }

    public func peekCharRaw() -> Character? {
        return peek()
    }

    private func wrap(_ symbolName: String, _ form: LispValue) -> LispValue {
        let sym = registry.lisp.intern(symbolName)
        return LispValue.list([.symbol(sym), form])
    }

    private func readList() throws -> LispValue {
        var items: [LispValue] = []
        while true {
            try skipWhitespaceAndComments()
            guard let c = peek() else {
                throw ReaderError("unterminated list", unexpectedEOF: true)
            }
            if c == ")" {
                pos += 1
                return LispValue.list(items)
            }
            // Check for consing dot.
            if c == "." {
                let isDot: Bool
                if pos + 1 >= chars.count {
                    isDot = true
                } else {
                    isDot = isTerminating(chars[pos + 1])
                }
                if isDot {
                    if items.isEmpty {
                        throw ReaderError("misplaced dot in list")
                    }
                    pos += 1
                    let tail = try readForm()
                    try skipWhitespaceAndComments()
                    guard peek() == ")" else {
                        throw ReaderError("malformed dotted list",
                                          unexpectedEOF: atEOF)
                    }
                    pos += 1
                    return LispValue.list(items, tail: tail)
                }
            }
            items.append(try readForm())
        }
    }

    private func readString() throws -> LispValue {
        var result = ""
        while true {
            guard let c = next() else {
                throw ReaderError("unterminated string", unexpectedEOF: true)
            }
            if c == "\"" {
                return .str(result)
            }
            if c == "\\" {
                guard let e = next() else {
                    throw ReaderError("unterminated string escape", unexpectedEOF: true)
                }
                switch e {
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append(e)
                }
            } else {
                result.append(c)
            }
        }
    }

    // MARK: - # dispatch

    private func readDispatch() throws -> LispValue {
        // Optional numeric argument, e.g. #2A or #16R.
        var numArg: Int? = nil
        var numStr = ""
        while let d = peek(), d.isNumber {
            numStr.append(d)
            pos += 1
        }
        if !numStr.isEmpty { numArg = Int(numStr) }

        guard let c = next() else {
            throw ReaderError("unexpected end after #", unexpectedEOF: true)
        }
        switch c {
        case "'":
            let form = try readForm()
            return wrap("FUNCTION", form)
        case "\\":
            return try readCharacter()
        case "(":
            let lst = try readList()
            guard let items = lst.asArray() else {
                throw ReaderError("dotted list not allowed in #(...)")
            }
            return .vector(LispVector(items))
        case ":":
            let (token, hadEscape) = try readToken()
            let name = hadEscape ? token : token.uppercased()
            return .symbol(Symbol(name: name, package: nil))
        case "x", "X":
            return try readRadixInteger(radix: 16)
        case "o", "O":
            return try readRadixInteger(radix: 8)
        case "b", "B":
            return try readRadixInteger(radix: 2)
        case "r", "R":
            guard let radix = numArg, radix >= 2, radix <= 36 else {
                throw ReaderError("#R requires a radix between 2 and 36")
            }
            return try readRadixInteger(radix: radix)
        case "c", "C":
            let form = try readForm()
            guard let parts = form.asArray(), parts.count == 2,
                  parts[0].isRealNumber, parts[1].isRealNumber else {
                throw ReaderError("#C requires (realpart imagpart)")
            }
            return NumericOps.makeComplex(parts[0], parts[1])
        case "a", "A":
            let rank = numArg ?? 1
            let contents = try readForm()
            return try buildArrayLiteral(rank: rank, contents: contents)
        case ".":
            let form = try readForm()
            guard let evalFn = evaluator else {
                throw ReaderError("#. is not enabled in this context")
            }
            do {
                return try evalFn(form).firstValue
            } catch let e as ReaderError {
                throw e
            } catch {
                throw ReaderError("#. evaluation failed: \(error)")
            }
        case "+", "-":
            // Feature conditionals: only :MUCL and :MULISP are present.
            let feature = try readForm()
            let present = featurePresent(feature)
            let keep = (c == "+") ? present : !present
            let guarded = try readForm()
            if keep { return guarded }
            return try readForm()   // skip the guarded form, read the following one
        default:
            throw ReaderError("unsupported reader macro #\(c)")
        }
    }

    private func featurePresent(_ feature: LispValue) -> Bool {
        switch feature {
        case .symbol(let s):
            return s.name == "MUCL" || s.name == "MULISP"
        case .cons(let c):
            guard case .symbol(let op) = c.car,
                  let rest = c.cdr.asArray() else { return false }
            switch op.name {
            case "AND": return rest.allSatisfy { featurePresent($0) }
            case "OR": return rest.contains { featurePresent($0) }
            case "NOT": return !(rest.first.map { featurePresent($0) } ?? false)
            default: return false
            }
        default:
            return false
        }
    }

    private func buildArrayLiteral(rank: Int, contents: LispValue) throws -> LispValue {
        if rank == 1 {
            guard let items = contents.asArray() else {
                throw ReaderError("malformed #A contents")
            }
            return .vector(LispVector(items))
        }
        // Determine dimensions from nesting, then flatten row-major.
        var dims: [Int] = []
        var probe = contents
        for _ in 0..<rank {
            guard let items = probe.asArray() else {
                throw ReaderError("malformed #\(rank)A contents")
            }
            dims.append(items.count)
            probe = items.first ?? .null
        }
        var flat: [LispValue] = []
        func flatten(_ v: LispValue, _ depth: Int) throws {
            if depth == rank {
                flat.append(v)
                return
            }
            guard let items = v.asArray(), items.count == dims[depth] else {
                throw ReaderError("ragged #\(rank)A contents")
            }
            for item in items {
                try flatten(item, depth + 1)
            }
        }
        try flatten(contents, 0)
        let vec = LispVector(dimensions: dims, initial: .null)
        vec.elements = flat
        return .vector(vec)
    }

    private func readRadixInteger(radix: Int) throws -> LispValue {
        let (token, _) = try readToken()
        guard let v = Int(token, radix: radix) else {
            throw ReaderError("invalid radix-\(radix) integer: \(token)")
        }
        return .int(v)
    }

    private func readCharacter() throws -> LispValue {
        guard let first = next() else {
            throw ReaderError("unexpected end after #\\", unexpectedEOF: true)
        }
        // Possibly a named character: letters follow.
        if first.isLetter {
            var name = String(first)
            while let c = peek(), c.isLetter || c.isNumber || c == "-" {
                name.append(c)
                pos += 1
            }
            if name.count == 1 {
                return .character(first)
            }
            switch name.uppercased() {
            case "SPACE": return .character(" ")
            case "NEWLINE", "LINEFEED": return .character("\n")
            case "TAB": return .character("\t")
            case "RETURN": return .character("\r")
            case "PAGE": return .character("\u{0C}")
            case "NULL", "NUL": return .character("\u{00}")
            case "BACKSPACE": return .character("\u{08}")
            case "RUBOUT", "DELETE": return .character("\u{7F}")
            default:
                throw ReaderError("unknown character name: #\\\(name)")
            }
        }
        return .character(first)
    }

    // MARK: - Atoms

    /// Read a raw token. Returns (text, hadEscape). Escaped characters keep
    /// their case; colons inside escapes are recorded via the escapedColons
    /// output used by readAtom through readTokenDetailed.
    private func readToken() throws -> (String, Bool) {
        let (parts, hadEscape) = try readTokenDetailed()
        return (String(parts.map { $0.0 }), hadEscape)
    }

    /// Returns ([(char, wasEscaped)], hadAnyEscape).
    private func readTokenDetailed() throws -> ([(Character, Bool)], Bool) {
        var parts: [(Character, Bool)] = []
        var hadEscape = false
        while let c = peek() {
            if isTerminating(c) { break }
            if c == "\\" {
                pos += 1
                guard let e = next() else {
                    throw ReaderError("unterminated \\ escape", unexpectedEOF: true)
                }
                parts.append((e, true))
                hadEscape = true
            } else if c == "|" {
                pos += 1
                hadEscape = true
                while true {
                    guard let e = next() else {
                        throw ReaderError("unterminated | escape", unexpectedEOF: true)
                    }
                    if e == "|" { break }
                    parts.append((e, true))
                }
            } else {
                pos += 1
                parts.append((c, false))
            }
        }
        if parts.isEmpty && !hadEscape {
            throw ReaderError("empty token")
        }
        return (parts, hadEscape)
    }

    private enum NumberClass {
        case integer   // 123, -7, 123.
        case float     // 1.5, .5, 1e5, 1.5e-3
        case ratio     // 1/2 (unsupported, but recognized to give a clear error)
        case notANumber
    }

    /// Strict Common Lisp number-token recognition. Tokens like 1+ and 1-
    /// are NOT numbers; they fall through and become symbols.
    private func classifyNumber(_ s: String) -> NumberClass {
        let arr = Array(s)
        var i = 0
        func isDigit(_ c: Character) -> Bool { return c.isASCII && c.isNumber }

        if i < arr.count, arr[i] == "+" || arr[i] == "-" {
            i += 1
        }
        var intDigits = 0
        while i < arr.count, isDigit(arr[i]) {
            i += 1
            intDigits += 1
        }

        // Ratio: digits/digits
        if i < arr.count, arr[i] == "/" {
            i += 1
            var denomDigits = 0
            while i < arr.count, isDigit(arr[i]) {
                i += 1
                denomDigits += 1
            }
            if intDigits > 0 && denomDigits > 0 && i == arr.count {
                return .ratio
            }
            return .notANumber
        }

        var isFloat = false
        if i < arr.count, arr[i] == "." {
            i += 1
            var fracDigits = 0
            while i < arr.count, isDigit(arr[i]) {
                i += 1
                fracDigits += 1
            }
            if fracDigits > 0 {
                isFloat = true
            } else {
                // "123." is an integer; anything else with a bare dot is not
                // a number.
                if intDigits > 0 && i == arr.count {
                    return .integer
                }
                return .notANumber
            }
        }

        if intDigits == 0 && !isFloat {
            return .notANumber
        }

        if i < arr.count, arr[i] == "e" || arr[i] == "E" {
            i += 1
            if i < arr.count, arr[i] == "+" || arr[i] == "-" {
                i += 1
            }
            var expDigits = 0
            while i < arr.count, isDigit(arr[i]) {
                i += 1
                expDigits += 1
            }
            if expDigits == 0 { return .notANumber }
            isFloat = true
        }

        guard i == arr.count else { return .notANumber }
        return isFloat ? .float : .integer
    }

    private func readAtom() throws -> LispValue {
        let (parts, hadEscape) = try readTokenDetailed()
        let raw = String(parts.map { $0.0 })

        if !hadEscape {
            switch classifyNumber(raw) {
            case .integer:
                var t = raw
                if t.hasSuffix(".") { t = String(t.dropLast()) }
                if let i = Int(t) {
                    return .int(i)
                }
                if let b = BigInt(t) {
                    return NumericOps.makeInteger(b)
                }
                throw ReaderError("invalid number syntax: \(raw)")
            case .float:
                if let d = Double(raw) {
                    return .double(d)
                }
                throw ReaderError("invalid number syntax: \(raw)")
            case .ratio:
                let parts = raw.split(separator: "/")
                guard parts.count == 2,
                      let num = BigInt(String(parts[0])),
                      let den = BigInt(String(parts[1])) else {
                    throw ReaderError("invalid ratio syntax: \(raw)")
                }
                do {
                    return try NumericOps.makeRational(num, den)
                } catch {
                    throw ReaderError("division by zero in ratio: \(raw)")
                }
            case .notANumber:
                break
            }
        }

        // Normalize case: unescaped characters are upcased.
        var normalized = ""
        for (c, escaped) in parts {
            normalized.append(escaped ? c : Character(String(c).uppercased()))
        }

        // Package prefix handling on unescaped colons.
        var colonPositions: [Int] = []
        for (i, (c, escaped)) in parts.enumerated() where c == ":" && !escaped {
            colonPositions.append(i)
        }

        if colonPositions.isEmpty {
            if !hadEscape {
                if normalized == "NIL" { return .null }
                if normalized == "T" {
                    return .symbol(registry.lisp.intern("T"))
                }
            }
            return .symbol(currentPackage().intern(normalized))
        }

        let normArray = Array(normalized)
        if colonPositions[0] == 0 {
            // :keyword (also handles ::keyword leniently)
            var start = 1
            if colonPositions.count > 1 && colonPositions[1] == 1 { start = 2 }
            let name = String(normArray[start...])
            if name.isEmpty { throw ReaderError("invalid keyword: \(raw)") }
            return .symbol(registry.keyword.intern(name))
        }

        // pkg:name or pkg::name
        let first = colonPositions[0]
        let pkgName = String(normArray[0..<first])
        var nameStart = first + 1
        if colonPositions.count > 1 && colonPositions[1] == first + 1 {
            nameStart = first + 2
        }
        if nameStart >= normArray.count {
            throw ReaderError("invalid symbol syntax: \(raw)")
        }
        let symName = String(normArray[nameStart...])
        guard let pkg = registry.find(pkgName) else {
            throw ReaderError("no such package: \(pkgName)")
        }
        return .symbol(pkg.intern(symName))
    }
}
