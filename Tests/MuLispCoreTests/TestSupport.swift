// TestSupport.swift

import XCTest
@testable import MuLispCore

extension XCTestCase {

    /// Evaluate source and return the printed principal value.
    func ev(_ interp: Interpreter, _ source: String,
            file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            let v = try interp.evalAll(source)
            return Printer.toString(v.firstValue, escape: true, interp: interp)
        } catch let e as LispError {
            XCTFail("Lisp error: \(e.message) for \(source)",
                    file: file, line: line)
            return "<error>"
        } catch {
            XCTFail("error: \(error) for \(source)", file: file, line: line)
            return "<error>"
        }
    }

    /// Evaluate and expect a LispError; returns its message.
    func evError(_ interp: Interpreter, _ source: String,
                 file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            _ = try interp.evalAll(source)
            XCTFail("expected an error for \(source)", file: file, line: line)
            return ""
        } catch let e as LispError {
            return e.message
        } catch {
            XCTFail("unexpected error kind: \(error)", file: file, line: line)
            return ""
        }
    }

    func assertBootOK(_ interp: Interpreter,
                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(interp.bootError,
                     "bootstrap failed: \(interp.bootError ?? "")",
                     file: file, line: line)
    }
}
