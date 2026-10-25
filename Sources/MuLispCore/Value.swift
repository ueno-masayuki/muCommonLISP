// Value.swift
// Core value representation for muCommonLISP.

import Foundation
import BigInt

/// Mutable cons cell.
public final class Cons {
    public var car: LispValue
    public var cdr: LispValue
    public init(car: LispValue, cdr: LispValue) {
        self.car = car
        self.cdr = cdr
    }
}

/// Mutable string (supports (setf (char s i)), fill pointers are not kept
/// for strings).
public final class LispString {
    public var chars: [Character]
    public init(_ s: String) { self.chars = Array(s) }
    public init(chars: [Character]) { self.chars = chars }
    public var string: String { return String(chars) }
    public var count: Int { return chars.count }
}

/// Mutable array. One-dimensional arrays double as vectors (and may carry a
/// fill pointer); multidimensional arrays use row-major `elements` storage.
public final class LispVector {
    public var elements: [LispValue]
    public var dimensions: [Int]
    public var fillPointer: Int?
    public var adjustable: Bool

    public init(_ elements: [LispValue]) {
        self.elements = elements
        self.dimensions = [elements.count]
        self.fillPointer = nil
        self.adjustable = false
    }

    public init(dimensions: [Int], initial: LispValue,
                fillPointer: Int? = nil, adjustable: Bool = false) {
        self.dimensions = dimensions
        let total = dimensions.reduce(1, *)
        self.elements = [LispValue](repeating: initial, count: total)
        self.fillPointer = fillPointer
        self.adjustable = adjustable
    }

    public var rank: Int { return dimensions.count }
    public var totalSize: Int { return elements.count }

    /// Number of active elements as a sequence (respects the fill pointer).
    public var activeCount: Int {
        if rank == 1, let fp = fillPointer { return fp }
        return elements.count
    }

    public var activeElements: [LispValue] {
        if rank == 1, let fp = fillPointer {
            return Array(elements[0..<min(fp, elements.count)])
        }
        return elements
    }

    public func rowMajorIndex(_ subscripts: [Int]) -> Int? {
        guard subscripts.count == dimensions.count else { return nil }
        var index = 0
        for (i, s) in subscripts.enumerated() {
            guard s >= 0 && s < dimensions[i] else { return nil }
            index = index * dimensions[i] + s
        }
        return index
    }
}

/// Hash table. Keys are wrapped so that Lisp equality (eql / equal) can be used.
public final class LispHashTable {
    public enum TestKind {
        case eq, eql, equal, equalp
    }
    public let test: TestKind
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
        switch key {
        case .null: return "nil"
        case .int(let i): return "i\(i)"
        case .bignum(let b): return "i\(b)"
        case .ratio(let r): return "q\(r.num)/\(r.den)"
        case .double(let d):
            if test == .equalp, d == d.rounded(), let i = Int(exactly: d.rounded()) {
                return "i\(i)"
            }
            return "d\(d)"
        case .string(let s):
            switch test {
            case .equal: return "s\(s.string)"
            case .equalp: return "s\(s.string.uppercased())"
            default: return "obj"
            }
        case .character(let c):
            if test == .equalp { return "c\(String(c).uppercased())" }
            return "c\(c)"
        case .symbol(let s): return "y\(ObjectIdentifier(s).hashValue)"
        case .cons:
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

/// Unique token used to implement BLOCK / RETURN-FROM (and TAGBODY / GO).
public final class BlockToken {
    public let name: String
    public init(name: String) { self.name = name }
}

/// A simple stream. See StreamsIO.swift for the file / input variants.
public final class LispStream {
    public enum Kind {
        case stringOutput
        case standardOutput
        case stringInput
        case fileOutput
        case fileInput
    }
    public let kind: Kind
    public var buffer: String = ""
    public var writer: ((String) -> Void)?

    // Input streams.
    public var inputChars: [Character] = []
    public var inputPos: Int = 0
    /// When set, this input stream delegates to a live Reader (used for
    /// user reader-macro functions).
    public weak var backingReader: Reader?

    // File streams.
    public var fileHandle: FileHandle?
    public var path: String?
    public var isOpen: Bool = true

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
        case .fileOutput:
            if isOpen, let h = fileHandle, let data = s.data(using: .utf8) {
                h.write(data)
            }
        default:
            break
        }
    }

    public func readChar() -> Character? {
        if let r = backingReader {
            return r.readCharRaw()
        }
        guard inputPos < inputChars.count else { return nil }
        let c = inputChars[inputPos]
        inputPos += 1
        return c
    }

    public func peekChar() -> Character? {
        if let r = backingReader {
            return r.peekCharRaw()
        }
        guard inputPos < inputChars.count else { return nil }
        return inputChars[inputPos]
    }

    public func unreadChar() {
        if inputPos > 0 { inputPos -= 1 }
    }
}

/// Base class for all callable objects.
public class LispFunction {
    public var name: String
    public var documentation: String?
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

/// A graphics window created from Lisp (see Graphics.swift).
public final class GraphicsWindow {
    public let id = UUID()
    public var title: String
    public let context: GraphicsContext2D
    public var isClosed = false

    public init(title: String, width: Double, height: Double) {
        self.title = title
        self.context = GraphicsContext2D()
        self.context.canvasWidth = width
        self.context.canvasHeight = height
    }
}

/// The central value type.
public enum LispValue {
    case null                           // NIL / empty list
    case int(Int)
    case bignum(BigInt)
    case ratio(BigRational)
    case double(Double)
    case complex(LispComplex)
    case string(LispString)
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
    case graphicsWindow(GraphicsWindow)
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

    /// Build a string value.
    public static func str(_ s: String) -> LispValue {
        return .string(LispString(s))
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
        switch self {
        case .int(let i): return i
        case .bignum(let b): return Int(exactly: b)
        default: return nil
        }
    }

    public var asDouble: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .bignum(let b): return Double(b)
        case .ratio(let r): return r.doubleValue
        case .double(let d): return d
        default: return nil
        }
    }

    public var asString: String? {
        if case .string(let s) = self { return s.string }
        return nil
    }

    public var asLispString: LispString? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var asFunction: LispFunction? {
        if case .function(let f) = self { return f }
        return nil
    }

    public var isNumber: Bool {
        switch self {
        case .int, .bignum, .ratio, .double, .complex: return true
        default: return false
        }
    }

    public var isRealNumber: Bool {
        switch self {
        case .int, .bignum, .ratio, .double: return true
        default: return false
        }
    }

    public var isExactInteger: Bool {
        switch self {
        case .int, .bignum: return true
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
        case (.string(let x), .string(let y)): return x === y
        case (.vector(let x), .vector(let y)): return x === y
        case (.hashTable(let x), .hashTable(let y)): return x === y
        case (.function(let x), .function(let y)): return x === y
        case (.instance(let x), .instance(let y)): return x === y
        case (.lispClass(let x), .lispClass(let y)): return x === y
        case (.package(let x), .package(let y)): return x === y
        case (.blockToken(let x), .blockToken(let y)): return x === y
        case (.stream(let x), .stream(let y)): return x === y
        case (.graphicsWindow(let x), .graphicsWindow(let y)): return x === y
        case (.double(let x), .double(let y)): return x == y
        case (.bignum(let x), .bignum(let y)): return x == y
        case (.ratio(let x), .ratio(let y)):
            return x.num == y.num && x.den == y.den
        case (.complex(let x), .complex(let y)): return x === y
        default: return false
        }
    }

    public static func eql(_ a: LispValue, _ b: LispValue) -> Bool {
        switch (a, b) {
        case (.int(let x), .int(let y)): return x == y
        case (.bignum(let x), .bignum(let y)): return x == y
        case (.ratio(let x), .ratio(let y)):
            return x.num == y.num && x.den == y.den
        case (.double(let x), .double(let y)): return x == y
        case (.complex(let x), .complex(let y)):
            return eql(x.re, y.re) && eql(x.im, y.im)
        case (.character(let x), .character(let y)): return x == y
        default: return eq(a, b)
        }
    }

    public static func equal(_ a: LispValue, _ b: LispValue) -> Bool {
        switch (a, b) {
        case (.cons(let x), .cons(let y)):
            return equal(x.car, y.car) && equal(x.cdr, y.cdr)
        case (.string(let x), .string(let y)):
            return x.chars == y.chars
        default:
            return eql(a, b)
        }
    }

    public static func equalp(_ a: LispValue, _ b: LispValue) -> Bool {
        switch (a, b) {
        case (.character(let x), .character(let y)):
            return String(x).uppercased() == String(y).uppercased()
        case (.string(let x), .string(let y)):
            return x.string.uppercased() == y.string.uppercased()
        case (.cons(let x), .cons(let y)):
            return equalp(x.car, y.car) && equalp(x.cdr, y.cdr)
        case (.vector(let x), .vector(let y)):
            let xe = x.activeElements
            let ye = y.activeElements
            if xe.count != ye.count { return false }
            for i in 0..<xe.count {
                if !equalp(xe[i], ye[i]) { return false }
            }
            return true
        case (.hashTable(let x), .hashTable(let y)):
            if x.count != y.count { return false }
            for (k, v) in x.allPairs() {
                guard let other = y.get(k), equalp(v, other) else { return false }
            }
            return true
        case (.instance(let x), .instance(let y)):
            // EQUALP descends structures of the same class.
            if x.clazz !== y.clazz || x.clazz.kind != .structure {
                return eq(a, b)
            }
            if x.slots.count != y.slots.count { return false }
            for i in 0..<x.slots.count {
                switch (x.slots[i], y.slots[i]) {
                case (nil, nil): continue
                case (let xv?, let yv?):
                    if !equalp(xv, yv) { return false }
                default: return false
                }
            }
            return true
        default:
            if a.isNumber && b.isNumber {
                return (try? NumericOps.numericEqual(a, b)) ?? false
            }
            return eq(a, b)
        }
    }
}
