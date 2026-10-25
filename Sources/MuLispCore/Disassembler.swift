// Disassembler.swift
// Human-readable bytecode listings for DISASSEMBLE.

import Foundation

public enum Disassembler {

    public static func disassemble(_ code: CodeObject, indent: String = "") -> String {
        var out = "\(indent);; code \(code.name)  (frame size \(code.frameSize))\n"
        for (i, inst) in code.instructions.enumerated() {
            let number = String(i)
            let padding = String(repeating: " ",
                                 count: max(0, 4 - number.count))
            out += "\(indent)\(padding)\(number)  \(describe(inst, code))\n"
        }
        for (i, child) in code.children.enumerated() {
            out += "\(indent);; child [\(i)]\n"
            out += disassemble(child, indent: indent + "    ")
        }
        return out
    }

    private static func describe(_ inst: Instruction, _ code: CodeObject) -> String {
        switch inst {
        case .pushConst(let i):
            let v = i < code.constants.count
                ? Printer.toString(code.constants[i], escape: true)
                : "?"
            return "PUSH-CONST \(i)    ; \(v)"
        case .pushNil: return "PUSH-NIL"
        case .localGet(let d, let s): return "LOCAL-GET \(d) \(s)"
        case .localSet(let d, let s): return "LOCAL-SET \(d) \(s)"
        case .globalGet(let sym): return "GLOBAL-GET \(sym.name)"
        case .globalSet(let sym): return "GLOBAL-SET \(sym.name)"
        case .funcGet(let sym): return "FUNC-GET \(sym.name)"
        case .bindSpecial(let sym): return "BIND-SPECIAL \(sym.name)"
        case .unbindSpecial(let n): return "UNBIND-SPECIAL \(n)"
        case .jump(let t): return "JUMP \(t)"
        case .jumpIfNil(let t): return "JUMP-IF-NIL \(t)"
        case .call(let n): return "CALL \(n)"
        case .tailCall(let n): return "TAIL-CALL \(n)"
        case .ret: return "RETURN"
        case .makeClosure(let i): return "MAKE-CLOSURE \(i)"
        case .pop: return "POP"
        case .dup: return "DUP"
        case .makeList(let n): return "MAKE-LIST \(n)"
        case .mvBind(let n): return "MV-BIND \(n)"
        case .opCar: return "CAR"
        case .opCdr: return "CDR"
        case .opCons: return "CONS"
        case .opAdd: return "ADD"
        case .opSub: return "SUB"
        case .opMul: return "MUL"
        case .opDiv: return "DIV"
        case .opNumEq: return "NUM="
        case .opNumLt: return "NUM<"
        case .opNumGt: return "NUM>"
        case .opNumLe: return "NUM<="
        case .opNumGe: return "NUM>="
        case .opEq: return "EQ"
        case .opNot: return "NOT"
        case .opNull: return "NULL"
        case .opConsp: return "CONSP"
        case .opAdd1: return "ADD1"
        case .opSub1: return "SUB1"
        }
    }
}
