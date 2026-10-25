// LambdaList.swift
// Parsing ordinary lambda lists (&optional &rest/&body &key &allow-other-keys).

import Foundation

public struct CompileError: Error {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public struct ParsedOptional {
    public let name: Symbol
    public let defaultForm: LispValue
    public let suppliedName: Symbol?
}

public struct ParsedKey {
    public let keyword: Symbol      // in KEYWORD package
    public let name: Symbol         // variable name
    public let defaultForm: LispValue
    public let suppliedName: Symbol?
}

public struct ParsedLambdaList {
    public var required: [Symbol] = []
    public var optionals: [ParsedOptional] = []
    public var rest: Symbol? = nil
    public var keys: [ParsedKey] = []
    public var allowOtherKeys: Bool = false

    /// All variable names bound by this lambda list, in binding order.
    public var allNames: [Symbol] {
        var names = required
        for o in optionals {
            names.append(o.name)
            if let s = o.suppliedName { names.append(s) }
        }
        if let r = rest { names.append(r) }
        for k in keys {
            names.append(k.name)
            if let s = k.suppliedName { names.append(s) }
        }
        return names
    }
}

public enum LambdaListParser {

    /// Parse an ordinary lambda list. `keywordPackage` is used to intern
    /// keyword names for &key parameters.
    public static func parse(_ list: LispValue,
                             keywordPackage: LispPackage) throws -> ParsedLambdaList {
        guard let items = list.asArray() else {
            throw CompileError("malformed lambda list")
        }
        var result = ParsedLambdaList()
        enum Mode { case required, optional, rest, key }
        var mode = Mode.required
        var restSeen = false

        for item in items {
            if case .symbol(let s) = item, s.name.hasPrefix("&") {
                switch s.name {
                case "&OPTIONAL":
                    mode = .optional
                case "&REST", "&BODY":
                    mode = .rest
                case "&KEY":
                    mode = .key
                case "&ALLOW-OTHER-KEYS":
                    result.allowOtherKeys = true
                default:
                    throw CompileError("unsupported lambda list keyword: \(s.name)")
                }
                continue
            }

            switch mode {
            case .required:
                guard case .symbol(let s) = item else {
                    throw CompileError("required parameter must be a symbol")
                }
                result.required.append(s)
            case .optional:
                let (name, def, supplied) = try parseVarSpec(item)
                result.optionals.append(
                    ParsedOptional(name: name, defaultForm: def, suppliedName: supplied))
            case .rest:
                guard case .symbol(let s) = item, !restSeen else {
                    throw CompileError("malformed &rest parameter")
                }
                result.rest = s
                restSeen = true
            case .key:
                let (name, def, supplied) = try parseVarSpec(item)
                let kw = keywordPackage.intern(name.name)
                result.keys.append(
                    ParsedKey(keyword: kw, name: name,
                              defaultForm: def, suppliedName: supplied))
            }
        }
        return result
    }

    /// Parse `name`, `(name default)` or `(name default supplied-p)`.
    private static func parseVarSpec(_ item: LispValue)
        throws -> (Symbol, LispValue, Symbol?) {
        if case .symbol(let s) = item {
            return (s, .null, nil)
        }
        guard let parts = item.asArray(), !parts.isEmpty,
              case .symbol(let name) = parts[0] else {
            throw CompileError("malformed parameter spec")
        }
        let def = parts.count > 1 ? parts[1] : .null
        var supplied: Symbol? = nil
        if parts.count > 2 {
            guard case .symbol(let sp) = parts[2] else {
                throw CompileError("supplied-p must be a symbol")
            }
            supplied = sp
        }
        if parts.count > 3 {
            throw CompileError("malformed parameter spec")
        }
        return (name, def, supplied)
    }
}
