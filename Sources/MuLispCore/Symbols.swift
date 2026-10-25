// Symbols.swift
// Symbols and (simplified) packages.

import Foundation

public final class Symbol: Hashable {
    public let name: String
    public weak var package: LispPackage?
    /// Value cell. nil = unbound.
    public var value: LispValue?
    /// Function cell.
    public var function: LispFunction?
    /// Macro function (takes the argument forms, returns the expansion).
    public var macroFunction: LispFunction?
    /// Function used by (setf (name ...) v); called as (fn newValue args...).
    public var setfFunction: LispFunction?
    public var plist: LispValue = .null
    /// Declared special (dynamically bound by LET)?
    public var isSpecial: Bool = false
    /// Constant (keywords, T, PI, ...); SETQ is an error.
    public var isConstant: Bool = false

    public init(name: String, package: LispPackage?) {
        self.name = name
        self.package = package
    }

    public static func == (lhs: Symbol, rhs: Symbol) -> Bool {
        return lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    public var isKeyword: Bool {
        return package?.name == "KEYWORD"
    }
}

public final class LispPackage {
    public let name: String
    public var nicknames: [String]
    public private(set) var symbols: [String: Symbol] = [:]
    public var useList: [LispPackage] = []
    /// Names of exported symbols. When `exportsEverything` is true (the
    /// COMMON-LISP and KEYWORD packages), every symbol counts as external.
    public private(set) var externals: Set<String> = []
    public var exportsEverything = false
    /// Names shadowed in this package (import conflicts are resolved to the
    /// local symbol).
    public private(set) var shadowed: Set<String> = []

    public init(name: String, nicknames: [String] = []) {
        self.name = name
        self.nicknames = nicknames
    }

    public func isExternal(_ name: String) -> Bool {
        return exportsEverything || externals.contains(name)
    }

    public func export(_ name: String) {
        externals.insert(name)
    }

    public func unexport(_ name: String) {
        externals.remove(name)
    }

    public func shadow(_ name: String) {
        shadowed.insert(name)
        if symbols[name] == nil {
            let s = Symbol(name: name, package: self)
            symbols[name] = s
        }
    }

    /// Find a symbol visible in this package: its own symbols, then symbols
    /// inherited from used packages (their external symbols).
    public func findSymbol(_ name: String) -> Symbol? {
        if let s = symbols[name] { return s }
        for used in useList {
            if let s = used.symbols[name], used.isExternal(name) {
                return s
            }
        }
        return nil
    }

    /// All symbols accessible in this package.
    public func accessibleSymbols() -> [Symbol] {
        var seen = Set<String>()
        var result: [Symbol] = []
        for (n, s) in symbols {
            seen.insert(n)
            result.append(s)
        }
        for used in useList {
            for (n, s) in used.symbols where used.isExternal(n) && !seen.contains(n) {
                seen.insert(n)
                result.append(s)
            }
        }
        return result
    }

    /// Intern: find or create a symbol in this package.
    public func intern(_ name: String) -> Symbol {
        if let s = findSymbol(name) { return s }
        let s = Symbol(name: name, package: self)
        symbols[name] = s
        if self.name == "KEYWORD" {
            s.value = .symbol(s)
            s.isConstant = true
        }
        return s
    }

    /// Add an existing symbol (used for import-like operations).
    public func add(_ symbol: Symbol) {
        symbols[symbol.name] = symbol
    }

    /// Remove a symbol from this package. Returns true when one was removed.
    public func removeSymbol(_ name: String) -> Bool {
        if let s = symbols.removeValue(forKey: name) {
            externals.remove(name)
            shadowed.remove(name)
            if s.package === self {
                s.package = nil
            }
            return true
        }
        return false
    }
}

/// Global registry of packages for one interpreter instance.
public final class PackageRegistry {
    public private(set) var packages: [String: LispPackage] = [:]
    public let lisp: LispPackage       // COMMON-LISP
    public let keyword: LispPackage    // KEYWORD
    public let user: LispPackage       // COMMON-LISP-USER

    public init() {
        lisp = LispPackage(name: "COMMON-LISP", nicknames: ["CL", "LISP"])
        lisp.exportsEverything = true
        keyword = LispPackage(name: "KEYWORD", nicknames: [])
        keyword.exportsEverything = true
        user = LispPackage(name: "COMMON-LISP-USER", nicknames: ["CL-USER", "USER"])
        user.useList = [lisp]
        register(lisp)
        register(keyword)
        register(user)
    }

    public func allPackages() -> [LispPackage] {
        var seen = Set<ObjectIdentifier>()
        var result: [LispPackage] = []
        for (_, p) in packages where !seen.contains(ObjectIdentifier(p)) {
            seen.insert(ObjectIdentifier(p))
            result.append(p)
        }
        return result
    }

    public func register(_ p: LispPackage) {
        packages[p.name] = p
        for nick in p.nicknames {
            packages[nick] = p
        }
    }

    public func find(_ name: String) -> LispPackage? {
        return packages[name]
    }

    public func findOrCreate(_ name: String) -> LispPackage {
        if let p = packages[name] { return p }
        let p = LispPackage(name: name)
        p.useList = [lisp]
        register(p)
        return p
    }
}
