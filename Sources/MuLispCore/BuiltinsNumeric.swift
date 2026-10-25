// BuiltinsNumeric.swift
// Arithmetic over the full numeric tower, and numeric predicates.

import Foundation
import BigInt

extension Interpreter {

    func registerNumericBuiltins() {
        let lisp = registry.lisp

        func wrapNumeric<T>(_ body: () throws -> T) throws -> T {
            do {
                return try body()
            } catch let e as NumericError {
                switch e.kind {
                case .notANumber(let v):
                    throw self.typeError(v, expected: "NUMBER")
                case .divisionByZero:
                    throw self.lispError("DIVISION-BY-ZERO", "division by zero")
                case .notAReal(let v):
                    throw self.typeError(v, expected: "REAL")
                }
            }
        }

        func requireDouble(_ v: LispValue) throws -> Double {
            guard let d = v.firstValue.asDouble else {
                throw self.typeError(v, expected: "REAL")
            }
            return d
        }

        func requireInt(_ v: LispValue) throws -> Int {
            guard let i = v.firstValue.asInt else {
                throw self.typeError(v, expected: "INTEGER")
            }
            return i
        }

        func requireBigInt(_ v: LispValue) throws -> BigInt {
            switch v.firstValue {
            case .int(let i): return BigInt(i)
            case .bignum(let b): return b
            default: throw self.typeError(v, expected: "INTEGER")
            }
        }

        defBuiltin("+", 0, nil) { args in
            try wrapNumeric {
                var acc = LispValue.int(0)
                for a in args {
                    acc = try NumericOps.add(acc, a.firstValue)
                }
                return acc
            }
        }

        defBuiltin("-", 1, nil) { args in
            try wrapNumeric {
                if args.count == 1 {
                    return try NumericOps.sub(.int(0), args[0].firstValue)
                }
                var acc = args[0].firstValue
                for a in args.dropFirst() {
                    acc = try NumericOps.sub(acc, a.firstValue)
                }
                return acc
            }
        }

        defBuiltin("*", 0, nil) { args in
            try wrapNumeric {
                var acc = LispValue.int(1)
                for a in args {
                    acc = try NumericOps.mul(acc, a.firstValue)
                }
                return acc
            }
        }

        defBuiltin("/", 1, nil) { args in
            try wrapNumeric {
                if args.count == 1 {
                    return try NumericOps.div(.int(1), args[0].firstValue)
                }
                var acc = args[0].firstValue
                for a in args.dropFirst() {
                    acc = try NumericOps.div(acc, a.firstValue)
                }
                return acc
            }
        }

        defBuiltin("1+", 1, 1) { args in
            try wrapNumeric { try NumericOps.add(args[0].firstValue, .int(1)) }
        }
        defBuiltin("1-", 1, 1) { args in
            try wrapNumeric { try NumericOps.sub(args[0].firstValue, .int(1)) }
        }

        defBuiltin("=", 1, nil) { [unowned self] args in
            try wrapNumeric {
                for i in 0..<(args.count - 1) {
                    if try !NumericOps.numericEqual(args[i].firstValue,
                                                    args[i + 1].firstValue) {
                        return .null
                    }
                }
                return self.tValue
            }
        }

        func comparison(_ name: String, _ ok: @escaping (Int) -> Bool) {
            defBuiltin(name, 1, nil) { [unowned self] args in
                try wrapNumeric {
                    for i in 0..<(args.count - 1) {
                        let c = try NumericOps.compare(args[i].firstValue,
                                                       args[i + 1].firstValue)
                        if !ok(c) { return .null }
                    }
                    return self.tValue
                }
            }
        }
        comparison("<") { $0 < 0 }
        comparison(">") { $0 > 0 }
        comparison("<=") { $0 <= 0 }
        comparison(">=") { $0 >= 0 }

        defBuiltin("/=", 1, nil) { [unowned self] args in
            try wrapNumeric {
                for i in 0..<args.count {
                    for j in (i + 1)..<args.count {
                        if try NumericOps.numericEqual(args[i].firstValue,
                                                       args[j].firstValue) {
                            return .null
                        }
                    }
                }
                return self.tValue
            }
        }

        defBuiltin("MIN", 1, nil) { args in
            try wrapNumeric {
                var best = args[0].firstValue
                for a in args.dropFirst() {
                    if try NumericOps.compare(a.firstValue, best) < 0 {
                        best = a.firstValue
                    }
                }
                return best
            }
        }

        defBuiltin("MAX", 1, nil) { args in
            try wrapNumeric {
                var best = args[0].firstValue
                for a in args.dropFirst() {
                    if try NumericOps.compare(a.firstValue, best) > 0 {
                        best = a.firstValue
                    }
                }
                return best
            }
        }

        defBuiltin("ABS", 1, 1) { args in
            try wrapNumeric { try NumericOps.absValue(args[0].firstValue) }
        }

        // FLOOR / CEILING / TRUNCATE / ROUND: exact for exact arguments.
        func floorLike(_ name: String,
                       _ intRound: @escaping (BigInt, BigInt) -> BigInt,
                       _ dblRound: @escaping (Double) -> Double) {
            defBuiltin(name, 1, 2) { [unowned self] args in
                try wrapNumeric {
                    let a = args[0].firstValue
                    let b = args.count == 2 ? args[1].firstValue : .int(1)
                    // Exact path: both rational.
                    if let (an, ad) = NumericOps.rationalValue(a),
                       let (bn, bd) = NumericOps.rationalValue(b) {
                        if bn == 0 {
                            throw NumericError(kind: .divisionByZero)
                        }
                        // a/b = (an*bd) / (ad*bn)
                        let num = an * bd
                        let den = ad * bn
                        let q = intRound(num, den)
                        // remainder = a - q*b
                        let r = try NumericOps.sub(a,
                            try NumericOps.mul(NumericOps.makeInteger(q), b))
                        return .values([NumericOps.makeInteger(q), r])
                    }
                    let x = try requireDouble(args[0])
                    let y = args.count == 2 ? try requireDouble(args[1]) : 1.0
                    if y == 0 {
                        throw NumericError(kind: .divisionByZero)
                    }
                    let q = dblRound(x / y)
                    let rem = x - q * y
                    guard let qi = Int(exactly: q) else {
                        return .values([.double(q), .double(rem)])
                    }
                    return .values([.int(qi), .double(rem)])
                }
            }
        }
        func floorQ(_ n: BigInt, _ d: BigInt) -> BigInt {
            return NumericOps.floorDiv(n, d).0
        }
        func ceilQ(_ n: BigInt, _ d: BigInt) -> BigInt {
            let (q, r) = NumericOps.floorDiv(n, d)
            return r == 0 ? q : q + 1
        }
        func truncQ(_ n: BigInt, _ d: BigInt) -> BigInt {
            return n / d
        }
        func roundQ(_ n: BigInt, _ d: BigInt) -> BigInt {
            // Round half to even.
            let (q, r) = NumericOps.floorDiv(n, d)
            let twice = 2 * r
            if twice < d { return q }
            if twice > d { return q + 1 }
            return q % 2 == 0 ? q : q + 1
        }
        floorLike("FLOOR", floorQ) { $0.rounded(.down) }
        floorLike("CEILING", ceilQ) { $0.rounded(.up) }
        floorLike("TRUNCATE", truncQ) { $0.rounded(.towardZero) }
        floorLike("ROUND", roundQ) { $0.rounded(.toNearestOrEven) }

        defBuiltin("MOD", 2, 2) { [unowned self] args in
            try wrapNumeric {
                if let a = NumericOps.bigIntValue(args[0].firstValue),
                   let b = NumericOps.bigIntValue(args[1].firstValue) {
                    if b == 0 { throw NumericError(kind: .divisionByZero) }
                    return NumericOps.makeInteger(NumericOps.floorDiv(a, b).1)
                }
                let a = try requireDouble(args[0])
                let b = try requireDouble(args[1])
                if b == 0 {
                    throw self.lispError("DIVISION-BY-ZERO", "division by zero")
                }
                let r = a.truncatingRemainder(dividingBy: b)
                return .double((r != 0 && (r < 0) != (b < 0)) ? r + b : r)
            }
        }

        defBuiltin("REM", 2, 2) { [unowned self] args in
            try wrapNumeric {
                if let a = NumericOps.bigIntValue(args[0].firstValue),
                   let b = NumericOps.bigIntValue(args[1].firstValue) {
                    if b == 0 { throw NumericError(kind: .divisionByZero) }
                    return NumericOps.makeInteger(a % b)
                }
                let a = try requireDouble(args[0])
                let b = try requireDouble(args[1])
                if b == 0 {
                    throw self.lispError("DIVISION-BY-ZERO", "division by zero")
                }
                return .double(a.truncatingRemainder(dividingBy: b))
            }
        }

        defBuiltin("EXPT", 2, 2) { args in
            try wrapNumeric {
                try NumericOps.expt(args[0].firstValue, args[1].firstValue)
            }
        }

        defBuiltin("SQRT", 1, 1) { args in
            try wrapNumeric { try NumericOps.sqrtValue(args[0].firstValue) }
        }

        defBuiltin("ISQRT", 1, 1) { [unowned self] args in
            let b = try requireBigInt(args[0])
            guard b >= 0 else {
                throw self.typeError(args[0], expected: "(INTEGER 0)")
            }
            return NumericOps.makeInteger(BigInt(b.magnitude.squareRoot()))
        }

        func mathFn(_ name: String, _ f: @escaping (Double) -> Double) {
            defBuiltin(name, 1, 1) { args in
                return .double(f(try requireDouble(args[0])))
            }
        }
        mathFn("SIN", sin)
        mathFn("COS", cos)
        mathFn("TAN", tan)
        mathFn("ASIN", asin)
        mathFn("ACOS", acos)
        mathFn("SINH", sinh)
        mathFn("COSH", cosh)
        mathFn("TANH", tanh)
        mathFn("EXP", exp)

        defBuiltin("ATAN", 1, 2) { args in
            let y = try requireDouble(args[0])
            if args.count == 2 {
                let x = try requireDouble(args[1])
                return .double(atan2(y, x))
            }
            return .double(atan(y))
        }

        defBuiltin("LOG", 1, 2) { args in
            let x = try requireDouble(args[0])
            if args.count == 2 {
                let base = try requireDouble(args[1])
                return .double(log(x) / log(base))
            }
            return .double(log(x))
        }

        defBuiltin("GCD", 0, nil) { args in
            var acc = BigInt(0)
            for a in args {
                let v = try requireBigInt(a)
                acc = BigInt(acc.magnitude.greatestCommonDivisor(with: v.magnitude))
            }
            return NumericOps.makeInteger(acc)
        }

        defBuiltin("LCM", 0, nil) { args in
            var acc = BigInt(1)
            for a in args {
                let v = abs(try requireBigInt(a))
                if v == 0 { return .int(0) }
                let g = BigInt(acc.magnitude.greatestCommonDivisor(with: v.magnitude))
                acc = acc / g * v
            }
            return NumericOps.makeInteger(acc)
        }

        defBuiltin("LOGAND", 0, nil) { args in
            var acc = BigInt(-1)
            for a in args { acc &= try requireBigInt(a) }
            return NumericOps.makeInteger(acc)
        }
        defBuiltin("LOGIOR", 0, nil) { args in
            var acc = BigInt(0)
            for a in args { acc |= try requireBigInt(a) }
            return NumericOps.makeInteger(acc)
        }
        defBuiltin("LOGXOR", 0, nil) { args in
            var acc = BigInt(0)
            for a in args { acc ^= try requireBigInt(a) }
            return NumericOps.makeInteger(acc)
        }
        defBuiltin("LOGNOT", 1, 1) { args in
            return NumericOps.makeInteger(~(try requireBigInt(args[0])))
        }
        defBuiltin("ASH", 2, 2) { args in
            let x = try requireBigInt(args[0])
            let n = try requireInt(args[1])
            if n >= 0 {
                return NumericOps.makeInteger(x << n)
            }
            return NumericOps.makeInteger(x >> (-n))
        }
        defBuiltin("INTEGER-LENGTH", 1, 1) { args in
            let x = try requireBigInt(args[0])
            if x >= 0 {
                return .int(x.bitWidth - 1)
            }
            return .int((~x).bitWidth - 1)
        }

        func numPredicate(_ name: String,
                          _ f: @escaping (LispValue) throws -> Bool) {
            defBuiltin(name, 1, 1) { [unowned self] args in
                return try f(args[0].firstValue) ? self.tValue : .null
            }
        }
        numPredicate("ZEROP") { v in
            guard v.isNumber else {
                throw NumericError(kind: .notANumber(v))
            }
            return NumericOps.isZero(v)
        }
        numPredicate("PLUSP") { v in
            try NumericOps.compare(v, .int(0)) > 0
        }
        numPredicate("MINUSP") { v in
            try NumericOps.compare(v, .int(0)) < 0
        }
        numPredicate("EVENP") { v in
            try requireBigInt(v) % 2 == 0
        }
        numPredicate("ODDP") { v in
            try requireBigInt(v) % 2 != 0
        }
        numPredicate("NUMBERP") { v in v.isNumber }
        numPredicate("INTEGERP") { v in v.isExactInteger }
        numPredicate("FLOATP") { v in
            if case .double = v { return true }
            return false
        }
        numPredicate("REALP") { v in v.isRealNumber }
        numPredicate("RATIONALP") { v in
            switch v {
            case .int, .bignum, .ratio: return true
            default: return false
            }
        }
        numPredicate("COMPLEXP") { v in
            if case .complex = v { return true }
            return false
        }

        defBuiltin("SIGNUM", 1, 1) { args in
            try wrapNumeric {
                let v = args[0].firstValue
                if case .double(let d) = v {
                    return .double(d > 0 ? 1 : (d < 0 ? -1 : 0))
                }
                let c = try NumericOps.compare(v, .int(0))
                return .int(c)
            }
        }

        defBuiltin("NUMERATOR", 1, 1) { [unowned self] args in
            switch args[0].firstValue {
            case .int, .bignum: return args[0].firstValue
            case .ratio(let r): return NumericOps.makeInteger(r.num)
            default: throw self.typeError(args[0], expected: "RATIONAL")
            }
        }

        defBuiltin("DENOMINATOR", 1, 1) { [unowned self] args in
            switch args[0].firstValue {
            case .int, .bignum: return .int(1)
            case .ratio(let r): return NumericOps.makeInteger(r.den)
            default: throw self.typeError(args[0], expected: "RATIONAL")
            }
        }

        defBuiltin("COMPLEX", 1, 2) { [unowned self] args in
            let re = args[0].firstValue
            let im = args.count == 2 ? args[1].firstValue : .int(0)
            guard re.isRealNumber, im.isRealNumber else {
                throw self.typeError(re.isRealNumber ? args[1] : args[0],
                                     expected: "REAL")
            }
            return NumericOps.makeComplex(re, im)
        }

        defBuiltin("REALPART", 1, 1) { [unowned self] args in
            switch args[0].firstValue {
            case .complex(let c): return c.re
            default:
                guard args[0].firstValue.isNumber else {
                    throw self.typeError(args[0], expected: "NUMBER")
                }
                return args[0].firstValue
            }
        }

        defBuiltin("IMAGPART", 1, 1) { [unowned self] args in
            switch args[0].firstValue {
            case .complex(let c): return c.im
            case .double: return .double(0)
            default:
                guard args[0].firstValue.isNumber else {
                    throw self.typeError(args[0], expected: "NUMBER")
                }
                return .int(0)
            }
        }

        defBuiltin("CONJUGATE", 1, 1) { args in
            try wrapNumeric {
                if case .complex(let c) = args[0].firstValue {
                    return NumericOps.makeComplex(c.re,
                                                  try NumericOps.negate(c.im))
                }
                return args[0].firstValue
            }
        }

        defBuiltin("PHASE", 1, 1) { args in
            if case .complex(let c) = args[0].firstValue,
               let re = c.re.asDouble, let im = c.im.asDouble {
                return .double(atan2(im, re))
            }
            let d = try requireDouble(args[0])
            return .double(d >= 0 ? 0 : Double.pi)
        }

        defBuiltin("CIS", 1, 1) { args in
            let theta = try requireDouble(args[0])
            return NumericOps.makeComplex(.double(cos(theta)),
                                          .double(sin(theta)))
        }

        defBuiltin("FLOAT", 1, 2) { args in
            return .double(try requireDouble(args[0]))
        }

        defBuiltin("RATIONAL", 1, 1) { [unowned self] args in
            switch args[0].firstValue {
            case .int, .bignum, .ratio:
                return args[0].firstValue
            case .double(let d):
                guard d.isFinite else {
                    throw self.lispError("ERROR", "cannot rationalize \(d)")
                }
                // Exact conversion via the binary representation.
                let (mantissa, exponent) = (d.significandBitPattern, d.exponent)
                _ = mantissa; _ = exponent
                // Use a simple decimal approach: scale by 2^52.
                let scaled = d * Double(1 << 52)
                if scaled.rounded() == scaled, abs(scaled) < 9e15 {
                    return try wrapNumeric {
                        try NumericOps.makeRational(BigInt(Int(scaled)),
                                                    BigInt(1) << 52)
                    }
                }
                return try wrapNumeric {
                    try NumericOps.makeRational(BigInt(Int(d.rounded())), 1)
                }
            default:
                throw self.typeError(args[0], expected: "REAL")
            }
        }
        lisp.intern("RATIONALIZE").function = lisp.intern("RATIONAL").function

        defBuiltin("RANDOM", 1, 1) { [unowned self] args in
            switch args[0].firstValue {
            case .int(let n):
                guard n > 0 else {
                    throw self.lispError("ERROR", "random bound must be positive")
                }
                return .int(Int.random(in: 0..<n))
            case .double(let d):
                guard d > 0 else {
                    throw self.lispError("ERROR", "random bound must be positive")
                }
                return .double(Double.random(in: 0..<d))
            default:
                throw self.typeError(args[0], expected: "NUMBER")
            }
        }

        let piSym = lisp.intern("PI")
        piSym.value = .double(Double.pi)
        piSym.isConstant = true

        let mprf = lisp.intern("MOST-POSITIVE-FIXNUM")
        mprf.value = .int(Int.max)
        mprf.isConstant = true
        let mnrf = lisp.intern("MOST-NEGATIVE-FIXNUM")
        mnrf.value = .int(Int.min)
        mnrf.isConstant = true
    }
}
