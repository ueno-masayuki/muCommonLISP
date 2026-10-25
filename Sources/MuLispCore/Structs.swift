// Structs.swift
// DEFSTRUCT, integrated with CLOS as structure classes.

import Foundation

extension Interpreter {

    func registerStructs() {
        defBuiltin("%ENSURE-STRUCT-CLASS", 3, 3) { [unowned self] args in
            guard case .symbol(let name) = args[0].firstValue else {
                throw self.lispError("ERROR", "struct name must be a symbol")
            }
            var superNames: [Symbol] = []
            if case .symbol(let p) = args[1].firstValue {
                superNames = [p]
            }
            var specs: [SlotSpecData] = []
            for spec in args[2].asArray() ?? [] {
                guard let parts = spec.asArray(), parts.count >= 2,
                      case .symbol(let slotName) = parts[0] else {
                    throw self.lispError("ERROR", "malformed struct slot spec")
                }
                specs.append(SlotSpecData(name: slotName, initargs: [],
                                          initFunction: parts[1].asFunction,
                                          readers: [], writers: [],
                                          allocation: .instance))
            }
            let cls = try self.ensureClass(name: name, superNames: superNames,
                                           slotSpecs: specs, kind: .structure)
            return .lispClass(cls)
        }

        defBuiltin("%MAKE-STRUCT", 2, 2) { [unowned self] args in
            guard case .symbol(let name) = args[0].firstValue,
                  let cls = self.findClass(name) else {
                throw self.lispError("ERROR", "unknown structure type")
            }
            let inst = StandardInstance(clazz: cls)
            var provided: Set<ObjectIdentifier> = []
            for pair in args[1].asArray() ?? [] {
                guard let p = pair.asArray(), p.count == 2,
                      case .symbol(let slotName) = p[0] else {
                    throw self.lispError("ERROR", "malformed struct initializer")
                }
                try self.setSlotValue(inst, slotName, p[1])
                provided.insert(ObjectIdentifier(slotName))
            }
            for slot in cls.effectiveSlots
            where slot.allocation == .instance
                && !provided.contains(ObjectIdentifier(slot.name)) {
                if let initFn = slot.initFunction {
                    let v = try self.applyFunction(initFn, []).firstValue
                    try self.setSlotValue(inst, slot.name, v)
                } else {
                    try self.setSlotValue(inst, slot.name, .null)
                }
            }
            return .instance(inst)
        }

        defBuiltin("%COPY-STRUCT", 1, 1) { [unowned self] args in
            guard case .instance(let inst) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "STRUCTURE-OBJECT")
            }
            self.ensureCurrentVersion(inst)
            let copy = StandardInstance(clazz: inst.clazz)
            copy.slots = inst.slots
            return .instance(copy)
        }

        defMacro("DEFSTRUCT") { [unowned self] forms in
            try self.expandDefstruct(forms)
        }
    }

    private func expandDefstruct(_ forms: [LispValue]) throws -> LispValue {
        guard !forms.isEmpty else {
            throw CompileError("malformed defstruct")
        }

        var structName: Symbol
        var includeName: Symbol? = nil
        var concName: String? = nil
        var concNameGiven = false
        var constructorName: String? = nil
        var predicateName: String? = nil
        var copierName: String? = nil

        switch forms[0] {
        case .symbol(let s):
            structName = s
        case .cons:
            guard let parts = forms[0].asArray(), !parts.isEmpty,
                  case .symbol(let s) = parts[0] else {
                throw CompileError("malformed defstruct name")
            }
            structName = s
            for opt in parts.dropFirst() {
                guard let o = opt.asArray(), !o.isEmpty,
                      case .symbol(let key) = o[0] else {
                    throw CompileError("malformed defstruct option")
                }
                switch key.name {
                case "INCLUDE":
                    guard o.count >= 2, case .symbol(let p) = o[1] else {
                        throw CompileError("malformed :include option")
                    }
                    includeName = p
                case "CONC-NAME":
                    concNameGiven = true
                    if o.count >= 2, case .symbol(let p) = o[1] {
                        concName = p.name
                    } else {
                        concName = nil   // (:conc-name) / (:conc-name nil)
                    }
                case "CONSTRUCTOR":
                    if o.count >= 2, case .symbol(let p) = o[1] {
                        constructorName = p.name
                    }
                case "PREDICATE":
                    if o.count >= 2, case .symbol(let p) = o[1] {
                        predicateName = p.name
                    }
                case "COPIER":
                    if o.count >= 2, case .symbol(let p) = o[1] {
                        copierName = p.name
                    }
                case "PRINT-FUNCTION", "PRINT-OBJECT":
                    break   // ignored
                default:
                    throw CompileError("unsupported defstruct option :\(key.name)")
                }
            }
        default:
            throw CompileError("malformed defstruct name")
        }

        // Own slots.
        var ownSlotNames: [Symbol] = []
        var ownSlotDefaults: [LispValue] = []
        for sf in forms.dropFirst() {
            switch sf {
            case .symbol(let s):
                ownSlotNames.append(s)
                ownSlotDefaults.append(.null)
            case .string:
                continue   // docstring
            case .cons:
                guard let parts = sf.asArray(), !parts.isEmpty,
                      case .symbol(let s) = parts[0] else {
                    throw CompileError("malformed defstruct slot")
                }
                ownSlotNames.append(s)
                ownSlotDefaults.append(parts.count >= 2 ? parts[1] : .null)
            default:
                throw CompileError("malformed defstruct slot")
            }
        }

        // Inherited slots (parent must already be defined).
        var inheritedNames: [Symbol] = []
        if let inc = includeName {
            guard let parent = findClass(inc), parent.kind == .structure else {
                throw CompileError(
                    ":include names an undefined structure \(inc.name)")
            }
            inheritedNames = parent.instanceSlotNames
        }

        let prefix: String
        if concNameGiven {
            prefix = concName.map { $0.hasSuffix("-") ? $0 : $0 } ?? ""
        } else {
            prefix = structName.name + "-"
        }

        let pkg = currentPackage
        func localSym(_ n: String) -> LispValue {
            return .symbol(pkg.intern(n))
        }

        var out: [LispValue] = [sym("PROGN")]

        // 1. Class definition.
        var slotSpecForms: [LispValue] = []
        for (i, n) in ownSlotNames.enumerated() {
            let initFn = ownSlotDefaults[i].isNil
                ? LispValue.null
                : lst(sym("LAMBDA"), .null, ownSlotDefaults[i])
            slotSpecForms.append(lst(sym("LIST"), quoted(.symbol(n)), initFn))
        }
        out.append(lst(sym("%ENSURE-STRUCT-CLASS"),
                       quoted(.symbol(structName)),
                       includeName.map { quoted(.symbol($0)) } ?? .null,
                       LispValue.list([sym("LIST")] + slotSpecForms)))

        // 2. Constructor.
        let allSlots = inheritedNames + ownSlotNames
        let ctorName = constructorName ?? "MAKE-" + structName.name
        var keyParams: [LispValue] = [sym("&KEY")]
        var initPairForms: [LispValue] = []
        for s in allSlots {
            let suppliedVar = LispValue.symbol(pkg.intern(s.name + "-SUPPLIED-P"))
            keyParams.append(lst(localSym(s.name), .null, suppliedVar))
            initPairForms.append(
                lst(sym("IF"), suppliedVar,
                    lst(sym("LIST"),
                        lst(sym("LIST"), quoted(.symbol(s)), localSym(s.name))),
                    .null))
        }
        out.append(lst(sym("DEFUN"), localSym(ctorName),
                       LispValue.list(keyParams),
                       lst(sym("%MAKE-STRUCT"), quoted(.symbol(structName)),
                           LispValue.list([sym("APPEND")] + initPairForms))))

        // 3. Accessors (own slots only; inherited ones come from the parent).
        let xVar = localSym("X")
        let vVar = localSym("V")
        for s in ownSlotNames {
            let accessor = localSym(prefix + s.name)
            out.append(lst(sym("DEFUN"), accessor, lst(xVar),
                           lst(sym("SLOT-VALUE"), xVar, quoted(.symbol(s)))))
            out.append(lst(sym("DEFUN"), lst(sym("SETF"), accessor),
                           lst(vVar, xVar),
                           lst(sym("SETF"),
                               lst(sym("SLOT-VALUE"), xVar, quoted(.symbol(s))),
                               vVar)))
        }

        // 4. Predicate and copier.
        let predName = predicateName ?? structName.name + "-P"
        out.append(lst(sym("DEFUN"), localSym(predName), lst(xVar),
                       lst(sym("TYPEP"), xVar, quoted(.symbol(structName)))))
        let copyName = copierName ?? "COPY-" + structName.name
        out.append(lst(sym("DEFUN"), localSym(copyName), lst(xVar),
                       lst(sym("%COPY-STRUCT"), xVar)))

        out.append(quoted(.symbol(structName)))
        return LispValue.list(out)
    }
}
