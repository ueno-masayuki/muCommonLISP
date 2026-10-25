// Builtins.swift
// Core and control-flow builtin functions.

import Foundation

extension Interpreter {

    func registerCoreBuiltins() {
        let lisp = registry.lisp

        // --- Definition support used by the compiler ---

        defBuiltin("%SET-FUNCTION", 2, 3) { [unowned self] args in
            guard let fn = args[1].asFunction else {
                throw self.typeError(args[1], expected: "FUNCTION")
            }
            if args.count == 3, case .string(let doc) = args[2].firstValue {
                fn.documentation = doc.string
            }
            switch args[0].firstValue {
            case .symbol(let s):
                if s.function is GenericFunction {
                    // Redefining a generic function with DEFUN: replace it.
                    s.function = fn
                } else {
                    s.function = fn
                }
                fn.name = s.name
                return .symbol(s)
            case .cons(let c):
                guard case .symbol(let setf) = c.car, setf.name == "SETF",
                      let rest = c.cdr.asCons,
                      case .symbol(let s) = rest.car else {
                    throw self.lispError("ERROR", "invalid function name")
                }
                s.setfFunction = fn
                fn.name = "(SETF \(s.name))"
                return args[0]
            default:
                throw self.lispError("ERROR", "invalid function name")
            }
        }

        defBuiltin("%SET-MACRO", 2, 3) { [unowned self] args in
            guard case .symbol(let s) = args[0].firstValue,
                  let fn = args[1].asFunction else {
                throw self.lispError("ERROR", "invalid defmacro")
            }
            s.macroFunction = fn
            fn.name = s.name
            return .symbol(s)
        }

        defBuiltin("%DEFVAR", 1, 2) { [unowned self] args in
            guard case .symbol(let s) = args[0].firstValue else {
                throw self.lispError("ERROR", "defvar name must be a symbol")
            }
            s.isSpecial = true
            if args.count == 2, s.value == nil, let thunk = args[1].asFunction {
                s.value = try self.applyFunction(thunk, []).firstValue
            }
            return .symbol(s)
        }

        defBuiltin("%DEFPARAMETER", 2, 2) { [unowned self] args in
            guard case .symbol(let s) = args[0].firstValue else {
                throw self.lispError("ERROR", "defparameter name must be a symbol")
            }
            s.isSpecial = true
            s.value = args[1].firstValue
            return .symbol(s)
        }

        defBuiltin("%DEFINE-SYMBOL-MACRO", 2, 2) { [unowned self] args in
            guard case .symbol(let s) = args[0].firstValue else {
                throw self.lispError("ERROR",
                    "define-symbol-macro name must be a symbol")
            }
            s.globalSymbolMacro = args[1].firstValue
            return .symbol(s)
        }

        defBuiltin("%DEFCONSTANT", 2, 2) { [unowned self] args in
            guard case .symbol(let s) = args[0].firstValue else {
                throw self.lispError("ERROR", "defconstant name must be a symbol")
            }
            s.value = args[1].firstValue
            s.isConstant = true
            return .symbol(s)
        }

        // --- BLOCK / RETURN-FROM / CATCH / THROW / UNWIND-PROTECT ---

        defBuiltin("%MAKE-BLOCK-TOKEN", 1, 1) { args in
            let name = args[0].asString ?? "?"
            return .blockToken(BlockToken(name: name))
        }

        defBuiltin("%BLOCK", 2, 2) { [unowned self] args in
            guard case .blockToken(let token) = args[0],
                  let thunk = args[1].asFunction else {
                throw self.lispError("ERROR", "malformed %block call")
            }
            do {
                return try self.applyFunction(thunk, [])
            } catch let b as BlockReturnSignal where b.token === token {
                return b.value
            }
        }

        defBuiltin("%RETURN-FROM", 2, 2) { [unowned self] args in
            guard case .blockToken(let token) = args[0] else {
                throw self.lispError("CONTROL-ERROR", "invalid return-from")
            }
            throw BlockReturnSignal(token: token, value: args[1])
        }

        defBuiltin("%CATCH", 2, 2) { [unowned self] args in
            guard let thunk = args[1].asFunction else {
                throw self.lispError("ERROR", "malformed %catch call")
            }
            let tag = args[0].firstValue
            do {
                return try self.applyFunction(thunk, [])
            } catch let t as LispThrowSignal where LispEquality.eq(t.tag, tag) {
                return t.value
            }
        }

        defBuiltin("THROW", 2, 2) { args in
            throw LispThrowSignal(tag: args[0].firstValue, value: args[1])
        }
        lisp.intern("%THROW").function = lisp.intern("THROW").function

        defBuiltin("%UNWIND-PROTECT", 2, 2) { [unowned self] args in
            guard let body = args[0].asFunction,
                  let cleanup = args[1].asFunction else {
                throw self.lispError("ERROR", "malformed %unwind-protect call")
            }
            do {
                let result = try self.applyFunction(body, [])
                _ = try self.applyFunction(cleanup, [])
                return result
            } catch {
                // Run the cleanup; if it throws, its transfer wins.
                _ = try self.applyFunction(cleanup, [])
                throw error
            }
        }

        // (%handler-case body-thunk (list (list 'type handler-fn) ...))
        defBuiltin("%HANDLER-CASE", 2, 2) { [unowned self] args in
            guard let body = args[0].asFunction else {
                throw self.lispError("ERROR", "malformed %handler-case call")
            }
            do {
                return try self.applyFunction(body, [])
            } catch let e as LispError {
                for clause in args[1].asArray() ?? [] {
                    guard let parts = clause.asArray(), parts.count == 2,
                          let handler = parts[1].asFunction else {
                        continue
                    }
                    if try self.typep(e.condition, parts[0]) {
                        return try self.applyFunction(handler, [e.condition])
                    }
                }
                throw e
            }
        }

        // --- SETF support ---

        defBuiltin("%SETF-CALL", 2, nil) { [unowned self] args in
            guard case .symbol(let op) = args[0].firstValue else {
                throw self.lispError("ERROR", "invalid setf place")
            }
            let rest = Array(args.dropFirst())   // (newval place-args...)
            if let fn = op.setfFunction {
                return try self.applyFunction(fn, rest)
            }
            if let handler = self.setfHandlers[op] {
                return try self.applyFunction(handler, rest)
            }
            throw self.lispError("ERROR", "no setf expander for \(op.name)")
        }

        defBuiltin("%SETF-FN", 1, 1) { [unowned self] args in
            guard case .symbol(let s) = args[0].firstValue,
                  let fn = s.setfFunction else {
                throw self.lispError("UNDEFINED-FUNCTION",
                    "undefined setf function")
            }
            return .function(fn)
        }

        // --- Function application ---

        defBuiltin("APPLY", 2, nil) { [unowned self] args in
            var callArgs = Array(args.dropFirst().dropLast())
            guard let lastList = args.last!.asArray() else {
                throw self.typeError(args.last!, expected: "LIST")
            }
            callArgs.append(contentsOf: lastList)
            return try self.apply(args[0].firstValue, callArgs)
        }

        defBuiltin("FUNCALL", 1, nil) { [unowned self] args in
            return try self.apply(args[0].firstValue, Array(args.dropFirst()))
        }

        defBuiltin("VALUES", 0, nil) { args in
            if args.count == 1 { return args[0].firstValue }
            return .values(args.map { $0.firstValue })
        }

        defBuiltin("VALUES-LIST", 1, 1) { [unowned self] args in
            guard let items = args[0].asArray() else {
                throw self.typeError(args[0], expected: "LIST")
            }
            if items.count == 1 { return items[0] }
            return .values(items)
        }

        defBuiltin("IDENTITY", 1, 1) { args in args[0] }

        defBuiltin("CONSTANTLY", 1, 1) { args in
            let v = args[0]
            return .function(Builtin(name: "CONSTANTLY", minArgs: 0, maxArgs: nil) { _ in v })
        }

        defBuiltin("COMPLEMENT", 1, 1) { [unowned self] args in
            let f = args[0].firstValue
            return .function(Builtin(name: "COMPLEMENT", minArgs: 0, maxArgs: nil) {
                inner in
                let r = try self.apply(f, inner)
                return r.isTrue ? .null : self.tValue
            })
        }

        // --- EVAL / COMPILE / MACROEXPAND ---

        defBuiltin("EVAL", 1, 1) { [unowned self] args in
            return try self.eval(args[0].firstValue)
        }

        defBuiltin("COMPILE", 1, 2) { [unowned self] args in
            // (compile name) recompiles nothing (already compiled);
            // (compile nil '(lambda ...)) returns a compiled closure.
            if args.count == 2 {
                let code = try self.compiler.compileLambdaExpression(args[1].firstValue)
                let fn = Closure(code: code, capturedFrame: nil)
                if case .symbol(let s) = args[0].firstValue {
                    s.function = fn
                    return .symbol(s)
                }
                return .function(fn)
            }
            guard case .symbol(let s) = args[0].firstValue,
                  s.function != nil else {
                throw self.lispError("UNDEFINED-FUNCTION", "nothing to compile")
            }
            return .symbol(s)
        }

        defBuiltin("COMPILED-FUNCTION-P", 1, 1) { [unowned self] args in
            if case .function = args[0].firstValue { return self.tValue }
            return .null
        }

        defBuiltin("DISASSEMBLE", 1, 1) { [unowned self] args in
            var fn: LispFunction? = nil
            switch args[0].firstValue {
            case .symbol(let s): fn = s.function
            case .function(let f): fn = f
            default: break
            }
            if let closure = fn as? Closure {
                self.write(Disassembler.disassemble(closure.code))
            } else if let f = fn {
                self.write(";; \(f.name) is not a bytecode function\n")
            } else {
                throw self.lispError("UNDEFINED-FUNCTION", "nothing to disassemble")
            }
            return .null
        }

        defBuiltin("MACROEXPAND-1", 1, 2) { [unowned self] args in
            let form = args[0].firstValue
            if let c = form.asCons, case .symbol(let head) = c.car,
               let mf = head.macroFunction,
               let macroArgs = c.cdr.asArray() {
                let expansion = try self.applyFunction(mf, macroArgs)
                return .values([expansion, self.tValue])
            }
            return .values([form, .null])
        }

        defBuiltin("MACROEXPAND", 1, 2) { [unowned self] args in
            var form = args[0].firstValue
            var expanded = false
            var iterations = 0
            while let c = form.asCons, case .symbol(let head) = c.car,
                  let mf = head.macroFunction,
                  let macroArgs = c.cdr.asArray() {
                form = try self.applyFunction(mf, macroArgs).firstValue
                expanded = true
                iterations += 1
                if iterations > 10_000 {
                    throw self.lispError("ERROR", "runaway macroexpansion")
                }
            }
            return .values([form, expanded ? self.tValue : .null])
        }

        defBuiltin("MACRO-FUNCTION", 1, 1) { args in
            if case .symbol(let s) = args[0].firstValue, let mf = s.macroFunction {
                return .function(mf)
            }
            return .null
        }

        // --- Conditions ---

        defBuiltin("ERROR", 1, nil) { [unowned self] args in
            let e = try self.signalToError(args, defaultClass: "SIMPLE-ERROR")
            // Give HANDLER-BIND handlers a chance before unwinding; they can
            // decline (return) or transfer control (throw).
            try self.runHandlers(for: e.condition)
            throw e
        }

        defBuiltin("SIGNAL", 1, nil) { [unowned self] args in
            let e = try self.signalToError(args,
                                           defaultClass: "SIMPLE-CONDITION")
            try self.runHandlers(for: e.condition)
            // SIGNAL returns NIL when the condition is not handled... but a
            // serious condition signalled through SIGNAL still unwinds via
            // HANDLER-CASE, which catches thrown LispErrors; approximate the
            // standard by returning NIL here.
            return .null
        }

        defBuiltin("WARN", 1, nil) { [unowned self] args in
            let e = try self.signalToError(args, defaultClass: "SIMPLE-WARNING")
            // Establish a MUFFLE-WARNING restart around the signal.
            let token = BlockToken(name: "WARN")
            let sym = self.registry.lisp.intern("MUFFLE-WARNING")
            self.restartStack.append(RestartEntry(
                name: sym, token: token, clauseIndex: 0, report: nil))
            defer { self.restartStack.removeLast() }
            do {
                try self.runHandlers(for: e.condition)
                self.write(";; WARNING: \(e.message)\n")
            } catch let r as RestartInvokeSignal where r.token === token {
                // muffled
            }
            return .null
        }

        defBuiltin("%CONDITION-MESSAGE", 1, 1) { [unowned self] args in
            return .str(self.conditionMessage(args[0].firstValue))
        }

        // --- Misc ---

        defBuiltin("GENSYM", 0, 1) { [unowned self] args in
            self.gensymCounter += 1
            var prefix = "G"
            if args.count == 1, case .string(let p) = args[0].firstValue {
                prefix = p.string
            }
            return .symbol(Symbol(name: "\(prefix)\(self.gensymCounter)",
                                  package: nil))
        }

        defBuiltin("GET-INTERNAL-REAL-TIME", 0, 0) { _ in
            return .int(Int(Date().timeIntervalSince1970 * 1000.0))
        }
        let itups = lisp.intern("INTERNAL-TIME-UNITS-PER-SECOND")
        itups.value = .int(1000)
        itups.isConstant = true

        defBuiltin("GET-UNIVERSAL-TIME", 0, 0) { _ in
            // Seconds since 1900-01-01 (CL epoch).
            return .int(Int(Date().timeIntervalSince1970) + 2_208_988_800)
        }

        defBuiltin("SLEEP", 1, 1) { [unowned self] args in
            guard let seconds = args[0].firstValue.asDouble, seconds >= 0 else {
                throw self.typeError(args[0], expected: "REAL")
            }
            // Sleep in small chunks so interrupts stay responsive.
            var remaining = seconds
            while remaining > 0 {
                if self.interruptRequested {
                    self.clearInterrupt()
                    throw InterruptSignal()
                }
                let chunk = min(remaining, 0.05)
                Thread.sleep(forTimeInterval: chunk)
                remaining -= chunk
            }
            return .null
        }

        defBuiltin("DOCUMENTATION", 1, 2) { _ in .null }

        defBuiltin("EXIT", 0, 1) { args in
            var code = 0
            if args.count == 1, case .int(let c) = args[0].firstValue {
                code = c
            }
            throw ExitSignal(code: code)
        }
        lisp.intern("QUIT").function = lisp.intern("EXIT").function

        defBuiltin("ROOM", 0, 1) { [unowned self] _ in
            self.write(";; muCommonLISP: memory statistics are not available\n")
            return .null
        }
    }

    /// Build a LispError from ERROR/SIGNAL/WARN arguments.
    func signalToError(_ args: [LispValue],
                       defaultClass: String) throws -> LispError {
        let datum = args[0].firstValue
        switch datum {
        case .string(let fmt):
            let message = try formatToString(control: fmt.string,
                                             args: Array(args.dropFirst()))
            let condition = makeConditionInstance(
                defaultClass, message: message,
                slots: [("FORMAT-CONTROL", .string(fmt)),
                        ("FORMAT-ARGUMENTS",
                         LispValue.list(Array(args.dropFirst())))])
            return LispError(condition: condition, message: message)
        case .symbol(let s):
            guard let cls = findClass(s) else {
                throw lispError("ERROR", "no condition class named \(s.name)")
            }
            let inst = try makeInstance(of: cls,
                                        initargs: Array(args.dropFirst()))
            return LispError(condition: inst,
                             message: conditionMessage(inst))
        case .instance:
            return LispError(condition: datum,
                             message: conditionMessage(datum))
        default:
            throw typeError(datum, expected: "CONDITION")
        }
    }
}
