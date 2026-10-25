// BuiltinsNumeric.swift
// Arithmetic and numeric predicates.

import Foundation

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
                }
            }
        }

        func requireDouble(_ v: LispValue) throws -> Double {
            guard let d = v.firstValue.asDouble else {
                throw self.typeError(v, expected: "NUMBER")
            }
            return d
        }

        func requireInt(_ v: LispValue) throws -> Int {
            guard case .int(let i) = v.firstValue else {
                throw self.typeError(v, expected: "INTEGER")
            }
            return i
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
        comparison("=") { $0 == 0 }
        comparison("<") { $0 < 0 }
        comparison(">") { $0 > 0 }
        comparison("<=") { $0 <= 0 }
        comparison(">=") { $0 >= 0 }

        defBuiltin("/=", 1, nil) { [unowned self] args in
            try wrapNumeric {
                for i in 0..<args.count {
                    for j in (i + 1)..<args.count {
                        if try NumericOps.compare(args[i].firstValue,
                                                  args[j].firstValue) == 0 {
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

        defBuiltin("ABS", 1, 1) { [unowned self] args in
            switch args[0].firstValue {
            case .int(let i): return .int(abs(i))
            case .double(let d): return .double(abs(d))
            default: throw self.typeError(args[0], expected: "NUMBER")
            }
        }

        func floorLike(_ name: String, _ f: @escaping (Double) -> Double) {
            defBuiltin(name, 1, 2) { [unowned self] args in
                var x = args[0].firstValue
                if args.count == 2 {
                    x = try wrapNumeric {
                        try NumericOps.div(args[0].firstValue, args[1].firstValue)
                    }
                    // Integer-exact division already yields an int quotient;
                    // recompute on doubles for the general case.
                    let a = try requireDouble(args[0])
                    let b = try requireDouble(args[1])
                    if b == 0 {
                        throw self.lispError("DIVISION-BY-ZERO", "division by zero")
                    }
                    x = .double(a / b)
                }
                let d = try requireDouble(x)
                let q = f(d)
                let quotient = LispValue.int(Int(q))
                // remainder = x - q*y
                if args.count == 2 {
                    let a = try requireDouble(args[0])
                    let b = try requireDouble(args[1])
                    let rem = a - q * b
                    let remValue: LispValue
                    if case .int = args[0].firstValue,
                       case .int = args[1].firstValue {
                        remValue = .int(Int(rem))
                    } else {
                        remValue = .double(rem)
                    }
                    return .values([quotient, remValue])
                }
                let rem = d - q
                let remValue: LispValue
                if case .int = args[0].firstValue {
                    remValue = .int(0)
                } else {
                    remValue = .double(rem)
                }
                return .values([quotient, remValue])
            }
        }
        floorLike("FLOOR") { $0.rounded(.down) }
        floorLike("CEILING") { $0.rounded(.up) }
        floorLike("TRUNCATE") { $0.rounded(.towardZero) }
        floorLike("ROUND") { $0.rounded(.toNearestOrEven) }

        defBuiltin("MOD", 2, 2) { [unowned self] args in
            switch (args[0].firstValue, args[1].firstValue) {
            case (.int(let a), .int(let b)):
                if b == 0 {
                    throw self.lispError("DIVISION-BY-ZERO", "division by zero")
                }
                let r = a % b
                return .int((r != 0 && (r < 0) != (b < 0)) ? r + b : r)
            default:
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
            switch (args[0].firstValue, args[1].firstValue) {
            case (.int(let a), .int(let b)):
                if b == 0 {
                    throw self.lispError("DIVISION-BY-ZERO", "division by zero")
                }
                return .int(a % b)
            default:
                let a = try requireDouble(args[0])
                let b = try requireDouble(args[1])
                if b == 0 {
                    throw self.lispError("DIVISION-BY-ZERO", "division by zero")
                }
                return .double(a.truncatingRemainder(dividingBy: b))
            }
        }

        defBuiltin("EXPT", 2, 2) { [unowned self] args in
            switch (args[0].firstValue, args[1].firstValue) {
            case (.int(let base), .int(let power)) where power >= 0:
                var result = 1
                var overflow = false
                for _ in 0..<power {
                    let (r, o) = result.multipliedReportingOverflow(by: base)
                    if o { overflow = true; break }
                    result = r
                }
                if !overflow { return .int(result) }
                return .double(pow(Double(base), Double(power)))
            default:
                let a = try requireDouble(args[0])
                let b = try requireDouble(args[1])
                _ = self
                return .double(pow(a, b))
            }
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

        defBuiltin("SQRT", 1, 1) { args in
            let x = try requireDouble(args[0])
            if case .int(let i) = args[0].firstValue, i >= 0 {
                let r = Int(Double(i).squareRoot())
                if r * r == i { return .int(r) }
            }
            return .double(x.squareRoot())
        }

        defBuiltin("ISQRT", 1, 1) { args in
            let i = try requireInt(args[0])
            return .int(Int(Double(i).squareRoot()))
        }

        defBuiltin("GCD", 0, nil) { args in
            func gcd(_ a: Int, _ b: Int) -> Int {
                var (x, y) = (abs(a), abs(b))
                while y != 0 { (x, y) = (y, x % y) }
                return x
            }
            var acc = 0
            for a in args {
                acc = gcd(acc, try requireInt(a))
            }
            return .int(acc)
        }

        defBuiltin("LCM", 0, nil) { args in
            func gcd(_ a: Int, _ b: Int) -> Int {
                var (x, y) = (abs(a), abs(b))
                while y != 0 { (x, y) = (y, x % y) }
                return x
            }
            var acc = 1
            for a in args {
                let v = abs(try requireInt(a))
                if v == 0 { return .int(0) }
                acc = acc / gcd(acc, v) * v
            }
            return .int(acc)
        }

        defBuiltin("LOGAND", 0, nil) { args in
            var acc = -1
            for a in args { acc &= try requireInt(a) }
            return .int(acc)
        }
        defBuiltin("LOGIOR", 0, nil) { args in
            var acc = 0
            for a in args { acc |= try requireInt(a) }
            return .int(acc)
        }
        defBuiltin("LOGXOR", 0, nil) { args in
            var acc = 0
            for a in args { acc ^= try requireInt(a) }
            return .int(acc)
        }
        defBuiltin("LOGNOT", 1, 1) { args in
            return .int(~(try requireInt(args[0])))
        }
        defBuiltin("ASH", 2, 2) { args in
            let x = try requireInt(args[0])
            let n = try requireInt(args[1])
            if n >= 0 {
                if n >= Int.bitWidth { return .int(0) }
                return .int(x << n)
            }
            let shift = -n
            if shift >= Int.bitWidth { return .int(x < 0 ? -1 : 0) }
            return .int(x >> shift)
        }

        func numPredicate(_ name: String,
                          _ f: @escaping (LispValue) throws -> Bool) {
            defBuiltin(name, 1, 1) { [unowned self] args in
                return try f(args[0].firstValue) ? self.tValue : .null
            }
        }
        numPredicate("ZEROP") { v in
            try requireDouble(v) == 0
        }
        numPredicate("PLUSP") { v in
            try requireDouble(v) > 0
        }
        numPredicate("MINUSP") { v in
            try requireDouble(v) < 0
        }
        numPredicate("EVENP") { v in
            try requireInt(v) % 2 == 0
        }
        numPredicate("ODDP") { v in
            try requireInt(v) % 2 != 0
        }
        numPredicate("NUMBERP") { v in v.isNumber }
        numPredicate("INTEGERP") { v in
            if case .int = v { return true }
            return false
        }
        numPredicate("FLOATP") { v in
            if case .double = v { return true }
            return false
        }
        numPredicate("REALP") { v in v.isNumber }
        numPredicate("RATIONALP") { v in
            if case .int = v { return true }
            return false
        }

        defBuiltin("FLOAT", 1, 2) { args in
            return .double(try requireDouble(args[0]))
        }

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
