// VM.swift
// The stack-based bytecode virtual machine.

import Foundation

public final class VM {
    unowned let interp: Interpreter

    /// Maximum number of simultaneously live activation records (guards
    /// against runaway non-tail recursion).
    public var maxActivationDepth = 200_000

    public init(interp: Interpreter) {
        self.interp = interp
    }

    private struct Activation {
        var code: CodeObject
        var frame: Frame
        var ip: Int
        var stackBase: Int
    }

    /// Execute a code object with a given frame (the frame must already have
    /// its parameters bound). Returns the result, which may be a `.values`.
    public func execute(_ code: CodeObject, frame: Frame) throws -> LispValue {
        var stack: [LispValue] = []
        stack.reserveCapacity(32)
        var suspended: [Activation] = []

        var curCode = code
        var curFrame = frame
        var ip = 0
        var stackBase = 0
        var counter = 0

        let dynamicMark = interp.dynamicStack.count

        func frameAt(_ depth: Int) -> Frame {
            var f = curFrame
            var d = depth
            while d > 0 {
                guard let p = f.parent else {
                    // Compiler bug if this happens; fail loudly but safely.
                    return f
                }
                f = p
                d -= 1
            }
            return f
        }

        /// Push a call result, collapsing multiple values unless the next
        /// instruction consumes them (mvBind) or passes them through (ret).
        func pushResult(_ result: LispValue) {
            if case .values = result {
                if ip < curCode.instructions.count {
                    switch curCode.instructions[ip] {
                    case .mvBind, .ret:
                        stack.append(result)
                        return
                    default:
                        break
                    }
                }
                stack.append(result.firstValue)
            } else {
                stack.append(result)
            }
        }

        /// Return `result` from the current activation.
        /// Returns non-nil when the whole execute() is finished.
        func doReturn(_ result: LispValue) -> LispValue? {
            if suspended.isEmpty {
                return result
            }
            let act = suspended.removeLast()
            if stackBase < stack.count {
                stack.removeSubrange(stackBase..<stack.count)
            }
            curCode = act.code
            curFrame = act.frame
            ip = act.ip
            stackBase = act.stackBase
            pushResult(result)
            return nil
        }

        /// Invoke a callable with arguments.
        func invoke(_ fnValue: LispValue, _ args: [LispValue],
                    tail: Bool) throws -> LispValue? {
            guard case .function(let fn) = fnValue else {
                throw interp.lispError("UNDEFINED-FUNCTION",
                    "not a function: \(Printer.toString(fnValue, escape: true, interp: interp))")
            }
            if let closure = fn as? Closure {
                let newFrame = try bindParameters(closure, args)
                if tail {
                    // Reuse the current activation.
                    stack.removeSubrange(stackBase..<stack.count)
                    curCode = closure.code
                    curFrame = newFrame
                    ip = 0
                } else {
                    if suspended.count >= maxActivationDepth {
                        throw interp.lispError("STORAGE-CONDITION",
                                               "control stack exhausted (too deep recursion)")
                    }
                    suspended.append(Activation(code: curCode, frame: curFrame,
                                                ip: ip, stackBase: stackBase))
                    curCode = closure.code
                    curFrame = newFrame
                    ip = 0
                    stackBase = stack.count
                }
                return nil
            }
            // Builtins and generic functions go through the interpreter.
            let result = try interp.applyFunction(fn, args)
            if tail {
                return doReturn(result)
            }
            pushResult(result)
            return nil
        }

        do {
            while true {
                counter += 1
                if counter & 0x3FF == 0 {
                    if interp.interruptRequested {
                        interp.clearInterrupt()
                        throw InterruptSignal()
                    }
                }

                let inst = curCode.instructions[ip]
                ip += 1

                switch inst {
                case .pushConst(let i):
                    stack.append(curCode.constants[i])
                case .pushNil:
                    stack.append(.null)
                case .localGet(let depth, let slot):
                    stack.append(frameAt(depth).slots[slot])
                case .localSet(let depth, let slot):
                    frameAt(depth).slots[slot] = stack.removeLast().firstValue
                case .globalGet(let sym):
                    guard let v = sym.value else {
                        throw interp.lispError("UNBOUND-VARIABLE",
                                               "unbound variable: \(sym.name)",
                                               slots: [("NAME", .symbol(sym))])
                    }
                    stack.append(v)
                case .globalSet(let sym):
                    sym.value = stack.removeLast().firstValue
                case .funcGet(let sym):
                    guard let f = sym.function else {
                        throw interp.lispError("UNDEFINED-FUNCTION",
                                               "undefined function: \(sym.name)",
                                               slots: [("NAME", .symbol(sym))])
                    }
                    stack.append(.function(f))
                case .bindSpecial(let sym):
                    interp.dynamicStack.append((sym, sym.value))
                    sym.value = stack.removeLast().firstValue
                case .unbindSpecial(let n):
                    interp.unwindDynamicStack(to: interp.dynamicStack.count - n)
                case .jump(let target):
                    ip = target
                case .jumpIfNil(let target):
                    if stack.removeLast().firstValue.isNil {
                        ip = target
                    }
                case .call(let n):
                    let argStart = stack.count - n
                    let fnValue = stack[argStart - 1]
                    let callArgs = Array(stack[argStart...])
                    stack.removeSubrange((argStart - 1)...)
                    if let final = try invoke(fnValue, callArgs, tail: false) {
                        return final
                    }
                case .tailCall(let n):
                    let argStart = stack.count - n
                    let fnValue = stack[argStart - 1]
                    let callArgs = Array(stack[argStart...])
                    stack.removeSubrange((argStart - 1)...)
                    if let final = try invoke(fnValue, callArgs, tail: true) {
                        return final
                    }
                case .ret:
                    let result = stack.removeLast()
                    if let final = doReturn(result) {
                        return final
                    }
                case .makeClosure(let i):
                    stack.append(.function(Closure(code: curCode.children[i],
                                                   capturedFrame: curFrame)))
                case .pop:
                    _ = stack.removeLast()
                case .dup:
                    stack.append(stack[stack.count - 1])
                case .makeList(let n):
                    let start = stack.count - n
                    let items = Array(stack[start...]).map { $0.firstValue }
                    stack.removeSubrange(start...)
                    stack.append(LispValue.list(items))
                case .mvBind(let n):
                    let v = stack.removeLast()
                    var vs: [LispValue]
                    if case .values(let list) = v {
                        vs = list
                    } else {
                        vs = [v]
                    }
                    while vs.count < n { vs.append(.null) }
                    for i in 0..<n {
                        stack.append(vs[i])
                    }

                // Fast operations
                case .opCar:
                    let v = stack.removeLast().firstValue
                    switch v {
                    case .null: stack.append(.null)
                    case .cons(let c): stack.append(c.car)
                    default:
                        throw interp.typeError(v, expected: "LIST")
                    }
                case .opCdr:
                    let v = stack.removeLast().firstValue
                    switch v {
                    case .null: stack.append(.null)
                    case .cons(let c): stack.append(c.cdr)
                    default:
                        throw interp.typeError(v, expected: "LIST")
                    }
                case .opCons:
                    let b = stack.removeLast().firstValue
                    let a = stack.removeLast().firstValue
                    stack.append(.cons(Cons(car: a, cdr: b)))
                case .opAdd:
                    let b = stack.removeLast().firstValue
                    let a = stack.removeLast().firstValue
                    stack.append(try numeric { try NumericOps.add(a, b) })
                case .opSub:
                    let b = stack.removeLast().firstValue
                    let a = stack.removeLast().firstValue
                    stack.append(try numeric { try NumericOps.sub(a, b) })
                case .opMul:
                    let b = stack.removeLast().firstValue
                    let a = stack.removeLast().firstValue
                    stack.append(try numeric { try NumericOps.mul(a, b) })
                case .opDiv:
                    let b = stack.removeLast().firstValue
                    let a = stack.removeLast().firstValue
                    stack.append(try numeric { try NumericOps.div(a, b) })
                case .opNumEq:
                    let b = stack.removeLast().firstValue
                    let a = stack.removeLast().firstValue
                    // numericEqual (not compare) so complex numbers work.
                    stack.append(try numeric { try NumericOps.numericEqual(a, b) }
                                 ? interp.tValue : .null)
                case .opNumLt:
                    let b = stack.removeLast().firstValue
                    let a = stack.removeLast().firstValue
                    stack.append(try numeric { try NumericOps.compare(a, b) < 0 }
                                 ? interp.tValue : .null)
                case .opNumGt:
                    let b = stack.removeLast().firstValue
                    let a = stack.removeLast().firstValue
                    stack.append(try numeric { try NumericOps.compare(a, b) > 0 }
                                 ? interp.tValue : .null)
                case .opNumLe:
                    let b = stack.removeLast().firstValue
                    let a = stack.removeLast().firstValue
                    stack.append(try numeric { try NumericOps.compare(a, b) <= 0 }
                                 ? interp.tValue : .null)
                case .opNumGe:
                    let b = stack.removeLast().firstValue
                    let a = stack.removeLast().firstValue
                    stack.append(try numeric { try NumericOps.compare(a, b) >= 0 }
                                 ? interp.tValue : .null)
                case .opEq:
                    let b = stack.removeLast().firstValue
                    let a = stack.removeLast().firstValue
                    stack.append(LispEquality.eq(a, b) ? interp.tValue : .null)
                case .opNot, .opNull:
                    let v = stack.removeLast().firstValue
                    stack.append(v.isNil ? interp.tValue : .null)
                case .opConsp:
                    let v = stack.removeLast().firstValue
                    if case .cons = v {
                        stack.append(interp.tValue)
                    } else {
                        stack.append(.null)
                    }
                case .opAdd1:
                    let a = stack.removeLast().firstValue
                    stack.append(try numeric { try NumericOps.add(a, .int(1)) })
                case .opSub1:
                    let a = stack.removeLast().firstValue
                    stack.append(try numeric { try NumericOps.sub(a, .int(1)) })
                }
            }
        } catch {
            interp.unwindDynamicStack(to: dynamicMark)
            throw error
        }
    }

    /// Translate NumericError into a Lisp condition.
    private func numeric<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let e as NumericError {
            switch e.kind {
            case .notANumber(let v):
                throw interp.typeError(v, expected: "NUMBER")
            case .divisionByZero:
                throw interp.lispError("DIVISION-BY-ZERO", "division by zero")
            case .notAReal(let v):
                throw interp.typeError(v, expected: "REAL")
            }
        }
    }

    // MARK: - Parameter binding

    /// Create and populate the frame for calling a closure.
    public func bindParameters(_ closure: Closure,
                               _ args: [LispValue]) throws -> Frame {
        let code = closure.code
        let p = code.params
        let frame = Frame(size: code.frameSize, parent: closure.capturedFrame)

        if args.count < p.nRequired {
            throw interp.lispError("PROGRAM-ERROR",
                "too few arguments to \(code.name): got \(args.count), need \(p.nRequired)")
        }
        if let maxA = p.maxArgs, args.count > maxA {
            throw interp.lispError("PROGRAM-ERROR",
                "too many arguments to \(code.name): got \(args.count), max \(maxA)")
        }

        for i in 0..<p.nRequired {
            frame.slots[i] = args[i]
        }
        var idx = p.nRequired

        for opt in p.optionals {
            if idx < args.count {
                frame.slots[opt.slot] = args[idx]
                if let s = opt.suppliedSlot { frame.slots[s] = interp.tValue }
            } else {
                if let dc = opt.defaultCode {
                    frame.slots[opt.slot] = try execute(dc, frame: frame).firstValue
                } else {
                    frame.slots[opt.slot] = .null
                }
                if let s = opt.suppliedSlot { frame.slots[s] = .null }
            }
            idx += 1
        }

        let remaining = idx < args.count ? Array(args[idx...]) : []

        if let restSlot = p.restSlot {
            frame.slots[restSlot] = LispValue.list(remaining)
        }

        if !p.keys.isEmpty {
            // Keyword parsing.
            if remaining.count % 2 != 0 {
                throw interp.lispError("PROGRAM-ERROR",
                    "odd number of keyword arguments to \(code.name)")
            }
            var allowOther = p.allowOtherKeys
            var pairs: [(Symbol, LispValue)] = []
            var i = 0
            while i < remaining.count {
                guard case .symbol(let k) = remaining[i] else {
                    throw interp.lispError("PROGRAM-ERROR",
                        "keyword argument name is not a symbol in call to \(code.name)")
                }
                pairs.append((k, remaining[i + 1]))
                if k.name == "ALLOW-OTHER-KEYS", k.isKeyword,
                   remaining[i + 1].isTrue {
                    allowOther = true
                }
                i += 2
            }
            if !allowOther {
                for (k, _) in pairs {
                    if k.name == "ALLOW-OTHER-KEYS" && k.isKeyword { continue }
                    var known = false
                    for kp in p.keys where kp.keyword === k { known = true; break }
                    if !known {
                        throw interp.lispError("PROGRAM-ERROR",
                            "unknown keyword argument :\(k.name) in call to \(code.name)")
                    }
                }
            }
            for kp in p.keys {
                var found: LispValue? = nil
                for (k, v) in pairs where k === kp.keyword {
                    found = v
                    break
                }
                if let v = found {
                    frame.slots[kp.slot] = v
                    if let s = kp.suppliedSlot { frame.slots[s] = interp.tValue }
                } else {
                    if let dc = kp.defaultCode {
                        frame.slots[kp.slot] = try execute(dc, frame: frame).firstValue
                    } else {
                        frame.slots[kp.slot] = .null
                    }
                    if let s = kp.suppliedSlot { frame.slots[s] = .null }
                }
            }
        } else if p.restSlot == nil && !remaining.isEmpty {
            throw interp.lispError("PROGRAM-ERROR",
                "too many arguments to \(code.name)")
        }

        return frame
    }
}
