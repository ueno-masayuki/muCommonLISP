// Compiler.swift
// Compiles Lisp forms into bytecode.

import Foundation

/// One lexical binding level inside a function.
private final class Level {
    var vars: [Symbol: Int] = [:]
    var symbolMacros: [Symbol: LispValue] = [:]
    var funcs: [Symbol: Int] = [:]
    var blocks: [Symbol: Int] = [:]
}

/// Compile-time model of one function (one runtime Frame).
private final class FunctionScope {
    let parent: FunctionScope?
    var levels: [Level] = [Level()]
    var nSlots: Int = 0

    init(parent: FunctionScope?) {
        self.parent = parent
    }

    func allocSlot() -> Int {
        let s = nSlots
        nSlots += 1
        return s
    }

    func pushLevel() { levels.append(Level()) }
    func popLevel() { levels.removeLast() }
    var top: Level { return levels[levels.count - 1] }
}

private enum VarResolution {
    case lexical(depth: Int, slot: Int)
    case symbolMacro(LispValue)
    case none
}

private struct Ctx {
    let code: CodeObject
    let scope: FunctionScope
}

public final class Compiler {
    private unowned let interp: Interpreter
    private var lisp: LispPackage { return interp.registry.lisp }
    private var gensymCounter = 0

    public init(interp: Interpreter) {
        self.interp = interp
    }

    // MARK: - Entry point

    /// Compile one top-level form into a zero-argument code object.
    public func compileTopLevel(_ form: LispValue) throws -> CodeObject {
        let code = CodeObject(name: "TOP-LEVEL")
        let scope = FunctionScope(parent: nil)
        let ctx = Ctx(code: code, scope: scope)
        try compile(form, ctx, tail: false)
        code.emit(.ret)
        code.frameSize = scope.nSlots
        return code
    }

    /// Compile a standalone lambda expression (used by COMPILE and EVAL of
    /// #'(lambda ...) values).
    public func compileLambdaExpression(_ form: LispValue) throws -> CodeObject {
        guard let items = form.asArray(), items.count >= 2,
              case .symbol(let head) = items[0], head.name == "LAMBDA" else {
            throw CompileError("not a lambda expression")
        }
        let scope = FunctionScope(parent: nil)
        let dummy = Ctx(code: CodeObject(name: "dummy"), scope: scope)
        return try buildLambdaCode(name: "ANONYMOUS-LAMBDA",
                                   lambdaList: items[1],
                                   body: Array(items[2...]),
                                   blockName: nil,
                                   outer: dummy)
    }

    // MARK: - Variable resolution

    private func resolveVar(_ s: Symbol, _ scope: FunctionScope) -> VarResolution {
        var depth = 0
        var sc: FunctionScope? = scope
        while let cur = sc {
            for level in cur.levels.reversed() {
                if let slot = level.vars[s] {
                    return .lexical(depth: depth, slot: slot)
                }
                if let expansion = level.symbolMacros[s] {
                    return .symbolMacro(expansion)
                }
            }
            depth += 1
            sc = cur.parent
        }
        return .none
    }

    private func resolveLocalFunction(_ s: Symbol, _ scope: FunctionScope)
        -> (depth: Int, slot: Int)? {
        var depth = 0
        var sc: FunctionScope? = scope
        while let cur = sc {
            for level in cur.levels.reversed() {
                if let slot = level.funcs[s] {
                    return (depth, slot)
                }
            }
            depth += 1
            sc = cur.parent
        }
        return nil
    }

    private func resolveBlock(_ s: Symbol, _ scope: FunctionScope)
        -> (depth: Int, slot: Int)? {
        var depth = 0
        var sc: FunctionScope? = scope
        while let cur = sc {
            for level in cur.levels.reversed() {
                if let slot = level.blocks[s] {
                    return (depth, slot)
                }
            }
            depth += 1
            sc = cur.parent
        }
        return nil
    }

    // MARK: - Helpers

    private func emitConstant(_ ctx: Ctx, _ v: LispValue) {
        if v.isNil {
            ctx.code.emit(.pushNil)
        } else {
            ctx.code.emit(.pushConst(ctx.code.addConstant(v)))
        }
    }

    private func emitCoreCall(_ ctx: Ctx, _ builtinName: String,
                              pushArgs: (() throws -> Int)) rethrows {
        let fn = interp.coreFunction(builtinName)
        ctx.code.emit(.pushConst(ctx.code.addConstant(.function(fn))))
        let n = try pushArgs()
        ctx.code.emit(.call(n))
    }

    private func isCLSymbol(_ s: Symbol) -> Bool {
        return s.package === lisp
    }

    /// Strip a leading docstring and (DECLARE ...) forms from a body.
    private func stripDeclarations(_ body: [LispValue]) -> [LispValue] {
        var rest = body
        while !rest.isEmpty {
            let first = rest[0]
            if case .string = first, rest.count > 1 {
                rest.removeFirst()
                continue
            }
            if let c = first.asCons, case .symbol(let s) = c.car,
               s.name == "DECLARE", isCLSymbol(s) {
                rest.removeFirst()
                continue
            }
            break
        }
        return rest
    }

    /// Conservative scan: does this body possibly perform RETURN / RETURN-FROM?
    private func mentionsReturn(_ forms: [LispValue]) -> Bool {
        var stack = forms
        var steps = 0
        while let f = stack.popLast() {
            steps += 1
            if steps > 200_000 { return true }
            switch f {
            case .symbol(let s):
                if s.name == "RETURN" || s.name == "RETURN-FROM" {
                    return true
                }
            case .cons(let c):
                stack.append(c.car)
                stack.append(c.cdr)
            default:
                break
            }
        }
        return false
    }

    private func makeGensym(_ prefix: String) -> Symbol {
        gensymCounter += 1
        return Symbol(name: "\(prefix)-\(gensymCounter)", package: nil)
    }

    /// Block names are symbols, but the reader turns the token NIL into the
    /// empty list — accept it and use the NIL symbol (for BLOCK NIL loops).
    private func blockNameSymbol(_ v: LispValue) -> Symbol? {
        switch v {
        case .symbol(let s): return s
        case .null: return lisp.intern("NIL")
        default: return nil
        }
    }

    // MARK: - Main compile dispatch

    private func compile(_ form: LispValue, _ ctx: Ctx, tail: Bool) throws {
        switch form {
        case .null:
            ctx.code.emit(.pushNil)
        case .symbol(let s):
            try compileVariable(s, ctx)
        case .cons(let c):
            try compileCons(c, ctx, tail: tail)
        default:
            // Self-evaluating: numbers, strings, characters, vectors, ...
            emitConstant(ctx, form)
        }
    }

    private func compileVariable(_ s: Symbol, _ ctx: Ctx) throws {
        if s.isKeyword {
            emitConstant(ctx, .symbol(s))
            return
        }
        switch resolveVar(s, ctx.scope) {
        case .lexical(let depth, let slot):
            ctx.code.emit(.localGet(depth, slot))
        case .symbolMacro(let expansion):
            try compile(expansion, ctx, tail: false)
        case .none:
            if s.isConstant, let v = s.value {
                emitConstant(ctx, v)
            } else {
                ctx.code.emit(.globalGet(s))
            }
        }
    }

    private func compileCons(_ c: Cons, _ ctx: Ctx, tail: Bool) throws {
        // ((lambda ...) args...) form
        if let headCons = c.car.asCons, case .symbol(let hs) = headCons.car,
           hs.name == "LAMBDA", isCLSymbol(hs) {
            try compile(c.car, ctx, tail: false)   // compiles via FUNCTION path below? no: plain cons
            // c.car is (LAMBDA ...): compile as closure
            // NOTE: handled by compile -> compileCons -> special form LAMBDA
            let args = c.cdr.asArray() ?? []
            for a in args {
                try compile(a, ctx, tail: false)
            }
            ctx.code.emit(tail ? .tailCall(args.count) : .call(args.count))
            return
        }

        guard case .symbol(let head) = c.car else {
            throw CompileError("invalid function call head: \(Printer.toString(c.car, escape: true))")
        }

        let argForms = c.cdr.asArray()

        // Special forms (all live in the COMMON-LISP package).
        if isCLSymbol(head) || head.package == nil {
            if let handled = try compileSpecialForm(head.name, c, ctx, tail: tail),
               handled {
                return
            }
        }

        // Local functions from FLET / LABELS.
        if let (depth, slot) = resolveLocalFunction(head, ctx.scope) {
            guard let args = argForms else {
                throw CompileError("malformed call to \(head.name)")
            }
            ctx.code.emit(.localGet(depth, slot))
            for a in args { try compile(a, ctx, tail: false) }
            ctx.code.emit(tail ? .tailCall(args.count) : .call(args.count))
            return
        }

        // Macros.
        if let macro = head.macroFunction {
            guard let args = argForms else {
                throw CompileError("malformed macro call to \(head.name)")
            }
            let expansion = try interp.applyFunction(macro, args)
            try compile(expansion, ctx, tail: tail)
            return
        }

        guard let args = argForms else {
            throw CompileError("malformed function call to \(head.name)")
        }

        // Fast inlined operators.
        if isCLSymbol(head), try compileFastOp(head.name, args, ctx, tail: tail) {
            return
        }

        // Ordinary call.
        ctx.code.emit(.funcGet(head))
        for a in args { try compile(a, ctx, tail: false) }
        ctx.code.emit(tail ? .tailCall(args.count) : .call(args.count))
    }

    // MARK: - Fast operators

    private func compileFastOp(_ name: String, _ args: [LispValue],
                               _ ctx: Ctx, tail: Bool) throws -> Bool {
        func compileArgs() throws {
            for a in args { try compile(a, ctx, tail: false) }
        }
        func chain(_ op: Instruction, identity: LispValue?) throws -> Bool {
            if args.isEmpty {
                if let id = identity { emitConstant(ctx, id); return true }
                return false
            }
            if args.count == 1 {
                return false   // let the builtin handle checking / unary cases
            }
            try compile(args[0], ctx, tail: false)
            for a in args.dropFirst() {
                try compile(a, ctx, tail: false)
                ctx.code.emit(op)
            }
            return true
        }

        switch name {
        case "CAR", "FIRST":
            guard args.count == 1 else { return false }
            try compileArgs(); ctx.code.emit(.opCar); return true
        case "CDR", "REST":
            guard args.count == 1 else { return false }
            try compileArgs(); ctx.code.emit(.opCdr); return true
        case "CONS":
            guard args.count == 2 else { return false }
            try compileArgs(); ctx.code.emit(.opCons); return true
        case "LIST":
            try compileArgs(); ctx.code.emit(.makeList(args.count)); return true
        case "+":
            return try chain(.opAdd, identity: .int(0))
        case "-":
            if args.count == 1 {
                emitConstant(ctx, .int(0))
                try compile(args[0], ctx, tail: false)
                ctx.code.emit(.opSub)
                return true
            }
            return try chain(.opSub, identity: nil)
        case "*":
            return try chain(.opMul, identity: .int(1))
        case "/":
            if args.count == 1 {
                emitConstant(ctx, .int(1))
                try compile(args[0], ctx, tail: false)
                ctx.code.emit(.opDiv)
                return true
            }
            return try chain(.opDiv, identity: nil)
        case "1+":
            guard args.count == 1 else { return false }
            try compileArgs(); ctx.code.emit(.opAdd1); return true
        case "1-":
            guard args.count == 1 else { return false }
            try compileArgs(); ctx.code.emit(.opSub1); return true
        case "=":
            guard args.count == 2 else { return false }
            try compileArgs(); ctx.code.emit(.opNumEq); return true
        case "<":
            guard args.count == 2 else { return false }
            try compileArgs(); ctx.code.emit(.opNumLt); return true
        case ">":
            guard args.count == 2 else { return false }
            try compileArgs(); ctx.code.emit(.opNumGt); return true
        case "<=":
            guard args.count == 2 else { return false }
            try compileArgs(); ctx.code.emit(.opNumLe); return true
        case ">=":
            guard args.count == 2 else { return false }
            try compileArgs(); ctx.code.emit(.opNumGe); return true
        case "EQ":
            guard args.count == 2 else { return false }
            try compileArgs(); ctx.code.emit(.opEq); return true
        case "NOT":
            guard args.count == 1 else { return false }
            try compileArgs(); ctx.code.emit(.opNot); return true
        case "NULL":
            guard args.count == 1 else { return false }
            try compileArgs(); ctx.code.emit(.opNull); return true
        case "CONSP":
            guard args.count == 1 else { return false }
            try compileArgs(); ctx.code.emit(.opConsp); return true
        case "ATOM":
            guard args.count == 1 else { return false }
            try compileArgs(); ctx.code.emit(.opConsp); ctx.code.emit(.opNot)
            return true
        case "FUNCALL":
            guard args.count >= 1 else { return false }
            try compile(args[0], ctx, tail: false)
            for a in args.dropFirst() { try compile(a, ctx, tail: false) }
            ctx.code.emit(tail ? .tailCall(args.count - 1) : .call(args.count - 1))
            return true
        default:
            return false
        }
    }

    // MARK: - Special forms

    /// Returns true when the name was handled as a special form.
    private func compileSpecialForm(_ name: String, _ c: Cons,
                                    _ ctx: Ctx, tail: Bool) throws -> Bool? {
        let rest = c.cdr
        func args(_ min: Int, _ max: Int? = nil) throws -> [LispValue] {
            guard let a = rest.asArray() else {
                throw CompileError("malformed \(name) form")
            }
            if a.count < min || (max != nil && a.count > max!) {
                throw CompileError("wrong number of subforms in \(name)")
            }
            return a
        }

        switch name {
        case "QUOTE":
            let a = try args(1, 1)
            emitConstant(ctx, a[0])
            return true

        case "QUASIQUOTE":
            let a = try args(1, 1)
            let expanded = try QuasiQuote.expand(a[0], lisp: lisp)
            try compile(expanded, ctx, tail: tail)
            return true

        case "UNQUOTE", "UNQUOTE-SPLICING":
            throw CompileError("comma not inside backquote")

        case "IF":
            let a = try args(2, 3)
            try compile(a[0], ctx, tail: false)
            let elseJump = ctx.code.emitPlaceholderJump { .jumpIfNil($0) }
            try compile(a[1], ctx, tail: tail)
            let endJump = ctx.code.emitPlaceholderJump { .jump($0) }
            ctx.code.patchJump(at: elseJump, to: ctx.code.currentAddress)
            if a.count == 3 {
                try compile(a[2], ctx, tail: tail)
            } else {
                ctx.code.emit(.pushNil)
            }
            ctx.code.patchJump(at: endJump, to: ctx.code.currentAddress)
            return true

        case "PROGN", "LOCALLY":
            let a = (try? args(0)) ?? []
            try compileBody(stripDeclarations(a), ctx, tail: tail)
            return true

        case "EVAL-WHEN":
            let a = try args(1)
            try compileBody(Array(a.dropFirst()), ctx, tail: tail)
            return true

        case "LET":
            try compileLet(try args(1), ctx, tail: tail, sequential: false)
            return true

        case "LET*":
            try compileLet(try args(1), ctx, tail: tail, sequential: true)
            return true

        case "LAMBDA":
            let a = try args(1)
            let code = try buildLambdaCode(name: "LAMBDA",
                                           lambdaList: a[0],
                                           body: Array(a.dropFirst()),
                                           blockName: nil,
                                           outer: ctx)
            ctx.code.children.append(code)
            ctx.code.emit(.makeClosure(ctx.code.children.count - 1))
            return true

        case "FUNCTION":
            let a = try args(1, 1)
            try compileFunctionRef(a[0], ctx)
            return true

        case "SETQ":
            try compileSetq(try args(0), ctx)
            return true

        case "SETF":
            try compileSetf(try args(0), ctx)
            return true

        case "DEFUN":
            let a = try args(2)
            try compileDefun(a, ctx, macro: false)
            return true

        case "DEFMACRO":
            let a = try args(2)
            try compileDefun(a, ctx, macro: true)
            return true

        case "DEFVAR", "DEFPARAMETER", "DEFCONSTANT":
            let a = try args(1, 3)
            try compileDefvar(name, a, ctx)
            return true

        case "AND":
            let a = try args(0)
            if a.isEmpty {
                emitConstant(ctx, .symbol(lisp.intern("T")))
                return true
            }
            var endJumps: [Int] = []
            for (i, f) in a.enumerated() {
                let isLast = (i == a.count - 1)
                try compile(f, ctx, tail: isLast && tail)
                if !isLast {
                    ctx.code.emit(.dup)
                    endJumps.append(ctx.code.emitPlaceholderJump { .jumpIfNil($0) })
                    ctx.code.emit(.pop)
                }
            }
            for j in endJumps {
                ctx.code.patchJump(at: j, to: ctx.code.currentAddress)
            }
            return true

        case "OR":
            let a = try args(0)
            if a.isEmpty {
                ctx.code.emit(.pushNil)
                return true
            }
            var endJumps: [Int] = []
            for (i, f) in a.enumerated() {
                let isLast = (i == a.count - 1)
                try compile(f, ctx, tail: isLast && tail)
                if !isLast {
                    ctx.code.emit(.dup)
                    let nextJump = ctx.code.emitPlaceholderJump { .jumpIfNil($0) }
                    endJumps.append(ctx.code.emitPlaceholderJump { .jump($0) })
                    ctx.code.patchJump(at: nextJump, to: ctx.code.currentAddress)
                    ctx.code.emit(.pop)
                }
            }
            for j in endJumps {
                ctx.code.patchJump(at: j, to: ctx.code.currentAddress)
            }
            return true

        case "%WHILE":
            let a = try args(1)
            let start = ctx.code.currentAddress
            try compile(a[0], ctx, tail: false)
            let exitJump = ctx.code.emitPlaceholderJump { .jumpIfNil($0) }
            for f in a.dropFirst() {
                try compile(f, ctx, tail: false)
                ctx.code.emit(.pop)
            }
            ctx.code.emit(.jump(start))
            ctx.code.patchJump(at: exitJump, to: ctx.code.currentAddress)
            ctx.code.emit(.pushNil)
            return true

        case "BLOCK":
            let a = try args(1)
            guard let blockName = blockNameSymbol(a[0]) else {
                throw CompileError("block name must be a symbol")
            }
            try compileBlock(blockName, Array(a.dropFirst()), ctx, tail: tail)
            return true

        case "RETURN-FROM":
            let a = try args(1, 2)
            guard let blockName = blockNameSymbol(a[0]) else {
                throw CompileError("block name must be a symbol")
            }
            guard let (depth, slot) = resolveBlock(blockName, ctx.scope) else {
                throw CompileError("no enclosing block named \(blockName.name)")
            }
            try emitCoreCall(ctx, "%RETURN-FROM") {
                ctx.code.emit(.localGet(depth, slot))
                if a.count == 2 {
                    try compile(a[1], ctx, tail: false)
                } else {
                    ctx.code.emit(.pushNil)
                }
                return 2
            }
            return true

        case "CATCH":
            let a = try args(1)
            try emitCoreCall(ctx, "%CATCH") {
                try compile(a[0], ctx, tail: false)
                try emitThunk(Array(a.dropFirst()), ctx, name: "CATCH-BODY")
                return 2
            }
            return true

        case "THROW":
            let a = try args(2, 2)
            try emitCoreCall(ctx, "%THROW") {
                try compile(a[0], ctx, tail: false)
                try compile(a[1], ctx, tail: false)
                return 2
            }
            return true

        case "UNWIND-PROTECT":
            let a = try args(1)
            try emitCoreCall(ctx, "%UNWIND-PROTECT") {
                try emitThunk([a[0]], ctx, name: "UP-BODY")
                try emitThunk(Array(a.dropFirst()), ctx, name: "UP-CLEANUP")
                return 2
            }
            return true

        case "MULTIPLE-VALUE-BIND":
            let a = try args(2)
            guard let varForms = a[0].asArray() else {
                throw CompileError("malformed multiple-value-bind variable list")
            }
            var vars: [Symbol] = []
            for v in varForms {
                guard case .symbol(let s) = v else {
                    throw CompileError("multiple-value-bind variables must be symbols")
                }
                vars.append(s)
            }
            try compile(a[1], ctx, tail: false)
            ctx.code.emit(.mvBind(vars.count))
            ctx.scope.pushLevel()
            var slots: [Int] = []
            var specials: [Symbol] = []
            for v in vars {
                if v.isSpecial {
                    slots.append(-1)
                } else {
                    let slot = ctx.scope.allocSlot()
                    ctx.scope.top.vars[v] = slot
                    slots.append(slot)
                }
            }
            // Values are on the stack first-pushed-first; bind in reverse.
            for (i, v) in vars.enumerated().reversed() {
                if v.isSpecial {
                    ctx.code.emit(.bindSpecial(v))
                    specials.append(v)
                } else {
                    ctx.code.emit(.localSet(0, slots[i]))
                }
            }
            try compileBody(stripDeclarations(Array(a.dropFirst(2))), ctx,
                            tail: tail && specials.isEmpty)
            if !specials.isEmpty {
                ctx.code.emit(.unbindSpecial(specials.count))
            }
            ctx.scope.popLevel()
            return true

        case "FLET", "LABELS":
            let a = try args(1)
            try compileFlet(name == "LABELS", a, ctx, tail: tail)
            return true

        case "SYMBOL-MACROLET":
            let a = try args(1)
            guard let bindings = a[0].asArray() else {
                throw CompileError("malformed symbol-macrolet")
            }
            ctx.scope.pushLevel()
            for b in bindings {
                guard let pair = b.asArray(), pair.count == 2,
                      case .symbol(let s) = pair[0] else {
                    throw CompileError("malformed symbol-macrolet binding")
                }
                ctx.scope.top.symbolMacros[s] = pair[1]
            }
            try compileBody(stripDeclarations(Array(a.dropFirst())), ctx, tail: tail)
            ctx.scope.popLevel()
            return true

        case "THE":
            let a = try args(2, 2)
            try compile(a[1], ctx, tail: tail)
            return true

        case "DECLARE":
            // A stray DECLARE evaluates to NIL (harmless).
            ctx.code.emit(.pushNil)
            return true

        case "TAGBODY", "GO", "MACROLET", "PROGV":
            throw CompileError("\(name) is not supported by muCommonLISP")

        default:
            return false
        }
    }

    // MARK: - Bodies and thunks

    private func compileBody(_ forms: [LispValue], _ ctx: Ctx, tail: Bool) throws {
        if forms.isEmpty {
            ctx.code.emit(.pushNil)
            return
        }
        for (i, f) in forms.enumerated() {
            let isLast = (i == forms.count - 1)
            try compile(f, ctx, tail: isLast && tail)
            if !isLast {
                ctx.code.emit(.pop)
            }
        }
    }

    /// Compile `forms` as a zero-argument closure over the current frame and
    /// emit code pushing that closure.
    private func emitThunk(_ forms: [LispValue], _ ctx: Ctx, name: String) throws {
        let child = CodeObject(name: name)
        let childScope = FunctionScope(parent: ctx.scope)
        let childCtx = Ctx(code: child, scope: childScope)
        try compileBody(forms, childCtx, tail: true)
        child.emit(.ret)
        child.frameSize = childScope.nSlots
        ctx.code.children.append(child)
        ctx.code.emit(.makeClosure(ctx.code.children.count - 1))
    }

    // MARK: - LET / LET*

    private func compileLet(_ a: [LispValue], _ ctx: Ctx, tail: Bool,
                            sequential: Bool) throws {
        guard let bindingForms = a[0].asArray() else {
            throw CompileError("malformed let bindings")
        }
        var names: [Symbol] = []
        var inits: [LispValue] = []
        for b in bindingForms {
            switch b {
            case .symbol(let s):
                names.append(s)
                inits.append(.null)
            case .cons:
                guard let pair = b.asArray(), pair.count >= 1, pair.count <= 2,
                      case .symbol(let s) = pair[0] else {
                    throw CompileError("malformed let binding")
                }
                names.append(s)
                inits.append(pair.count == 2 ? pair[1] : .null)
            default:
                throw CompileError("malformed let binding")
            }
        }

        var specialCount = 0
        ctx.scope.pushLevel()

        if sequential {
            for (i, name) in names.enumerated() {
                try compile(inits[i], ctx, tail: false)
                if name.isSpecial {
                    ctx.code.emit(.bindSpecial(name))
                    specialCount += 1
                } else {
                    let slot = ctx.scope.allocSlot()
                    ctx.code.emit(.localSet(0, slot))
                    ctx.scope.top.vars[name] = slot
                }
            }
        } else {
            // Parallel: evaluate all inits before binding any.
            for ini in inits {
                try compile(ini, ctx, tail: false)
            }
            var slots: [Int] = []
            for name in names {
                if name.isSpecial {
                    slots.append(-1)
                } else {
                    slots.append(ctx.scope.allocSlot())
                }
            }
            for (i, name) in names.enumerated().reversed() {
                if name.isSpecial {
                    ctx.code.emit(.bindSpecial(name))
                    specialCount += 1
                } else {
                    ctx.code.emit(.localSet(0, slots[i]))
                }
            }
            for (i, name) in names.enumerated() where !name.isSpecial {
                ctx.scope.top.vars[name] = slots[i]
            }
        }

        try compileBody(stripDeclarations(Array(a.dropFirst())), ctx,
                        tail: tail && specialCount == 0)
        if specialCount > 0 {
            ctx.code.emit(.unbindSpecial(specialCount))
        }
        ctx.scope.popLevel()
    }

    // MARK: - LAMBDA / DEFUN

    private func buildLambdaCode(name: String, lambdaList: LispValue,
                                 body: [LispValue], blockName: Symbol?,
                                 outer: Ctx) throws -> CodeObject {
        let parsed = try LambdaListParser.parse(lambdaList,
                                                keywordPackage: interp.registry.keyword)
        let code = CodeObject(name: name)
        let scope = FunctionScope(parent: outer.scope)
        let ctx = Ctx(code: code, scope: scope)

        var info = ParamInfo()
        // Required parameters occupy slots 0..<n in order.
        for r in parsed.required {
            let slot = scope.allocSlot()
            scope.top.vars[r] = slot
        }
        info.nRequired = parsed.required.count

        for o in parsed.optionals {
            let slot = scope.allocSlot()
            scope.top.vars[o.name] = slot
            var suppliedSlot: Int? = nil
            if let sp = o.suppliedName {
                let s = scope.allocSlot()
                scope.top.vars[sp] = s
                suppliedSlot = s
            }
            var defaultCode: CodeObject? = nil
            if !o.defaultForm.isNil {
                defaultCode = try buildInFrameThunk(o.defaultForm, ctx,
                                                    name: "\(name)-OPT-DEFAULT")
            }
            info.optionals.append(OptionalParam(slot: slot,
                                                defaultCode: defaultCode,
                                                suppliedSlot: suppliedSlot))
        }

        if let r = parsed.rest {
            let slot = scope.allocSlot()
            scope.top.vars[r] = slot
            info.restSlot = slot
        }

        for k in parsed.keys {
            let slot = scope.allocSlot()
            scope.top.vars[k.name] = slot
            var suppliedSlot: Int? = nil
            if let sp = k.suppliedName {
                let s = scope.allocSlot()
                scope.top.vars[sp] = s
                suppliedSlot = s
            }
            var defaultCode: CodeObject? = nil
            if !k.defaultForm.isNil {
                defaultCode = try buildInFrameThunk(k.defaultForm, ctx,
                                                    name: "\(name)-KEY-DEFAULT")
            }
            info.keys.append(KeyParam(keyword: k.keyword, slot: slot,
                                      defaultCode: defaultCode,
                                      suppliedSlot: suppliedSlot))
        }
        info.allowOtherKeys = parsed.allowOtherKeys
        code.params = info

        let realBody = stripDeclarations(body)
        if let blockName = blockName, mentionsReturn(realBody) {
            try compileBlock(blockName, realBody, ctx, tail: true)
        } else {
            try compileBody(realBody, ctx, tail: true)
        }
        code.emit(.ret)
        code.frameSize = scope.nSlots
        return code
    }

    /// Compile a default-value expression executed *in the function's own
    /// frame* (not a closure). The returned code object must be run with the
    /// frame of the function being entered.
    private func buildInFrameThunk(_ form: LispValue, _ ctx: Ctx,
                                   name: String) throws -> CodeObject {
        let code = CodeObject(name: name)
        // Note: shares the scope (and frame) of ctx.
        let thunkCtx = Ctx(code: code, scope: ctx.scope)
        try compile(form, thunkCtx, tail: false)
        code.emit(.ret)
        code.frameSize = 0
        return code
    }

    private func compileDefun(_ a: [LispValue], _ ctx: Ctx, macro: Bool) throws {
        let nameDesignator = a[0]
        var fname = "?"
        var blockName: Symbol? = nil
        if case .symbol(let s) = nameDesignator {
            fname = s.name
            blockName = s
        } else if let parts = nameDesignator.asArray(), parts.count == 2,
                  case .symbol(let setf) = parts[0], setf.name == "SETF",
                  case .symbol(let s) = parts[1] {
            fname = "(SETF \(s.name))"
            blockName = s
        } else {
            throw CompileError("invalid defun name")
        }

        let code = try buildLambdaCode(name: fname,
                                       lambdaList: a[1],
                                       body: Array(a.dropFirst(2)),
                                       blockName: macro ? nil : blockName,
                                       outer: ctx)
        emitCoreCall(ctx, macro ? "%SET-MACRO" : "%SET-FUNCTION") {
            emitConstant(ctx, nameDesignator)
            ctx.code.children.append(code)
            ctx.code.emit(.makeClosure(ctx.code.children.count - 1))
            return 2
        }
    }

    private func compileDefvar(_ kind: String, _ a: [LispValue], _ ctx: Ctx) throws {
        guard case .symbol(let s) = a[0] else {
            throw CompileError("\(kind) name must be a symbol")
        }
        switch kind {
        case "DEFVAR":
            if a.count >= 2 {
                try emitCoreCall(ctx, "%DEFVAR") {
                    emitConstant(ctx, .symbol(s))
                    try emitThunk([a[1]], ctx, name: "DEFVAR-INIT")
                    return 2
                }
            } else {
                emitCoreCall(ctx, "%DEFVAR") {
                    emitConstant(ctx, .symbol(s))
                    return 1
                }
            }
        case "DEFPARAMETER":
            guard a.count >= 2 else {
                throw CompileError("defparameter requires an initial value")
            }
            try emitCoreCall(ctx, "%DEFPARAMETER") {
                emitConstant(ctx, .symbol(s))
                try compile(a[1], ctx, tail: false)
                return 2
            }
        default: // DEFCONSTANT
            guard a.count >= 2 else {
                throw CompileError("defconstant requires a value")
            }
            try emitCoreCall(ctx, "%DEFCONSTANT") {
                emitConstant(ctx, .symbol(s))
                try compile(a[1], ctx, tail: false)
                return 2
            }
        }
    }

    // MARK: - FUNCTION

    private func compileFunctionRef(_ designator: LispValue, _ ctx: Ctx) throws {
        switch designator {
        case .symbol(let s):
            if let (depth, slot) = resolveLocalFunction(s, ctx.scope) {
                ctx.code.emit(.localGet(depth, slot))
            } else {
                ctx.code.emit(.funcGet(s))
            }
        case .cons(let c):
            if case .symbol(let head) = c.car, head.name == "LAMBDA" {
                guard let items = designator.asArray(), items.count >= 2 else {
                    throw CompileError("malformed lambda expression")
                }
                let code = try buildLambdaCode(name: "LAMBDA",
                                               lambdaList: items[1],
                                               body: Array(items[2...]),
                                               blockName: nil,
                                               outer: ctx)
                ctx.code.children.append(code)
                ctx.code.emit(.makeClosure(ctx.code.children.count - 1))
            } else if case .symbol(let head) = c.car, head.name == "SETF" {
                try emitCoreCall(ctx, "%SETF-FN") {
                    guard let parts = designator.asArray(), parts.count == 2 else {
                        throw CompileError("malformed (setf name)")
                    }
                    emitConstant(ctx, parts[1])
                    return 1
                }
            } else {
                throw CompileError("invalid function designator")
            }
        default:
            throw CompileError("invalid function designator")
        }
    }

    // MARK: - SETQ / SETF

    private func compileSetq(_ a: [LispValue], _ ctx: Ctx) throws {
        if a.isEmpty {
            ctx.code.emit(.pushNil)
            return
        }
        guard a.count % 2 == 0 else {
            throw CompileError("odd number of forms in setq")
        }
        var i = 0
        while i < a.count {
            guard case .symbol(let s) = a[i] else {
                throw CompileError("setq target must be a symbol")
            }
            let valueForm = a[i + 1]
            let isLast = (i + 2 >= a.count)
            switch resolveVar(s, ctx.scope) {
            case .lexical(let depth, let slot):
                try compile(valueForm, ctx, tail: false)
                ctx.code.emit(.dup)
                ctx.code.emit(.localSet(depth, slot))
            case .symbolMacro(let expansion):
                try compileSetfPair(place: expansion, valueForm: valueForm, ctx)
            case .none:
                if s.isConstant {
                    throw CompileError("cannot setq constant \(s.name)")
                }
                try compile(valueForm, ctx, tail: false)
                ctx.code.emit(.dup)
                ctx.code.emit(.globalSet(s))
            }
            if !isLast {
                ctx.code.emit(.pop)
            }
            i += 2
        }
    }

    private func compileSetf(_ a: [LispValue], _ ctx: Ctx) throws {
        if a.isEmpty {
            ctx.code.emit(.pushNil)
            return
        }
        guard a.count % 2 == 0 else {
            throw CompileError("odd number of forms in setf")
        }
        var i = 0
        while i < a.count {
            try compileSetfPair(place: a[i], valueForm: a[i + 1], ctx)
            if i + 2 < a.count {
                ctx.code.emit(.pop)
            }
            i += 2
        }
    }

    private func compileSetfPair(place: LispValue, valueForm: LispValue,
                                 _ ctx: Ctx) throws {
        switch place {
        case .symbol:
            try compileSetq([place, valueForm], ctx)
        case .cons(let c):
            guard case .symbol(let op) = c.car else {
                throw CompileError("invalid setf place")
            }
            let placeArgs = c.cdr.asArray() ?? []
            // Note: the new value is evaluated before the place subforms
            // (a documented deviation from strict left-to-right order).
            try emitCoreCall(ctx, "%SETF-CALL") {
                emitConstant(ctx, .symbol(op))
                try compile(valueForm, ctx, tail: false)
                for p in placeArgs {
                    try compile(p, ctx, tail: false)
                }
                return 2 + placeArgs.count
            }
        default:
            throw CompileError("invalid setf place")
        }
    }

    // MARK: - BLOCK

    private func compileBlock(_ name: Symbol, _ body: [LispValue],
                              _ ctx: Ctx, tail: Bool) throws {
        if !mentionsReturn(body) {
            try compileBody(body, ctx, tail: tail)
            return
        }
        let tokenSlot = ctx.scope.allocSlot()
        emitCoreCall(ctx, "%MAKE-BLOCK-TOKEN") {
            emitConstant(ctx, .string(name.name))
            return 1
        }
        ctx.code.emit(.localSet(0, tokenSlot))

        ctx.scope.pushLevel()
        ctx.scope.top.blocks[name] = tokenSlot
        try emitCoreCall(ctx, "%BLOCK") {
            ctx.code.emit(.localGet(0, tokenSlot))
            try emitThunk(body, ctx, name: "BLOCK-\(name.name)")
            return 2
        }
        ctx.scope.popLevel()
    }

    // MARK: - FLET / LABELS

    private func compileFlet(_ isLabels: Bool, _ a: [LispValue],
                             _ ctx: Ctx, tail: Bool) throws {
        guard let defs = a[0].asArray() else {
            throw CompileError("malformed flet/labels definitions")
        }
        var names: [Symbol] = []
        var lambdaLists: [LispValue] = []
        var bodies: [[LispValue]] = []
        for d in defs {
            guard let parts = d.asArray(), parts.count >= 2,
                  case .symbol(let fn) = parts[0] else {
                throw CompileError("malformed local function definition")
            }
            names.append(fn)
            lambdaLists.append(parts[1])
            bodies.append(Array(parts.dropFirst(2)))
        }

        var slots: [Int] = []
        if isLabels {
            ctx.scope.pushLevel()
            for n in names {
                let slot = ctx.scope.allocSlot()
                ctx.scope.top.funcs[n] = slot
                slots.append(slot)
            }
            for (i, n) in names.enumerated() {
                let code = try buildLambdaCode(name: n.name,
                                               lambdaList: lambdaLists[i],
                                               body: bodies[i],
                                               blockName: n,
                                               outer: ctx)
                ctx.code.children.append(code)
                ctx.code.emit(.makeClosure(ctx.code.children.count - 1))
                ctx.code.emit(.localSet(0, slots[i]))
            }
        } else {
            // FLET: compile bodies in the outer environment first.
            for (i, n) in names.enumerated() {
                let code = try buildLambdaCode(name: n.name,
                                               lambdaList: lambdaLists[i],
                                               body: bodies[i],
                                               blockName: n,
                                               outer: ctx)
                ctx.code.children.append(code)
                ctx.code.emit(.makeClosure(ctx.code.children.count - 1))
            }
            ctx.scope.pushLevel()
            for n in names {
                let slot = ctx.scope.allocSlot()
                ctx.scope.top.funcs[n] = slot
                slots.append(slot)
            }
            for slot in slots.reversed() {
                ctx.code.emit(.localSet(0, slot))
            }
        }

        try compileBody(stripDeclarations(Array(a.dropFirst())), ctx, tail: tail)
        ctx.scope.popLevel()
    }
}
