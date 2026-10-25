// BuiltinsString.swift
// Strings, characters, symbols and packages.

import Foundation

extension Interpreter {

    func requireStringDesignator(_ v: LispValue) throws -> String {
        switch v.firstValue {
        case .string(let s): return s.string
        case .symbol(let s): return s.name
        case .character(let c): return String(c)
        case .null: return "NIL"
        default: throw self.typeError(v, expected: "STRING")
        }
    }

    func registerStringBuiltins() {
        let lisp = registry.lisp

        func requireString(_ v: LispValue) throws -> String {
            return try self.requireStringDesignator(v)
        }

        func requireChar(_ v: LispValue) throws -> Character {
            guard case .character(let c) = v.firstValue else {
                throw self.typeError(v, expected: "CHARACTER")
            }
            return c
        }

        // --- Strings ---

        defBuiltin("STRING", 1, 1) { args in .str(try requireString(args[0])) }

        defBuiltin("MAKE-STRING", 1, nil) { [unowned self] args in
            guard case .int(let n) = args[0].firstValue, n >= 0 else {
                throw self.typeError(args[0], expected: "INTEGER")
            }
            let keys = try self.parseKeys(args, from: 1)
            var fill: Character = " "
            if let e = keys["INITIAL-ELEMENT"],
               case .character(let c) = e { fill = c }
            return .string(LispString(chars: [Character](repeating: fill,
                                                         count: n)))
        }

        defBuiltin("STRING-UPCASE", 1, 1) { args in
            .str(try requireString(args[0]).uppercased())
        }
        defBuiltin("STRING-DOWNCASE", 1, 1) { args in
            .str(try requireString(args[0]).lowercased())
        }
        defBuiltin("STRING-CAPITALIZE", 1, 1) { args in
            .str(try requireString(args[0]).capitalized)
        }
        defBuiltin("NSTRING-UPCASE", 1, 1) { [unowned self] args in
            guard case .string(let s) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "STRING")
            }
            s.chars = Array(s.string.uppercased())
            return args[0]
        }
        defBuiltin("NSTRING-DOWNCASE", 1, 1) { [unowned self] args in
            guard case .string(let s) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "STRING")
            }
            s.chars = Array(s.string.lowercased())
            return args[0]
        }

        func stringCompare(_ name: String,
                           _ ok: @escaping (String, String) -> Bool,
                           caseInsensitive: Bool = false) {
            defBuiltin(name, 2, 2) { [unowned self] args in
                var a = try requireString(args[0])
                var b = try requireString(args[1])
                if caseInsensitive {
                    a = a.uppercased()
                    b = b.uppercased()
                }
                return ok(a, b) ? self.tValue : .null
            }
        }
        stringCompare("STRING=") { $0 == $1 }
        stringCompare("STRING/=") { $0 != $1 }
        stringCompare("STRING<") { $0 < $1 }
        stringCompare("STRING>") { $0 > $1 }
        stringCompare("STRING<=") { $0 <= $1 }
        stringCompare("STRING>=") { $0 >= $1 }
        stringCompare("STRING-EQUAL", { $0 == $1 }, caseInsensitive: true)
        stringCompare("STRING-LESSP", { $0 < $1 }, caseInsensitive: true)
        stringCompare("STRING-GREATERP", { $0 > $1 }, caseInsensitive: true)
        stringCompare("STRING-NOT-EQUAL", { $0 != $1 }, caseInsensitive: true)

        defBuiltin("CHAR", 2, 2) { [unowned self] args in
            guard case .string(let s) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "STRING")
            }
            guard case .int(let i) = args[1].firstValue, i >= 0,
                  i < s.chars.count else {
                throw self.lispError("ERROR", "char index out of range")
            }
            return .character(s.chars[i])
        }
        lisp.intern("SCHAR").function = lisp.intern("CHAR").function

        defSetfHandler("CHAR") { [unowned self] args in
            // (newval string index)
            guard case .string(let s) = args[1].firstValue else {
                throw self.typeError(args[1], expected: "STRING")
            }
            guard case .character(let c) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "CHARACTER")
            }
            guard case .int(let i) = args[2].firstValue, i >= 0,
                  i < s.chars.count else {
                throw self.lispError("ERROR", "char index out of range")
            }
            s.chars[i] = c
            return args[0]
        }
        setfHandlers[lisp.intern("SCHAR")] = setfHandlers[lisp.intern("CHAR")]

        func charBag(_ v: LispValue) throws -> Set<Character> {
            switch v.firstValue {
            case .string(let s):
                return Set(s.chars)
            default:
                var set = Set<Character>()
                if let items = v.firstValue.asArray() {
                    for i in items {
                        if case .character(let c) = i { set.insert(c) }
                    }
                }
                return set
            }
        }

        defBuiltin("STRING-TRIM", 2, 2) { args in
            let bag = try charBag(args[0])
            var s = Array(try requireString(args[1]))
            while let f = s.first, bag.contains(f) { s.removeFirst() }
            while let l = s.last, bag.contains(l) { s.removeLast() }
            return .str(String(s))
        }

        defBuiltin("STRING-LEFT-TRIM", 2, 2) { args in
            let bag = try charBag(args[0])
            var s = Array(try requireString(args[1]))
            while let f = s.first, bag.contains(f) { s.removeFirst() }
            return .str(String(s))
        }

        defBuiltin("STRING-RIGHT-TRIM", 2, 2) { args in
            let bag = try charBag(args[0])
            var s = Array(try requireString(args[1]))
            while let l = s.last, bag.contains(l) { s.removeLast() }
            return .str(String(s))
        }

        defBuiltin("PARSE-INTEGER", 1, nil) { [unowned self] args in
            let s = try requireString(args[0]).trimmingCharacters(in: .whitespaces)
            let keys = try self.parseKeys(args, from: 1)
            var radix = 10
            if case .int(let r)? = keys["RADIX"]?.firstValue { radix = r }
            let junkAllowed = (keys["JUNK-ALLOWED"]?.isTrue) ?? false
            if let v = Int(s, radix: radix) {
                return .int(v)
            }
            if junkAllowed { return .null }
            throw self.lispError("PARSE-ERROR", "cannot parse integer: \(s)")
        }

        // --- Characters ---

        defBuiltin("CHAR-CODE", 1, 1) { args in
            let c = try requireChar(args[0])
            return .int(Int(c.unicodeScalars.first!.value))
        }
        lisp.intern("CHAR-INT").function = lisp.intern("CHAR-CODE").function

        defBuiltin("CODE-CHAR", 1, 1) { [unowned self] args in
            guard case .int(let i) = args[0].firstValue,
                  let scalar = Unicode.Scalar(i) else {
                throw self.lispError("ERROR", "invalid character code")
            }
            return .character(Character(scalar))
        }
        defBuiltin("CHAR-UPCASE", 1, 1) { args in
            let c = try requireChar(args[0])
            return .character(Character(String(c).uppercased()))
        }
        defBuiltin("CHAR-DOWNCASE", 1, 1) { args in
            let c = try requireChar(args[0])
            return .character(Character(String(c).lowercased()))
        }
        defBuiltin("CHARACTERP", 1, 1) { [unowned self] args in
            if case .character = args[0].firstValue { return self.tValue }
            return .null
        }
        defBuiltin("CHARACTER", 1, 1) { [unowned self] args in
            switch args[0].firstValue {
            case .character(let c): return .character(c)
            case .string(let s) where s.chars.count == 1:
                return .character(s.chars[0])
            case .symbol(let s) where s.name.count == 1:
                return .character(s.name.first!)
            default:
                throw self.typeError(args[0], expected: "CHARACTER")
            }
        }

        defBuiltin("CHAR-NAME", 1, 1) { args in
            let c = try requireChar(args[0])
            switch c {
            case " ": return .str("Space")
            case "\n": return .str("Newline")
            case "\t": return .str("Tab")
            case "\r": return .str("Return")
            default: return .null
            }
        }

        defBuiltin("NAME-CHAR", 1, 1) { args in
            let name = try requireString(args[0]).uppercased()
            switch name {
            case "SPACE": return .character(" ")
            case "NEWLINE", "LINEFEED": return .character("\n")
            case "TAB": return .character("\t")
            case "RETURN": return .character("\r")
            default: return .null
            }
        }

        func charCompare(_ name: String,
                         _ ok: @escaping (Character, Character) -> Bool) {
            defBuiltin(name, 2, 2) { [unowned self] args in
                return ok(try requireChar(args[0]), try requireChar(args[1]))
                    ? self.tValue : .null
            }
        }
        charCompare("CHAR=") { $0 == $1 }
        charCompare("CHAR/=") { $0 != $1 }
        charCompare("CHAR<") { $0 < $1 }
        charCompare("CHAR>") { $0 > $1 }
        charCompare("CHAR<=") { $0 <= $1 }
        charCompare("CHAR>=") { $0 >= $1 }
        charCompare("CHAR-EQUAL") {
            String($0).uppercased() == String($1).uppercased()
        }
        charCompare("CHAR-LESSP") {
            String($0).uppercased() < String($1).uppercased()
        }
        charCompare("CHAR-GREATERP") {
            String($0).uppercased() > String($1).uppercased()
        }

        defBuiltin("DIGIT-CHAR-P", 1, 2) { args in
            let c = try requireChar(args[0])
            var radix = 10
            if args.count == 2, case .int(let r) = args[1].firstValue { radix = r }
            if let v = c.hexDigitValue, v < radix {
                return .int(v)
            }
            return .null
        }

        defBuiltin("DIGIT-CHAR", 1, 2) { args in
            guard case .int(let w) = args[0].firstValue else { return .null }
            var radix = 10
            if args.count == 2, case .int(let r) = args[1].firstValue { radix = r }
            if w >= 0 && w < radix {
                let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
                return .character(digits[w])
            }
            return .null
        }

        defBuiltin("ALPHA-CHAR-P", 1, 1) { [unowned self] args in
            return try requireChar(args[0]).isLetter ? self.tValue : .null
        }
        defBuiltin("ALPHANUMERICP", 1, 1) { [unowned self] args in
            let c = try requireChar(args[0])
            return (c.isLetter || c.isNumber) ? self.tValue : .null
        }
        defBuiltin("UPPER-CASE-P", 1, 1) { [unowned self] args in
            return try requireChar(args[0]).isUppercase ? self.tValue : .null
        }
        defBuiltin("LOWER-CASE-P", 1, 1) { [unowned self] args in
            return try requireChar(args[0]).isLowercase ? self.tValue : .null
        }
        defBuiltin("BOTH-CASE-P", 1, 1) { [unowned self] args in
            let c = try requireChar(args[0])
            return (c.isUppercase || c.isLowercase) ? self.tValue : .null
        }
        defBuiltin("WHITESPACEP", 1, 1) { [unowned self] args in
            return try requireChar(args[0]).isWhitespace ? self.tValue : .null
        }

        // --- Symbols ---

        defBuiltin("SYMBOL-NAME", 1, 1) { [unowned self] args in
            guard case .symbol(let s) = args[0].firstValue else {
                if args[0].firstValue.isNil { return .str("NIL") }
                throw self.typeError(args[0], expected: "SYMBOL")
            }
            return .str(s.name)
        }

        defBuiltin("SYMBOL-VALUE", 1, 1) { [unowned self] args in
            guard case .symbol(let s) = args[0].firstValue else {
                if args[0].firstValue.isNil { return .null }
                throw self.typeError(args[0], expected: "SYMBOL")
            }
            guard let v = s.value else {
                throw self.lispError("UNBOUND-VARIABLE",
                                     "unbound variable: \(s.name)",
                                     slots: [("NAME", args[0].firstValue)])
            }
            return v
        }

        defSetfHandler("SYMBOL-VALUE") { [unowned self] args in
            guard case .symbol(let s) = args[1].firstValue else {
                throw self.typeError(args[1], expected: "SYMBOL")
            }
            s.value = args[0].firstValue
            return args[0]
        }

        defBuiltin("SET", 2, 2) { [unowned self] args in
            guard case .symbol(let s) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "SYMBOL")
            }
            s.value = args[1].firstValue
            return args[1]
        }

        defBuiltin("SYMBOL-FUNCTION", 1, 1) { [unowned self] args in
            guard case .symbol(let s) = args[0].firstValue,
                  let f = s.function else {
                throw self.lispError("UNDEFINED-FUNCTION", "undefined function")
            }
            return .function(f)
        }
        lisp.intern("FDEFINITION").function =
            lisp.intern("SYMBOL-FUNCTION").function

        defSetfHandler("SYMBOL-FUNCTION") { [unowned self] args in
            guard case .symbol(let s) = args[1].firstValue,
                  let f = args[0].asFunction else {
                throw self.typeError(args[1], expected: "SYMBOL")
            }
            s.function = f
            return args[0]
        }

        defBuiltin("SYMBOL-PLIST", 1, 1) { [unowned self] args in
            guard case .symbol(let s) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "SYMBOL")
            }
            return s.plist
        }

        defBuiltin("SYMBOL-PACKAGE", 1, 1) { [unowned self] args in
            guard case .symbol(let s) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "SYMBOL")
            }
            if let p = s.package { return .package(p) }
            return .null
        }

        defBuiltin("COPY-SYMBOL", 1, 2) { [unowned self] args in
            guard case .symbol(let s) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "SYMBOL")
            }
            let copy = Symbol(name: s.name, package: nil)
            if args.count == 2 && args[1].isTrue {
                copy.value = s.value
                copy.function = s.function
                copy.plist = s.plist
            }
            return .symbol(copy)
        }

        defBuiltin("BOUNDP", 1, 1) { [unowned self] args in
            guard case .symbol(let s) = args[0].firstValue else {
                if args[0].firstValue.isNil { return self.tValue }
                throw self.typeError(args[0], expected: "SYMBOL")
            }
            return s.value != nil ? self.tValue : .null
        }

        defBuiltin("FBOUNDP", 1, 1) { [unowned self] args in
            guard case .symbol(let s) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "SYMBOL")
            }
            return s.function != nil ? self.tValue : .null
        }

        defBuiltin("MAKUNBOUND", 1, 1) { [unowned self] args in
            guard case .symbol(let s) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "SYMBOL")
            }
            s.value = nil
            return args[0]
        }

        defBuiltin("FMAKUNBOUND", 1, 1) { [unowned self] args in
            guard case .symbol(let s) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "SYMBOL")
            }
            s.function = nil
            return args[0]
        }

        defBuiltin("MAKE-SYMBOL", 1, 1) { args in
            return .symbol(Symbol(name: try requireString(args[0]), package: nil))
        }

        defBuiltin("INTERN", 1, 2) { [unowned self] args in
            let name = try requireString(args[0])
            var pkg = self.currentPackage
            if args.count == 2 {
                pkg = try self.resolvePackage(args[1])
            }
            return .symbol(pkg.intern(name))
        }

        defBuiltin("FIND-SYMBOL", 1, 2) { [unowned self] args in
            let name = try requireString(args[0])
            var pkg = self.currentPackage
            if args.count == 2 {
                pkg = try self.resolvePackage(args[1])
            }
            if let s = pkg.symbols[name] {
                let status = pkg.isExternal(name) ? "EXTERNAL" : "INTERNAL"
                return .values([.symbol(s),
                                .symbol(self.registry.keyword.intern(status))])
            }
            for used in pkg.useList {
                if let s = used.symbols[name], used.isExternal(name) || true {
                    return .values([.symbol(s),
                                    .symbol(self.registry.keyword.intern("INHERITED"))])
                }
            }
            return .values([.null, .null])
        }

        defBuiltin("SYMBOLP", 1, 1) { [unowned self] args in
            switch args[0].firstValue {
            case .symbol, .null: return self.tValue
            default: return .null
            }
        }

        defBuiltin("KEYWORDP", 1, 1) { [unowned self] args in
            if case .symbol(let s) = args[0].firstValue, s.isKeyword {
                return self.tValue
            }
            return .null
        }

        defBuiltin("SPECIAL-OPERATOR-P", 1, 1) { [unowned self] args in
            guard case .symbol(let s) = args[0].firstValue else { return .null }
            return Interpreter.specialFormNameSet.contains(s.name)
                ? self.tValue : .null
        }

        defBuiltin("CONSTANTP", 1, 1) { [unowned self] args in
            switch args[0].firstValue {
            case .symbol(let s): return s.isConstant ? self.tValue : .null
            case .cons(let c):
                if case .symbol(let q) = c.car, q.name == "QUOTE" {
                    return self.tValue
                }
                return .null
            default: return self.tValue
            }
        }

        registerPackageBuiltins()
    }

    func resolvePackage(_ v: LispValue) throws -> LispPackage {
        switch v.firstValue {
        case .package(let p):
            return p
        case .string(let s):
            guard let p = registry.find(s.string) else {
                throw lispError("PACKAGE-ERROR", "no package named \(s.string)")
            }
            return p
        case .symbol(let s):
            guard let p = registry.find(s.name) else {
                throw lispError("PACKAGE-ERROR", "no package named \(s.name)")
            }
            return p
        default:
            throw typeError(v, expected: "PACKAGE")
        }
    }
}
