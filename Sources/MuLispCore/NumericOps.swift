// NumericOps.swift
// The full numeric tower: fixnum -> bignum -> ratio -> float -> complex.

import Foundation
import BigInt

public struct NumericError: Error {
    public enum Kind {
        case notANumber(LispValue)
        case divisionByZero
        case notAReal(LispValue)      // complex where a real is required
    }
    public let kind: Kind
}

/// An exact rational number. Invariants: den > 0, gcd(|num|, den) == 1,
/// den != 1 (integral values are normalized to int/bignum).
public struct BigRational {
    public let num: BigInt
    public let den: BigInt
    init(unchecked num: BigInt, den: BigInt) {
        self.num = num
        self.den = den
    }
    public var doubleValue: Double {
        return Double(num) / Double(den)
    }
}

/// A complex number. Components are real (never complex).
public final class LispComplex {
    public let re: LispValue
    public let im: LispValue
    public init(re: LispValue, im: LispValue) {
        self.re = re
        self.im = im
    }
}

public enum NumericOps {

    // MARK: - Construction / normalization

    public static func makeInteger(_ v: BigInt) -> LispValue {
        if let i = Int(exactly: v) {
            return .int(i)
        }
        return .bignum(v)
    }

    public static func makeRational(_ num: BigInt, _ den: BigInt) throws -> LispValue {
        if den == 0 {
            throw NumericError(kind: .divisionByZero)
        }
        var n = num
        var d = den
        if d < 0 {
            n = -n
            d = -d
        }
        let g = n.magnitude.greatestCommonDivisor(with: d.magnitude)
        if g > 1 {
            n /= BigInt(g)
            d /= BigInt(g)
        }
        if d == 1 {
            return makeInteger(n)
        }
        return .ratio(BigRational(unchecked: n, den: d))
    }

    /// CL rule: a complex with an exact (rational) zero imaginary part is a
    /// real; a float 0.0 imaginary part keeps it complex.
    public static func makeComplex(_ re: LispValue, _ im: LispValue) -> LispValue {
        switch im {
        case .int(0):
            return re
        case .bignum(let b) where b == 0:
            return re
        default:
            return .complex(LispComplex(re: re, im: im))
        }
    }

    // MARK: - Classification

    /// 0 fixnum, 1 bignum, 2 ratio, 3 float, 4 complex; nil = not a number.
    static func level(_ v: LispValue) -> Int? {
        switch v {
        case .int: return 0
        case .bignum: return 1
        case .ratio: return 2
        case .double: return 3
        case .complex: return 4
        default: return nil
        }
    }

    static func bigIntValue(_ v: LispValue) -> BigInt? {
        switch v {
        case .int(let i): return BigInt(i)
        case .bignum(let b): return b
        default: return nil
        }
    }

    static func rationalValue(_ v: LispValue) -> (BigInt, BigInt)? {
        switch v {
        case .int(let i): return (BigInt(i), 1)
        case .bignum(let b): return (b, 1)
        case .ratio(let r): return (r.num, r.den)
        default: return nil
        }
    }

    static func doubleValue(_ v: LispValue) -> Double? {
        switch v {
        case .int(let i): return Double(i)
        case .bignum(let b): return Double(b)
        case .ratio(let r): return r.doubleValue
        case .double(let d): return d
        default: return nil
        }
    }

    static func complexParts(_ v: LispValue) -> (LispValue, LispValue) {
        if case .complex(let c) = v {
            return (c.re, c.im)
        }
        return (v, .int(0))
    }

    public static func isExactZero(_ v: LispValue) -> Bool {
        switch v {
        case .int(0): return true
        case .bignum(let b): return b == 0
        default: return false
        }
    }

    public static func isZero(_ v: LispValue) -> Bool {
        switch v {
        case .int(0): return true
        case .bignum(let b): return b == 0
        case .double(let d): return d == 0
        case .ratio: return false
        case .complex(let c): return isZero(c.re) && isZero(c.im)
        default: return false
        }
    }

    // MARK: - Binary operations

    private static func requireLevels(_ a: LispValue, _ b: LispValue)
        throws -> (Int, Int) {
        guard let la = level(a) else {
            throw NumericError(kind: .notANumber(a))
        }
        guard let lb = level(b) else {
            throw NumericError(kind: .notANumber(b))
        }
        return (la, lb)
    }

    public static func add(_ a: LispValue, _ b: LispValue) throws -> LispValue {
        let (la, lb) = try requireLevels(a, b)
        let lvl = max(la, lb)
        switch lvl {
        case 0:
            guard case .int(let x) = a, case .int(let y) = b else { break }
            let (r, overflow) = x.addingReportingOverflow(y)
            if overflow { return makeInteger(BigInt(x) + BigInt(y)) }
            return .int(r)
        case 1:
            return makeInteger(bigIntValue(a)! + bigIntValue(b)!)
        case 2:
            let (an, ad) = rationalValue(a)!
            let (bn, bd) = rationalValue(b)!
            return try makeRational(an * bd + bn * ad, ad * bd)
        case 3:
            return .double(doubleValue(a)! + doubleValue(b)!)
        default:
            let (ar, ai) = complexParts(a)
            let (br, bi) = complexParts(b)
            return makeComplex(try add(ar, br), try add(ai, bi))
        }
        return makeInteger(bigIntValue(a)! + bigIntValue(b)!)
    }

    public static func sub(_ a: LispValue, _ b: LispValue) throws -> LispValue {
        let (la, lb) = try requireLevels(a, b)
        let lvl = max(la, lb)
        switch lvl {
        case 0:
            guard case .int(let x) = a, case .int(let y) = b else { break }
            let (r, overflow) = x.subtractingReportingOverflow(y)
            if overflow { return makeInteger(BigInt(x) - BigInt(y)) }
            return .int(r)
        case 1:
            return makeInteger(bigIntValue(a)! - bigIntValue(b)!)
        case 2:
            let (an, ad) = rationalValue(a)!
            let (bn, bd) = rationalValue(b)!
            return try makeRational(an * bd - bn * ad, ad * bd)
        case 3:
            return .double(doubleValue(a)! - doubleValue(b)!)
        default:
            let (ar, ai) = complexParts(a)
            let (br, bi) = complexParts(b)
            return makeComplex(try sub(ar, br), try sub(ai, bi))
        }
        return makeInteger(bigIntValue(a)! - bigIntValue(b)!)
    }

    public static func mul(_ a: LispValue, _ b: LispValue) throws -> LispValue {
        let (la, lb) = try requireLevels(a, b)
        let lvl = max(la, lb)
        switch lvl {
        case 0:
            guard case .int(let x) = a, case .int(let y) = b else { break }
            let (r, overflow) = x.multipliedReportingOverflow(by: y)
            if overflow { return makeInteger(BigInt(x) * BigInt(y)) }
            return .int(r)
        case 1:
            return makeInteger(bigIntValue(a)! * bigIntValue(b)!)
        case 2:
            let (an, ad) = rationalValue(a)!
            let (bn, bd) = rationalValue(b)!
            return try makeRational(an * bn, ad * bd)
        case 3:
            return .double(doubleValue(a)! * doubleValue(b)!)
        default:
            // (a+bi)(c+di) = (ac-bd) + (ad+bc)i
            let (ar, ai) = complexParts(a)
            let (br, bi) = complexParts(b)
            let re = try sub(try mul(ar, br), try mul(ai, bi))
            let im = try add(try mul(ar, bi), try mul(ai, br))
            return makeComplex(re, im)
        }
        return makeInteger(bigIntValue(a)! * bigIntValue(b)!)
    }

    /// Exact division of exact arguments yields a rational.
    public static func div(_ a: LispValue, _ b: LispValue) throws -> LispValue {
        let (la, lb) = try requireLevels(a, b)
        let lvl = max(la, lb)
        switch lvl {
        case 0, 1, 2:
            let (an, ad) = rationalValue(a)!
            let (bn, bd) = rationalValue(b)!
            if bn == 0 {
                throw NumericError(kind: .divisionByZero)
            }
            return try makeRational(an * bd, ad * bn)
        case 3:
            let d = doubleValue(b)!
            if d == 0 {
                throw NumericError(kind: .divisionByZero)
            }
            return .double(doubleValue(a)! / d)
        default:
            // (a+bi)/(c+di) = ((ac+bd) + (bc-ad)i) / (c^2+d^2)
            let (ar, ai) = complexParts(a)
            let (br, bi) = complexParts(b)
            let denom = try add(try mul(br, br), try mul(bi, bi))
            if isZero(denom) {
                throw NumericError(kind: .divisionByZero)
            }
            let re = try div(try add(try mul(ar, br), try mul(ai, bi)), denom)
            let im = try div(try sub(try mul(ai, br), try mul(ar, bi)), denom)
            return makeComplex(re, im)
        }
    }

    /// Returns -1, 0 or 1. Complex numbers cannot be ordered.
    public static func compare(_ a: LispValue, _ b: LispValue) throws -> Int {
        let (la, lb) = try requireLevels(a, b)
        if la == 4 || lb == 4 {
            throw NumericError(kind: .notAReal(la == 4 ? a : b))
        }
        let lvl = max(la, lb)
        switch lvl {
        case 0:
            guard case .int(let x) = a, case .int(let y) = b else { break }
            return x < y ? -1 : (x > y ? 1 : 0)
        case 1:
            let x = bigIntValue(a)!
            let y = bigIntValue(b)!
            return x < y ? -1 : (x > y ? 1 : 0)
        case 2:
            let (an, ad) = rationalValue(a)!
            let (bn, bd) = rationalValue(b)!
            let left = an * bd
            let right = bn * ad
            return left < right ? -1 : (left > right ? 1 : 0)
        default:
            let x = doubleValue(a)!
            let y = doubleValue(b)!
            return x < y ? -1 : (x > y ? 1 : 0)
        }
        let x = bigIntValue(a)!
        let y = bigIntValue(b)!
        return x < y ? -1 : (x > y ? 1 : 0)
    }

    /// Numeric equality (=), including complex numbers.
    public static func numericEqual(_ a: LispValue, _ b: LispValue) throws -> Bool {
        let (la, lb) = try requireLevels(a, b)
        if la == 4 || lb == 4 {
            let (ar, ai) = complexParts(a)
            let (br, bi) = complexParts(b)
            return try numericEqual(ar, br) && (try numericEqual(ai, bi))
        }
        return try compare(a, b) == 0
    }

    // MARK: - Integer operations

    public static func floorDiv(_ a: BigInt, _ b: BigInt) -> (BigInt, BigInt) {
        var q = a / b
        var r = a % b
        if r != 0 && ((r < 0) != (b < 0)) {
            q -= 1
            r += b
        }
        return (q, r)
    }

    public static func expt(_ base: LispValue, _ power: LispValue) throws -> LispValue {
        // Exact integer/rational base with integer power: exact result.
        if case .int(let p) = power {
            if let (n, d) = rationalValue(base) {
                if p >= 0 {
                    return try makeRational(n.power(p), d.power(p))
                } else {
                    if n == 0 { throw NumericError(kind: .divisionByZero) }
                    return try makeRational(d.power(-p), n.power(-p))
                }
            }
            if case .double(let b) = base {
                return .double(pow(b, Double(p)))
            }
            if case .complex = base {
                // Repeated multiplication for small integer powers.
                var result: LispValue = .int(1)
                let n = abs(p)
                if n > 1024 {
                    throw NumericError(kind: .notAReal(power))
                }
                for _ in 0..<n {
                    result = try mul(result, base)
                }
                if p < 0 {
                    return try div(.int(1), result)
                }
                return result
            }
        }
        // General case through doubles (negative base -> complex result).
        guard let b = doubleValue(base) else {
            if case .complex = base {
                throw NumericError(kind: .notAReal(base))
            }
            throw NumericError(kind: .notANumber(base))
        }
        guard let p = doubleValue(power) else {
            throw NumericError(kind: .notANumber(power))
        }
        if b < 0 && p != p.rounded() {
            // Principal value via polar form.
            let r = pow(-b, p)
            let theta = Double.pi * p
            return makeComplex(.double(r * cos(theta)), .double(r * sin(theta)))
        }
        return .double(pow(b, p))
    }

    public static func sqrtValue(_ v: LispValue) throws -> LispValue {
        switch v {
        case .int(let i) where i >= 0:
            let r = Int(Double(i).squareRoot())
            if r * r == i { return .int(r) }
            return .double(Double(i).squareRoot())
        case .bignum(let b) where b >= 0:
            let r = BigInt(b.magnitude.squareRoot())
            if r * r == b { return makeInteger(r) }
            return .double(Double(b).squareRoot())
        case .complex(let c):
            // sqrt in polar form.
            guard let re = doubleValue(c.re), let im = doubleValue(c.im) else {
                throw NumericError(kind: .notANumber(v))
            }
            let r = (re * re + im * im).squareRoot().squareRoot()
            let theta = atan2(im, re) / 2
            return makeComplex(.double(r * cos(theta)), .double(r * sin(theta)))
        default:
            guard let d = doubleValue(v) else {
                throw NumericError(kind: .notANumber(v))
            }
            if d < 0 {
                return makeComplex(.double(0), .double((-d).squareRoot()))
            }
            return .double(d.squareRoot())
        }
    }

    public static func negate(_ v: LispValue) throws -> LispValue {
        return try sub(.int(0), v)
    }

    public static func absValue(_ v: LispValue) throws -> LispValue {
        switch v {
        case .int(let i):
            if i == Int.min { return .bignum(-BigInt(i)) }
            return .int(abs(i))
        case .bignum(let b): return makeInteger(abs(b))
        case .ratio(let r): return try makeRational(abs(r.num), r.den)
        case .double(let d): return .double(abs(d))
        case .complex(let c):
            guard let re = doubleValue(c.re), let im = doubleValue(c.im) else {
                throw NumericError(kind: .notANumber(v))
            }
            return .double((re * re + im * im).squareRoot())
        default:
            throw NumericError(kind: .notANumber(v))
        }
    }
}
