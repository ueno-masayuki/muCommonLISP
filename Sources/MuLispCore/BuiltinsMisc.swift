// BuiltinsMisc.swift
// Predicates, hash tables, vectors, I/O.

import Foundation

extension Interpreter {

    func registerMiscBuiltins() {
        let lisp = registry.lisp

        // --- Equality and type predicates ---

        defBuiltin("EQ", 2, 2) { [unowned self] args in
            LispEquality.eq(args[0].firstValue, args[1].firstValue)
                ? self.tValue : .null
        }
        defBuiltin("EQL", 2, 2) { [unowned self] args in
            LispEquality.eql(args[0].firstValue, args[1].firstValue)
                ? self.tValue : .null
        }
        defBuiltin("EQUAL", 2, 2) { [unowned self] args in
            LispEquality.equal(args[0].firstValue, args[1].firstValue)
                ? self.tValue : .null
        }
        defBuiltin("EQUALP", 2, 2) { [unowned self] args in
            LispEquality.equalp(args[0].firstValue, args[1].firstValue)
                ? self.tValue : .null
        }

        func predicate(_ name: String,
                       _ f: @escaping (LispValue) -> Bool) {
            defBuiltin(name, 1, 1) { [unowned self] args in
                f(args[0].firstValue) ? self.tValue : .null
            }
        }
        predicate("NOT") { $0.isNil }
        predicate("NULL") { $0.isNil }
        predicate("CONSP") {
            if case .cons = $0 { return true }
            return false
        }
        predicate("ATOM") {
            if case .cons = $0 { return false }
            return true
        }
        predicate("LISTP") {
            switch $0 {
            case .cons, .null: return true
            default: return false
            }
        }
        predicate("STRINGP") {
            if case .string = $0 { return true }
            return false
        }
        predicate("FUNCTIONP") {
            if case .function = $0 { return true }
            return false
        }
        predicate("VECTORP") {
            if case .vector = $0 { return true }
            return false
        }
        predicate("HASH-TABLE-P") {
            if case .hashTable = $0 { return true }
            return false
        }
        predicate("PACKAGEP") {
            if case .package = $0 { return true }
            return false
        }
        predicate("STREAMP") {
            if case .stream = $0 { return true }
            return false
        }
        predicate("ENDP") { $0.isNil }

        defBuiltin("TYPE-OF", 1, 1) { [unowned self] args in
            return .symbol(self.classOf(args[0].firstValue).name)
        }

        // --- Hash tables ---

        defBuiltin("MAKE-HASH-TABLE", 0, nil) { [unowned self] args in
            let keys = try self.parseKeys(args, from: 0)
            var test = LispHashTable.TestKind.eql
            if let t = keys["TEST"] {
                var name = ""
                switch t.firstValue {
                case .symbol(let s): name = s.name
                case .function(let f): name = f.name
                default: break
                }
                switch name {
                case "EQ": test = .eq
                case "EQL": test = .eql
                case "EQUAL": test = .equal
                case "EQUALP": test = .equalp
                default: test = .eql
                }
            }
            return .hashTable(LispHashTable(test: test))
        }

        defBuiltin("GETHASH", 2, 3) { [unowned self] args in
            guard case .hashTable(let h) = args[1].firstValue else {
                throw self.typeError(args[1], expected: "HASH-TABLE")
            }
            if let v = h.get(args[0].firstValue) {
                return .values([v, self.tValue])
            }
            return .values([args.count == 3 ? args[2] : .null, .null])
        }

        defSetfHandler("GETHASH") { [unowned self] args in
            // (newval key table [default])
            guard case .hashTable(let h) = args[2].firstValue else {
                throw self.typeError(args[2], expected: "HASH-TABLE")
            }
            h.set(args[1].firstValue, args[0].firstValue)
            return args[0]
        }

        defBuiltin("REMHASH", 2, 2) { [unowned self] args in
            guard case .hashTable(let h) = args[1].firstValue else {
                throw self.typeError(args[1], expected: "HASH-TABLE")
            }
            return h.remove(args[0].firstValue) ? self.tValue : .null
        }

        defBuiltin("CLRHASH", 1, 1) { [unowned self] args in
            guard case .hashTable(let h) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "HASH-TABLE")
            }
            h.clear()
            return args[0]
        }

        defBuiltin("HASH-TABLE-COUNT", 1, 1) { [unowned self] args in
            guard case .hashTable(let h) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "HASH-TABLE")
            }
            return .int(h.count)
        }

        defBuiltin("MAPHASH", 2, 2) { [unowned self] args in
            guard case .hashTable(let h) = args[1].firstValue else {
                throw self.typeError(args[1], expected: "HASH-TABLE")
            }
            for (k, v) in h.allPairs() {
                _ = try self.apply(args[0].firstValue, [k, v])
            }
            return .null
        }

        defBuiltin("HASH-TABLE-KEYS", 1, 1) { [unowned self] args in
            guard case .hashTable(let h) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "HASH-TABLE")
            }
            return LispValue.list(h.allPairs().map { $0.0 })
        }

        defBuiltin("HASH-TABLE-VALUES", 1, 1) { [unowned self] args in
            guard case .hashTable(let h) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "HASH-TABLE")
            }
            return LispValue.list(h.allPairs().map { $0.1 })
        }

        defBuiltin("%HASH-PAIRS", 1, 1) { [unowned self] args in
            guard case .hashTable(let h) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "HASH-TABLE")
            }
            return LispValue.list(h.allPairs().map {
                .cons(Cons(car: $0.0, cdr: $0.1))
            })
        }

        defBuiltin("HASH-TABLE-TEST", 1, 1) { [unowned self] args in
            guard case .hashTable(let h) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "HASH-TABLE")
            }
            let name: String
            switch h.test {
            case .eq: name = "EQ"
            case .eql: name = "EQL"
            case .equal: name = "EQUAL"
            case .equalp: name = "EQUALP"
            }
            return .symbol(self.registry.lisp.intern(name))
        }

        defBuiltin("COPY-HASH-TABLE", 1, 1) { [unowned self] args in
            guard case .hashTable(let h) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "HASH-TABLE")
            }
            let copy = LispHashTable(test: h.test)
            for (k, v) in h.allPairs() {
                copy.set(k, v)
            }
            return .hashTable(copy)
        }

        // --- Vectors / arrays ---

        defBuiltin("VECTOR", 0, nil) { args in
            .vector(LispVector(args.map { $0.firstValue }))
        }

        defBuiltin("MAKE-ARRAY", 1, nil) { [unowned self] args in
            var dims: [Int] = []
            switch args[0].firstValue {
            case .int(let n):
                dims = [n]
            case .null:
                dims = []
            case .cons:
                for d in args[0].firstValue.asArray() ?? [] {
                    guard case .int(let n) = d, n >= 0 else {
                        throw self.typeError(d, expected: "INTEGER")
                    }
                    dims.append(n)
                }
            default:
                throw self.typeError(args[0], expected: "INTEGER")
            }
            let keys = try self.parseKeys(args, from: 1)
            let initial = keys["INITIAL-ELEMENT"] ?? .null
            var fillPointer: Int? = nil
            if let fp = keys["FILL-POINTER"] {
                if case .int(let n) = fp {
                    fillPointer = n
                } else if fp.isTrue {
                    fillPointer = dims.first ?? 0
                }
            }
            let adjustable = (keys["ADJUSTABLE"]?.isTrue) ?? false
            let vec = LispVector(dimensions: dims.isEmpty ? [0] : dims,
                                 initial: initial,
                                 fillPointer: fillPointer,
                                 adjustable: adjustable)
            if let contents = keys["INITIAL-CONTENTS"] {
                if dims.count <= 1 {
                    vec.elements = try self.seqToArray(contents)
                    vec.dimensions = [vec.elements.count]
                } else {
                    var flat: [LispValue] = []
                    func flatten(_ v: LispValue, _ depth: Int) throws {
                        if depth == dims.count {
                            flat.append(v)
                            return
                        }
                        let items = try self.seqToArray(v)
                        guard items.count == dims[depth] else {
                            throw self.lispError("ERROR",
                                "initial-contents shape mismatch")
                        }
                        for i in items { try flatten(i, depth + 1) }
                    }
                    try flatten(contents, 0)
                    vec.elements = flat
                }
            }
            return .vector(vec)
        }

        defBuiltin("AREF", 2, nil) { [unowned self] args in
            switch args[0].firstValue {
            case .vector(let v):
                var subs: [Int] = []
                for a in args.dropFirst() {
                    guard case .int(let i) = a.firstValue else {
                        throw self.typeError(a, expected: "INTEGER")
                    }
                    subs.append(i)
                }
                guard let idx = v.rowMajorIndex(subs) else {
                    throw self.lispError("ERROR", "aref subscripts out of range")
                }
                return v.elements[idx]
            case .string(let s):
                guard args.count == 2,
                      case .int(let i) = args[1].firstValue, i >= 0,
                      i < s.chars.count else {
                    throw self.lispError("ERROR", "aref index out of range")
                }
                return .character(s.chars[i])
            default:
                throw self.typeError(args[0], expected: "ARRAY")
            }
        }
        lisp.intern("SVREF").function = lisp.intern("AREF").function
        lisp.intern("ROW-MAJOR-AREF").function = lisp.intern("AREF").function

        defSetfHandler("AREF") { [unowned self] args in
            // (newval array subscripts...)
            switch args[1].firstValue {
            case .vector(let v):
                var subs: [Int] = []
                for a in args.dropFirst(2) {
                    guard case .int(let i) = a.firstValue else {
                        throw self.typeError(a, expected: "INTEGER")
                    }
                    subs.append(i)
                }
                guard let idx = v.rowMajorIndex(subs) else {
                    throw self.lispError("ERROR", "aref subscripts out of range")
                }
                v.elements[idx] = args[0].firstValue
                return args[0]
            case .string(let s):
                guard args.count == 3,
                      case .int(let i) = args[2].firstValue, i >= 0,
                      i < s.chars.count,
                      case .character(let c) = args[0].firstValue else {
                    throw self.lispError("ERROR", "invalid string aref assignment")
                }
                s.chars[i] = c
                return args[0]
            default:
                throw self.typeError(args[1], expected: "ARRAY")
            }
        }
        setfHandlers[lisp.intern("SVREF")] = setfHandlers[lisp.intern("AREF")]

        defBuiltin("VECTOR-PUSH", 2, 2) { [unowned self] args in
            guard case .vector(let v) = args[1].firstValue,
                  let fp = v.fillPointer else {
                throw self.lispError("ERROR",
                    "vector-push requires a vector with a fill pointer")
            }
            if fp >= v.elements.count {
                return .null
            }
            v.elements[fp] = args[0].firstValue
            v.fillPointer = fp + 1
            return .int(fp)
        }

        defBuiltin("VECTOR-PUSH-EXTEND", 2, 3) { [unowned self] args in
            guard case .vector(let v) = args[1].firstValue else {
                throw self.typeError(args[1], expected: "VECTOR")
            }
            if let fp = v.fillPointer {
                if fp < v.elements.count {
                    v.elements[fp] = args[0].firstValue
                } else {
                    v.elements.append(args[0].firstValue)
                }
                v.fillPointer = fp + 1
                v.dimensions = [max(v.elements.count, fp + 1)]
                return .int(fp)
            }
            v.elements.append(args[0].firstValue)
            v.dimensions = [v.elements.count]
            return .int(v.elements.count - 1)
        }

        defBuiltin("VECTOR-POP", 1, 1) { [unowned self] args in
            guard case .vector(let v) = args[0].firstValue,
                  let fp = v.fillPointer, fp > 0 else {
                throw self.lispError("ERROR",
                    "vector-pop requires a non-empty vector with a fill pointer")
            }
            v.fillPointer = fp - 1
            return v.elements[fp - 1]
        }

        defBuiltin("FILL-POINTER", 1, 1) { [unowned self] args in
            guard case .vector(let v) = args[0].firstValue,
                  let fp = v.fillPointer else {
                throw self.lispError("ERROR", "no fill pointer")
            }
            return .int(fp)
        }

        defSetfHandler("FILL-POINTER") { [unowned self] args in
            guard case .vector(let v) = args[1].firstValue,
                  case .int(let n) = args[0].firstValue,
                  n >= 0, n <= v.elements.count else {
                throw self.lispError("ERROR", "invalid fill pointer")
            }
            v.fillPointer = n
            return args[0]
        }

        defBuiltin("ARRAY-DIMENSION", 2, 2) { [unowned self] args in
            guard case .int(let axis) = args[1].firstValue else {
                throw self.typeError(args[1], expected: "INTEGER")
            }
            switch args[0].firstValue {
            case .vector(let v):
                guard axis >= 0 && axis < v.dimensions.count else {
                    throw self.lispError("ERROR", "array axis out of range")
                }
                return .int(v.dimensions[axis])
            case .string(let s):
                return .int(s.chars.count)
            default:
                throw self.typeError(args[0], expected: "ARRAY")
            }
        }

        defBuiltin("ARRAY-DIMENSIONS", 1, 1) { [unowned self] args in
            switch args[0].firstValue {
            case .vector(let v):
                return LispValue.list(v.dimensions.map { .int($0) })
            case .string(let s):
                return LispValue.list([.int(s.chars.count)])
            default:
                throw self.typeError(args[0], expected: "ARRAY")
            }
        }

        defBuiltin("ARRAY-RANK", 1, 1) { [unowned self] args in
            switch args[0].firstValue {
            case .vector(let v): return .int(v.rank)
            case .string: return .int(1)
            default:
                throw self.typeError(args[0], expected: "ARRAY")
            }
        }

        defBuiltin("ARRAY-TOTAL-SIZE", 1, 1) { [unowned self] args in
            switch args[0].firstValue {
            case .vector(let v): return .int(v.totalSize)
            case .string(let s): return .int(s.chars.count)
            default:
                throw self.typeError(args[0], expected: "ARRAY")
            }
        }

        defBuiltin("ARRAYP", 1, 1) { [unowned self] args in
            switch args[0].firstValue {
            case .vector, .string: return self.tValue
            default: return .null
            }
        }

        defBuiltin("ADJUST-ARRAY", 2, nil) { [unowned self] args in
            guard case .vector(let v) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "VECTOR")
            }
            var dims: [Int] = []
            switch args[1].firstValue {
            case .int(let n): dims = [n]
            default:
                for d in args[1].firstValue.asArray() ?? [] {
                    if case .int(let n) = d { dims.append(n) }
                }
            }
            let keys = try self.parseKeys(args, from: 2)
            let initial = keys["INITIAL-ELEMENT"] ?? .null
            let newTotal = dims.reduce(1, *)
            if v.rank == 1 && dims.count == 1 {
                if newTotal > v.elements.count {
                    v.elements.append(contentsOf:
                        [LispValue](repeating: initial,
                                    count: newTotal - v.elements.count))
                } else {
                    v.elements.removeSubrange(newTotal...)
                }
                v.dimensions = dims
            } else {
                var newElements = [LispValue](repeating: initial, count: newTotal)
                let common = min(newTotal, v.elements.count)
                for i in 0..<common { newElements[i] = v.elements[i] }
                v.elements = newElements
                v.dimensions = dims
            }
            return args[0]
        }

        // --- Output ---

        defBuiltin("PRIN1", 1, 2) { [unowned self] args in
            let text = Printer.toString(args[0].firstValue, escape: true,
                                        interp: self)
            try self.writeTo(args.count > 1 ? args[1] : self.tValue, text)
            return args[0].firstValue
        }

        defBuiltin("PRINC", 1, 2) { [unowned self] args in
            let text = Printer.toString(args[0].firstValue, escape: false,
                                        interp: self)
            try self.writeTo(args.count > 1 ? args[1] : self.tValue, text)
            return args[0].firstValue
        }

        defBuiltin("PRINT", 1, 2) { [unowned self] args in
            let text = Printer.toString(args[0].firstValue, escape: true,
                                        interp: self)
            try self.writeTo(args.count > 1 ? args[1] : self.tValue,
                             "\n" + text + " ")
            return args[0].firstValue
        }

        defBuiltin("TERPRI", 0, 1) { [unowned self] args in
            try self.writeTo(args.count > 0 ? args[0] : self.tValue, "\n")
            return .null
        }

        defBuiltin("FRESH-LINE", 0, 1) { [unowned self] args in
            try self.writeTo(args.count > 0 ? args[0] : self.tValue, "\n")
            return self.tValue
        }

        defBuiltin("WRITE-STRING", 1, 2) { [unowned self] args in
            guard case .string(let s) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "STRING")
            }
            try self.writeTo(args.count > 1 ? args[1] : self.tValue, s.string)
            return args[0]
        }

        defBuiltin("WRITE-LINE", 1, 2) { [unowned self] args in
            guard case .string(let s) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "STRING")
            }
            try self.writeTo(args.count > 1 ? args[1] : self.tValue,
                             s.string + "\n")
            return args[0]
        }

        defBuiltin("WRITE-CHAR", 1, 2) { [unowned self] args in
            guard case .character(let c) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "CHARACTER")
            }
            try self.writeTo(args.count > 1 ? args[1] : self.tValue, String(c))
            return args[0]
        }

        defBuiltin("PRIN1-TO-STRING", 1, 1) { [unowned self] args in
            .str(Printer.toString(args[0].firstValue, escape: true,
                                  interp: self))
        }
        defBuiltin("PRINC-TO-STRING", 1, 1) { [unowned self] args in
            .str(Printer.toString(args[0].firstValue, escape: false,
                                  interp: self))
        }
        lisp.intern("WRITE-TO-STRING").function =
            lisp.intern("PRIN1-TO-STRING").function

        defBuiltin("MAKE-STRING-OUTPUT-STREAM", 0, nil) { _ in
            .stream(LispStream(kind: .stringOutput))
        }

        defBuiltin("GET-OUTPUT-STREAM-STRING", 1, 1) { [unowned self] args in
            guard case .stream(let s) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "STREAM")
            }
            let text = s.buffer
            s.buffer = ""
            return .str(text)
        }

        // --- Reading ---

        defBuiltin("READ-FROM-STRING", 1, 1) { [unowned self] args in
            guard case .string(let s) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "STRING")
            }
            let reader = self.makeReader(source: s.string)
            do {
                guard let form = try reader.read() else {
                    throw self.lispError("END-OF-FILE", "no form in string")
                }
                return form
            } catch let e as ReaderError {
                throw self.lispError("READER-ERROR", e.message)
            }
        }
    }

    /// Resolve an output-stream designator and write to it. T and NIL follow
    /// the current binding of *STANDARD-OUTPUT*.
    func writeTo(_ designator: LispValue, _ text: String) throws {
        switch designator.firstValue {
        case .null:
            writeToStandardOutput(text)
        case .symbol(let s) where s.name == "T":
            writeToStandardOutput(text)
        case .stream(let stream):
            stream.write(text)
        default:
            throw typeError(designator, expected: "STREAM")
        }
    }

    func writeToStandardOutput(_ text: String) {
        if let sym = standardOutputSymbol,
           case .stream(let s)? = sym.value {
            s.write(text)
        } else {
            write(text)
        }
    }
}
