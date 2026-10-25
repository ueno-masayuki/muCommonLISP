// NumericOps.swift
// Shared arithmetic used by both the VM fast ops and the builtin functions.

import Foundation

public struct NumericError: Error {
    public enum Kind {
        case notANumber(LispValue)
        case divisionByZero
    }
    public let kind: Kind
}

public enum NumericOps {

    @inline(__always)
    public static func add(_ a: LispValue, _ b: LispValue) throws -> LispValue {
        switch (a, b) {
        case (.int(let x), .int(let y)):
            let (r, overflow) = x.addingReportingOverflow(y)
            if overflow { return .double(Double(x) + Double(y)) }
            return .int(r)
        case (.int(let x), .double(let y)): return .double(Double(x) + y)
        case (.double(let x), .int(let y)): return .double(x + Double(y))
        case (.double(let x), .double(let y)): return .double(x + y)
        default:
            throw NumericError(kind: .notANumber(a.isNumber ? b : a))
        }
    }

    @inline(__always)
    public static func sub(_ a: LispValue, _ b: LispValue) throws -> LispValue {
        switch (a, b) {
        case (.int(let x), .int(let y)):
            let (r, overflow) = x.subtractingReportingOverflow(y)
            if overflow { return .double(Double(x) - Double(y)) }
            return .int(r)
        case (.int(let x), .double(let y)): return .double(Double(x) - y)
        case (.double(let x), .int(let y)): return .double(x - Double(y))
        case (.double(let x), .double(let y)): return .double(x - y)
        default:
            throw NumericError(kind: .notANumber(a.isNumber ? b : a))
        }
    }

    @inline(__always)
    public static func mul(_ a: LispValue, _ b: LispValue) throws -> LispValue {
        switch (a, b) {
        case (.int(let x), .int(let y)):
            let (r, overflow) = x.multipliedReportingOverflow(by: y)
            if overflow { return .double(Double(x) * Double(y)) }
            return .int(r)
        case (.int(let x), .double(let y)): return .double(Double(x) * y)
        case (.double(let x), .int(let y)): return .double(x * Double(y))
        case (.double(let x), .double(let y)): return .double(x * y)
        default:
            throw NumericError(kind: .notANumber(a.isNumber ? b : a))
        }
    }

    /// Division. Integer division that is not exact falls back to Double
    /// (ratios are not supported).
    @inline(__always)
    public static func div(_ a: LispValue, _ b: LispValue) throws -> LispValue {
        switch (a, b) {
        case (.int(let x), .int(let y)):
            if y == 0 { throw NumericError(kind: .divisionByZero) }
            if x % y == 0 { return .int(x / y) }
            return .double(Double(x) / Double(y))
        case (.int(let x), .double(let y)):
            if y == 0 { throw NumericError(kind: .divisionByZero) }
            return .double(Double(x) / y)
        case (.double(let x), .int(let y)):
            if y == 0 { throw NumericError(kind: .divisionByZero) }
            return .double(x / Double(y))
        case (.double(let x), .double(let y)):
            if y == 0 { throw NumericError(kind: .divisionByZero) }
            return .double(x / y)
        default:
            throw NumericError(kind: .notANumber(a.isNumber ? b : a))
        }
    }

    /// Returns -1, 0 or 1.
    @inline(__always)
    public static func compare(_ a: LispValue, _ b: LispValue) throws -> Int {
        switch (a, b) {
        case (.int(let x), .int(let y)):
            return x < y ? -1 : (x > y ? 1 : 0)
        case (.int(let x), .double(let y)):
            let dx = Double(x)
            return dx < y ? -1 : (dx > y ? 1 : 0)
        case (.double(let x), .int(let y)):
            let dy = Double(y)
            return x < dy ? -1 : (x > dy ? 1 : 0)
        case (.double(let x), .double(let y)):
            return x < y ? -1 : (x > y ? 1 : 0)
        default:
            throw NumericError(kind: .notANumber(a.isNumber ? b : a))
        }
    }
}
