// Conditions.swift
// Swift-level error types used for non-local exits and the Lisp condition system.

import Foundation

/// A signalled Lisp condition (ERROR etc.). `condition` is usually a CLOS
/// instance of a subclass of CONDITION; `message` is a preformatted
/// human-readable description.
public struct LispError: Error {
    public let condition: LispValue
    public let message: String
    public init(condition: LispValue, message: String) {
        self.condition = condition
        self.message = message
    }
}

/// CATCH / THROW.
public struct LispThrowSignal: Error {
    public let tag: LispValue
    public let value: LispValue
}

/// BLOCK / RETURN-FROM.
public struct BlockReturnSignal: Error {
    public let token: BlockToken
    public let value: LispValue
}

/// User pressed the stop button / Ctrl-C. Not catchable by HANDLER-CASE.
public struct InterruptSignal: Error {}

/// (EXIT) / (QUIT) was called. The embedding REPL decides what to do.
public struct ExitSignal: Error {
    public let code: Int
    public init(code: Int) { self.code = code }
}

/// Reader errors. `unexpectedEOF` distinguishes "input incomplete, keep
/// reading" (used by the REPL for multi-line input) from genuine syntax errors.
public struct ReaderError: Error {
    public let message: String
    public let unexpectedEOF: Bool
    public init(_ message: String, unexpectedEOF: Bool = false) {
        self.message = message
        self.unexpectedEOF = unexpectedEOF
    }
}
