// MOPExtras.swift
// Basic MOP introspection, DEFINE-METHOD-COMBINATION (short form) and
// reader-macro (readtable) support.

import Foundation

extension Interpreter {

    func registerMOP() {
        let lisp = registry.lisp

        func requireClass(_ v: LispValue) throws -> LispClass {
            switch v.firstValue {
            case .lispClass(let c): return c
            case .symbol(let s):
                guard let c = findClass(s) else {
                    throw lispError("ERROR", "no class named \(s.name)")
                }
                return c
            default:
                throw typeError(v, expected: "CLASS")
            }
        }

        // --- Class introspection ---

        defBuiltin("CLASS-DIRECT-SUPERCLASSES", 1, 1) { [unowned self] args in
            let c = try requireClass(args[0])
            _ = self
            return LispValue.list(c.directSuperclasses.map { .lispClass($0) })
        }

        defBuiltin("CLASS-DIRECT-SUBCLASSES", 1, 1) { args in
            let c = try requireClass(args[0])
            return LispValue.list(c.directSubclasses.map { .lispClass($0) })
        }

        defBuiltin("CLASS-PRECEDENCE-LIST", 1, 1) { args in
            let c = try requireClass(args[0])
            return LispValue.list(c.cpl.map { .lispClass($0) })
        }

        /// Slot definitions are represented as property lists:
        /// (name :initargs (...) :readers (...) :writers (...)
        ///       :allocation :instance|:class :initform-p t|nil)
        func slotPlist(_ s: SlotDef) -> LispValue {
            let kw = self.registry.keyword
            return LispValue.list([
                .symbol(s.name),
                .symbol(kw.intern("INITARGS")),
                LispValue.list(s.initargs.map { .symbol($0) }),
                .symbol(kw.intern("READERS")),
                LispValue.list(s.readers.map { .symbol($0) }),
                .symbol(kw.intern("WRITERS")),
                LispValue.list(s.writers.map { .symbol($0) }),
                .symbol(kw.intern("ALLOCATION")),
                .symbol(kw.intern(s.allocation == .instance
                                  ? "INSTANCE" : "CLASS")),
                .symbol(kw.intern("INITFORM-P")),
                s.initFunction != nil ? self.tValue : .null,
            ])
        }

        defBuiltin("CLASS-SLOTS", 1, 1) { args in
            let c = try requireClass(args[0])
            return LispValue.list(c.effectiveSlots.map { slotPlist($0) })
        }

        defBuiltin("CLASS-DIRECT-SLOTS", 1, 1) { args in
            let c = try requireClass(args[0])
            return LispValue.list(c.directSlots.map { slotPlist($0) })
        }

        defBuiltin("SLOT-DEFINITION-NAME", 1, 1) { args in
            guard let items = args[0].firstValue.asArray(),
                  let first = items.first else { return .null }
            return first
        }

        func slotDefReader(_ name: String, _ key: String) {
            defBuiltin(name, 1, 1) { [unowned self] args in
                guard let items = args[0].firstValue.asArray() else {
                    return .null
                }
                var i = 1
                while i + 1 < items.count {
                    if case .symbol(let k) = items[i], k.name == key {
                        return items[i + 1]
                    }
                    i += 2
                }
                _ = self
                return .null
            }
        }
        slotDefReader("SLOT-DEFINITION-INITARGS", "INITARGS")
        slotDefReader("SLOT-DEFINITION-READERS", "READERS")
        slotDefReader("SLOT-DEFINITION-WRITERS", "WRITERS")
        slotDefReader("SLOT-DEFINITION-ALLOCATION", "ALLOCATION")

        // --- Generic function introspection ---

        defBuiltin("GENERIC-FUNCTION-METHODS", 1, 1) { [unowned self] args in
            var gf: GenericFunction? = nil
            switch args[0].firstValue {
            case .function(let f): gf = f as? GenericFunction
            case .symbol(let s): gf = s.function as? GenericFunction
            default: break
            }
            guard let generic = gf else {
                throw self.typeError(args[0], expected: "GENERIC-FUNCTION")
            }
            let kw = self.registry.keyword
            var result: [LispValue] = []
            for m in generic.methods {
                let qualifier: LispValue
                switch m.qualifier {
                case .primary: qualifier = .null
                case .before: qualifier = .symbol(kw.intern("BEFORE"))
                case .after: qualifier = .symbol(kw.intern("AFTER"))
                case .around: qualifier = .symbol(kw.intern("AROUND"))
                case .custom(let s): qualifier = .symbol(s)
                }
                var specs: [LispValue] = []
                for s in m.specializers {
                    switch s {
                    case .clazz(let c):
                        specs.append(.symbol(c.name))
                    case .eql(let v):
                        specs.append(LispValue.list(
                            [.symbol(self.registry.lisp.intern("EQL")), v]))
                    }
                }
                result.append(LispValue.list([
                    .symbol(kw.intern("QUALIFIER")), qualifier,
                    .symbol(kw.intern("SPECIALIZERS")), LispValue.list(specs),
                ]))
            }
            return LispValue.list(result)
        }

        defBuiltin("ALLOCATE-INSTANCE", 1, nil) { [unowned self] args in
            let c = try requireClass(args[0])
            guard c.kind != .builtin else {
                throw self.lispError("ERROR",
                    "cannot allocate an instance of a built-in class")
            }
            return .instance(StandardInstance(clazz: c))
        }

        defBuiltin("VALIDATE-SUPERCLASS", 2, 2) { [unowned self] _ in
            self.tValue
        }

        defBuiltin("CLASS-FINALIZED-P", 1, 1) { [unowned self] _ in
            self.tValue
        }

        // --- DEFINE-METHOD-COMBINATION (short form) ---

        defMacro("DEFINE-METHOD-COMBINATION") { [unowned self] forms in
            guard !forms.isEmpty, case .symbol = forms[0] else {
                throw CompileError("malformed define-method-combination")
            }
            if forms.count > 1, case .cons = forms[1] {
                throw CompileError(
                    "only the short form of define-method-combination is supported")
            }
            // Parse &key operator identity-with-one-argument.
            var opForm: LispValue = forms[0]
            var identity: LispValue = .null
            var i = 1
            while i < forms.count {
                guard i + 1 < forms.count,
                      case .symbol(let k) = forms[i], k.isKeyword else { break }
                switch k.name {
                case "OPERATOR": opForm = forms[i + 1]
                case "IDENTITY-WITH-ONE-ARGUMENT": identity = forms[i + 1]
                default: break
                }
                i += 2
            }
            return self.lst(self.sym("%DEFINE-METHOD-COMBINATION"),
                            self.quoted(forms[0]), self.quoted(opForm),
                            identity)
        }

        defBuiltin("%DEFINE-METHOD-COMBINATION", 3, 3) { [unowned self] args in
            guard case .symbol(let name) = args[0].firstValue,
                  case .symbol(let op) = args[1].firstValue else {
                throw self.lispError("ERROR",
                    "malformed %define-method-combination")
            }
            self.methodCombinations[ObjectIdentifier(name)] =
                (op: op, identity: args[2].isTrue)
            return .symbol(name)
        }

        // Built-in operator combinations.
        for name in ["+", "AND", "OR", "LIST", "PROGN", "MAX", "MIN",
                     "APPEND", "NCONC"] {
            let sym = lisp.intern(name)
            methodCombinations[ObjectIdentifier(sym)] =
                (op: sym, identity: true)
        }

        // --- Readtable (simplified) ---

        defBuiltin("SET-MACRO-CHARACTER", 2, 4) { [unowned self] args in
            guard case .character(let c) = args[0].firstValue,
                  let fn = args[1].asFunction else {
                throw self.lispError("ERROR",
                    "set-macro-character needs a character and a function")
            }
            self.readtableMacros[c] = fn
            return self.tValue
        }

        defBuiltin("GET-MACRO-CHARACTER", 1, 2) { [unowned self] args in
            guard case .character(let c) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "CHARACTER")
            }
            if let fn = self.readtableMacros[c] {
                return .values([.function(fn), .null])
            }
            return .values([.null, .null])
        }

        defBuiltin("COPY-READTABLE", 0, 2) { [unowned self] _ in
            // There is a single global readtable in muCommonLISP.
            return self.registry.lisp.intern("*READTABLE*").value ?? .null
        }

        let readtableSym = lisp.intern("*READTABLE*")
        readtableSym.isSpecial = true
        readtableSym.value = .symbol(lisp.intern("READTABLE"))
    }
}
