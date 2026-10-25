// PlaceMacros.swift
// Single-evaluation modify macros: PUSH, POP, INCF, DECF, PUSHNEW,
// ROTATEF, SHIFTF, REMF — and DEFSETF (short form).

import Foundation

extension Interpreter {

    /// Allocate temporaries for the subforms of a place.
    /// Returns let*-style bindings and the access form with temps substituted.
    private func placeTemps(_ place: LispValue)
        throws -> (bindings: [LispValue], access: LispValue) {
        switch place {
        case .symbol:
            return ([], place)
        case .cons(let c):
            guard case .symbol = c.car,
                  let args = c.cdr.asArray() else {
                throw CompileError("invalid place for a modify macro")
            }
            var bindings: [LispValue] = []
            var newArgs: [LispValue] = [c.car]
            for arg in args {
                switch arg {
                case .symbol, .int, .double, .string, .character:
                    // Constants and plain variables need no temporary.
                    newArgs.append(arg)
                default:
                    gensymCounter += 1
                    let tmp = Symbol(name: "PLACE-TMP\(gensymCounter)",
                                     package: nil)
                    bindings.append(lst(.symbol(tmp), arg))
                    newArgs.append(.symbol(tmp))
                }
            }
            return (bindings, LispValue.list(newArgs))
        default:
            throw CompileError("invalid place for a modify macro")
        }
    }

    private func freshTemp(_ prefix: String) -> LispValue {
        gensymCounter += 1
        return .symbol(Symbol(name: "\(prefix)\(gensymCounter)", package: nil))
    }

    private func wrapLet(_ bindings: [LispValue],
                         _ body: [LispValue]) -> LispValue {
        if bindings.isEmpty && body.count == 1 {
            return body[0]
        }
        return LispValue.list([sym("LET*"), LispValue.list(bindings)] + body)
    }

    func registerPlaceMacros() {

        defMacro("PUSH") { [unowned self] forms in
            guard forms.count == 2 else {
                throw CompileError("malformed push")
            }
            let itemTemp = self.freshTemp("ITEM")
            let (bindings, access) = try self.placeTemps(forms[1])
            return self.wrapLet([self.lst(itemTemp, forms[0])] + bindings,
                [self.lst(self.sym("SETF"), access,
                          self.lst(self.sym("CONS"), itemTemp, access))])
        }

        defMacro("PUSHNEW") { [unowned self] forms in
            guard forms.count >= 2 else {
                throw CompileError("malformed pushnew")
            }
            let itemTemp = self.freshTemp("ITEM")
            let (bindings, access) = try self.placeTemps(forms[1])
            let adjoinCall = LispValue.list(
                [self.sym("ADJOIN"), itemTemp, access]
                + Array(forms.dropFirst(2)))
            return self.wrapLet([self.lst(itemTemp, forms[0])] + bindings,
                [self.lst(self.sym("SETF"), access, adjoinCall)])
        }

        defMacro("POP") { [unowned self] forms in
            guard forms.count == 1 else {
                throw CompileError("malformed pop")
            }
            let head = self.freshTemp("HEAD")
            let (bindings, access) = try self.placeTemps(forms[0])
            return self.wrapLet(bindings + [self.lst(head, access)],
                [self.lst(self.sym("SETF"), access,
                          self.lst(self.sym("CDR"), head)),
                 self.lst(self.sym("CAR"), head)])
        }

        func arithModify(_ name: String, _ op: String) {
            self.defMacro(name) { [unowned self] forms in
                guard forms.count == 1 || forms.count == 2 else {
                    throw CompileError("malformed \(name.lowercased())")
                }
                let (bindings, access) = try self.placeTemps(forms[0])
                let deltaTemp = self.freshTemp("DELTA")
                let delta = forms.count == 2 ? forms[1] : .int(1)
                return self.wrapLet(bindings + [self.lst(deltaTemp, delta)],
                    [self.lst(self.sym("SETF"), access,
                              self.lst(self.sym(op), access, deltaTemp))])
            }
        }
        arithModify("INCF", "+")
        arithModify("DECF", "-")

        defMacro("ROTATEF") { [unowned self] forms in
            if forms.count < 2 { return .null }
            var allBindings: [LispValue] = []
            var accesses: [LispValue] = []
            for place in forms {
                let (b, a) = try self.placeTemps(place)
                allBindings.append(contentsOf: b)
                accesses.append(a)
            }
            var valueTemps: [LispValue] = []
            for a in accesses {
                let t = self.freshTemp("ROT")
                allBindings.append(self.lst(t, a))
                valueTemps.append(t)
            }
            var body: [LispValue] = []
            for i in 0..<accesses.count {
                let nextValue = valueTemps[(i + 1) % valueTemps.count]
                body.append(self.lst(self.sym("SETF"), accesses[i], nextValue))
            }
            body.append(.null)
            return self.wrapLet(allBindings, body)
        }

        defMacro("SHIFTF") { [unowned self] forms in
            guard forms.count >= 2 else {
                throw CompileError("malformed shiftf")
            }
            let places = Array(forms.dropLast())
            let newValueForm = forms.last!
            var allBindings: [LispValue] = []
            var accesses: [LispValue] = []
            for place in places {
                let (b, a) = try self.placeTemps(place)
                allBindings.append(contentsOf: b)
                accesses.append(a)
            }
            var valueTemps: [LispValue] = []
            for a in accesses {
                let t = self.freshTemp("SHIFT")
                allBindings.append(self.lst(t, a))
                valueTemps.append(t)
            }
            let newTemp = self.freshTemp("NEW")
            allBindings.append(self.lst(newTemp, newValueForm))
            var body: [LispValue] = []
            for i in 0..<accesses.count {
                let incoming = i + 1 < valueTemps.count
                    ? valueTemps[i + 1] : newTemp
                body.append(self.lst(self.sym("SETF"), accesses[i], incoming))
            }
            body.append(valueTemps[0])
            return self.wrapLet(allBindings, body)
        }

        // (remf place indicator)
        defMacro("REMF") { [unowned self] forms in
            guard forms.count == 2 else {
                throw CompileError("malformed remf")
            }
            let (bindings, access) = try self.placeTemps(forms[0])
            let ind = self.freshTemp("IND")
            let newList = self.freshTemp("NEWL")
            let found = self.freshTemp("FOUND")
            return self.wrapLet(bindings + [self.lst(ind, forms[1])],
                [self.lst(self.sym("MULTIPLE-VALUE-BIND"),
                          self.lst(newList, found),
                          self.lst(self.sym("%PLIST-REMOVE"), access, ind),
                          self.lst(self.sym("SETF"), access, newList),
                          found)])
        }

        // (defsetf reader writer) — short form only.
        defMacro("DEFSETF") { [unowned self] forms in
            guard forms.count >= 2,
                  case .symbol = forms[0], case .symbol = forms[1] else {
                throw CompileError("only the short form of defsetf is supported")
            }
            return self.lst(self.sym("%DEFSETF"),
                            self.quoted(forms[0]), self.quoted(forms[1]))
        }

        defBuiltin("%DEFSETF", 2, 2) { [unowned self] args in
            guard case .symbol(let reader) = args[0].firstValue,
                  case .symbol(let writer) = args[1].firstValue else {
                throw self.lispError("ERROR", "malformed %defsetf call")
            }
            reader.setfFunction = Builtin(
                name: "(SETF \(reader.name))", minArgs: 1, maxArgs: nil) {
                [unowned self] callArgs in
                // callArgs = (newval placeargs...); writer takes
                // (placeargs... newval).
                guard let fn = writer.function else {
                    throw self.lispError("UNDEFINED-FUNCTION",
                        "undefined setf writer \(writer.name)")
                }
                let reordered = Array(callArgs.dropFirst()) + [callArgs[0]]
                _ = try self.applyFunction(fn, reordered)
                return callArgs[0]
            }
            return args[0].firstValue
        }

        defBuiltin("%PLIST-REMOVE", 2, 2) { [unowned self] args in
            var result: [LispValue] = []
            var found = false
            var cur = args[0].firstValue
            while case .cons(let c) = cur {
                guard case .cons(let next) = c.cdr else { break }
                if !found && LispEquality.eq(c.car, args[1].firstValue) {
                    found = true
                } else {
                    result.append(c.car)
                    result.append(next.car)
                }
                cur = next.cdr
            }
            return .values([LispValue.list(result),
                            found ? self.tValue : .null])
        }

        defBuiltin("%PLIST-PUT", 3, 3) { args in
            // Returns a plist with key set; mutates in place when found.
            var cur = args[0].firstValue
            while case .cons(let c) = cur {
                guard case .cons(let next) = c.cdr else { break }
                if LispEquality.eq(c.car, args[1].firstValue) {
                    next.car = args[2].firstValue
                    return args[0].firstValue
                }
                cur = next.cdr
            }
            return .cons(Cons(car: args[1].firstValue,
                              cdr: .cons(Cons(car: args[2].firstValue,
                                              cdr: args[0].firstValue))))
        }
    }
}
