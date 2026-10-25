// CLOSGeneric.swift
// Generic functions: multiple dispatch, EQL specializers, standard method
// combination (:before / :after / :around, CALL-NEXT-METHOD).

import Foundation

public enum Specializer {
    case clazz(LispClass)
    case eql(LispValue)
}

public enum MethodQualifier {
    case primary, before, after, around
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
    public var documentation: String?
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

        // Chain of primary methods (CALL-NEXT-METHOD walks it).
        var primaryChain: (([LispValue]) throws -> LispValue)? = nil
        for m in primaries.reversed() {
            let captured = primaryChain
            primaryChain = { callArgs in
                try invokeMethod(m, callArgs, next: captured)
            }
        }

        // Core: befores (most specific first), primaries, afters (least
        // specific first).
        let aftersReversed = Array(afters.reversed())
        let core: ([LispValue]) throws -> LispValue = { callArgs in
            for b in befores {
                _ = try invokeMethod(b, callArgs, next: nil)
            }
            let result = try primaryChain!(callArgs)
            for a in aftersReversed {
                _ = try invokeMethod(a, callArgs, next: nil)
            }
            return result
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
