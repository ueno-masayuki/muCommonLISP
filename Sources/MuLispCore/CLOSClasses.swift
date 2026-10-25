// CLOSClasses.swift
// CLOS classes: slots, class precedence lists, instances, redefinition.

import Foundation

/// Shared cell for :allocation :class slots.
public final class SlotCell {
    public var value: LispValue?
    public init() {}
}

public enum SlotAllocation {
    case instance
    case classAllocation
}

public final class SlotDef {
    public let name: Symbol
    public var initargs: [Symbol]
    public var initFunction: LispFunction?    // zero-argument thunk
    public var readers: [Symbol]
    public var writers: [Symbol]
    public var allocation: SlotAllocation
    public var documentation: String?

    /// Effective-slot info: index into instance storage (-1 for class slots).
    public var location: Int = -1
    /// For class-allocated slots, the shared cell (owned by the defining class).
    public var classCell: SlotCell? = nil

    public init(name: Symbol, initargs: [Symbol] = [],
                initFunction: LispFunction? = nil,
                readers: [Symbol] = [], writers: [Symbol] = [],
                allocation: SlotAllocation = .instance,
                documentation: String? = nil) {
        self.name = name
        self.initargs = initargs
        self.initFunction = initFunction
        self.readers = readers
        self.writers = writers
        self.allocation = allocation
        self.documentation = documentation
        if allocation == .classAllocation {
            self.classCell = SlotCell()
        }
    }

    /// Copy used when computing effective slots.
    func effectiveCopy() -> SlotDef {
        let s = SlotDef(name: name, initargs: initargs,
                        initFunction: initFunction,
                        readers: [], writers: [],
                        allocation: allocation,
                        documentation: documentation)
        s.classCell = classCell
        return s
    }
}

public enum ClassKind {
    case standard       // defclass
    case builtin        // system classes for built-in types
    case structure      // defstruct
}

public final class LispClass {
    public let name: Symbol
    public var kind: ClassKind
    public var directSuperclasses: [LispClass] = []
    public var directSlots: [SlotDef] = []
    public private(set) var cpl: [LispClass] = []
    public private(set) var effectiveSlots: [SlotDef] = []
    public private(set) var instanceSlotCount: Int = 0
    public var version: Int = 0
    public var directSubclasses: [LispClass] = []
    public var documentation: String?

    /// Instance slot name layout per version (for lazy instance updating).
    public private(set) var layoutHistory: [Int: [Symbol]] = [:]

    public init(name: Symbol, kind: ClassKind) {
        self.name = name
        self.kind = kind
    }

    public func isSubclass(of other: LispClass) -> Bool {
        for c in cpl where c === other { return true }
        return false
    }

    public var instanceSlotNames: [Symbol] {
        return effectiveSlots.filter { $0.allocation == .instance }.map { $0.name }
    }

    public func effectiveSlot(named n: Symbol) -> SlotDef? {
        for s in effectiveSlots where s.name === n { return s }
        return nil
    }

    // MARK: - Finalization

    /// Compute class precedence list and effective slots.
    public func finalizeClass() throws {
        cpl = try LispClass.computeCPL(self)
        var merged: [Symbol: SlotDef] = [:]
        var order: [Symbol] = []
        // Least specific first so more specific definitions override.
        for cls in cpl.reversed() {
            for slot in cls.directSlots {
                if let existing = merged[slot.name] {
                    // Override init function if the more specific class gives one;
                    // merge initargs.
                    let combined = existing
                    if slot.initFunction != nil {
                        combined.initFunction = slot.initFunction
                    }
                    for ia in slot.initargs where !combined.initargs.contains(where: { $0 === ia }) {
                        combined.initargs.append(ia)
                    }
                    combined.allocation = slot.allocation
                    if slot.allocation == .classAllocation {
                        combined.classCell = slot.classCell
                    }
                    merged[slot.name] = combined
                } else {
                    let copy = slot.effectiveCopy()
                    merged[slot.name] = copy
                    order.append(slot.name)
                }
            }
        }
        var slots: [SlotDef] = []
        var location = 0
        for n in order {
            let s = merged[n]!
            if s.allocation == .instance {
                s.location = location
                location += 1
            } else {
                s.location = -1
                if s.classCell == nil { s.classCell = SlotCell() }
            }
            slots.append(s)
        }
        effectiveSlots = slots
        instanceSlotCount = location
        layoutHistory[version] = instanceSlotNames
    }

    /// Re-finalize this class and all (transitive) subclasses after a
    /// redefinition. Bumps versions so live instances update lazily.
    public func refinalizeTree() throws {
        version += 1
        try finalizeClass()
        for sub in directSubclasses {
            try sub.refinalizeTree()
        }
    }

    public func layout(forVersion v: Int) -> [Symbol]? {
        return layoutHistory[v]
    }

    // MARK: - Class precedence list (ANSI CLOS topological sort)

    public static func computeCPL(_ c: LispClass) throws -> [LispClass] {
        var all: [LispClass] = []
        func gather(_ k: LispClass) {
            if all.contains(where: { $0 === k }) { return }
            all.append(k)
            for s in k.directSuperclasses { gather(s) }
        }
        gather(c)

        // Local precedence order pairs: (a must precede b).
        var pairs: [(LispClass, LispClass)] = []
        for k in all {
            var prev = k
            for s in k.directSuperclasses {
                pairs.append((prev, s))
                prev = s
            }
        }

        var result: [LispClass] = []
        var remaining = all

        while !remaining.isEmpty {
            // Candidates: classes with no unplaced predecessor.
            var candidates: [LispClass] = []
            for n in remaining {
                var blocked = false
                for (a, b) in pairs where b === n {
                    if remaining.contains(where: { $0 === a }) {
                        blocked = true
                        break
                    }
                }
                if !blocked { candidates.append(n) }
            }
            if candidates.isEmpty {
                throw CompileError(
                    "inconsistent class precedence for \(c.name.name)")
            }
            var chosen = candidates[0]
            if candidates.count > 1 {
                // Choose the candidate with a direct subclass rightmost in the
                // partial CPL.
                outer: for placed in result.reversed() {
                    for cand in candidates {
                        if placed.directSuperclasses.contains(where: { $0 === cand }) {
                            chosen = cand
                            break outer
                        }
                    }
                }
            }
            result.append(chosen)
            remaining.removeAll { $0 === chosen }
        }
        return result
    }
}

/// An instance of a standard (or structure / condition) class.
public final class StandardInstance {
    public var clazz: LispClass
    /// Instance-allocated slot storage; nil = unbound.
    public var slots: [LispValue?]
    public var version: Int

    public init(clazz: LispClass) {
        self.clazz = clazz
        self.slots = [LispValue?](repeating: nil, count: clazz.instanceSlotCount)
        self.version = clazz.version
    }
}
