// BuiltinsList.swift
// List and sequence builtins.

import Foundation

extension Interpreter {

    // MARK: - Sequence helpers

    /// Convert a sequence (list / vector / string) to an array of elements.
    func seqToArray(_ v: LispValue) throws -> [LispValue] {
        switch v.firstValue {
        case .null:
            return []
        case .cons:
            guard let items = v.firstValue.asArray() else {
                throw typeError(v, expected: "SEQUENCE")
            }
            return items
        case .vector(let vec):
            return vec.activeElements
        case .string(let s):
            return s.chars.map { .character($0) }
        default:
            throw typeError(v, expected: "SEQUENCE")
        }
    }

    /// Rebuild a sequence of the same kind as `like`.
    func seqRebuild(like: LispValue, _ items: [LispValue]) -> LispValue {
        switch like.firstValue {
        case .vector:
            return .vector(LispVector(items))
        case .string:
            var s = ""
            for i in items {
                if case .character(let c) = i { s.append(c) }
            }
            return .str(s)
        default:
            return LispValue.list(items)
        }
    }

    /// Parse trailing &key style arguments.
    func parseKeys(_ args: [LispValue], from index: Int) throws -> [String: LispValue] {
        var result: [String: LispValue] = [:]
        var i = index
        while i < args.count {
            guard case .symbol(let k) = args[i].firstValue, k.isKeyword,
                  i + 1 < args.count else {
                throw lispError("PROGRAM-ERROR", "malformed keyword arguments")
            }
            if result[k.name] == nil {
                result[k.name] = args[i + 1].firstValue
            }
            i += 2
        }
        return result
    }

    /// Build the (test, key) functions from parsed keyword arguments.
    func testAndKey(_ keys: [String: LispValue])
        -> (test: (LispValue, LispValue) throws -> Bool,
            key: (LispValue) throws -> LispValue) {
        let testFn = keys["TEST"]
        let keyFn = keys["KEY"]
        let test: (LispValue, LispValue) throws -> Bool = { [unowned self] a, b in
            if let t = testFn, !t.isNil {
                return try self.apply(t, [a, b]).isTrue
            }
            return LispEquality.eql(a, b)
        }
        let key: (LispValue) throws -> LispValue = { [unowned self] x in
            if let k = keyFn, !k.isNil {
                return try self.apply(k, [x]).firstValue
            }
            return x
        }
        return (test, key)
    }

    /// Call a predicate designator.
    func callPredicate(_ f: LispValue, _ args: [LispValue]) throws -> Bool {
        return try apply(f, args).isTrue
    }

    // MARK: - Registration

    func registerListBuiltins() {

        func carOf(_ v: LispValue) throws -> LispValue {
            switch v.firstValue {
            case .null: return .null
            case .cons(let c): return c.car
            default: throw self.typeError(v, expected: "LIST")
            }
        }
        func cdrOf(_ v: LispValue) throws -> LispValue {
            switch v.firstValue {
            case .null: return .null
            case .cons(let c): return c.cdr
            default: throw self.typeError(v, expected: "LIST")
            }
        }

        defBuiltin("CAR", 1, 1) { try carOf($0[0]) }
        defBuiltin("CDR", 1, 1) { try cdrOf($0[0]) }
        defBuiltin("FIRST", 1, 1) { try carOf($0[0]) }
        defBuiltin("REST", 1, 1) { try cdrOf($0[0]) }
        defBuiltin("CAAR", 1, 1) { try carOf(carOf($0[0])) }
        defBuiltin("CADR", 1, 1) { try carOf(cdrOf($0[0])) }
        defBuiltin("CDAR", 1, 1) { try cdrOf(carOf($0[0])) }
        defBuiltin("CDDR", 1, 1) { try cdrOf(cdrOf($0[0])) }
        defBuiltin("CADDR", 1, 1) { try carOf(cdrOf(cdrOf($0[0]))) }
        defBuiltin("CDDDR", 1, 1) { try cdrOf(cdrOf(cdrOf($0[0]))) }
        defBuiltin("SECOND", 1, 1) { try carOf(cdrOf($0[0])) }
        defBuiltin("THIRD", 1, 1) { try carOf(cdrOf(cdrOf($0[0]))) }
        defBuiltin("FOURTH", 1, 1) { try carOf(cdrOf(cdrOf(cdrOf($0[0])))) }
        defBuiltin("FIFTH", 1, 1) { try carOf(cdrOf(cdrOf(cdrOf(cdrOf($0[0]))))) }

        defBuiltin("CONS", 2, 2) { args in
            .cons(Cons(car: args[0].firstValue, cdr: args[1].firstValue))
        }

        defBuiltin("LIST", 0, nil) { args in
            LispValue.list(args.map { $0.firstValue })
        }

        defBuiltin("LIST*", 1, nil) { [unowned self] args in
            if args.count == 1 { return args[0] }
            let items = args.dropLast().map { $0.firstValue }
            _ = self
            return LispValue.list(Array(items), tail: args.last!.firstValue)
        }

        defBuiltin("RPLACA", 2, 2) { [unowned self] args in
            guard case .cons(let c) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "CONS")
            }
            c.car = args[1].firstValue
            return args[0]
        }

        defBuiltin("RPLACD", 2, 2) { [unowned self] args in
            guard case .cons(let c) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "CONS")
            }
            c.cdr = args[1].firstValue
            return args[0]
        }

        func setfCarHandler(_ setCar: Bool) -> ([LispValue]) throws -> LispValue {
            return { [unowned self] args in
                // (newval cons)
                guard case .cons(let c) = args[1].firstValue else {
                    throw self.typeError(args[1], expected: "CONS")
                }
                if setCar {
                    c.car = args[0].firstValue
                } else {
                    c.cdr = args[0].firstValue
                }
                return args[0]
            }
        }
        defSetfHandler("CAR", setfCarHandler(true))
        defSetfHandler("FIRST", setfCarHandler(true))
        defSetfHandler("CDR", setfCarHandler(false))
        defSetfHandler("REST", setfCarHandler(false))

        defSetfHandler("ELT") { [unowned self] args in
            // (newval sequence index)
            guard case .int(let i) = args[2].firstValue, i >= 0 else {
                throw self.typeError(args[2], expected: "INTEGER")
            }
            switch args[1].firstValue {
            case .vector(let v):
                guard i < v.elements.count else {
                    throw self.lispError("ERROR", "elt index out of range")
                }
                v.elements[i] = args[0].firstValue
                return args[0]
            case .cons:
                var cur = args[1].firstValue
                var k = 0
                while k < i {
                    guard case .cons(let c) = cur else {
                        throw self.lispError("ERROR", "elt index out of range")
                    }
                    cur = c.cdr
                    k += 1
                }
                guard case .cons(let c) = cur else {
                    throw self.lispError("ERROR", "elt index out of range")
                }
                c.car = args[0].firstValue
                return args[0]
            default:
                throw self.typeError(args[1], expected: "SEQUENCE")
            }
        }

        defBuiltin("APPEND", 0, nil) { [unowned self] args in
            if args.isEmpty { return .null }
            var items: [LispValue] = []
            for a in args.dropLast() {
                guard let list = a.firstValue.asArray() else {
                    throw self.typeError(a, expected: "LIST")
                }
                items.append(contentsOf: list)
            }
            return LispValue.list(items, tail: args.last!.firstValue)
        }
        // NCONC behaves like APPEND here (no structure sharing guarantees).
        registry.lisp.intern("NCONC").function =
            registry.lisp.intern("APPEND").function

        defBuiltin("REVERSE", 1, 1) { [unowned self] args in
            let items = try self.seqToArray(args[0])
            return self.seqRebuild(like: args[0], items.reversed())
        }
        registry.lisp.intern("NREVERSE").function =
            registry.lisp.intern("REVERSE").function

        defBuiltin("NTH", 2, 2) { [unowned self] args in
            guard case .int(let n) = args[0].firstValue, n >= 0 else {
                throw self.typeError(args[0], expected: "INTEGER")
            }
            var cur = args[1].firstValue
            var i = 0
            while i < n {
                guard case .cons(let c) = cur else { return .null }
                cur = c.cdr
                i += 1
            }
            return try carOf(cur)
        }

        defSetfHandler("NTH") { [unowned self] args in
            // (newval n list)
            guard case .int(let n) = args[1].firstValue, n >= 0 else {
                throw self.typeError(args[1], expected: "INTEGER")
            }
            var cur = args[2].firstValue
            var i = 0
            while i < n {
                guard case .cons(let c) = cur else {
                    throw self.lispError("ERROR", "nth index out of range")
                }
                cur = c.cdr
                i += 1
            }
            guard case .cons(let c) = cur else {
                throw self.lispError("ERROR", "nth index out of range")
            }
            c.car = args[0].firstValue
            return args[0]
        }

        defBuiltin("NTHCDR", 2, 2) { [unowned self] args in
            guard case .int(let n) = args[0].firstValue, n >= 0 else {
                throw self.typeError(args[0], expected: "INTEGER")
            }
            var cur = args[1].firstValue
            var i = 0
            while i < n {
                guard case .cons(let c) = cur else { return .null }
                cur = c.cdr
                i += 1
            }
            return cur
        }

        defBuiltin("LAST", 1, 2) { [unowned self] args in
            guard let items = args[0].firstValue.asArray() else {
                throw self.typeError(args[0], expected: "LIST")
            }
            var n = 1
            if args.count == 2, case .int(let k) = args[1].firstValue { n = k }
            let start = max(0, items.count - n)
            return LispValue.list(Array(items[start...]))
        }

        defBuiltin("BUTLAST", 1, 2) { [unowned self] args in
            guard let items = args[0].firstValue.asArray() else {
                throw self.typeError(args[0], expected: "LIST")
            }
            var n = 1
            if args.count == 2, case .int(let k) = args[1].firstValue { n = k }
            let end = max(0, items.count - n)
            return LispValue.list(Array(items[0..<end]))
        }

        defBuiltin("LENGTH", 1, 1) { [unowned self] args in
            return .int(try self.seqToArray(args[0]).count)
        }

        defBuiltin("LIST-LENGTH", 1, 1) { [unowned self] args in
            guard let items = args[0].firstValue.asArray() else {
                throw self.typeError(args[0], expected: "LIST")
            }
            return .int(items.count)
        }

        defBuiltin("COPY-LIST", 1, 1) { [unowned self] args in
            guard let items = args[0].firstValue.asArray() else {
                throw self.typeError(args[0], expected: "LIST")
            }
            return LispValue.list(items)
        }

        defBuiltin("COPY-SEQ", 1, 1) { [unowned self] args in
            let items = try self.seqToArray(args[0])
            return self.seqRebuild(like: args[0], items)
        }

        defBuiltin("MAKE-LIST", 1, nil) { [unowned self] args in
            guard case .int(let n) = args[0].firstValue, n >= 0 else {
                throw self.typeError(args[0], expected: "INTEGER")
            }
            let keys = try self.parseKeys(args, from: 1)
            let elt = keys["INITIAL-ELEMENT"] ?? .null
            return LispValue.list([LispValue](repeating: elt, count: n))
        }

        defBuiltin("ACONS", 3, 3) { args in
            .cons(Cons(car: .cons(Cons(car: args[0].firstValue,
                                       cdr: args[1].firstValue)),
                       cdr: args[2].firstValue))
        }

        defBuiltin("ASSOC", 2, nil) { [unowned self] args in
            let keys = try self.parseKeys(args, from: 2)
            let (test, key) = self.testAndKey(keys)
            for pair in args[1].firstValue.asArray() ?? [] {
                guard case .cons(let c) = pair else { continue }
                if try test(args[0].firstValue, key(c.car)) {
                    return pair
                }
            }
            return .null
        }

        defBuiltin("MEMBER", 2, nil) { [unowned self] args in
            let keys = try self.parseKeys(args, from: 2)
            let (test, key) = self.testAndKey(keys)
            var cur = args[1].firstValue
            while case .cons(let c) = cur {
                if try test(args[0].firstValue, key(c.car)) {
                    return cur
                }
                cur = c.cdr
            }
            return .null
        }

        defBuiltin("MEMBER-IF", 2, 2) { [unowned self] args in
            var cur = args[1].firstValue
            while case .cons(let c) = cur {
                if try self.callPredicate(args[0], [c.car]) {
                    return cur
                }
                cur = c.cdr
            }
            return .null
        }

        defBuiltin("MAPCAR", 2, nil) { [unowned self] args in
            var lists: [[LispValue]] = []
            for l in args.dropFirst() {
                lists.append(try self.seqToArray(l))
            }
            let n = lists.map { $0.count }.min() ?? 0
            var result: [LispValue] = []
            for i in 0..<n {
                result.append(try self.apply(args[0].firstValue,
                                             lists.map { $0[i] }).firstValue)
            }
            return LispValue.list(result)
        }

        defBuiltin("MAPC", 2, nil) { [unowned self] args in
            var lists: [[LispValue]] = []
            for l in args.dropFirst() {
                lists.append(try self.seqToArray(l))
            }
            let n = lists.map { $0.count }.min() ?? 0
            for i in 0..<n {
                _ = try self.apply(args[0].firstValue, lists.map { $0[i] })
            }
            return args[1]
        }

        defBuiltin("MAPCAN", 2, nil) { [unowned self] args in
            var lists: [[LispValue]] = []
            for l in args.dropFirst() {
                lists.append(try self.seqToArray(l))
            }
            let n = lists.map { $0.count }.min() ?? 0
            var result: [LispValue] = []
            for i in 0..<n {
                let piece = try self.apply(args[0].firstValue,
                                           lists.map { $0[i] }).firstValue
                result.append(contentsOf: piece.asArray() ?? [])
            }
            return LispValue.list(result)
        }

        defBuiltin("REDUCE", 2, nil) { [unowned self] args in
            let keys = try self.parseKeys(args, from: 2)
            var items = try self.seqToArray(args[1])
            if let keyFn = keys["KEY"], !keyFn.isNil {
                var mapped: [LispValue] = []
                for i in items {
                    mapped.append(try self.apply(keyFn, [i]).firstValue)
                }
                items = mapped
            }
            var acc: LispValue
            var start = 0
            if let initial = keys["INITIAL-VALUE"] {
                acc = initial
            } else if items.isEmpty {
                return try self.apply(args[0].firstValue, [])
            } else {
                acc = items[0]
                start = 1
            }
            for i in start..<items.count {
                acc = try self.apply(args[0].firstValue, [acc, items[i]]).firstValue
            }
            return acc
        }

        defBuiltin("REMOVE", 2, nil) { [unowned self] args in
            let keys = try self.parseKeys(args, from: 2)
            let (test, key) = self.testAndKey(keys)
            let items = try self.seqToArray(args[1])
            var result: [LispValue] = []
            for item in items {
                if try !test(args[0].firstValue, key(item)) {
                    result.append(item)
                }
            }
            return self.seqRebuild(like: args[1], result)
        }
        registry.lisp.intern("DELETE").function =
            registry.lisp.intern("REMOVE").function

        defBuiltin("REMOVE-IF", 2, nil) { [unowned self] args in
            let items = try self.seqToArray(args[1])
            var result: [LispValue] = []
            for item in items {
                if try !self.callPredicate(args[0], [item]) {
                    result.append(item)
                }
            }
            return self.seqRebuild(like: args[1], result)
        }

        defBuiltin("REMOVE-IF-NOT", 2, nil) { [unowned self] args in
            let items = try self.seqToArray(args[1])
            var result: [LispValue] = []
            for item in items {
                if try self.callPredicate(args[0], [item]) {
                    result.append(item)
                }
            }
            return self.seqRebuild(like: args[1], result)
        }

        defBuiltin("REMOVE-DUPLICATES", 1, nil) { [unowned self] args in
            let keys = try self.parseKeys(args, from: 1)
            let (test, key) = self.testAndKey(keys)
            let items = try self.seqToArray(args[0])
            var result: [LispValue] = []
            for (i, item) in items.enumerated() {
                var dupLater = false
                for j in (i + 1)..<items.count {
                    if try test(key(item), key(items[j])) {
                        dupLater = true
                        break
                    }
                }
                if !dupLater { result.append(item) }
            }
            return self.seqRebuild(like: args[0], result)
        }

        defBuiltin("FIND", 2, nil) { [unowned self] args in
            let keys = try self.parseKeys(args, from: 2)
            let (test, key) = self.testAndKey(keys)
            for item in try self.seqToArray(args[1]) {
                if try test(args[0].firstValue, key(item)) {
                    return item
                }
            }
            return .null
        }

        defBuiltin("FIND-IF", 2, nil) { [unowned self] args in
            let keys = try self.parseKeys(args, from: 2)
            let (_, key) = self.testAndKey(keys)
            for item in try self.seqToArray(args[1]) {
                if try self.callPredicate(args[0], [key(item)]) {
                    return item
                }
            }
            return .null
        }

        defBuiltin("POSITION", 2, nil) { [unowned self] args in
            let keys = try self.parseKeys(args, from: 2)
            let (test, key) = self.testAndKey(keys)
            for (i, item) in try self.seqToArray(args[1]).enumerated() {
                if try test(args[0].firstValue, key(item)) {
                    return .int(i)
                }
            }
            return .null
        }

        defBuiltin("POSITION-IF", 2, 2) { [unowned self] args in
            for (i, item) in try self.seqToArray(args[1]).enumerated() {
                if try self.callPredicate(args[0], [item]) {
                    return .int(i)
                }
            }
            return .null
        }

        defBuiltin("COUNT", 2, nil) { [unowned self] args in
            let keys = try self.parseKeys(args, from: 2)
            let (test, key) = self.testAndKey(keys)
            var n = 0
            for item in try self.seqToArray(args[1]) {
                if try test(args[0].firstValue, key(item)) { n += 1 }
            }
            return .int(n)
        }

        defBuiltin("COUNT-IF", 2, 2) { [unowned self] args in
            var n = 0
            for item in try self.seqToArray(args[1]) {
                if try self.callPredicate(args[0], [item]) { n += 1 }
            }
            return .int(n)
        }

        defBuiltin("SORT", 2, nil) { [unowned self] args in
            let keys = try self.parseKeys(args, from: 2)
            let keyFn = keys["KEY"]
            let items = try self.seqToArray(args[0])
            // Simple merge sort (stable), using the Lisp predicate.
            func lessThan(_ a: LispValue, _ b: LispValue) throws -> Bool {
                var ka = a, kb = b
                if let k = keyFn, !k.isNil {
                    ka = try self.apply(k, [a]).firstValue
                    kb = try self.apply(k, [b]).firstValue
                }
                return try self.apply(args[1].firstValue, [ka, kb]).isTrue
            }
            func mergeSort(_ xs: [LispValue]) throws -> [LispValue] {
                if xs.count <= 1 { return xs }
                let mid = xs.count / 2
                let left = try mergeSort(Array(xs[0..<mid]))
                let right = try mergeSort(Array(xs[mid...]))
                var result: [LispValue] = []
                var i = 0, j = 0
                while i < left.count && j < right.count {
                    if try lessThan(right[j], left[i]) {
                        result.append(right[j]); j += 1
                    } else {
                        result.append(left[i]); i += 1
                    }
                }
                result.append(contentsOf: left[i...])
                result.append(contentsOf: right[j...])
                return result
            }
            return self.seqRebuild(like: args[0], try mergeSort(items))
        }
        registry.lisp.intern("STABLE-SORT").function =
            registry.lisp.intern("SORT").function

        defBuiltin("SUBSEQ", 2, 3) { [unowned self] args in
            let items = try self.seqToArray(args[0])
            guard case .int(let start) = args[1].firstValue,
                  start >= 0, start <= items.count else {
                throw self.lispError("ERROR", "subseq start out of range")
            }
            var end = items.count
            if args.count == 3, case .int(let e) = args[2].firstValue {
                end = e
            }
            guard end >= start, end <= items.count else {
                throw self.lispError("ERROR", "subseq end out of range")
            }
            return self.seqRebuild(like: args[0], Array(items[start..<end]))
        }

        defBuiltin("ELT", 2, 2) { [unowned self] args in
            let items = try self.seqToArray(args[0])
            guard case .int(let i) = args[1].firstValue,
                  i >= 0, i < items.count else {
                throw self.lispError("ERROR", "elt index out of range")
            }
            return items[i]
        }

        defBuiltin("CONCATENATE", 1, nil) { [unowned self] args in
            guard case .symbol(let type) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "SYMBOL")
            }
            var items: [LispValue] = []
            for a in args.dropFirst() {
                items.append(contentsOf: try self.seqToArray(a))
            }
            switch type.name {
            case "STRING", "SIMPLE-STRING":
                var s = ""
                for i in items {
                    switch i {
                    case .character(let c): s.append(c)
                    case .string(let str): s += str.string
                    default:
                        throw self.typeError(i, expected: "CHARACTER")
                    }
                }
                return .str(s)
            case "VECTOR", "SIMPLE-VECTOR":
                return .vector(LispVector(items))
            default:
                return LispValue.list(items)
            }
        }

        defBuiltin("EVERY", 2, nil) { [unowned self] args in
            var lists: [[LispValue]] = []
            for l in args.dropFirst() {
                lists.append(try self.seqToArray(l))
            }
            let n = lists.map { $0.count }.min() ?? 0
            for i in 0..<n {
                if try !self.apply(args[0].firstValue,
                                   lists.map { $0[i] }).isTrue {
                    return .null
                }
            }
            return self.tValue
        }

        defBuiltin("SOME", 2, nil) { [unowned self] args in
            var lists: [[LispValue]] = []
            for l in args.dropFirst() {
                lists.append(try self.seqToArray(l))
            }
            let n = lists.map { $0.count }.min() ?? 0
            for i in 0..<n {
                let r = try self.apply(args[0].firstValue, lists.map { $0[i] })
                if r.isTrue { return r.firstValue }
            }
            return .null
        }

        defBuiltin("GETF", 2, 3) { args in
            var cur = args[0].firstValue
            while case .cons(let c) = cur {
                guard case .cons(let next) = c.cdr else { break }
                if LispEquality.eq(c.car, args[1].firstValue) {
                    return next.car
                }
                cur = next.cdr
            }
            return args.count == 3 ? args[2] : .null
        }

        defBuiltin("GET", 2, 3) { [unowned self] args in
            guard case .symbol(let s) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "SYMBOL")
            }
            var cur = s.plist
            while case .cons(let c) = cur {
                guard case .cons(let next) = c.cdr else { break }
                if LispEquality.eq(c.car, args[1].firstValue) {
                    return next.car
                }
                cur = next.cdr
            }
            return args.count == 3 ? args[2] : .null
        }

        defSetfHandler("GET") { [unowned self] args in
            // (newval symbol indicator)
            guard case .symbol(let s) = args[1].firstValue else {
                throw self.typeError(args[1], expected: "SYMBOL")
            }
            var cur = s.plist
            while case .cons(let c) = cur {
                guard case .cons(let next) = c.cdr else { break }
                if LispEquality.eq(c.car, args[2].firstValue) {
                    next.car = args[0].firstValue
                    return args[0]
                }
                cur = next.cdr
            }
            s.plist = .cons(Cons(car: args[2].firstValue,
                                 cdr: .cons(Cons(car: args[0].firstValue,
                                                 cdr: s.plist))))
            return args[0]
        }

        defBuiltin("UNION", 2, nil) { [unowned self] args in
            let keys = try self.parseKeys(args, from: 2)
            let (test, key) = self.testAndKey(keys)
            let a = try self.seqToArray(args[0])
            let b = try self.seqToArray(args[1])
            var result = a
            for item in b {
                var found = false
                for existing in a {
                    if try test(key(existing), key(item)) { found = true; break }
                }
                if !found { result.append(item) }
            }
            return LispValue.list(result)
        }

        defBuiltin("INTERSECTION", 2, nil) { [unowned self] args in
            let keys = try self.parseKeys(args, from: 2)
            let (test, key) = self.testAndKey(keys)
            let a = try self.seqToArray(args[0])
            let b = try self.seqToArray(args[1])
            var result: [LispValue] = []
            for item in a {
                for other in b {
                    if try test(key(item), key(other)) {
                        result.append(item)
                        break
                    }
                }
            }
            return LispValue.list(result)
        }

        defBuiltin("SET-DIFFERENCE", 2, nil) { [unowned self] args in
            let keys = try self.parseKeys(args, from: 2)
            let (test, key) = self.testAndKey(keys)
            let a = try self.seqToArray(args[0])
            let b = try self.seqToArray(args[1])
            var result: [LispValue] = []
            for item in a {
                var found = false
                for other in b {
                    if try test(key(item), key(other)) { found = true; break }
                }
                if !found { result.append(item) }
            }
            return LispValue.list(result)
        }
    }
}
