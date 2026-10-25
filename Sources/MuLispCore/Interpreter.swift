// Interpreter.swift
// The public face of muCommonLISP: bootstrap, evaluation, error handling.

import Foundation

public final class Interpreter {

    // MARK: - State

    public let registry = PackageRegistry()
    public var classRegistry: [Symbol: LispClass] = [:]
    public let classes = SystemClasses()

    public private(set) var vm: VM!
    public private(set) var compiler: Compiler!

    /// Shallow-binding stack of (symbol, saved value) pairs.
    public var dynamicStack: [(Symbol, LispValue?)] = []
    /// CALL-NEXT-METHOD contexts.
    public var nextMethodStack: [NextMethodContext] = []
    /// Builtin SETF handlers (CAR, GETHASH, ...).
    var setfHandlers: [Symbol: LispFunction] = [:]

    var initializeInstanceGF: GenericFunction!
    var printObjectGF: GenericFunction!

    /// User reader macros installed with SET-MACRO-CHARACTER.
    var readtableMacros: [Character: LispFunction] = [:]

    public var gensymCounter = 0
    public let graphics = GraphicsContext2D()

    /// Receives all textual output (PRINT, FORMAT T, ...). Defaults to stdout.
    public var outputHandler: ((String) -> Void)?

    public private(set) var tValue: LispValue = .null
    private var packageSymbol: Symbol!

    /// Non-nil when the bootstrap (prelude) failed; the interpreter still
    /// works for debugging purposes.
    public private(set) var bootError: String?

    private let interruptLock = NSLock()
    private var interruptFlag = false

    /// Guard against exhausting the Swift call stack (builtins and generic
    /// dispatch re-enter the VM through Swift frames).
    public var applyDepth = 0
    public var maxApplyDepth = 10_000

    var printDepth = 0

    // MARK: - Init

    /// Names the compiler recognizes as special forms. They must live in the
    /// COMMON-LISP package, so they are interned up front — user code must
    /// not be the first to intern them (that would put them in CL-USER and
    /// the compiler would no longer recognize them).
    private static let specialFormNames = [
        "QUOTE", "QUASIQUOTE", "UNQUOTE", "UNQUOTE-SPLICING",
        "IF", "PROGN", "LOCALLY", "EVAL-WHEN",
        "LET", "LET*", "LAMBDA", "FUNCTION", "SETQ", "SETF",
        "DEFUN", "DEFMACRO", "DEFVAR", "DEFPARAMETER", "DEFCONSTANT",
        "AND", "OR", "%WHILE",
        "BLOCK", "RETURN-FROM", "CATCH", "THROW", "UNWIND-PROTECT",
        "MULTIPLE-VALUE-BIND", "FLET", "LABELS", "SYMBOL-MACROLET",
        "THE", "DECLARE", "TAGBODY", "GO", "MACROLET", "PROGV",
        "NIL", "T", "OTHERWISE",
    ]

    static let specialFormNameSet: Set<String> = Set(specialFormNames)

    public init() {
        for name in Interpreter.specialFormNames {
            _ = registry.lisp.intern(name)
        }
        let tSym = registry.lisp.intern("T")
        tSym.value = .symbol(tSym)
        tSym.isConstant = true
        tValue = .symbol(tSym)

        let pkgSym = registry.lisp.intern("*PACKAGE*")
        pkgSym.isSpecial = true
        pkgSym.value = .package(registry.lisp)
        packageSymbol = pkgSym

        vm = VM(interp: self)
        compiler = Compiler(interp: self)

        do {
            try bootstrapClasses()
        } catch {
            bootError = "class bootstrap failed: \(error)"
        }

        registerCoreBuiltins()
        registerListBuiltins()
        registerNumericBuiltins()
        registerStringBuiltins()
        registerMiscBuiltins()
        registerFormat()
        registerCLOS()
        registerStructs()
        registerGraphicsBuiltins()

        // Standard output stream object (for explicit stream arguments).
        let stdout = LispStream(kind: .standardOutput) { [weak self] s in
            self?.write(s)
        }
        let stdoutSym = registry.lisp.intern("*STANDARD-OUTPUT*")
        stdoutSym.isSpecial = true
        stdoutSym.value = .stream(stdout)

        // Load the Lisp-level prelude (macros, LOOP, ...).
        do {
            try evalAll(Prelude.source)
        } catch let e as LispError {
            bootError = "prelude failed: \(e.message)"
        } catch {
            bootError = "prelude failed: \(error)"
        }

        // User code starts in COMMON-LISP-USER.
        setCurrentPackage(registry.user)
    }

    // MARK: - Packages

    public var currentPackage: LispPackage {
        if case .package(let p)? = packageSymbol.value {
            return p
        }
        return registry.user
    }

    public func setCurrentPackage(_ p: LispPackage) {
        packageSymbol.value = .package(p)
    }

    // MARK: - Output

    public func write(_ s: String) {
        if let handler = outputHandler {
            handler(s)
        } else {
            FileHandle.standardOutput.write(s.data(using: .utf8) ?? Data())
        }
    }

    // MARK: - Interrupts

    public var interruptRequested: Bool {
        interruptLock.lock()
        defer { interruptLock.unlock() }
        return interruptFlag
    }

    public func requestInterrupt() {
        interruptLock.lock()
        interruptFlag = true
        interruptLock.unlock()
    }

    public func clearInterrupt() {
        interruptLock.lock()
        interruptFlag = false
        interruptLock.unlock()
    }

    // MARK: - Dynamic bindings

    public func unwindDynamicStack(to depth: Int) {
        while dynamicStack.count > depth {
            let (sym, old) = dynamicStack.removeLast()
            sym.value = old
        }
    }

    // MARK: - Application

    public func apply(_ fnValue: LispValue, _ args: [LispValue]) throws -> LispValue {
        switch fnValue.firstValue {
        case .function(let f):
            return try applyFunction(f, args)
        case .symbol(let s):
            guard let f = s.function else {
                throw lispError("UNDEFINED-FUNCTION",
                                "undefined function: \(s.name)",
                                slots: [("NAME", .symbol(s))])
            }
            return try applyFunction(f, args)
        default:
            throw lispError("UNDEFINED-FUNCTION",
                "not a function: \(Printer.toString(fnValue, escape: true, interp: self))")
        }
    }

    public func applyFunction(_ f: LispFunction,
                              _ args: [LispValue]) throws -> LispValue {
        applyDepth += 1
        defer { applyDepth -= 1 }
        if applyDepth > maxApplyDepth {
            throw lispError("STORAGE-CONDITION",
                            "call stack exhausted (too deep nesting)")
        }
        let plainArgs = args.map { $0.firstValue }
        if let b = f as? Builtin {
            if plainArgs.count < b.minArgs {
                throw lispError("PROGRAM-ERROR",
                    "too few arguments to \(b.name): got \(plainArgs.count)")
            }
            if let maxA = b.maxArgs, plainArgs.count > maxA {
                throw lispError("PROGRAM-ERROR",
                    "too many arguments to \(b.name): got \(plainArgs.count)")
            }
            return try b.fn(plainArgs)
        }
        if let c = f as? Closure {
            let frame = try vm.bindParameters(c, plainArgs)
            return try vm.execute(c.code, frame: frame)
        }
        if let g = f as? GenericFunction {
            return try dispatchGeneric(g, plainArgs)
        }
        throw lispError("ERROR", "cannot apply \(f.name)")
    }

    // MARK: - Evaluation

    @discardableResult
    public func eval(_ form: LispValue) throws -> LispValue {
        // Top-level PROGN (and EVAL-WHEN) forms are processed one subform at
        // a time, so that macro definitions take effect for later subforms.
        if let c = form.asCons, case .symbol(let s) = c.car,
           s.package === registry.lisp,
           s.name == "PROGN" || s.name == "EVAL-WHEN" {
            var subforms = c.cdr.asArray() ?? []
            if s.name == "EVAL-WHEN" && !subforms.isEmpty {
                subforms.removeFirst()   // drop the situation list
            }
            var result = LispValue.null
            for sub in subforms {
                result = try eval(sub)
            }
            return result
        }
        do {
            let code = try compiler.compileTopLevel(form)
            let frame = Frame(size: code.frameSize, parent: nil)
            return try vm.execute(code, frame: frame)
        } catch let e as CompileError {
            throw lispError("PROGRAM-ERROR", e.message)
        }
    }

    /// Build a reader wired to this interpreter (current package, #. and
    /// user reader macros).
    public func makeReader(source: String) -> Reader {
        let reader = Reader(source: source, registry: registry) {
            [unowned self] in self.currentPackage
        }
        reader.evaluator = { [unowned self] form in
            try self.eval(form)
        }
        reader.macroCharacterHandler = { [unowned self] ch in
            self.readtableMacroHandler(ch)
        }
        return reader
    }

    func readtableMacroHandler(_ ch: Character)
        -> ((Reader, Character) throws -> LispValue?)? {
        guard let fn = readtableMacros[ch] else { return nil }
        return { [unowned self] reader, c in
            let proxy = LispStream(kind: .stringInput)
            proxy.backingReader = reader
            let result = try self.applyFunction(fn, [.stream(proxy),
                                                     .character(c)])
            if case .values(let vs) = result, vs.isEmpty {
                return nil   // the macro produced no object
            }
            return result.firstValue
        }
    }

    /// Read and evaluate every form in `source`; returns the last value.
    @discardableResult
    public func evalAll(_ source: String) throws -> LispValue {
        let reader = makeReader(source: source)
        var result = LispValue.null
        while true {
            let form: LispValue?
            do {
                form = try reader.read()
            } catch let e as ReaderError {
                throw lispError("READER-ERROR", e.message)
            }
            guard let f = form else { break }
            result = try eval(f)
        }
        return result
    }

    /// Format a value the way the REPL shows results.
    public func printString(_ v: LispValue) -> String {
        if case .values(let vs) = v {
            if vs.isEmpty { return "; No values" }
            return vs.map { Printer.toString($0, escape: true, interp: self) }
                     .joined(separator: "\n")
        }
        return Printer.toString(v, escape: true, interp: self)
    }

    // MARK: - Builtin / macro registration helpers

    func defBuiltin(_ name: String, _ minArgs: Int, _ maxArgs: Int?,
                    _ fn: @escaping ([LispValue]) throws -> LispValue) {
        let s = registry.lisp.intern(name)
        s.function = Builtin(name: name, minArgs: minArgs, maxArgs: maxArgs,
                             fn: fn)
    }

    func defMacro(_ name: String,
                  _ expander: @escaping ([LispValue]) throws -> LispValue) {
        let s = registry.lisp.intern(name)
        s.macroFunction = Builtin(name: name, minArgs: 0, maxArgs: nil,
                                  fn: expander)
    }

    func defSetfHandler(_ name: String,
                        _ fn: @escaping ([LispValue]) throws -> LispValue) {
        let s = registry.lisp.intern(name)
        setfHandlers[s] = Builtin(name: "(SETF \(name))", minArgs: 1,
                                  maxArgs: nil, fn: fn)
    }

    /// Look up a core function registered during bootstrap. Returns a stub
    /// that signals an error if the function is missing (compiler bug guard).
    public func coreFunction(_ name: String) -> LispFunction {
        if let f = registry.lisp.intern(name).function {
            return f
        }
        return Builtin(name: name, minArgs: 0, maxArgs: nil) { _ in
            throw LispError(condition: .str("missing core function \(name)"),
                            message: "missing core function \(name)")
        }
    }

    // MARK: - Form building helpers (used by Swift-implemented macros)

    func sym(_ name: String) -> LispValue {
        return .symbol(registry.lisp.intern(name))
    }

    func lst(_ parts: LispValue...) -> LispValue {
        return LispValue.list(parts)
    }

    func quoted(_ v: LispValue) -> LispValue {
        return LispValue.list([sym("QUOTE"), v])
    }

    // MARK: - Conditions

    public func makeConditionInstance(_ className: String, message: String,
                                      slots: [(String, LispValue)] = []) -> LispValue {
        guard let cls = findClassByName(className)
                ?? findClassByName("CONDITION") else {
            return .str(message)
        }
        let inst = StandardInstance(clazz: cls)
        try? setSlotValue(inst, registry.lisp.intern("%MESSAGE"),
                          .str(message))
        for (name, value) in slots {
            try? setSlotValue(inst, registry.lisp.intern(name), value)
        }
        return .instance(inst)
    }

    public func lispError(_ className: String, _ message: String,
                          slots: [(String, LispValue)] = []) -> LispError {
        return LispError(condition: makeConditionInstance(className,
                                                          message: message,
                                                          slots: slots),
                         message: message)
    }

    public func typeError(_ v: LispValue, expected: String) -> LispError {
        let printed = Printer.toString(v.firstValue, escape: true, interp: self)
        return lispError("TYPE-ERROR",
                         "\(printed) is not of type \(expected)",
                         slots: [("DATUM", v.firstValue),
                                 ("EXPECTED-TYPE",
                                  .symbol(registry.lisp.intern(expected)))])
    }

    /// Human-readable message for a signalled condition.
    public func conditionMessage(_ condition: LispValue) -> String {
        switch condition.firstValue {
        case .string(let s):
            return s.string
        case .instance(let inst):
            let msgSym = registry.lisp.intern("%MESSAGE")
            if let v = try? slotValue(inst, msgSym), case .string(let m) = v {
                return m.string
            }
            let fcSym = registry.lisp.intern("FORMAT-CONTROL")
            if let fc = try? slotValue(inst, fcSym), case .string(let ctrl) = fc {
                let faSym = registry.lisp.intern("FORMAT-ARGUMENTS")
                let fargs = (try? slotValue(inst, faSym))?.asArray() ?? []
                if let text = try? formatToString(control: ctrl.string, args: fargs) {
                    return text
                }
                return ctrl.string
            }
            return "condition of type \(inst.clazz.name.name)"
        default:
            return Printer.toString(condition, escape: false, interp: self)
        }
    }

    /// Render an instance for the printer, honoring user PRINT-OBJECT methods.
    public func printInstance(_ inst: StandardInstance, escape: Bool) -> String {
        ensureCurrentVersion(inst)

        if inst.clazz.kind == .structure {
            var out = "#S(\(inst.clazz.name.name)"
            for slot in inst.clazz.effectiveSlots
            where slot.allocation == .instance {
                let v = inst.slots[slot.location]
                out += " :\(slot.name.name) "
                out += v.map { Printer.toString($0, escape: true, interp: self) }
                     ?? "#<unbound>"
            }
            return out + ")"
        }

        if let gf = printObjectGF, !gf.methods.isEmpty, printDepth < 8 {
            let probe: [LispValue] = [.instance(inst), .null]
            if !applicableMethods(gf, probe).isEmpty {
                printDepth += 1
                defer { printDepth -= 1 }
                let stream = LispStream(kind: .stringOutput)
                if (try? dispatchGeneric(gf, [.instance(inst),
                                              .stream(stream)])) != nil {
                    return stream.buffer
                }
            }
        }

        if let condClass = classes.condition,
           inst.clazz.isSubclass(of: condClass) {
            let msgSym = registry.lisp.intern("%MESSAGE")
            if let v = try? slotValue(inst, msgSym), case .string(let m) = v {
                return "#<\(inst.clazz.name.name): \(m.string)>"
            }
            return "#<\(inst.clazz.name.name): \(conditionMessage(.instance(inst)))>"
        }

        return "#<\(inst.clazz.name.name)>"
    }
}
