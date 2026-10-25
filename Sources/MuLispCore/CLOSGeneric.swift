// CLOSGeneric.swift
// Generic functions: multiple dispatch, EQL specializers, standard method
// combination (:before / :after / :around, CALL-NEXT-METHOD).

import Foundation

public enum Specializer {
    case clazz(LispClass)
    case eql(LispValue)
}

public enum MethodQualifier: Equatable {
    case primary, before, after, around
    /// Operator method combinations (DEFINE-METHOD-COMBINATION short form):
    /// the qualifier is the combination name (e.g. + or PROGN).
    case custom(Symbol)
}

public final class MethodObj {
    public let qualifier: MethodQualifier
    public let specializers: [Specializer]
    public let function: LispFunction

    public init(qualifier: MethodQualifier, specializers: [Specializer],
                function: LispFunction) {
        self.qualifier = qualifier
        self.specializers = specializers
        self.function = function
    }

    /// Two methods with equal qualifier and specializers replace each other.
    public func agrees(with other: MethodObj) -> Bool {
        if qualifier != other.qualifier { return false }
        if specializers.count != other.specializers.count { return false }
        for (a, b) in zip(specializers, other.specializers) {
            switch (a, b) {
            case (.clazz(let x), .clazz(let y)):
                if x !== y { return false }
            case (.eql(let x), .eql(let y)):
                if !LispEquality.eql(x, y) { return false }
            default:
                return false
            }
        }
        return true
    }
}

private struct DispatchKey: Hashable {
    let ids: [ObjectIdentifier]
}

public final class GenericFunction: LispFunction {
    public var methods: [MethodObj] = []
    public var nRequired: Int
    /// Non-nil = operator method combination with this name.
    public var combination: Symbol?
    fileprivate var cache: [DispatchKey: [MethodObj]] = [:]
    fileprivate var hasEql: Bool = false

    public init(name: String, nRequired: Int) {
        self.nRequired = nRequired
        super.init(name: name)
    }

    public func addMethod(_ m: MethodObj) {
        methods.removeAll { $0.agrees(with: m) }
        methods.append(m)
        for s in m.specializers {
            if case .eql = s { hasEql = true }
        }
        cache.removeAll()
    }

    public func clearCache() {
        cache.removeAll()
    }
}

/// Dynamic context for CALL-NEXT-METHOD.
public struct NextMethodContext {
    public let next: (([LispValue]) throws -> LispValue)?
    public let args: [LispValue]
}

extension Interpreter {

    func specializerMatches(_ s: Specializer, _ arg: LispValue) -> Bool {
        switch s {
        case .clazz(let cls):
            return classOf(arg).isSubclass(of: cls)
        case .eql(let v):
            return LispEquality.eql(v, arg)
        }
    }

    /// Specificity of method m1 vs m2 for the given arguments:
    /// true when m1 is more specific.
    private func moreSpecific(_ m1: MethodObj, _ m2: MethodObj,
                              _ args: [LispValue]) -> Bool {
        for i in 0..<min(m1.specializers.count, m2.specializers.count) {
            let s1 = m1.specializers[i]
            let s2 = m2.specializers[i]
            switch (s1, s2) {
            case (.eql, .clazz):
                return true
            case (.clazz, .eql):
                return false
            case (.eql(let a), .eql(let b)):
                if LispEquality.eql(a, b) { continue }
                return false   // arbitrary; both match only if eql anyway
            case (.clazz(let c1), .clazz(let c2)):
                if c1 === c2 { continue }
                let cpl = classOf(args[i]).cpl
                let i1 = cpl.firstIndex(where: { $0 === c1 }) ?? Int.max
                let i2 = cpl.firstIndex(where: { $0 === c2 }) ?? Int.max
                if i1 == i2 { continue }
                return i1 < i2
            }
        }
        return false
    }

    func applicableMethods(_ gf: GenericFunction,
                           _ args: [LispValue]) -> [MethodObj] {
        if !gf.hasEql && gf.nRequired >= 1 && args.count >= gf.nRequired {
            let key = DispatchKey(ids: (0..<gf.nRequired).map {
                ObjectIdentifier(classOf(args[$0]))
            })
            if let cached = gf.cache[key] {
                return cached
            }
            let result = computeApplicable(gf, args)
            gf.cache[key] = result
            return result
        }
        return computeApplicable(gf, args)
    }

    private func computeApplicable(_ gf: GenericFunction,
                                   _ args: [LispValue]) -> [MethodObj] {
        var applicable: [MethodObj] = []
        for m in gf.methods {
            if m.specializers.count > args.count { continue }
            var ok = true
            for (i, s) in m.specializers.enumerated() {
                if !specializerMatches(s, args[i]) {
                    ok = false
                    break
                }
            }
            if ok { applicable.append(m) }
        }
        // Insertion-sort by specificity, most specific first.
        var sorted: [MethodObj] = []
        for m in applicable {
            var inserted = false
            for i in 0..<sorted.count {
                if moreSpecific(m, sorted[i], args) {
                    sorted.insert(m, at: i)
                    inserted = true
                    break
                }
            }
            if !inserted { sorted.append(m) }
        }
        return sorted
    }

    /// Invoke a generic function with standard method combination.
    public func dispatchGeneric(_ gf: GenericFunction,
                                _ args: [LispValue]) throws -> LispValue {
        if gf.nRequired >= 0 && args.count < gf.nRequired {
            throw lispError("PROGRAM-ERROR",
                "too few arguments to generic function \(gf.name)")
        }
        let applicable = applicableMethods(gf, args)
        if applicable.isEmpty {
            throw lispError("ERROR",
                "no applicable method for \(gf.name) with arguments "
                + args.map { Printer.toString($0, escape: true, interp: self) }
                      .joined(separator: " "))
        }

        var befores: [MethodObj] = []
        var primaries: [MethodObj] = []
        var afters: [MethodObj] = []
        var arounds: [MethodObj] = []
        for m in applicable {
            switch m.qualifier {
            case .primary: primaries.append(m)
            case .before: befores.append(m)
            case .after: afters.append(m)
            case .around: arounds.append(m)
            case .custom(let q):
                if let combo = gf.combination, q === combo {
                    primaries.append(m)
                }
            }
        }
        if primaries.isEmpty {
            throw lispError("ERROR",
                "no applicable primary method for \(gf.name)")
        }

        func invokeMethod(_ m: MethodObj, _ callArgs: [LispValue],
                          next: (([LispValue]) throws -> LispValue)?)
            throws -> LispValue {
            nextMethodStack.append(NextMethodContext(next: next, args: callArgs))
            defer { nextMethodStack.removeLast() }
            return try applyFunction(m.function, callArgs)
        }

        let core: ([LispValue]) throws -> LispValue

        if let combo = gf.combination {
            // Operator method combination (short form).
            core = { [unowned self] callArgs in
                switch combo.name {
                case "AND":
                    var result = self.tValue
                    for m in primaries {
                        result = try invokeMethod(m, callArgs, next: nil)
                        if !result.isTrue { return result }
                    }
                    return result
                case "OR":
                    for m in primaries {
                        let result = try invokeMethod(m, callArgs, next: nil)
                        if result.isTrue { return result }
                    }
                    return .null
                case "PROGN":
                    var result = LispValue.null
                    for m in primaries {
                        result = try invokeMethod(m, callArgs, next: nil)
                    }
                    return result
                default:
                    var results: [LispValue] = []
                    for m in primaries {
                        results.append(
                            try invokeMethod(m, callArgs, next: nil).firstValue)
                    }
                    let info = self.methodCombinations[ObjectIdentifier(combo)]
                    if results.count == 1 && (info?.identity ?? true) {
                        return results[0]
                    }
                    let opSymbol = info?.op ?? combo
                    guard let opFn = opSymbol.function else {
                        throw self.lispError("UNDEFINED-FUNCTION",
                            "method combination operator \(opSymbol.name)")
                    }
                    return try self.applyFunction(opFn, results)
                }
            }
        } else {
            // Standard combination: befores (most specific first), the
            // primary chain, afters (least specific first).
            var primaryChain: (([LispValue]) throws -> LispValue)? = nil
            for m in primaries.reversed() {
                let captured = primaryChain
                primaryChain = { callArgs in
                    try invokeMethod(m, callArgs, next: captured)
                }
            }
            let aftersReversed = Array(afters.reversed())
            core = { callArgs in
                for b in befores {
                    _ = try invokeMethod(b, callArgs, next: nil)
                }
                let result = try primaryChain!(callArgs)
                for a in aftersReversed {
                    _ = try invokeMethod(a, callArgs, next: nil)
                }
                return result
            }
        }

        // Around methods wrap the core.
        var effective = core
        for m in arounds.reversed() {
            let captured = effective
            effective = { callArgs in
                try invokeMethod(m, callArgs, next: captured)
            }
        }

        return try effective(args)
    }
}
