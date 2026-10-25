// Packages.swift
// Package system operations.

import Foundation

extension Interpreter {

    func registerPackageBuiltins() {

        func stringDesignator(_ v: LispValue) throws -> String {
            return try requireStringDesignator(v)
        }

        func symbolList(_ v: LispValue) -> [Symbol] {
            var result: [Symbol] = []
            let items = v.firstValue.asArray()
                ?? (v.firstValue.isNil ? [] : [v.firstValue])
            for i in items {
                if case .symbol(let s) = i { result.append(s) }
            }
            return result
        }

        defBuiltin("MAKE-PACKAGE", 1, nil) { [unowned self] args in
            let name = try stringDesignator(args[0])
            let keys = try self.parseKeys(args, from: 1)
            let p = self.registry.findOrCreate(name)
            if let use = keys["USE"] {
                var useList: [LispPackage] = []
                for u in use.asArray() ?? [] {
                    useList.append(try self.resolvePackage(u))
                }
                p.useList = useList
            }
            if let nicks = keys["NICKNAMES"] {
                for n in nicks.asArray() ?? [] {
                    let nick = try stringDesignator(n)
                    if !p.nicknames.contains(nick) {
                        p.nicknames.append(nick)
                    }
                }
                self.registry.register(p)
            }
            return .package(p)
        }

        defBuiltin("FIND-PACKAGE", 1, 1) { [unowned self] args in
            if case .package(let p) = args[0].firstValue { return .package(p) }
            let name = try stringDesignator(args[0])
            if let p = self.registry.find(name) { return .package(p) }
            return .null
        }

        defBuiltin("PACKAGE-NAME", 1, 1) { [unowned self] args in
            let p = try self.resolvePackage(args[0])
            return .str(p.name)
        }

        defBuiltin("PACKAGE-NICKNAMES", 1, 1) { [unowned self] args in
            let p = try self.resolvePackage(args[0])
            return LispValue.list(p.nicknames.map { .str($0) })
        }

        defBuiltin("PACKAGE-USE-LIST", 1, 1) { [unowned self] args in
            let p = try self.resolvePackage(args[0])
            return LispValue.list(p.useList.map { .package($0) })
        }

        defBuiltin("LIST-ALL-PACKAGES", 0, 0) { [unowned self] _ in
            return LispValue.list(self.registry.allPackages().map { .package($0) })
        }

        defBuiltin("PACKAGEP", 1, 1) { [unowned self] args in
            if case .package = args[0].firstValue { return self.tValue }
            return .null
        }

        defBuiltin("%IN-PACKAGE", 1, 1) { [unowned self] args in
            let name = try stringDesignator(args[0])
            let p = self.registry.findOrCreate(name)
            self.setCurrentPackage(p)
            return .package(p)
        }

        defBuiltin("EXPORT", 1, 2) { [unowned self] args in
            let pkg = args.count == 2
                ? try self.resolvePackage(args[1])
                : self.currentPackage
            for s in symbolList(args[0]) {
                pkg.export(s.name)
                if pkg.symbols[s.name] == nil {
                    pkg.add(s)
                }
            }
            return self.tValue
        }

        defBuiltin("UNEXPORT", 1, 2) { [unowned self] args in
            let pkg = args.count == 2
                ? try self.resolvePackage(args[1])
                : self.currentPackage
            for s in symbolList(args[0]) {
                pkg.unexport(s.name)
            }
            return self.tValue
        }

        defBuiltin("IMPORT", 1, 2) { [unowned self] args in
            let pkg = args.count == 2
                ? try self.resolvePackage(args[1])
                : self.currentPackage
            for s in symbolList(args[0]) {
                pkg.add(s)
            }
            return self.tValue
        }

        defBuiltin("SHADOWING-IMPORT", 1, 2) { [unowned self] args in
            let pkg = args.count == 2
                ? try self.resolvePackage(args[1])
                : self.currentPackage
            for s in symbolList(args[0]) {
                pkg.add(s)
                pkg.shadow(s.name)
            }
            return self.tValue
        }

        defBuiltin("SHADOW", 1, 2) { [unowned self] args in
            let pkg = args.count == 2
                ? try self.resolvePackage(args[1])
                : self.currentPackage
            let items = args[0].firstValue.asArray()
                ?? (args[0].firstValue.isNil ? [] : [args[0].firstValue])
            for item in items {
                pkg.shadow(try stringDesignator(item))
            }
            return self.tValue
        }

        defBuiltin("USE-PACKAGE", 1, 2) { [unowned self] args in
            let pkg = args.count == 2
                ? try self.resolvePackage(args[1])
                : self.currentPackage
            let items = args[0].firstValue.asArray() ?? [args[0].firstValue]
            for item in items {
                let used = try self.resolvePackage(item)
                if !pkg.useList.contains(where: { $0 === used }) {
                    pkg.useList.append(used)
                }
            }
            return self.tValue
        }

        defBuiltin("UNUSE-PACKAGE", 1, 2) { [unowned self] args in
            let pkg = args.count == 2
                ? try self.resolvePackage(args[1])
                : self.currentPackage
            let items = args[0].firstValue.asArray() ?? [args[0].firstValue]
            for item in items {
                let used = try self.resolvePackage(item)
                pkg.useList.removeAll { $0 === used }
            }
            return self.tValue
        }

        defBuiltin("UNINTERN", 1, 2) { [unowned self] args in
            guard case .symbol(let s) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "SYMBOL")
            }
            let pkg = args.count == 2
                ? try self.resolvePackage(args[1])
                : self.currentPackage
            return pkg.removeSymbol(s.name) ? self.tValue : .null
        }

        defBuiltin("%PACKAGE-SYMBOLS", 1, 1) { [unowned self] args in
            let p = try self.resolvePackage(args[0])
            return LispValue.list(p.accessibleSymbols().map { .symbol($0) })
        }

        defBuiltin("%PACKAGE-EXTERNAL-SYMBOLS", 1, 1) { [unowned self] args in
            let p = try self.resolvePackage(args[0])
            var result: [LispValue] = []
            for (n, s) in p.symbols where p.isExternal(n) {
                result.append(.symbol(s))
            }
            return LispValue.list(result)
        }

        defBuiltin("FIND-ALL-SYMBOLS", 1, 1) { [unowned self] args in
            let name = try stringDesignator(args[0])
            var result: [LispValue] = []
            for p in self.registry.allPackages() {
                if let s = p.symbols[name] {
                    if !result.contains(where: { LispEquality.eq($0, .symbol(s)) }) {
                        result.append(.symbol(s))
                    }
                }
            }
            return LispValue.list(result)
        }

        defBuiltin("APROPOS", 1, 2) { [unowned self] args in
            let fragment = try stringDesignator(args[0]).uppercased()
            var names: [String] = []
            for p in self.registry.allPackages() {
                for (n, _) in p.symbols where n.contains(fragment) {
                    if !names.contains(n) { names.append(n) }
                }
            }
            for n in names.sorted() {
                self.write("\(n)\n")
            }
            return .values([])
        }

        defBuiltin("APROPOS-LIST", 1, 2) { [unowned self] args in
            let fragment = try stringDesignator(args[0]).uppercased()
            var result: [LispValue] = []
            var seen = Set<ObjectIdentifier>()
            for p in self.registry.allPackages() {
                for (n, s) in p.symbols where n.contains(fragment) {
                    if !seen.contains(ObjectIdentifier(s)) {
                        seen.insert(ObjectIdentifier(s))
                        result.append(.symbol(s))
                    }
                }
            }
            return LispValue.list(result)
        }

        // IN-PACKAGE / DEFPACKAGE macros.
        defMacro("IN-PACKAGE") { [unowned self] forms in
            guard forms.count == 1 else {
                throw CompileError("malformed in-package")
            }
            let name: String
            switch forms[0] {
            case .symbol(let s): name = s.name
            case .string(let s): name = s.string
            default: throw CompileError("malformed in-package")
            }
            return self.lst(self.sym("%IN-PACKAGE"), .str(name))
        }

        defMacro("DEFPACKAGE") { [unowned self] forms in
            guard !forms.isEmpty else {
                throw CompileError("malformed defpackage")
            }
            let name: String
            switch forms[0] {
            case .symbol(let s): name = s.name
            case .string(let s): name = s.string
            default: throw CompileError("malformed defpackage")
            }
            var nicknames: [LispValue] = []
            var uses: [LispValue] = []
            var exports: [LispValue] = []
            var shadows: [LispValue] = []
            for opt in forms.dropFirst() {
                guard let parts = opt.asArray(), !parts.isEmpty,
                      case .symbol(let k) = parts[0] else { continue }
                switch k.name {
                case "NICKNAMES":
                    for n in parts.dropFirst() {
                        nicknames.append(.str((try? self.requireStringDesignator(n)) ?? ""))
                    }
                case "USE":
                    for u in parts.dropFirst() {
                        uses.append(.str((try? self.requireStringDesignator(u)) ?? ""))
                    }
                case "EXPORT":
                    for e in parts.dropFirst() {
                        exports.append(.str((try? self.requireStringDesignator(e)) ?? ""))
                    }
                case "SHADOW":
                    for e in parts.dropFirst() {
                        shadows.append(.str((try? self.requireStringDesignator(e)) ?? ""))
                    }
                case "DOCUMENTATION", "IMPORT-FROM", "SIZE":
                    break   // accepted and ignored
                default:
                    break
                }
            }
            return self.lst(self.sym("%ENSURE-PACKAGE"), .str(name),
                            self.quoted(LispValue.list(nicknames)),
                            self.quoted(LispValue.list(uses)),
                            self.quoted(LispValue.list(exports)),
                            self.quoted(LispValue.list(shadows)))
        }

        defBuiltin("%ENSURE-PACKAGE", 5, 5) { [unowned self] args in
            let name = try stringDesignator(args[0])
            let p = self.registry.findOrCreate(name)
            for nick in args[1].asArray() ?? [] {
                let n = try stringDesignator(nick)
                if !n.isEmpty && !p.nicknames.contains(n) {
                    p.nicknames.append(n)
                }
            }
            self.registry.register(p)
            var useList: [LispPackage] = []
            for u in args[2].asArray() ?? [] {
                let n = try stringDesignator(u)
                if !n.isEmpty {
                    useList.append(self.registry.findOrCreate(n))
                }
            }
            if !useList.isEmpty {
                p.useList = useList
            } else if p.useList.isEmpty {
                p.useList = [self.registry.lisp]
            }
            for s in args[4].asArray() ?? [] {
                let n = try stringDesignator(s)
                if !n.isEmpty { p.shadow(n) }
            }
            for e in args[3].asArray() ?? [] {
                let n = try stringDesignator(e)
                if !n.isEmpty {
                    _ = p.intern(n)
                    p.export(n)
                }
            }
            return .package(p)
        }
    }
}
