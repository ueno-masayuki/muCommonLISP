// Value.swift
// Core value representation for muCommonLISP.

import Foundation

/// Mutable cons cell.
public final class Cons {
    public var car: LispValue
    public var cdr: LispValue
    public init(car: LispValue, cdr: LispValue) {
        self.car = car
        self.cdr = cdr
    }
}

/// Mutable general vector (also used as the basis for strings is NOT the case;
/// strings are Swift String and immutable in this implementation).
public final class LispVector {
    public var elements: [LispValue]
    public init(_ elements: [LispValue]) {
        self.elements = elements
    }
}

/// Hash table. Keys are wrapped so that Lisp equality (eql / equal) can be used.
public final class LispHashTable {
    public enum TestKind {
        case eq, eql, equal, equalp
    }
    public let test: TestKind
    // We store buckets keyed by a hash string of the key plus linear probing of
    // candidates, because LispValue is not Hashable in general.
    private var buckets: [String: [(LispValue, LispValue)]] = [:]
    public private(set) var count: Int = 0

    public init(test: TestKind) {
        self.test = test
    }

    private func matches(_ a: LispValue, _ b: LispValue) -> Bool {
        switch test {
        case .eq: return LispEquality.eq(a, b)
        case .eql: return LispEquality.eql(a, b)
        case .equal: return LispEquality.equal(a, b)
        case .equalp: return LispEquality.equalp(a, b)
        }
    }

    private func hashKey(_ key: LispValue) -> String {
        // A conservative hash: eql-distinct objects may share a bucket; that is
        // fine, correctness comes from `matches`.
        switch key {
        case .null: return "nil"
        case .int(let i): return "i\(i)"
        case .double(let d):
            if test == .equalp, d == d.rounded(), let i = Int(exactly: d.rounded()) {
                return "i\(i)"
            }
            return "d\(d)"
        case .string(let s):
            switch test {
            case .equal: return "s\(s)"
            case .equalp: return "s\(s.uppercased())"
            default: return "obj"
            }
        case .character(let c):
            if test == .equalp { return "c\(String(c).uppercased())" }
            return "c\(c)"
        case .symbol(let s): return "y\(ObjectIdentifier(s).hashValue)"
        case .cons:
            // equal/equalp hashing of lists: hash on length only (cheap, safe).
            return "cons"
        default:
            return "obj"
        }
    }

    public func get(_ key: LispValue) -> LispValue? {
        let h = hashKey(key)
        guard let entries = buckets[h] else { return nil }
        for (k, v) in entries where matches(k, key) {
            return v
        }
        return nil
    }

    public func set(_ key: LispValue, _ value: LispValue) {
        let h = hashKey(key)
        var entries = buckets[h] ?? []
        for i in 0..<entries.count where matches(entries[i].0, key) {
            entries[i].1 = value
            buckets[h] = entries
            return
        }
        entries.append((key, value))
        buckets[h] = entries
        count += 1
    }

    public func remove(_ key: LispValue) -> Bool {
        let h = hashKey(key)
        guard var entries = buckets[h] else { return false }
        for i in 0..<entries.count where matches(entries[i].0, key) {
            entries.remove(at: i)
            buckets[h] = entries
            count -= 1
            return true
        }
        return false
    }

    public func clear() {
        buckets = [:]
        count = 0
    }

    public func allPairs() -> [(LispValue, LispValue)] {
        var result: [(LispValue, LispValue)] = []
        for (_, entries) in buckets {
            result.append(contentsOf: entries)
        }
        return result
    }
}

/// Unique token used to implement BLOCK / RETURN-FROM.
public final class BlockToken {
    public let name: String
    public init(name: String) { self.name = name }
}

/// A (very) simple stream. String-output streams accumulate text in `buffer`;
/// the standard-output stream forwards text to the interpreter's output
/// handler via `writer`.
public final class LispStream {
    public enum Kind {
        case stringOutput
        case standardOutput
    }
    public let kind: Kind
    public var buffer: String = ""
    public var writer: ((String) -> Void)?

    public init(kind: Kind, writer: ((String) -> Void)? = nil) {
        self.kind = kind
        self.writer = writer
    }

    public func write(_ s: String) {
        switch kind {
        case .stringOutput:
            buffer += s
        case .standardOutput:
            writer?(s)
        }
    }
}

/// Base class for all callable objects.
public class LispFunction {
    public var name: String
    public init(name: String) { self.name = name }
}

/// A function implemented in Swift.
public final class Builtin: LispFunction {
    public let minArgs: Int
    public let maxArgs: Int?    // nil = unlimited
    public let fn: ([LispValue]) throws -> LispValue
    public init(name: String, minArgs: Int, maxArgs: Int?,
                fn: @escaping ([LispValue]) throws -> LispValue) {
        self.minArgs = minArgs
        self.maxArgs = maxArgs
        self.fn = fn
        super.init(name: name)
    }
}

/// A compiled Lisp closure.
public final class Closure: LispFunction {
    public let code: CodeObject
    public let capturedFrame: Frame?
    public init(code: CodeObject, capturedFrame: Frame?) {
        self.code = code
        self.capturedFrame = capturedFrame
        super.init(name: code.name)
    }
}

/// Runtime environment frame: one per function invocation.
public final class Frame {
    public var slots: [LispValue]
    public let parent: Frame?
    public init(size: Int, parent: Frame?) {
        self.slots = [LispValue](repeating: .null, count: size)
        self.parent = parent
    }
}

/// The central value type.
public enum LispValue {
    case null                           // NIL / empty list
    case int(Int)
    case double(Double)
    case string(String)
    case character(Character)
    case symbol(Symbol)
    case cons(Cons)
    case vector(LispVector)
    case hashTable(LispHashTable)
    case function(LispFunction)
    case instance(StandardInstance)
    case lispClass(LispClass)
    case package(LispPackage)
    case blockToken(BlockToken)
    case stream(LispStream)
    case values([LispValue])            // multiple values (transient)

    public var isNil: Bool {
        if case .null = self { return true }
        return false
    }

    public var isTrue: Bool {
        return !firstValue.isNil
    }

    /// Collapse multiple values to the primary value.
    public var firstValue: LispValue {
        if case .values(let vs) = self {
            return vs.first ?? .null
        }
        return self
    }

    /// Build a proper list from an array.
    public static func list(_ items: [LispValue]) -> LispValue {
        var result = LispValue.null
        for item in items.reversed() {
            result = .cons(Cons(car: item, cdr: result))
        }
        return result
    }

    /// Build a list ending with a given tail.
    public static func list(_ items: [LispValue], tail: LispValue) -> LispValue {
        var result = tail
        for item in items.reversed() {
            result = .cons(Cons(car: item, cdr: result))
        }
        return result
    }

    /// Convert a proper list to an array; nil if improper or not a list.
    public func asArray() -> [LispValue]? {
        var result: [LispValue] = []
        var cur = self
        var guardCount = 0
        while true {
            switch cur {
            case .null:
                return result
            case .cons(let c):
                result.append(c.car)
                cur = c.cdr
            default:
                return nil
            }
            guardCount += 1
            if guardCount > 10_000_000 { return nil }   // circular protection
        }
    }

    public var asCons: Cons? {
        if case .cons(let c) = self { return c }
        return nil
    }

    public var asSymbol: Symbol? {
        if case .symbol(let s) = self { return s }
        return nil
    }

    public var asInt: Int? {
        if case .int(let i) = self { return i }
        return nil
    }

    public var asDouble: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    public var asString: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var asFunction: LispFunction? {
        if case .function(let f) = self { return f }
        return nil
    }

    public var isNumber: Bool {
        switch self {
        case .int, .double: return true
        default: return false
        }
    }
}

/// Equality predicates.
public enum LispEquality {
    public static func eq(_ a: LispValue, _ b: LispValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.int(let x), .int(let y)): return x == y   // small ints behave eq-like
        case (.character(let x), .character(let y)): return x == y
        case (.symbol(let x), .symbol(let y)): return x === y
        case (.cons(let x), .cons(let y)): return x === y
        case (.string(let x), .string(let y)):
            // Strings are value types here; eq on distinct string objects is
            // not meaningful. Treat identical contents as eq (documented).
            return x == y
        case (.vector(let x), .vector(let y)): return x === y
        case (.hashTable(let x), .hashTable(let y)): return x === y
        case (.function(let x), .function(let y)): return x === y
        case (.instance(let x), .instance(let y)): return x === y
        case (.lispClass(let x), .lispClass(let y)): return x === y
        case (.package(let x), .package(let y)): return x === y
        case (.blockToken(let x), .blockToken(let y)): return x === y
        case (.stream(let x), .stream(let y)): return x === y
        case (.double(let x), .double(let y)): return x == y
        default: return false
        }
    }

    public static func eql(_ a: LispValue, _ b: LispValue) -> Bool {
        switch (a, b) {
        case (.int(let x), .int(let y)): return x == y
        case (.double(let x), .double(let y)): return x == y
        case (.character(let x), .character(let y)): return x == y
        default: return eq(a, b)
        }
    }

    public static func equal(_ a: LispValue, _ b: LispValue) -> Bool {
        switch (a, b) {
        case (.cons(let x), .cons(let y)):
            return equal(x.car, y.car) && equal(x.cdr, y.cdr)
        case (.string(let x), .string(let y)):
            return x == y
        default:
            return eql(a, b)
        }
    }

    public static func equalp(_ a: LispValue, _ b: LispValue) -> Bool {
        switch (a, b) {
        case (.int(let x), .int(let y)): return x == y
        case (.double(let x), .double(let y)): return x == y
        case (.int(let x), .double(let y)): return Double(x) == y
        case (.double(let x), .int(let y)): return x == Double(y)
        case (.character(let x), .character(let y)):
            return String(x).uppercased() == String(y).uppercased()
        case (.string(let x), .string(let y)):
            return x.uppercased() == y.uppercased()
        case (.cons(let x), .cons(let y)):
            return equalp(x.car, y.car) && equalp(x.cdr, y.cdr)
        case (.vector(let x), .vector(let y)):
            if x.elements.count != y.elements.count { return false }
            for i in 0..<x.elements.count {
                if !equalp(x.elements[i], y.elements[i]) { return false }
            }
            return true
        default:
            return eq(a, b)
        }
    }
}
