// ClassBootstrap.swift
// The built-in class hierarchy, the condition class tree, CLASS-OF and TYPEP.

import Foundation

/// References to frequently used system classes.
public final class SystemClasses {
    public var t: LispClass!
    public var standardObject: LispClass!
    public var structureObject: LispClass!
    public var sequence: LispClass!
    public var list: LispClass!
    public var cons: LispClass!
    public var symbol: LispClass!
    public var null: LispClass!
    public var keyword: LispClass!
    public var number: LispClass!
    public var real: LispClass!
    public var rational: LispClass!
    public var integer: LispClass!
    public var float: LispClass!
    public var array: LispClass!
    public var vector: LispClass!
    public var string: LispClass!
    public var character: LispClass!
    public var hashTable: LispClass!
    public var function: LispClass!
    public var genericFunction: LispClass!
    public var package: LispClass!
    public var stream: LispClass!
    public var classClass: LispClass!
    public var standardClass: LispClass!
    public var builtInClass: LispClass!
    public var structureClass: LispClass!
    public var condition: LispClass!
}

extension Interpreter {

    func bootstrapClasses() throws {
        let lisp = registry.lisp

        func make(_ name: String, _ supers: [LispClass],
                  kind: ClassKind = .builtin) throws -> LispClass {
            let s = lisp.intern(name)
            let c = LispClass(name: s, kind: kind)
            c.directSuperclasses = supers
            for p in supers { p.directSubclasses.append(c) }
            try c.finalizeClass()
            classRegistry[s] = c
            return c
        }

        let t = try make("T", [])
        classes.t = t
        classes.standardObject = try make("STANDARD-OBJECT", [t], kind: .standard)
        classes.structureObject = try make("STRUCTURE-OBJECT", [t], kind: .structure)
        classes.sequence = try make("SEQUENCE", [t])
        classes.list = try make("LIST", [classes.sequence])
        classes.cons = try make("CONS", [classes.list])
        classes.symbol = try make("SYMBOL", [t])
        classes.null = try make("NULL", [classes.symbol, classes.list])
        classes.keyword = try make("KEYWORD", [classes.symbol])
        classes.number = try make("NUMBER", [t])
        classes.real = try make("REAL", [classes.number])
        classes.rational = try make("RATIONAL", [classes.real])
        classes.integer = try make("INTEGER", [classes.rational])
        classes.float = try make("FLOAT", [classes.real])
        classes.array = try make("ARRAY", [t])
        classes.vector = try make("VECTOR", [classes.array, classes.sequence])
        classes.string = try make("STRING", [classes.vector])
        classes.character = try make("CHARACTER", [t])
        classes.hashTable = try make("HASH-TABLE", [t])
        classes.function = try make("FUNCTION", [t])
        classes.genericFunction = try make("GENERIC-FUNCTION", [classes.function])
        classes.package = try make("PACKAGE", [t])
        classes.stream = try make("STREAM", [t])
        classes.classClass = try make("CLASS", [t])
        classes.standardClass = try make("STANDARD-CLASS", [classes.classClass])
        classes.builtInClass = try make("BUILT-IN-CLASS", [classes.classClass])
        classes.structureClass = try make("STRUCTURE-CLASS", [classes.classClass])

        // Aliases.
        classRegistry[lisp.intern("FIXNUM")] = classes.integer
        classRegistry[lisp.intern("BIGNUM")] = classes.integer
        classRegistry[lisp.intern("SINGLE-FLOAT")] = classes.float
        classRegistry[lisp.intern("DOUBLE-FLOAT")] = classes.float
        classRegistry[lisp.intern("SIMPLE-STRING")] = classes.string
        classRegistry[lisp.intern("SIMPLE-VECTOR")] = classes.vector
        classRegistry[lisp.intern("COMPILED-FUNCTION")] = classes.function
        classRegistry[lisp.intern("STANDARD-GENERIC-FUNCTION")] = classes.genericFunction

        // --- Condition classes (standard classes rooted below T) ---

        func cond(_ name: String, _ supers: [String],
                  _ slots: [(String, String)] = []) throws {
            var specs: [SlotSpecData] = []
            for (slotName, initarg) in slots {
                specs.append(SlotSpecData(
                    name: lisp.intern(slotName),
                    initargs: [registry.keyword.intern(initarg)],
                    initFunction: nil, readers: [], writers: [],
                    allocation: .instance))
            }
            _ = try ensureClass(name: lisp.intern(name),
                                superNames: supers.map { lisp.intern($0) },
                                slotSpecs: specs, kind: .standard)
        }

        try cond("CONDITION", ["T"], [("%MESSAGE", "MESSAGE")])
        classes.condition = findClassByName("CONDITION")
        try cond("WARNING", ["CONDITION"])
        try cond("SERIOUS-CONDITION", ["CONDITION"])
        try cond("STORAGE-CONDITION", ["SERIOUS-CONDITION"])
        try cond("ERROR", ["SERIOUS-CONDITION"])
        try cond("SIMPLE-CONDITION", ["CONDITION"],
                 [("FORMAT-CONTROL", "FORMAT-CONTROL"),
                  ("FORMAT-ARGUMENTS", "FORMAT-ARGUMENTS")])
        try cond("SIMPLE-ERROR", ["SIMPLE-CONDITION", "ERROR"])
        try cond("SIMPLE-WARNING", ["SIMPLE-CONDITION", "WARNING"])
        try cond("TYPE-ERROR", ["ERROR"],
                 [("DATUM", "DATUM"), ("EXPECTED-TYPE", "EXPECTED-TYPE")])
        try cond("CELL-ERROR", ["ERROR"], [("NAME", "NAME")])
        try cond("UNBOUND-VARIABLE", ["CELL-ERROR"])
        try cond("UNDEFINED-FUNCTION", ["CELL-ERROR"])
        try cond("UNBOUND-SLOT", ["CELL-ERROR"])
        try cond("ARITHMETIC-ERROR", ["ERROR"])
        try cond("DIVISION-BY-ZERO", ["ARITHMETIC-ERROR"])
        try cond("CONTROL-ERROR", ["ERROR"])
        try cond("PROGRAM-ERROR", ["ERROR"])
        try cond("PARSE-ERROR", ["ERROR"])
        try cond("READER-ERROR", ["PARSE-ERROR"])
        try cond("STREAM-ERROR", ["ERROR"])
        try cond("END-OF-FILE", ["STREAM-ERROR"])
        try cond("PACKAGE-ERROR", ["ERROR"])
    }

    // MARK: - CLASS-OF

    public func classOf(_ v: LispValue) -> LispClass {
        switch v {
        case .null: return classes.null
        case .int: return classes.integer
        case .double: return classes.float
        case .string: return classes.string
        case .character: return classes.character
        case .symbol(let s):
            return s.isKeyword ? classes.keyword : classes.symbol
        case .cons: return classes.cons
        case .vector: return classes.vector
        case .hashTable: return classes.hashTable
        case .function(let f):
            return f is GenericFunction ? classes.genericFunction : classes.function
        case .instance(let inst):
            ensureCurrentVersion(inst)
            return inst.clazz
        case .lispClass(let c):
            switch c.kind {
            case .standard: return classes.standardClass
            case .builtin: return classes.builtInClass
            case .structure: return classes.structureClass
            }
        case .package: return classes.package
        case .blockToken: return classes.t
        case .stream: return classes.stream
        case .values(let vs): return classOf(vs.first ?? .null)
        }
    }

    // MARK: - TYPEP

    public func typep(_ v: LispValue, _ spec: LispValue) throws -> Bool {
        switch spec {
        case .symbol(let s):
            switch s.name {
            case "T": return true
            case "NIL": return false
            case "ATOM":
                if case .cons = v { return false }
                return true
            case "BOOLEAN":
                if v.isNil { return true }
                if case .symbol(let sym) = v, sym.name == "T",
                   sym.package === registry.lisp { return true }
                return false
            default:
                guard let cls = findClass(s) else {
                    throw lispError("ERROR", "unknown type specifier \(s.name)")
                }
                return classOf(v).isSubclass(of: cls)
            }
        case .null:
            return false
        case .lispClass(let cls):
            return classOf(v).isSubclass(of: cls)
        case .cons(let c):
            guard case .symbol(let op) = c.car else {
                throw lispError("ERROR", "invalid type specifier")
            }
            let rest = c.cdr.asArray() ?? []
            switch op.name {
            case "OR":
                for t in rest {
                    if try typep(v, t) { return true }
                }
                return false
            case "AND":
                for t in rest {
                    if try !typep(v, t) { return false }
                }
                return true
            case "NOT":
                guard rest.count == 1 else {
                    throw lispError("ERROR", "malformed NOT type specifier")
                }
                return try !typep(v, rest[0])
            case "MEMBER":
                for item in rest where LispEquality.eql(v, item) { return true }
                return false
            case "EQL":
                guard rest.count == 1 else {
                    throw lispError("ERROR", "malformed EQL type specifier")
                }
                return LispEquality.eql(v, rest[0])
            case "SATISFIES":
                guard rest.count == 1, case .symbol(let fn) = rest[0],
                      let f = fn.function else {
                    throw lispError("ERROR", "malformed SATISFIES type specifier")
                }
                return try applyFunction(f, [v]).isTrue
            case "INTEGER", "REAL", "FLOAT", "RATIONAL", "NUMBER":
                // Range specifiers: (integer low high) etc.
                guard try typep(v, .symbol(op)) else { return false }
                guard let x = v.asDouble else { return false }
                if rest.count >= 1, let low = boundValue(rest[0]), x < low {
                    return false
                }
                if rest.count >= 2, let high = boundValue(rest[1]), x > high {
                    return false
                }
                return true
            default:
                throw lispError("ERROR",
                    "unsupported compound type specifier \(op.name)")
            }
        default:
            throw lispError("ERROR", "invalid type specifier")
        }
    }

    private func boundValue(_ v: LispValue) -> Double? {
        if case .symbol(let s) = v, s.name == "*" { return nil }
        return v.asDouble
    }
}
