// Introspection.swift
// DESCRIBE, DOCUMENTATION, TRACE, time utilities, LISP-IMPLEMENTATION-*.

import Foundation

extension Interpreter {

    func registerIntrospection() {
        let lisp = registry.lisp

        // --- DOCUMENTATION ---

        // Replaces the earlier stub (defined in registerCoreBuiltins).
        defBuiltin("DOCUMENTATION", 1, 2) { [unowned self] args in
            switch args[0].firstValue {
            case .symbol(let s):
                var kind = "FUNCTION"
                if args.count == 2, case .symbol(let k) = args[1].firstValue {
                    kind = k.name
                }
                switch kind {
                case "FUNCTION":
                    if let doc = s.function?.documentation {
                        return .str(doc)
                    }
                case "TYPE", "CLASS":
                    if let cls = self.findClass(s), let doc = cls.documentation {
                        return .str(doc)
                    }
                case "VARIABLE":
                    break
                default:
                    break
                }
                return .null
            case .function(let f):
                if let doc = f.documentation { return .str(doc) }
                return .null
            default:
                return .null
            }
        }

        defSetfHandler("DOCUMENTATION") { [unowned self] args in
            // (newval thing kind)
            guard case .string(let doc) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "STRING")
            }
            if case .symbol(let s) = args[1].firstValue {
                s.function?.documentation = doc.string
            }
            return args[0]
        }

        // --- DESCRIBE / INSPECT ---

        defBuiltin("DESCRIBE", 1, 2) { [unowned self] args in
            let v = args[0].firstValue
            var out = Printer.toString(v, escape: true, interp: self)
            out += "\n  type: \(self.classOf(v).name.name)\n"
            switch v {
            case .symbol(let s):
                if let value = s.value {
                    out += "  value: "
                    out += Printer.toString(value, escape: true, interp: self)
                    out += "\n"
                }
                if let f = s.function {
                    out += "  function: \(f.name)"
                    if let gf = f as? GenericFunction {
                        out += " (generic, \(gf.methods.count) methods)"
                    }
                    out += "\n"
                    if let doc = f.documentation {
                        out += "  documentation: \(doc)\n"
                    }
                }
                if s.macroFunction != nil {
                    out += "  macro: yes\n"
                }
                if let p = s.package {
                    out += "  package: \(p.name)\n"
                }
                if s.isSpecial {
                    out += "  special variable\n"
                }
            case .instance(let inst):
                self.ensureCurrentVersion(inst)
                for slot in inst.clazz.effectiveSlots {
                    let value: LispValue?
                    if slot.allocation == .instance {
                        value = inst.slots[slot.location]
                    } else {
                        value = slot.classCell?.value
                    }
                    out += "  \(slot.name.name): "
                    out += value.map {
                        Printer.toString($0, escape: true, interp: self)
                    } ?? "#<unbound>"
                    out += "\n"
                }
            case .lispClass(let cls):
                out += "  superclasses: "
                out += cls.directSuperclasses.map { $0.name.name }
                        .joined(separator: " ")
                out += "\n  slots: "
                out += cls.effectiveSlots.map { $0.name.name }
                        .joined(separator: " ")
                out += "\n"
            default:
                break
            }
            self.write(out)
            return .values([])
        }
        lisp.intern("INSPECT").function = lisp.intern("DESCRIBE").function

        // --- TRACE / UNTRACE ---

        defBuiltin("%TRACE", 1, nil) { [unowned self] args in
            for arg in args {
                guard case .symbol(let s) = arg.firstValue,
                      let original = s.function else { continue }
                if self.tracedFunctions[ObjectIdentifier(s)] != nil { continue }
                self.tracedFunctions[ObjectIdentifier(s)] = original
                let name = s.name
                s.function = Builtin(name: name, minArgs: 0, maxArgs: nil) {
                    [unowned self] callArgs in
                    let depth = self.traceDepth
                    self.traceDepth += 1
                    defer { self.traceDepth -= 1 }
                    let indent = String(repeating: "  ", count: depth)
                    let argText = callArgs.map {
                        Printer.toString($0, escape: true, interp: self)
                    }.joined(separator: " ")
                    self.write("\(indent)\(depth): (\(name) \(argText))\n")
                    let result = try self.applyFunction(original, callArgs)
                    let resText = Printer.toString(result.firstValue,
                                                   escape: true, interp: self)
                    self.write("\(indent)\(depth): \(name) returned \(resText)\n")
                    return result
                }
            }
            return LispValue.list(args.map { $0.firstValue })
        }

        defBuiltin("%UNTRACE", 0, nil) { [unowned self] args in
            if args.isEmpty {
                for (id, fn) in self.tracedFunctions {
                    for p in self.registry.allPackages() {
                        for (_, sym) in p.symbols
                        where ObjectIdentifier(sym) == id {
                            sym.function = fn
                        }
                    }
                }
                self.tracedFunctions.removeAll()
                return .null
            }
            for arg in args {
                guard case .symbol(let s) = arg.firstValue,
                      let original = self.tracedFunctions[ObjectIdentifier(s)]
                else { continue }
                s.function = original
                self.tracedFunctions.removeValue(forKey: ObjectIdentifier(s))
            }
            return .null
        }

        defMacro("TRACE") { [unowned self] forms in
            LispValue.list([self.sym("%TRACE")] + forms.map { self.quoted($0) })
        }
        defMacro("UNTRACE") { [unowned self] forms in
            LispValue.list([self.sym("%UNTRACE")] + forms.map { self.quoted($0) })
        }

        // --- Time ---

        defBuiltin("DECODE-UNIVERSAL-TIME", 1, 2) { [unowned self] args in
            guard case .int(let ut) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "INTEGER")
            }
            let date = Date(timeIntervalSince1970: Double(ut - 2_208_988_800))
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone.current
            let c = cal.dateComponents([.second, .minute, .hour, .day,
                                        .month, .year, .weekday], from: date)
            // CL weekday: 0 = Monday; Calendar: 1 = Sunday.
            let clWeekday = ((c.weekday ?? 1) + 5) % 7
            let tzHours = -TimeZone.current.secondsFromGMT() / 3600
            return .values([.int(c.second ?? 0), .int(c.minute ?? 0),
                            .int(c.hour ?? 0), .int(c.day ?? 1),
                            .int(c.month ?? 1), .int(c.year ?? 1900),
                            .int(clWeekday), .null, .int(tzHours)])
        }

        defBuiltin("GET-DECODED-TIME", 0, 0) { [unowned self] _ in
            let now = Int(Date().timeIntervalSince1970) + 2_208_988_800
            guard let fn = self.registry.lisp.intern("DECODE-UNIVERSAL-TIME")
                    .function else {
                return .null
            }
            return try self.applyFunction(fn, [.int(now)])
        }

        defBuiltin("ENCODE-UNIVERSAL-TIME", 6, 7) { [unowned self] args in
            var c = DateComponents()
            c.second = args[0].firstValue.asInt
            c.minute = args[1].firstValue.asInt
            c.hour = args[2].firstValue.asInt
            c.day = args[3].firstValue.asInt
            c.month = args[4].firstValue.asInt
            c.year = args[5].firstValue.asInt
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone.current
            guard let date = cal.date(from: c) else {
                throw self.lispError("ERROR", "invalid time components")
            }
            return .int(Int(date.timeIntervalSince1970) + 2_208_988_800)
        }

        // --- Implementation info ---

        defBuiltin("LISP-IMPLEMENTATION-TYPE", 0, 0) { _ in
            .str("muCommonLISP")
        }
        defBuiltin("LISP-IMPLEMENTATION-VERSION", 0, 0) { _ in
            .str("2.0")
        }
        defBuiltin("MACHINE-TYPE", 0, 0) { _ in
            #if arch(arm64)
            return .str("ARM64")
            #else
            return .str("X86-64")
            #endif
        }
        defBuiltin("SOFTWARE-TYPE", 0, 0) { _ in
            #if os(macOS)
            return .str("macOS")
            #else
            return .str("Linux")
            #endif
        }

        let featuresSym = lisp.intern("*FEATURES*")
        featuresSym.isSpecial = true
        featuresSym.value = LispValue.list([
            .symbol(registry.keyword.intern("MUCL")),
            .symbol(registry.keyword.intern("MULISP")),
            .symbol(registry.keyword.intern("COMMON-LISP")),
        ])
    }
}
