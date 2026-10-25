// Bytecode.swift
// Instruction set and compiled code objects.

import Foundation

public enum Instruction {
    case pushConst(Int)          // push constants[i]
    case pushNil
    case localGet(Int, Int)      // (frame depth, slot index)
    case localSet(Int, Int)      // pops value
    case globalGet(Symbol)       // push symbol value (dynamic / global)
    case globalSet(Symbol)       // pops value
    case funcGet(Symbol)         // push symbol's function
    case bindSpecial(Symbol)     // pops value, dynamically binds
    case unbindSpecial(Int)      // restore n dynamic bindings
    case jump(Int)               // absolute target
    case jumpIfNil(Int)          // pops; jump when NIL
    case call(Int)               // stack: [... fn a1..an] -> [... result]
    case tailCall(Int)
    case ret
    case makeClosure(Int)        // children[i] closed over current frame
    case pop
    case dup
    case makeList(Int)           // pops n items, pushes list
    case mvBind(Int)             // pops a (values ...) and pushes n values

    // Fast inlined operations. Binary ops pop rhs then lhs.
    case opCar, opCdr, opCons
    case opAdd, opSub, opMul, opDiv
    case opNumEq, opNumLt, opNumGt, opNumLe, opNumGe
    case opEq, opNot, opConsp, opNull
    case opAdd1, opSub1
}

/// One optional/key parameter description.
public struct OptionalParam {
    public let slot: Int
    public let defaultCode: CodeObject?   // executed in the function's own frame
    public let suppliedSlot: Int?
}

public struct KeyParam {
    public let keyword: Symbol
    public let slot: Int
    public let defaultCode: CodeObject?
    public let suppliedSlot: Int?
}

public struct ParamInfo {
    public var nRequired: Int = 0
    public var optionals: [OptionalParam] = []
    public var restSlot: Int? = nil
    public var keys: [KeyParam] = []
    public var allowOtherKeys: Bool = false

    public var hasOptionalOrKeys: Bool {
        return !optionals.isEmpty || restSlot != nil || !keys.isEmpty
    }

    public var minArgs: Int { return nRequired }
    public var maxArgs: Int? {
        if restSlot != nil || !keys.isEmpty { return nil }
        return nRequired + optionals.count
    }
}

public final class CodeObject {
    public var name: String
    public var instructions: [Instruction] = []
    public var constants: [LispValue] = []
    public var children: [CodeObject] = []
    public var params: ParamInfo = ParamInfo()
    public var frameSize: Int = 0

    public init(name: String) {
        self.name = name
    }

    public func addConstant(_ v: LispValue) -> Int {
        constants.append(v)
        return constants.count - 1
    }

    public func emit(_ i: Instruction) {
        instructions.append(i)
    }

    /// Emit a placeholder jump; returns its index for later patching.
    public func emitPlaceholderJump(_ make: (Int) -> Instruction) -> Int {
        instructions.append(make(-1))
        return instructions.count - 1
    }

    public func patchJump(at index: Int, to target: Int) {
        switch instructions[index] {
        case .jump:
            instructions[index] = .jump(target)
        case .jumpIfNil:
            instructions[index] = .jumpIfNil(target)
        default:
            fatalError("patchJump on non-jump instruction")
        }
    }

    public var currentAddress: Int { return instructions.count }
}
