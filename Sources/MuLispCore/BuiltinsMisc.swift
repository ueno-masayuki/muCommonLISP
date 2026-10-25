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

        // --- Vectors / arrays (one-dimensional only) ---

        defBuiltin("VECTOR", 0, nil) { args in
            .vector(LispVector(args.map { $0.firstValue }))
        }

        defBuiltin("MAKE-ARRAY", 1, nil) { [unowned self] args in
            var size = 0
            switch args[0].firstValue {
            case .int(let n):
                size = n
            case .cons(let c):
                guard case .int(let n) = c.car, c.cdr.isNil else {
                    throw self.lispError("ERROR",
                        "only one-dimensional arrays are supported")
                }
                size = n
            default:
                throw self.typeError(args[0], expected: "INTEGER")
            }
            let keys = try self.parseKeys(args, from: 1)
            let initial = keys["INITIAL-ELEMENT"] ?? .null
            if let contents = keys["INITIAL-CONTENTS"] {
                let items = try self.seqToArray(contents)
                return .vector(LispVector(items))
            }
            return .vector(LispVector([LispValue](repeating: initial,
                                                  count: size)))
        }

        defBuiltin("AREF", 2, 2) { [unowned self] args in
            switch args[0].firstValue {
            case .vector(let v):
                guard case .int(let i) = args[1].firstValue, i >= 0,
                      i < v.elements.count else {
                    throw self.lispError("ERROR", "aref index out of range")
                }
                return v.elements[i]
            case .string(let s):
                guard case .int(let i) = args[1].firstValue, i >= 0,
                      i < s.count else {
                    throw self.lispError("ERROR", "aref index out of range")
                }
                return .character(Array(s)[i])
            default:
                throw self.typeError(args[0], expected: "ARRAY")
            }
        }
        lisp.intern("SVREF").function = lisp.intern("AREF").function

        defSetfHandler("AREF") { [unowned self] args in
            // (newval vector index)
            guard case .vector(let v) = args[1].firstValue else {
                throw self.typeError(args[1], expected: "VECTOR")
            }
            guard case .int(let i) = args[2].firstValue, i >= 0,
                  i < v.elements.count else {
                throw self.lispError("ERROR", "aref index out of range")
            }
            v.elements[i] = args[0].firstValue
            return args[0]
        }
        setfHandlers[lisp.intern("SVREF")] = setfHandlers[lisp.intern("AREF")]

        defBuiltin("VECTOR-PUSH-EXTEND", 2, 2) { [unowned self] args in
            guard case .vector(let v) = args[1].firstValue else {
                throw self.typeError(args[1], expected: "VECTOR")
            }
            v.elements.append(args[0].firstValue)
            return .int(v.elements.count - 1)
        }

        defBuiltin("ARRAY-DIMENSION", 2, 2) { [unowned self] args in
            guard case .vector(let v) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "VECTOR")
            }
            return .int(v.elements.count)
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
            try self.writeTo(args.count > 1 ? args[1] : self.tValue, s)
            return args[0]
        }

        defBuiltin("WRITE-LINE", 1, 2) { [unowned self] args in
            guard case .string(let s) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "STRING")
            }
            try self.writeTo(args.count > 1 ? args[1] : self.tValue, s + "\n")
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
            .string(Printer.toString(args[0].firstValue, escape: true,
                                     interp: self))
        }
        defBuiltin("PRINC-TO-STRING", 1, 1) { [unowned self] args in
            .string(Printer.toString(args[0].firstValue, escape: false,
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
            return .string(text)
        }

        // --- Reading ---

        defBuiltin("READ-FROM-STRING", 1, 1) { [unowned self] args in
            guard case .string(let s) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "STRING")
            }
            let reader = Reader(source: s, registry: self.registry) {
                [unowned self] in self.currentPackage
            }
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

    /// Resolve an output-stream designator and write to it.
    func writeTo(_ designator: LispValue, _ text: String) throws {
        switch designator.firstValue {
        case .null:
            // NIL means "standard output" for these builtins (we do not model
            // *standard-output* rebinding).
            write(text)
        case .symbol(let s) where s.name == "T":
            write(text)
        case .stream(let stream):
            stream.write(text)
        default:
            if case .symbol(let s) = designator.firstValue,
               s.package === registry.lisp, s.name == "T" {
                write(text)
            } else {
                throw typeError(designator, expected: "STREAM")
            }
        }
    }
}
