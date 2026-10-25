// ControlFlow.swift
// TAGBODY/GO, the restart system, HANDLER-BIND, PROGV and
// multiple-value control forms.

import Foundation

/// GO transfers control to a tag inside an enclosing TAGBODY.
public struct GoSignal: Error {
    public let token: BlockToken
    public let segmentIndex: Int
}

/// INVOKE-RESTART transfers control to the owning RESTART-CASE.
public struct RestartInvokeSignal: Error {
    public let token: BlockToken
    public let clauseIndex: Int
    public let args: [LispValue]
}

/// One active restart.
struct RestartEntry {
    let name: Symbol?            // nil = anonymous
    let token: BlockToken
    let clauseIndex: Int
    let report: String?
}

/// One active HANDLER-BIND handler.
struct HandlerEntry {
    let typeSpec: LispValue
    let fn: LispValue
}

extension Interpreter {

    /// Run HANDLER-BIND handlers for a condition. Handlers may decline
    /// (return normally) or transfer control (throw). Returns normally when
    /// no handler transferred.
    func runHandlers(for condition: LispValue) throws {
        var index = handlerStack.count - 1
        while index >= 0 {
            if index >= handlerStack.count {
                index = handlerStack.count - 1
                continue
            }
            let entry = handlerStack[index]
            let matches = (try? typep(condition, entry.typeSpec)) ?? false
            if matches {
                // While a handler runs, only handlers established outside of
                // it are visible (CL semantics).
                let saved = handlerStack
                handlerStack = Array(handlerStack[0..<index])
                defer { handlerStack = saved }
                _ = try apply(entry.fn, [condition])
            }
            index -= 1
        }
    }

    func registerControlFlowBuiltins() {

        // --- TAGBODY / GO ---

        defBuiltin("%TAGBODY", 2, 2) { [unowned self] args in
            guard case .blockToken(let token) = args[0],
                  let thunks = args[1].asArray() else {
                throw self.lispError("ERROR", "malformed %tagbody call")
            }
            var i = 0
            while i < thunks.count {
                do {
                    while i < thunks.count {
                        _ = try self.apply(thunks[i], [])
                        i += 1
                    }
                } catch let g as GoSignal where g.token === token {
                    i = g.segmentIndex
                }
            }
            return .null
        }

        defBuiltin("%GO", 2, 2) { [unowned self] args in
            guard case .blockToken(let token) = args[0],
                  case .int(let index) = args[1].firstValue else {
                throw self.lispError("CONTROL-ERROR", "malformed %go call")
            }
            throw GoSignal(token: token, segmentIndex: index)
        }

        // --- PROGV ---

        defBuiltin("%PROGV", 3, 3) { [unowned self] args in
            guard let symbols = args[0].asArray(),
                  let values = args[1].asArray(),
                  let thunk = args[2].asFunction else {
                throw self.lispError("ERROR", "malformed %progv call")
            }
            let mark = self.dynamicStack.count
            defer { self.unwindDynamicStack(to: mark) }
            for (i, sv) in symbols.enumerated() {
                guard case .symbol(let s) = sv else {
                    throw self.typeError(sv, expected: "SYMBOL")
                }
                self.dynamicStack.append((s, s.value))
                s.isSpecial = true
                s.value = i < values.count ? values[i] : nil
            }
            return try self.applyFunction(thunk, [])
        }

        // --- Multiple values ---

        defBuiltin("%MVCALL", 1, nil) { [unowned self] args in
            let fn = args[0].firstValue
            var collected: [LispValue] = []
            for thunk in args.dropFirst() {
                guard let f = thunk.asFunction else {
                    throw self.lispError("ERROR", "malformed %mvcall thunk")
                }
                let r = try self.applyFunction(f, [])
                if case .values(let vs) = r {
                    collected.append(contentsOf: vs)
                } else {
                    collected.append(r)
                }
            }
            return try self.apply(fn, collected)
        }

        defBuiltin("%MVPROG1", 2, 2) { [unowned self] args in
            guard let first = args[0].asFunction,
                  let rest = args[1].asFunction else {
                throw self.lispError("ERROR", "malformed %mvprog1 call")
            }
            let result = try self.applyFunction(first, [])
            _ = try self.applyFunction(rest, [])
            return result
        }

        // --- HANDLER-BIND ---

        // (%handler-bind body-thunk (list (list 'type fn) ...))
        defBuiltin("%HANDLER-BIND", 2, 2) { [unowned self] args in
            guard let body = args[0].asFunction else {
                throw self.lispError("ERROR", "malformed %handler-bind call")
            }
            var entries: [HandlerEntry] = []
            for clause in args[1].asArray() ?? [] {
                guard let parts = clause.asArray(), parts.count == 2 else {
                    continue
                }
                entries.append(HandlerEntry(typeSpec: parts[0], fn: parts[1]))
            }
            let mark = self.handlerStack.count
            self.handlerStack.append(contentsOf: entries)
            defer {
                if self.handlerStack.count > mark {
                    self.handlerStack.removeSubrange(mark...)
                }
            }
            do {
                return try self.applyFunction(body, [])
            } catch let e as LispError {
                // Conditions signalled from Swift builtins did not pass
                // through SIGNAL; give these handlers a chance now.
                self.handlerStack.removeSubrange(mark...)
                try self.runHandlersSubset(entries, for: e.condition)
                throw e
            }
        }

        // --- Restarts ---

        // (%restart-case body-thunk
        //    (list (list 'name handler-fn "report") ...))
        defBuiltin("%RESTART-CASE", 2, 2) { [unowned self] args in
            guard let body = args[0].asFunction,
                  let clauses = args[1].asArray() else {
                throw self.lispError("ERROR", "malformed %restart-case call")
            }
            let token = BlockToken(name: "RESTART-CASE")
            var handlers: [LispValue] = []
            let mark = self.restartStack.count
            for (i, clause) in clauses.enumerated() {
                guard let parts = clause.asArray(), parts.count >= 2 else {
                    throw self.lispError("ERROR", "malformed restart clause")
                }
                var name: Symbol? = nil
                if case .symbol(let s) = parts[0] { name = s }
                var report: String? = nil
                if parts.count >= 3, case .string(let r) = parts[2] {
                    report = r.string
                }
                self.restartStack.append(RestartEntry(
                    name: name, token: token, clauseIndex: i, report: report))
                handlers.append(parts[1])
            }
            defer {
                if self.restartStack.count > mark {
                    self.restartStack.removeSubrange(mark...)
                }
            }
            do {
                return try self.applyFunction(body, [])
            } catch let r as RestartInvokeSignal where r.token === token {
                guard r.clauseIndex < handlers.count,
                      let fn = handlers[r.clauseIndex].asFunction else {
                    throw self.lispError("CONTROL-ERROR", "bad restart invocation")
                }
                // The restart's own extent has ended.
                self.restartStack.removeSubrange(mark...)
                return try self.applyFunction(fn, r.args)
            }
        }

        defBuiltin("INVOKE-RESTART", 1, nil) { [unowned self] args in
            let entry = try self.findRestartEntry(args[0].firstValue)
            throw RestartInvokeSignal(token: entry.token,
                                      clauseIndex: entry.clauseIndex,
                                      args: Array(args.dropFirst()))
        }
        registry.lisp.intern("INVOKE-RESTART-INTERACTIVELY").function =
            registry.lisp.intern("INVOKE-RESTART").function

        defBuiltin("FIND-RESTART", 1, 2) { [unowned self] args in
            if (try? self.findRestartEntry(args[0].firstValue)) != nil {
                return args[0].firstValue
            }
            return .null
        }

        defBuiltin("COMPUTE-RESTARTS", 0, 1) { [unowned self] _ in
            var names: [LispValue] = []
            for entry in self.restartStack.reversed() {
                if let n = entry.name {
                    names.append(.symbol(n))
                }
            }
            return LispValue.list(names)
        }

        defBuiltin("ABORT", 0, 1) { [unowned self] _ in
            let abortSym = self.registry.lisp.intern("ABORT")
            if let entry = try? self.findRestartEntry(.symbol(abortSym)) {
                throw RestartInvokeSignal(token: entry.token,
                                          clauseIndex: entry.clauseIndex,
                                          args: [])
            }
            throw self.lispError("CONTROL-ERROR", "no ABORT restart available")
        }

        defBuiltin("CONTINUE", 0, 1) { [unowned self] _ in
            let sym = self.registry.lisp.intern("CONTINUE")
            if let entry = try? self.findRestartEntry(.symbol(sym)) {
                throw RestartInvokeSignal(token: entry.token,
                                          clauseIndex: entry.clauseIndex,
                                          args: [])
            }
            return .null
        }

        defBuiltin("USE-VALUE", 1, 2) { [unowned self] args in
            let sym = self.registry.lisp.intern("USE-VALUE")
            if let entry = try? self.findRestartEntry(.symbol(sym)) {
                throw RestartInvokeSignal(token: entry.token,
                                          clauseIndex: entry.clauseIndex,
                                          args: [args[0]])
            }
            return .null
        }

        defBuiltin("STORE-VALUE", 1, 2) { [unowned self] args in
            let sym = self.registry.lisp.intern("STORE-VALUE")
            if let entry = try? self.findRestartEntry(.symbol(sym)) {
                throw RestartInvokeSignal(token: entry.token,
                                          clauseIndex: entry.clauseIndex,
                                          args: [args[0]])
            }
            return .null
        }

        defBuiltin("MUFFLE-WARNING", 0, 1) { [unowned self] _ in
            let sym = self.registry.lisp.intern("MUFFLE-WARNING")
            if let entry = try? self.findRestartEntry(.symbol(sym)) {
                throw RestartInvokeSignal(token: entry.token,
                                          clauseIndex: entry.clauseIndex,
                                          args: [])
            }
            return .null
        }

        defBuiltin("RESTART-NAME", 1, 1) { args in
            return args[0].firstValue
        }

        // (cerror continue-format datum args...)
        defBuiltin("CERROR", 2, nil) { [unowned self] args in
            let e = try self.signalToError(Array(args.dropFirst()),
                                           defaultClass: "SIMPLE-ERROR")
            // Establish a CONTINUE restart around the signal.
            let token = BlockToken(name: "CERROR")
            let sym = self.registry.lisp.intern("CONTINUE")
            self.restartStack.append(RestartEntry(
                name: sym, token: token, clauseIndex: 0, report: nil))
            defer { self.restartStack.removeLast() }
            do {
                try self.runHandlers(for: e.condition)
                throw e
            } catch let r as RestartInvokeSignal where r.token === token {
                return .null
            }
        }

        // Swift-implemented macros for the clause syntax.
        defMacro("RESTART-CASE") { [unowned self] forms in
            try self.expandRestartCase(forms)
        }

        defMacro("HANDLER-BIND") { [unowned self] forms in
            guard forms.count >= 1, let bindings = forms[0].asArray() else {
                throw CompileError("malformed handler-bind")
            }
            var clauses: [LispValue] = []
            for b in bindings {
                guard let parts = b.asArray(), parts.count == 2 else {
                    throw CompileError("malformed handler-bind binding")
                }
                clauses.append(self.lst(self.sym("LIST"),
                                        self.quoted(parts[0]), parts[1]))
            }
            return self.lst(self.sym("%HANDLER-BIND"),
                            self.lst(self.sym("LAMBDA"), .null,
                                     LispValue.list([self.sym("PROGN")]
                                                    + forms.dropFirst())),
                            LispValue.list([self.sym("LIST")] + clauses))
        }
    }

    /// Run only the given handlers (used by %HANDLER-BIND for errors raised
    /// from Swift that bypassed SIGNAL).
    func runHandlersSubset(_ entries: [HandlerEntry],
                           for condition: LispValue) throws {
        for entry in entries.reversed() {
            let matches = (try? typep(condition, entry.typeSpec)) ?? false
            if matches {
                _ = try apply(entry.fn, [condition])
            }
        }
    }

    func findRestartEntry(_ designator: LispValue) throws -> RestartEntry {
        guard case .symbol(let name) = designator else {
            throw lispError("CONTROL-ERROR",
                "restart designator must be a symbol")
        }
        for entry in restartStack.reversed() {
            if let n = entry.name, n === name {
                return entry
            }
        }
        throw lispError("CONTROL-ERROR", "no restart named \(name.name)")
    }

    /// (restart-case form (name lambda-list [:report "..."] body...) ...)
    private func expandRestartCase(_ forms: [LispValue]) throws -> LispValue {
        guard !forms.isEmpty else {
            throw CompileError("malformed restart-case")
        }
        var clauseForms: [LispValue] = []
        for clause in forms.dropFirst() {
            guard let parts = clause.asArray(), parts.count >= 2 else {
                throw CompileError("malformed restart-case clause")
            }
            let name = parts[0]
            let lambdaList = parts[1]
            var body = Array(parts.dropFirst(2))
            var report: LispValue = .null
            // Parse clause options (:report / :interactive / :test).
            while body.count >= 2, case .symbol(let k) = body[0], k.isKeyword {
                if k.name == "REPORT" {
                    report = body[1]
                }
                body.removeFirst(2)
            }
            let handler = LispValue.list([sym("LAMBDA"), lambdaList]
                                         + (body.isEmpty ? [LispValue.null] : body))
            clauseForms.append(lst(sym("LIST"), quoted(name), handler, report))
        }
        return lst(sym("%RESTART-CASE"),
                   lst(sym("LAMBDA"), .null, forms[0]),
                   LispValue.list([sym("LIST")] + clauseForms))
    }
}
