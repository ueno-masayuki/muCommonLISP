// BuiltinsSeq.swift
// The remaining sequence and list functions.

import Foundation

extension Interpreter {

    func registerSequenceBuiltins() {
        let lisp = registry.lisp

        func startEnd(_ keys: [String: LispValue],
                      _ count: Int) throws -> (Int, Int) {
            var start = 0
            var end = count
            if case .int(let s)? = keys["START"]?.firstValue { start = s }
            if let e = keys["END"], case .int(let n) = e.firstValue { end = n }
            guard start >= 0, start <= end, end <= count else {
                throw lispError("ERROR", "bad :start/:end bounds")
            }
            return (start, end)
        }

        // --- Sequence functions ---

        defBuiltin("SUBSTITUTE", 3, nil) { [unowned self] args in
            let keys = try self.parseKeys(args, from: 3)
            let (test, key) = self.testAndKey(keys)
            var items = try self.seqToArray(args[2])
            for i in 0..<items.count {
                if try test(args[1].firstValue, key(items[i])) {
                    items[i] = args[0].firstValue
                }
            }
            return self.seqRebuild(like: args[2], items)
        }
        lisp.intern("NSUBSTITUTE").function =
            lisp.intern("SUBSTITUTE").function

        defBuiltin("SUBSTITUTE-IF", 3, nil) { [unowned self] args in
            var items = try self.seqToArray(args[2])
            for i in 0..<items.count {
                if try self.callPredicate(args[1], [items[i]]) {
                    items[i] = args[0].firstValue
                }
            }
            return self.seqRebuild(like: args[2], items)
        }

        defBuiltin("FILL", 2, nil) { [unowned self] args in
            let keys = try self.parseKeys(args, from: 2)
            switch args[0].firstValue {
            case .vector(let v):
                let (s, e) = try startEnd(keys, v.elements.count)
                for i in s..<e { v.elements[i] = args[1].firstValue }
                return args[0].firstValue
            case .string(let str):
                guard case .character(let c) = args[1].firstValue else {
                    throw self.typeError(args[1], expected: "CHARACTER")
                }
                let (s, e) = try startEnd(keys, str.chars.count)
                for i in s..<e { str.chars[i] = c }
                return args[0].firstValue
            case .cons:
                var cur = args[0].firstValue
                while case .cons(let c) = cur {
                    c.car = args[1].firstValue
                    cur = c.cdr
                }
                return args[0].firstValue
            default:
                throw self.typeError(args[0], expected: "SEQUENCE")
            }
        }

        defBuiltin("REPLACE", 2, nil) { [unowned self] args in
            // Simplified: copies as much of seq2 into seq1 as fits.
            let source = try self.seqToArray(args[1])
            switch args[0].firstValue {
            case .vector(let v):
                for i in 0..<min(v.elements.count, source.count) {
                    v.elements[i] = source[i]
                }
            case .string(let str):
                for i in 0..<min(str.chars.count, source.count) {
                    if case .character(let c) = source[i] {
                        str.chars[i] = c
                    }
                }
            case .cons:
                var cur = args[0].firstValue
                var i = 0
                while case .cons(let c) = cur, i < source.count {
                    c.car = source[i]
                    cur = c.cdr
                    i += 1
                }
            default:
                throw self.typeError(args[0], expected: "SEQUENCE")
            }
            return args[0].firstValue
        }

        defBuiltin("MISMATCH", 2, nil) { [unowned self] args in
            let keys = try self.parseKeys(args, from: 2)
            let (test, key) = self.testAndKey(keys)
            let a = try self.seqToArray(args[0])
            let b = try self.seqToArray(args[1])
            let n = min(a.count, b.count)
            for i in 0..<n {
                if try !test(key(a[i]), key(b[i])) {
                    return .int(i)
                }
            }
            if a.count != b.count {
                return .int(n)
            }
            return .null
        }

        defBuiltin("MERGE", 3, nil) { [unowned self] args in
            // (merge result-type seq1 seq2 predicate &key key)
            guard args.count >= 4 else {
                throw self.lispError("PROGRAM-ERROR", "merge needs 4 arguments")
            }
            let keys = try self.parseKeys(args, from: 4)
            let keyFn = keys["KEY"]
            let a = try self.seqToArray(args[1])
            let b = try self.seqToArray(args[2])
            let pred = args[3].firstValue
            func keyOf(_ v: LispValue) throws -> LispValue {
                if let k = keyFn, !k.isNil {
                    return try self.apply(k, [v]).firstValue
                }
                return v
            }
            var result: [LispValue] = []
            var i = 0
            var j = 0
            while i < a.count && j < b.count {
                if try self.apply(pred, [keyOf(b[j]), keyOf(a[i])]).isTrue {
                    result.append(b[j]); j += 1
                } else {
                    result.append(a[i]); i += 1
                }
            }
            result.append(contentsOf: a[i...])
            result.append(contentsOf: b[j...])
            guard case .symbol(let type) = args[0].firstValue else {
                return LispValue.list(result)
            }
            switch type.name {
            case "VECTOR", "SIMPLE-VECTOR":
                return .vector(LispVector(result))
            case "STRING", "SIMPLE-STRING":
                var s = ""
                for v in result {
                    if case .character(let c) = v { s.append(c) }
                }
                return .str(s)
            default:
                return LispValue.list(result)
            }
        }

        defBuiltin("MAP", 2, nil) { [unowned self] args in
            // (map result-type fn &rest sequences)
            guard args.count >= 3 else {
                throw self.lispError("PROGRAM-ERROR", "map needs 3 arguments")
            }
            var lists: [[LispValue]] = []
            for l in args.dropFirst(2) {
                lists.append(try self.seqToArray(l))
            }
            let n = lists.map { $0.count }.min() ?? 0
            var result: [LispValue] = []
            for i in 0..<n {
                result.append(try self.apply(args[1].firstValue,
                                             lists.map { $0[i] }).firstValue)
            }
            switch args[0].firstValue {
            case .null:
                return .null
            case .symbol(let type):
                switch type.name {
                case "VECTOR", "SIMPLE-VECTOR":
                    return .vector(LispVector(result))
                case "STRING", "SIMPLE-STRING":
                    var s = ""
                    for v in result {
                        if case .character(let c) = v { s.append(c) }
                    }
                    return .str(s)
                default:
                    return LispValue.list(result)
                }
            default:
                return LispValue.list(result)
            }
        }

        defBuiltin("MAP-INTO", 2, nil) { [unowned self] args in
            var lists: [[LispValue]] = []
            for l in args.dropFirst(2) {
                lists.append(try self.seqToArray(l))
            }
            let limit = lists.map { $0.count }.min() ?? Int.max
            switch args[0].firstValue {
            case .vector(let v):
                let n = min(v.elements.count, limit)
                for i in 0..<n {
                    v.elements[i] = try self.apply(args[1].firstValue,
                                                   lists.map { $0[i] }).firstValue
                }
            case .cons:
                var cur = args[0].firstValue
                var i = 0
                while case .cons(let c) = cur, i < limit {
                    c.car = try self.apply(args[1].firstValue,
                                           lists.map { $0[i] }).firstValue
                    cur = c.cdr
                    i += 1
                }
            default:
                throw self.typeError(args[0], expected: "SEQUENCE")
            }
            return args[0].firstValue
        }

        func ifNotVariant(_ name: String, _ positive: String) {
            // find-if-not etc: complement the predicate and delegate.
            defBuiltin(name, 2, nil) { [unowned self] args in
                guard let base = self.registry.lisp.intern(positive).function else {
                    throw self.lispError("UNDEFINED-FUNCTION", positive)
                }
                let pred = args[0].firstValue
                let complemented = Builtin(name: "COMPLEMENT",
                                           minArgs: 0, maxArgs: nil) {
                    [unowned self] inner in
                    let r = try self.apply(pred, inner)
                    return r.isTrue ? .null : self.tValue
                }
                var newArgs = args
                newArgs[0] = .function(complemented)
                return try self.applyFunction(base, newArgs)
            }
        }
        ifNotVariant("FIND-IF-NOT", "FIND-IF")
        ifNotVariant("POSITION-IF-NOT", "POSITION-IF")
        ifNotVariant("COUNT-IF-NOT", "COUNT-IF")
        ifNotVariant("MEMBER-IF-NOT", "MEMBER-IF")

        defBuiltin("NOTANY", 2, nil) { [unowned self] args in
            guard let someFn = self.registry.lisp.intern("SOME").function else {
                throw self.lispError("UNDEFINED-FUNCTION", "SOME")
            }
            let r = try self.applyFunction(someFn, args)
            return r.isTrue ? .null : self.tValue
        }

        defBuiltin("NOTEVERY", 2, nil) { [unowned self] args in
            guard let everyFn = self.registry.lisp.intern("EVERY").function else {
                throw self.lispError("UNDEFINED-FUNCTION", "EVERY")
            }
            let r = try self.applyFunction(everyFn, args)
            return r.isTrue ? .null : self.tValue
        }

        defSetfHandler("SUBSEQ") { [unowned self] args in
            // (newval sequence start [end])
            let source = try self.seqToArray(args[0])
            guard case .int(let start) = args[2].firstValue else {
                throw self.typeError(args[2], expected: "INTEGER")
            }
            switch args[1].firstValue {
            case .vector(let v):
                var end = v.elements.count
                if args.count > 3, case .int(let e) = args[3].firstValue {
                    end = e
                }
                for (offset, value) in source.enumerated() {
                    let i = start + offset
                    if i >= end || i >= v.elements.count { break }
                    v.elements[i] = value
                }
            case .string(let str):
                var end = str.chars.count
                if args.count > 3, case .int(let e) = args[3].firstValue {
                    end = e
                }
                for (offset, value) in source.enumerated() {
                    let i = start + offset
                    if i >= end || i >= str.chars.count { break }
                    if case .character(let c) = value { str.chars[i] = c }
                }
            default:
                throw self.typeError(args[1], expected: "SEQUENCE")
            }
            return args[0]
        }

        // --- List functions ---

        defBuiltin("ADJOIN", 2, nil) { [unowned self] args in
            let keys = try self.parseKeys(args, from: 2)
            let (test, key) = self.testAndKey(keys)
            let item = args[0].firstValue
            var cur = args[1].firstValue
            while case .cons(let c) = cur {
                if try test(key(item), key(c.car)) {
                    return args[1].firstValue
                }
                cur = c.cdr
            }
            return .cons(Cons(car: item, cdr: args[1].firstValue))
        }

        defBuiltin("COPY-TREE", 1, 1) { args in
            func copy(_ v: LispValue) -> LispValue {
                if case .cons(let c) = v {
                    return .cons(Cons(car: copy(c.car), cdr: copy(c.cdr)))
                }
                return v
            }
            return copy(args[0].firstValue)
        }

        defBuiltin("TREE-EQUAL", 2, nil) { [unowned self] args in
            let keys = try self.parseKeys(args, from: 2)
            let (test, _) = self.testAndKey(keys)
            func walk(_ a: LispValue, _ b: LispValue) throws -> Bool {
                switch (a, b) {
                case (.cons(let x), .cons(let y)):
                    return try walk(x.car, y.car) && (try walk(x.cdr, y.cdr))
                case (.cons, _), (_, .cons):
                    return false
                default:
                    return try test(a, b)
                }
            }
            return try walk(args[0].firstValue, args[1].firstValue)
                ? self.tValue : .null
        }

        defBuiltin("SUBST", 3, nil) { [unowned self] args in
            let keys = try self.parseKeys(args, from: 3)
            let (test, key) = self.testAndKey(keys)
            func walk(_ v: LispValue) throws -> LispValue {
                if try test(args[1].firstValue, key(v)) {
                    return args[0].firstValue
                }
                if case .cons(let c) = v {
                    return .cons(Cons(car: try walk(c.car),
                                      cdr: try walk(c.cdr)))
                }
                return v
            }
            return try walk(args[2].firstValue)
        }
        lisp.intern("NSUBST").function = lisp.intern("SUBST").function

        defBuiltin("SUBLIS", 2, nil) { [unowned self] args in
            let keys = try self.parseKeys(args, from: 2)
            let (test, key) = self.testAndKey(keys)
            let alist = args[0].firstValue.asArray() ?? []
            func walk(_ v: LispValue) throws -> LispValue {
                for pair in alist {
                    if case .cons(let p) = pair,
                       try test(p.car, key(v)) {
                        return p.cdr
                    }
                }
                if case .cons(let c) = v {
                    return .cons(Cons(car: try walk(c.car),
                                      cdr: try walk(c.cdr)))
                }
                return v
            }
            return try walk(args[1].firstValue)
        }

        defBuiltin("PAIRLIS", 2, 3) { [unowned self] args in
            let keyList = try self.seqToArray(args[0])
            let valueList = try self.seqToArray(args[1])
            var result = args.count == 3 ? args[2].firstValue : .null
            for i in (0..<min(keyList.count, valueList.count)).reversed() {
                result = .cons(Cons(
                    car: .cons(Cons(car: keyList[i], cdr: valueList[i])),
                    cdr: result))
            }
            return result
        }

        defBuiltin("RASSOC", 2, nil) { [unowned self] args in
            let keys = try self.parseKeys(args, from: 2)
            let (test, key) = self.testAndKey(keys)
            for pair in args[1].firstValue.asArray() ?? [] {
                guard case .cons(let c) = pair else { continue }
                if try test(args[0].firstValue, key(c.cdr)) {
                    return pair
                }
            }
            return .null
        }

        defBuiltin("ASSOC-IF", 2, 2) { [unowned self] args in
            for pair in args[1].firstValue.asArray() ?? [] {
                guard case .cons(let c) = pair else { continue }
                if try self.callPredicate(args[0], [c.car]) {
                    return pair
                }
            }
            return .null
        }

        defBuiltin("RASSOC-IF", 2, 2) { [unowned self] args in
            for pair in args[1].firstValue.asArray() ?? [] {
                guard case .cons(let c) = pair else { continue }
                if try self.callPredicate(args[0], [c.cdr]) {
                    return pair
                }
            }
            return .null
        }

        defBuiltin("TAILP", 2, 2) { [unowned self] args in
            var cur = args[1].firstValue
            while true {
                if LispEquality.eql(args[0].firstValue, cur) {
                    return self.tValue
                }
                guard case .cons(let c) = cur else { return .null }
                cur = c.cdr
            }
        }

        defBuiltin("LDIFF", 2, 2) { args in
            var result: [LispValue] = []
            var cur = args[0].firstValue
            while case .cons(let c) = cur {
                if LispEquality.eql(args[1].firstValue, cur) { break }
                result.append(c.car)
                cur = c.cdr
            }
            return LispValue.list(result)
        }

        defBuiltin("REVAPPEND", 2, 2) { [unowned self] args in
            guard let items = args[0].firstValue.asArray() else {
                throw self.typeError(args[0], expected: "LIST")
            }
            var result = args[1].firstValue
            for item in items {
                result = .cons(Cons(car: item, cdr: result))
            }
            return result
        }
        lisp.intern("NRECONC").function = lisp.intern("REVAPPEND").function
        lisp.intern("NBUTLAST").function = lisp.intern("BUTLAST").function

        defBuiltin("MAPLIST", 2, nil) { [unowned self] args in
            var result: [LispValue] = []
            var cur = args[1].firstValue
            while case .cons = cur {
                result.append(try self.apply(args[0].firstValue, [cur]).firstValue)
                guard case .cons(let c) = cur else { break }
                cur = c.cdr
            }
            return LispValue.list(result)
        }

        defBuiltin("MAPL", 2, nil) { [unowned self] args in
            var cur = args[1].firstValue
            while case .cons(let c) = cur {
                _ = try self.apply(args[0].firstValue, [cur])
                cur = c.cdr
            }
            return args[1].firstValue
        }

        defBuiltin("MAPCON", 2, nil) { [unowned self] args in
            var result: [LispValue] = []
            var cur = args[1].firstValue
            while case .cons(let c) = cur {
                let piece = try self.apply(args[0].firstValue, [cur]).firstValue
                result.append(contentsOf: piece.asArray() ?? [])
                cur = c.cdr
            }
            return LispValue.list(result)
        }

        defBuiltin("COPY-ALIST", 1, 1) { [unowned self] args in
            guard let items = args[0].firstValue.asArray() else {
                throw self.typeError(args[0], expected: "LIST")
            }
            var result: [LispValue] = []
            for item in items {
                if case .cons(let c) = item {
                    result.append(.cons(Cons(car: c.car, cdr: c.cdr)))
                } else {
                    result.append(item)
                }
            }
            return LispValue.list(result)
        }
    }
}
