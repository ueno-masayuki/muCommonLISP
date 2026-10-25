// CLOSInit.swift
// Slot access, instance initialization protocol, class (re)definition,
// and the DEFCLASS / DEFMETHOD / DEFGENERIC macros.

import Foundation

extension Interpreter {

    // MARK: - Slot access

    /// Lazily migrate an instance whose class has been redefined.
    public func ensureCurrentVersion(_ inst: StandardInstance) {
        guard inst.version != inst.clazz.version else { return }
        let oldLayout = inst.clazz.layout(forVersion: inst.version) ?? []
        var oldValues: [Symbol: LispValue?] = [:]
        for (i, name) in oldLayout.enumerated() where i < inst.slots.count {
            oldValues[name] = inst.slots[i]
        }
        var newSlots = [LispValue?](repeating: nil,
                                    count: inst.clazz.instanceSlotCount)
        for slot in inst.clazz.effectiveSlots where slot.allocation == .instance {
            if let old = oldValues[slot.name] {
                newSlots[slot.location] = old
            } else if let initFn = slot.initFunction,
                      let v = try? applyFunction(initFn, []) {
                newSlots[slot.location] = v.firstValue
            }
        }
        inst.slots = newSlots
        inst.version = inst.clazz.version
    }

    public func slotValue(_ inst: StandardInstance,
                          _ name: Symbol) throws -> LispValue {
        ensureCurrentVersion(inst)
        guard let slot = inst.clazz.effectiveSlot(named: name) else {
            throw lispError("CELL-ERROR",
                "no slot named \(name.name) in class \(inst.clazz.name.name)",
                slots: [("NAME", .symbol(name))])
        }
        let value: LispValue?
        if slot.allocation == .instance {
            value = inst.slots[slot.location]
        } else {
            value = slot.classCell?.value
        }
        guard let v = value else {
            throw lispError("UNBOUND-SLOT",
                "slot \(name.name) is unbound in instance of \(inst.clazz.name.name)",
                slots: [("NAME", .symbol(name))])
        }
        return v
    }

    public func setSlotValue(_ inst: StandardInstance, _ name: Symbol,
                             _ value: LispValue) throws {
        ensureCurrentVersion(inst)
        guard let slot = inst.clazz.effectiveSlot(named: name) else {
            throw lispError("CELL-ERROR",
                "no slot named \(name.name) in class \(inst.clazz.name.name)",
                slots: [("NAME", .symbol(name))])
        }
        if slot.allocation == .instance {
            inst.slots[slot.location] = value
        } else {
            slot.classCell?.value = value
        }
    }

    public func slotBoundp(_ inst: StandardInstance, _ name: Symbol) throws -> Bool {
        ensureCurrentVersion(inst)
        guard let slot = inst.clazz.effectiveSlot(named: name) else {
            throw lispError("CELL-ERROR",
                "no slot named \(name.name) in class \(inst.clazz.name.name)")
        }
        if slot.allocation == .instance {
            return inst.slots[slot.location] != nil
        }
        return slot.classCell?.value != nil
    }

    // MARK: - Class lookup

    public func findClass(_ name: Symbol) -> LispClass? {
        return classRegistry[name]
    }

    public func findClassByName(_ name: String) -> LispClass? {
        return classRegistry[registry.lisp.intern(name)]
    }

    // MARK: - ensure-class

    /// Slot specification passed from the DEFCLASS macro expansion.
    public struct SlotSpecData {
        public let name: Symbol
        public let initargs: [Symbol]
        public let initFunction: LispFunction?
        public let readers: [Symbol]
        public let writers: [Symbol]
        public let allocation: SlotAllocation
    }

    @discardableResult
    public func ensureClass(name: Symbol, superNames: [Symbol],
                            slotSpecs: [SlotSpecData],
                            kind: ClassKind = .standard,
                            documentation: String? = nil) throws -> LispClass {
        var supers: [LispClass] = []
        for sn in superNames {
            guard let sc = findClass(sn) else {
                throw lispError("ERROR", "unknown superclass \(sn.name) for \(name.name)")
            }
            supers.append(sc)
        }
        if supers.isEmpty {
            let defaultSuper = kind == .structure ? "STRUCTURE-OBJECT" : "STANDARD-OBJECT"
            if let sc = findClassByName(defaultSuper), name.name != defaultSuper {
                supers = [sc]
            }
        }

        let cls: LispClass
        var isRedefinition = false
        if let existing = findClass(name), existing.kind == kind {
            cls = existing
            isRedefinition = true
            for oldSuper in cls.directSuperclasses {
                oldSuper.directSubclasses.removeAll { $0 === cls }
            }
        } else {
            cls = LispClass(name: name, kind: kind)
            classRegistry[name] = cls
        }

        cls.directSuperclasses = supers
        cls.documentation = documentation
        cls.directSlots = slotSpecs.map { spec in
            SlotDef(name: spec.name, initargs: spec.initargs,
                    initFunction: spec.initFunction,
                    readers: spec.readers, writers: spec.writers,
                    allocation: spec.allocation)
        }
        for s in supers where !s.directSubclasses.contains(where: { $0 === cls }) {
            s.directSubclasses.append(cls)
        }

        if isRedefinition {
            try cls.refinalizeTree()
            clearAllGFCaches()
        } else {
            try cls.finalizeClass()
        }

        // Generate reader / writer methods.
        for spec in slotSpecs {
            let slotName = spec.name
            for reader in spec.readers {
                let gf = try ensureGenericFunction(named: reader, nRequired: 1)
                let fn = Builtin(name: reader.name, minArgs: 1, maxArgs: 1) {
                    [unowned self] args in
                    guard case .instance(let inst) = args[0].firstValue else {
                        throw self.typeError(args[0], expected: cls.name.name)
                    }
                    return try self.slotValue(inst, slotName)
                }
                gf.addMethod(MethodObj(qualifier: .primary,
                                       specializers: [.clazz(cls)],
                                       function: fn))
            }
            for writer in spec.writers {
                let gf = try ensureSetfGenericFunction(named: writer, nRequired: 2)
                let fn = Builtin(name: "(SETF \(writer.name))",
                                 minArgs: 2, maxArgs: 2) {
                    [unowned self] args in
                    guard case .instance(let inst) = args[1].firstValue else {
                        throw self.typeError(args[1], expected: cls.name.name)
                    }
                    try self.setSlotValue(inst, slotName, args[0])
                    return args[0]
                }
                gf.addMethod(MethodObj(qualifier: .primary,
                                       specializers: [.clazz(classes.t), .clazz(cls)],
                                       function: fn))
            }
        }
        return cls
    }

    public func clearAllGFCaches() {
        for (_, pkg) in registry.packages {
            for (_, sym) in pkg.symbols {
                if let gf = sym.function as? GenericFunction { gf.clearCache() }
                if let gf = sym.setfFunction as? GenericFunction { gf.clearCache() }
            }
        }
    }

    public func ensureGenericFunction(named name: Symbol,
                                      nRequired: Int) throws -> GenericFunction {
        if let existing = name.function {
            if let gf = existing as? GenericFunction { return gf }
            throw lispError("ERROR",
                "\(name.name) already names an ordinary function")
        }
        let gf = GenericFunction(name: name.name, nRequired: nRequired)
        name.function = gf
        return gf
    }

    public func ensureSetfGenericFunction(named name: Symbol,
                                          nRequired: Int) throws -> GenericFunction {
        if let existing = name.setfFunction {
            if let gf = existing as? GenericFunction { return gf }
            throw lispError("ERROR",
                "(SETF \(name.name)) already names an ordinary function")
        }
        let gf = GenericFunction(name: "(SETF \(name.name))", nRequired: nRequired)
        name.setfFunction = gf
        return gf
    }

    // MARK: - Instance creation protocol

    public func makeInstance(of cls: LispClass,
                             initargs: [LispValue]) throws -> LispValue {
        guard cls.kind != .builtin else {
            throw lispError("ERROR",
                "cannot make an instance of built-in class \(cls.name.name)")
        }
        let inst = StandardInstance(clazz: cls)
        let gf = initializeInstanceGF
        _ = try dispatchGeneric(gf, [.instance(inst)] + initargs)
        return .instance(inst)
    }

    /// The system behavior of SHARED-INITIALIZE.
    public func systemSharedInitialize(_ inst: StandardInstance,
                                       _ slotNames: LispValue,
                                       _ initargs: [LispValue]) throws -> LispValue {
        ensureCurrentVersion(inst)
        if initargs.count % 2 != 0 {
            throw lispError("PROGRAM-ERROR", "odd number of initargs")
        }
        var pairs: [(Symbol, LispValue)] = []
        var i = 0
        while i < initargs.count {
            guard case .symbol(let k) = initargs[i].firstValue else {
                throw lispError("PROGRAM-ERROR", "initarg name is not a symbol")
            }
            pairs.append((k, initargs[i + 1].firstValue))
            i += 2
        }
        let namesList = slotNames.asArray()

        for slot in inst.clazz.effectiveSlots {
            var initialized = false
            for (k, v) in pairs {
                if slot.initargs.contains(where: { $0 === k }) {
                    try setSlotValue(inst, slot.name, v)
                    initialized = true
                    break
                }
            }
            if initialized { continue }

            let inNames: Bool
            if slotNames.isTrue, namesList == nil {
                inNames = true   // slot-names = T
            } else if let list = namesList {
                inNames = list.contains {
                    if case .symbol(let s) = $0 { return s === slot.name }
                    return false
                }
            } else {
                inNames = false
            }
            guard inNames else { continue }

            let isUnbound: Bool
            if slot.allocation == .instance {
                isUnbound = inst.slots[slot.location] == nil
            } else {
                isUnbound = slot.classCell?.value == nil
            }
            if isUnbound, let initFn = slot.initFunction {
                let v = try applyFunction(initFn, []).firstValue
                try setSlotValue(inst, slot.name, v)
            }
        }
        return .instance(inst)
    }

    // MARK: - change-class

    public func changeClass(_ inst: StandardInstance, to newClass: LispClass,
                            initargs: [LispValue]) throws -> LispValue {
        ensureCurrentVersion(inst)
        let oldClass = inst.clazz
        var oldValues: [Symbol: LispValue?] = [:]
        for slot in oldClass.effectiveSlots where slot.allocation == .instance {
            oldValues[slot.name] = inst.slots[slot.location]
        }
        inst.clazz = newClass
        inst.version = newClass.version
        inst.slots = [LispValue?](repeating: nil,
                                  count: newClass.instanceSlotCount)
        var added: [LispValue] = []
        for slot in newClass.effectiveSlots where slot.allocation == .instance {
            if let old = oldValues[slot.name], let v = old {
                inst.slots[slot.location] = v
            } else {
                added.append(.symbol(slot.name))
            }
        }
        _ = try systemSharedInitialize(inst, LispValue.list(added), initargs)
        return .instance(inst)
    }

    // MARK: - Registration of CLOS builtins and macros

    func registerCLOS() {
        let lisp = registry.lisp

        // --- Core protocol generic functions with system methods ---

        let tSpec = Specializer.clazz(classes.t)

        let initGF = GenericFunction(name: "INITIALIZE-INSTANCE", nRequired: 1)
        initGF.addMethod(MethodObj(
            qualifier: .primary, specializers: [tSpec],
            function: Builtin(name: "SYSTEM-INITIALIZE-INSTANCE",
                              minArgs: 1, maxArgs: nil) { [unowned self] args in
                guard case .instance(let inst) = args[0].firstValue else {
                    throw self.typeError(args[0], expected: "STANDARD-OBJECT")
                }
                return try self.systemSharedInitialize(inst, self.tValue,
                                                       Array(args.dropFirst()))
            }))
        lisp.intern("INITIALIZE-INSTANCE").function = initGF
        initializeInstanceGF = initGF

        let sharedGF = GenericFunction(name: "SHARED-INITIALIZE", nRequired: 2)
        sharedGF.addMethod(MethodObj(
            qualifier: .primary, specializers: [tSpec, tSpec],
            function: Builtin(name: "SYSTEM-SHARED-INITIALIZE",
                              minArgs: 2, maxArgs: nil) { [unowned self] args in
                guard case .instance(let inst) = args[0].firstValue else {
                    throw self.typeError(args[0], expected: "STANDARD-OBJECT")
                }
                return try self.systemSharedInitialize(inst, args[1],
                                                       Array(args.dropFirst(2)))
            }))
        lisp.intern("SHARED-INITIALIZE").function = sharedGF

        let reinitGF = GenericFunction(name: "REINITIALIZE-INSTANCE", nRequired: 1)
        reinitGF.addMethod(MethodObj(
            qualifier: .primary, specializers: [tSpec],
            function: Builtin(name: "SYSTEM-REINITIALIZE-INSTANCE",
                              minArgs: 1, maxArgs: nil) { [unowned self] args in
                guard case .instance(let inst) = args[0].firstValue else {
                    throw self.typeError(args[0], expected: "STANDARD-OBJECT")
                }
                return try self.systemSharedInitialize(inst, .null,
                                                       Array(args.dropFirst()))
            }))
        lisp.intern("REINITIALIZE-INSTANCE").function = reinitGF

        let printObjGF = GenericFunction(name: "PRINT-OBJECT", nRequired: 2)
        lisp.intern("PRINT-OBJECT").function = printObjGF
        printObjectGF = printObjGF

        // MAKE-INSTANCE as a generic function on SYMBOL / CLASS.
        let miGF = GenericFunction(name: "MAKE-INSTANCE", nRequired: 1)
        miGF.addMethod(MethodObj(
            qualifier: .primary, specializers: [.clazz(classes.symbol)],
            function: Builtin(name: "MAKE-INSTANCE-BY-NAME",
                              minArgs: 1, maxArgs: nil) { [unowned self] args in
                guard case .symbol(let s) = args[0].firstValue,
                      let cls = self.findClass(s) else {
                    throw self.lispError("ERROR",
                        "no class named \(Printer.toString(args[0], escape: true))")
                }
                return try self.makeInstance(of: cls,
                                             initargs: Array(args.dropFirst()))
            }))
        miGF.addMethod(MethodObj(
            qualifier: .primary, specializers: [.clazz(classes.classClass)],
            function: Builtin(name: "MAKE-INSTANCE-BY-CLASS",
                              minArgs: 1, maxArgs: nil) { [unowned self] args in
                guard case .lispClass(let cls) = args[0].firstValue else {
                    throw self.typeError(args[0], expected: "CLASS")
                }
                return try self.makeInstance(of: cls,
                                             initargs: Array(args.dropFirst()))
            }))
        lisp.intern("MAKE-INSTANCE").function = miGF

        // --- Plain builtins ---

        defBuiltin("SLOT-VALUE", 2, 2) { [unowned self] args in
            guard case .instance(let inst) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "STANDARD-OBJECT")
            }
            guard case .symbol(let name) = args[1].firstValue else {
                throw self.typeError(args[1], expected: "SYMBOL")
            }
            return try self.slotValue(inst, name)
        }

        defSetfHandler("SLOT-VALUE") { [unowned self] args in
            // (newval instance slot-name)
            guard case .instance(let inst) = args[1].firstValue else {
                throw self.typeError(args[1], expected: "STANDARD-OBJECT")
            }
            guard case .symbol(let name) = args[2].firstValue else {
                throw self.typeError(args[2], expected: "SYMBOL")
            }
            try self.setSlotValue(inst, name, args[0])
            return args[0]
        }

        defBuiltin("SLOT-BOUNDP", 2, 2) { [unowned self] args in
            guard case .instance(let inst) = args[0].firstValue,
                  case .symbol(let name) = args[1].firstValue else {
                throw self.typeError(args[0], expected: "STANDARD-OBJECT")
            }
            return try self.slotBoundp(inst, name) ? self.tValue : .null
        }

        defBuiltin("SLOT-MAKUNBOUND", 2, 2) { [unowned self] args in
            guard case .instance(let inst) = args[0].firstValue,
                  case .symbol(let name) = args[1].firstValue else {
                throw self.typeError(args[0], expected: "STANDARD-OBJECT")
            }
            self.ensureCurrentVersion(inst)
            guard let slot = inst.clazz.effectiveSlot(named: name) else {
                throw self.lispError("CELL-ERROR", "no slot named \(name.name)")
            }
            if slot.allocation == .instance {
                inst.slots[slot.location] = nil
            } else {
                slot.classCell?.value = nil
            }
            return args[0]
        }

        defBuiltin("SLOT-EXISTS-P", 2, 2) { [unowned self] args in
            guard case .instance(let inst) = args[0].firstValue,
                  case .symbol(let name) = args[1].firstValue else {
                return .null
            }
            self.ensureCurrentVersion(inst)
            return inst.clazz.effectiveSlot(named: name) != nil
                ? self.tValue : .null
        }

        defBuiltin("CLASS-OF", 1, 1) { [unowned self] args in
            return .lispClass(self.classOf(args[0].firstValue))
        }

        defBuiltin("FIND-CLASS", 1, 2) { [unowned self] args in
            guard case .symbol(let s) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "SYMBOL")
            }
            if let cls = self.findClass(s) {
                return .lispClass(cls)
            }
            let errorp = args.count < 2 || args[1].isTrue
            if errorp {
                throw self.lispError("ERROR", "no class named \(s.name)")
            }
            return .null
        }

        defBuiltin("CLASS-NAME", 1, 1) { [unowned self] args in
            guard case .lispClass(let cls) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "CLASS")
            }
            return .symbol(cls.name)
        }

        defBuiltin("CHANGE-CLASS", 2, nil) { [unowned self] args in
            guard case .instance(let inst) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "STANDARD-OBJECT")
            }
            let cls: LispClass
            switch args[1].firstValue {
            case .symbol(let s):
                guard let c = self.findClass(s) else {
                    throw self.lispError("ERROR", "no class named \(s.name)")
                }
                cls = c
            case .lispClass(let c):
                cls = c
            default:
                throw self.typeError(args[1], expected: "CLASS")
            }
            return try self.changeClass(inst, to: cls,
                                        initargs: Array(args.dropFirst(2)))
        }

        defBuiltin("CALL-NEXT-METHOD", 0, nil) { [unowned self] args in
            guard let ctx = self.nextMethodStack.last else {
                throw self.lispError("CONTROL-ERROR",
                    "call-next-method outside of a method")
            }
            guard let next = ctx.next else {
                throw self.lispError("CONTROL-ERROR", "no next method")
            }
            return try next(args.isEmpty ? ctx.args : args)
        }

        defBuiltin("NEXT-METHOD-P", 0, 0) { [unowned self] _ in
            guard let ctx = self.nextMethodStack.last else { return .null }
            return ctx.next != nil ? self.tValue : .null
        }

        defBuiltin("TYPEP", 2, 2) { [unowned self] args in
            return try self.typep(args[0].firstValue, args[1].firstValue)
                ? self.tValue : .null
        }

        defBuiltin("SUBTYPEP", 2, 2) { [unowned self] args in
            guard case .symbol(let s1) = args[0].firstValue,
                  case .symbol(let s2) = args[1].firstValue,
                  let c1 = self.findClass(s1), let c2 = self.findClass(s2) else {
                return .values([.null, .null])
            }
            return .values([c1.isSubclass(of: c2) ? self.tValue : .null,
                            self.tValue])
        }

        defBuiltin("%ENSURE-GF", 2, 3) { [unowned self] args in
            guard case .symbol(let s) = args[0].firstValue,
                  case .int(let n) = args[1].firstValue else {
                throw self.lispError("ERROR", "malformed %ensure-gf call")
            }
            let gf = try self.ensureGenericFunction(named: s, nRequired: n)
            if args.count > 2, case .string(let doc) = args[2].firstValue {
                gf.documentation = doc
            }
            return .symbol(s)
        }

        defBuiltin("%ENSURE-CLASS", 3, 4) { [unowned self] args in
            guard case .symbol(let name) = args[0].firstValue else {
                throw self.lispError("ERROR", "class name must be a symbol")
            }
            var superNames: [Symbol] = []
            for s in args[1].asArray() ?? [] {
                guard case .symbol(let sn) = s else {
                    throw self.lispError("ERROR", "superclass name must be a symbol")
                }
                superNames.append(sn)
            }
            var specs: [SlotSpecData] = []
            for spec in args[2].asArray() ?? [] {
                guard let parts = spec.asArray(), parts.count >= 6,
                      case .symbol(let slotName) = parts[0] else {
                    throw self.lispError("ERROR", "malformed slot spec")
                }
                var initargs: [Symbol] = []
                for ia in parts[1].asArray() ?? [] {
                    if case .symbol(let s) = ia { initargs.append(s) }
                }
                let initFn = parts[2].asFunction
                var readers: [Symbol] = []
                for r in parts[3].asArray() ?? [] {
                    if case .symbol(let s) = r { readers.append(s) }
                }
                var writers: [Symbol] = []
                for w in parts[4].asArray() ?? [] {
                    if case .symbol(let s) = w { writers.append(s) }
                }
                var allocation = SlotAllocation.instance
                if case .symbol(let a) = parts[5], a.name == "CLASS" {
                    allocation = .classAllocation
                }
                specs.append(SlotSpecData(name: slotName, initargs: initargs,
                                          initFunction: initFn,
                                          readers: readers, writers: writers,
                                          allocation: allocation))
            }
            var doc: String? = nil
            if args.count > 3, case .string(let d) = args[3].firstValue {
                doc = d
            }
            let cls = try self.ensureClass(name: name, superNames: superNames,
                                           slotSpecs: specs,
                                           documentation: doc)
            return .lispClass(cls)
        }

        defBuiltin("%ADD-METHOD", 4, 4) { [unowned self] args in
            // (%add-method name-designator qualifier specializers function)
            let nameDes = args[0].firstValue
            guard case .symbol(let qual) = args[1].firstValue else {
                throw self.lispError("ERROR", "bad method qualifier")
            }
            let qualifier: MethodQualifier
            switch qual.name {
            case "PRIMARY": qualifier = .primary
            case "BEFORE": qualifier = .before
            case "AFTER": qualifier = .after
            case "AROUND": qualifier = .around
            default:
                throw self.lispError("ERROR",
                    "unsupported method qualifier \(qual.name)")
            }
            var specializers: [Specializer] = []
            for s in args[2].asArray() ?? [] {
                switch s {
                case .symbol(let className):
                    guard let cls = self.findClass(className) else {
                        throw self.lispError("ERROR",
                            "no class named \(className.name)")
                    }
                    specializers.append(.clazz(cls))
                case .cons(let c):
                    // (EQL value)
                    guard case .symbol(let eql) = c.car, eql.name == "EQL",
                          let rest = c.cdr.asCons else {
                        throw self.lispError("ERROR", "bad specializer")
                    }
                    specializers.append(.eql(rest.car))
                default:
                    throw self.lispError("ERROR", "bad specializer")
                }
            }
            guard let fn = args[3].asFunction else {
                throw self.lispError("ERROR", "method function missing")
            }
            let gf: GenericFunction
            switch nameDes {
            case .symbol(let s):
                gf = try self.ensureGenericFunction(named: s,
                                                    nRequired: specializers.count)
            case .cons(let c):
                guard case .symbol(let setf) = c.car, setf.name == "SETF",
                      let rest = c.cdr.asCons,
                      case .symbol(let s) = rest.car else {
                    throw self.lispError("ERROR", "bad method name")
                }
                gf = try self.ensureSetfGenericFunction(named: s,
                                                        nRequired: specializers.count)
            default:
                throw self.lispError("ERROR", "bad method name")
            }
            if gf.nRequired < specializers.count {
                gf.nRequired = specializers.count
            }
            gf.addMethod(MethodObj(qualifier: qualifier,
                                   specializers: specializers,
                                   function: fn))
            return nameDes
        }

        registerCLOSMacros()
    }

    // MARK: - DEFCLASS / DEFMETHOD / DEFGENERIC macros (Swift-implemented)

    private func registerCLOSMacros() {
        defMacro("DEFCLASS") { [unowned self] forms in
            try self.expandDefclass(forms)
        }
        defMacro("DEFMETHOD") { [unowned self] forms in
            try self.expandDefmethod(forms)
        }
        defMacro("DEFGENERIC") { [unowned self] forms in
            try self.expandDefgeneric(forms)
        }
    }

    // (defclass name (supers...) (slot-specs...) options...)
    private func expandDefclass(_ forms: [LispValue]) throws -> LispValue {
        guard forms.count >= 3, case .symbol = forms[0] else {
            throw CompileError("malformed defclass")
        }
        let name = forms[0]
        let supers = forms[1]
        guard let slotForms = forms[2].asArray() else {
            throw CompileError("malformed defclass slot list")
        }
        var slotSpecForms: [LispValue] = []
        for sf in slotForms {
            slotSpecForms.append(try expandSlotSpec(sf))
        }
        var doc: LispValue = .null
        for opt in forms.dropFirst(3) {
            if let parts = opt.asArray(), parts.count == 2,
               case .symbol(let k) = parts[0], k.name == "DOCUMENTATION" {
                doc = parts[1]
            }
            // :default-initargs and :metaclass are not supported (ignored).
        }
        return lst(sym("%ENSURE-CLASS"), quoted(name), quoted(supers),
                   LispValue.list([sym("LIST")] + slotSpecForms), doc)
    }

    /// One slot spec -> a (LIST 'name '(initargs) initfn '(readers) '(writers)
    /// 'allocation) form.
    private func expandSlotSpec(_ sf: LispValue) throws -> LispValue {
        var slotName: LispValue
        var initargs: [LispValue] = []
        var initform: LispValue? = nil
        var readers: [LispValue] = []
        var writers: [LispValue] = []
        var allocation = "INSTANCE"

        switch sf {
        case .symbol:
            slotName = sf
        case .cons:
            guard let parts = sf.asArray(), !parts.isEmpty,
                  case .symbol = parts[0] else {
                throw CompileError("malformed slot spec")
            }
            slotName = parts[0]
            var i = 1
            while i < parts.count {
                guard i + 1 < parts.count,
                      case .symbol(let key) = parts[i] else {
                    throw CompileError("malformed slot option in slot spec")
                }
                let value = parts[i + 1]
                switch key.name {
                case "INITARG":
                    initargs.append(value)
                case "INITFORM":
                    initform = value
                case "READER":
                    readers.append(value)
                case "WRITER":
                    writers.append(value)
                case "ACCESSOR":
                    readers.append(value)
                    writers.append(value)
                case "ALLOCATION":
                    if case .symbol(let a) = value, a.name == "CLASS" {
                        allocation = "CLASS"
                    }
                case "TYPE", "DOCUMENTATION":
                    break   // accepted and ignored
                default:
                    throw CompileError("unsupported slot option :\(key.name)")
                }
                i += 2
            }
        default:
            throw CompileError("malformed slot spec")
        }

        let initFnForm: LispValue
        if let form = initform {
            initFnForm = lst(sym("LAMBDA"), .null, form)
        } else {
            initFnForm = .null
        }
        return lst(sym("LIST"),
                   quoted(slotName),
                   quoted(LispValue.list(initargs)),
                   initFnForm,
                   quoted(LispValue.list(readers)),
                   quoted(LispValue.list(writers)),
                   quoted(.symbol(registry.lisp.intern(allocation))))
    }

    // (defmethod name [qualifier] lambda-list body...)
    private func expandDefmethod(_ forms: [LispValue]) throws -> LispValue {
        guard forms.count >= 2 else {
            throw CompileError("malformed defmethod")
        }
        let nameDes = forms[0]
        var idx = 1
        var qualifier = "PRIMARY"
        if case .symbol(let q) = forms[idx], q.isKeyword || q.name == "AROUND" {
            switch q.name {
            case "BEFORE", "AFTER", "AROUND":
                qualifier = q.name
                idx += 1
            default:
                throw CompileError("unsupported method qualifier :\(q.name)")
            }
        }
        guard idx < forms.count else {
            throw CompileError("defmethod missing lambda list")
        }
        guard let llItems = forms[idx].asArray() else {
            throw CompileError("malformed defmethod lambda list")
        }
        let body = Array(forms.dropFirst(idx + 1))

        var plainParams: [LispValue] = []
        var specializerForms: [LispValue] = []
        var inRequired = true
        for item in llItems {
            if case .symbol(let s) = item, s.name.hasPrefix("&") {
                inRequired = false
                plainParams.append(item)
                continue
            }
            if inRequired {
                switch item {
                case .symbol:
                    plainParams.append(item)
                    specializerForms.append(quoted(sym("T")))
                case .cons:
                    guard let parts = item.asArray(), parts.count == 2,
                          case .symbol = parts[0] else {
                        throw CompileError("malformed specialized parameter")
                    }
                    plainParams.append(parts[0])
                    if let specParts = parts[1].asArray(), specParts.count == 2,
                       case .symbol(let eql) = specParts[0], eql.name == "EQL" {
                        // (eql form): evaluate form at definition time.
                        specializerForms.append(
                            lst(sym("LIST"), quoted(sym("EQL")), specParts[1]))
                    } else if case .symbol = parts[1] {
                        specializerForms.append(quoted(parts[1]))
                    } else {
                        throw CompileError("malformed specializer")
                    }
                default:
                    throw CompileError("malformed defmethod parameter")
                }
            } else {
                plainParams.append(item)
            }
        }

        // Block name for RETURN-FROM.
        var blockName: LispValue = nameDes
        if let parts = nameDes.asArray(), parts.count == 2 {
            blockName = parts[1]
        }

        let lambdaForm = lst(sym("LAMBDA"), LispValue.list(plainParams),
                             LispValue.list([sym("BLOCK"), blockName] + body))
        return lst(sym("%ADD-METHOD"),
                   quoted(nameDes),
                   quoted(.symbol(registry.lisp.intern(qualifier))),
                   LispValue.list([sym("LIST")] + specializerForms),
                   lambdaForm)
    }

    // (defgeneric name lambda-list options...)
    private func expandDefgeneric(_ forms: [LispValue]) throws -> LispValue {
        guard forms.count >= 2, case .symbol = forms[0],
              let ll = forms[1].asArray() else {
            throw CompileError("malformed defgeneric")
        }
        var nRequired = 0
        for item in ll {
            if case .symbol(let s) = item, s.name.hasPrefix("&") { break }
            nRequired += 1
        }
        var doc: LispValue = .null
        var methodForms: [LispValue] = []
        for opt in forms.dropFirst(2) {
            guard let parts = opt.asArray(), !parts.isEmpty,
                  case .symbol(let k) = parts[0] else { continue }
            switch k.name {
            case "DOCUMENTATION":
                if parts.count == 2 { doc = parts[1] }
            case "METHOD":
                methodForms.append(
                    try expandDefmethod([forms[0]] + Array(parts.dropFirst())))
            default:
                break   // other options ignored
            }
        }
        let ensure = lst(sym("%ENSURE-GF"), quoted(forms[0]),
                         .int(nRequired), doc)
        if methodForms.isEmpty {
            return ensure
        }
        return LispValue.list([sym("PROGN"), ensure] + methodForms
                              + [quoted(forms[0])])
    }
}
