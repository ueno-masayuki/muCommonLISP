// BuiltinsString.swift
// Strings, characters, symbols and packages.

import Foundation

extension Interpreter {

    func registerStringBuiltins() {
        let lisp = registry.lisp

        func requireString(_ v: LispValue) throws -> String {
            switch v.firstValue {
            case .string(let s): return s
            case .symbol(let s): return s.name
            case .character(let c): return String(c)
            default: throw self.typeError(v, expected: "STRING")
            }
        }

        func requireChar(_ v: LispValue) throws -> Character {
            guard case .character(let c) = v.firstValue else {
                throw self.typeError(v, expected: "CHARACTER")
            }
            return c
        }

        // --- Strings ---

        defBuiltin("STRING", 1, 1) { args in .string(try requireString(args[0])) }

        defBuiltin("STRING-UPCASE", 1, 1) { args in
            .string(try requireString(args[0]).uppercased())
        }
        defBuiltin("STRING-DOWNCASE", 1, 1) { args in
            .string(try requireString(args[0]).lowercased())
        }
        defBuiltin("STRING-CAPITALIZE", 1, 1) { args in
            .string(try requireString(args[0]).capitalized)
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

        defBuiltin("CHAR", 2, 2) { [unowned self] args in
            let s = try requireString(args[0])
            guard case .int(let i) = args[1].firstValue, i >= 0,
                  i < s.count else {
                throw self.lispError("ERROR", "char index out of range")
            }
            return .character(Array(s)[i])
        }
        lisp.intern("SCHAR").function = lisp.intern("CHAR").function

        defBuiltin("STRING-TRIM", 2, 2) { args in
            let bagChars: Set<Character>
            switch args[0].firstValue {
            case .string(let s): bagChars = Set(s)
            default:
                var set = Set<Character>()
                if let items = args[0].firstValue.asArray() {
                    for i in items {
                        if case .character(let c) = i { set.insert(c) }
                    }
                }
                bagChars = set
            }
            var s = Array(try requireString(args[1]))
            while let f = s.first, bagChars.contains(f) { s.removeFirst() }
            while let l = s.last, bagChars.contains(l) { s.removeLast() }
            return .string(String(s))
        }

        defBuiltin("SEARCH", 2, nil) { args in
            let needle = try requireString(args[0])
            let haystack = try requireString(args[1])
            if needle.isEmpty { return .int(0) }
            let hChars = Array(haystack)
            let nChars = Array(needle)
            if nChars.count > hChars.count { return .null }
            for start in 0...(hChars.count - nChars.count) {
                var match = true
                for k in 0..<nChars.count where hChars[start + k] != nChars[k] {
                    match = false
                    break
                }
                if match { return .int(start) }
            }
            return .null
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

        defBuiltin("STRING-TO-NUMBER", 1, 1) { args in
            let s = try requireString(args[0])
            if let i = Int(s) { return .int(i) }
            if let d = Double(s) { return .double(d) }
            return .null
        }

        // --- Characters ---

        defBuiltin("CHAR-CODE", 1, 1) { args in
            let c = try requireChar(args[0])
            return .int(Int(c.unicodeScalars.first!.value))
        }
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

        defBuiltin("DIGIT-CHAR-P", 1, 2) { args in
            let c = try requireChar(args[0])
            var radix = 10
            if args.count == 2, case .int(let r) = args[1].firstValue { radix = r }
            if let v = c.hexDigitValue, v < radix {
                return .int(v)
            }
            return .null
        }

        defBuiltin("ALPHA-CHAR-P", 1, 1) { [unowned self] args in
            return try requireChar(args[0]).isLetter ? self.tValue : .null
        }

        // --- Symbols ---

        defBuiltin("SYMBOL-NAME", 1, 1) { [unowned self] args in
            guard case .symbol(let s) = args[0].firstValue else {
                if args[0].firstValue.isNil { return .string("NIL") }
                throw self.typeError(args[0], expected: "SYMBOL")
            }
            return .string(s.name)
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
            if let s = pkg.findSymbol(name) {
                return .values([.symbol(s), .symbol(self.registry.keyword.intern("INTERNAL"))])
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

        // --- Packages ---

        defBuiltin("MAKE-PACKAGE", 1, nil) { [unowned self] args in
            let name = try requireString(args[0])
            return .package(self.registry.findOrCreate(name))
        }

        defBuiltin("FIND-PACKAGE", 1, 1) { [unowned self] args in
            if case .package(let p) = args[0].firstValue { return .package(p) }
            let name = try requireString(args[0])
            if let p = self.registry.find(name) { return .package(p) }
            return .null
        }

        defBuiltin("PACKAGE-NAME", 1, 1) { [unowned self] args in
            let p = try self.resolvePackage(args[0])
            return .string(p.name)
        }

        defBuiltin("%IN-PACKAGE", 1, 1) { [unowned self] args in
            let name = try requireString(args[0])
            let p = self.registry.findOrCreate(name)
            self.setCurrentPackage(p)
            return .package(p)
        }

        defBuiltin("%ENSURE-PACKAGE", 3, 3) { [unowned self] args in
            let name = try requireString(args[0])
            let p = self.registry.findOrCreate(name)
            for nick in args[1].asArray() ?? [] {
                let n = try requireString(nick)
                if !p.nicknames.contains(n) {
                    p.nicknames.append(n)
                }
                self.registry.register(p)
            }
            var useList: [LispPackage] = []
            for u in args[2].asArray() ?? [] {
                useList.append(try self.resolvePackage(u))
            }
            if !useList.isEmpty {
                p.useList = useList
            }
            return .package(p)
        }

        // IN-PACKAGE / DEFPACKAGE macros.
        defMacro("IN-PACKAGE") { [unowned self] forms in
            guard forms.count == 1 else {
                throw CompileError("malformed in-package")
            }
            let name: String
            switch forms[0] {
            case .symbol(let s): name = s.name
            case .string(let s): name = s
            default: throw CompileError("malformed in-package")
            }
            return self.lst(self.sym("%IN-PACKAGE"), .string(name))
        }

        defMacro("DEFPACKAGE") { [unowned self] forms in
            guard !forms.isEmpty else {
                throw CompileError("malformed defpackage")
            }
            let name: String
            switch forms[0] {
            case .symbol(let s): name = s.name
            case .string(let s): name = s
            default: throw CompileError("malformed defpackage")
            }
            var nicknames: [LispValue] = []
            var uses: [LispValue] = []
            for opt in forms.dropFirst() {
                guard let parts = opt.asArray(), !parts.isEmpty,
                      case .symbol(let k) = parts[0] else { continue }
                switch k.name {
                case "NICKNAMES":
                    for n in parts.dropFirst() {
                        if case .symbol(let s) = n {
                            nicknames.append(.string(s.name))
                        } else if case .string = n {
                            nicknames.append(n)
                        }
                    }
                case "USE":
                    for u in parts.dropFirst() {
                        if case .symbol(let s) = u {
                            uses.append(.string(s.name))
                        } else if case .string = u {
                            uses.append(u)
                        }
                    }
                case "EXPORT", "DOCUMENTATION", "IMPORT-FROM", "SHADOW":
                    break   // accepted and ignored
                default:
                    break
                }
            }
            return self.lst(self.sym("%ENSURE-PACKAGE"), .string(name),
                            self.quoted(LispValue.list(nicknames)),
                            self.quoted(LispValue.list(uses)))
        }
    }

    func resolvePackage(_ v: LispValue) throws -> LispPackage {
        switch v.firstValue {
        case .package(let p):
            return p
        case .string(let s):
            guard let p = registry.find(s) else {
                throw lispError("PACKAGE-ERROR", "no package named \(s)")
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
