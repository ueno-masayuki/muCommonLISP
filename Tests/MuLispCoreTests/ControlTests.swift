// ControlTests.swift
// Condition system, LOOP, graphics, disassembler.

import XCTest
@testable import MuLispCore

final class ConditionTests: XCTestCase {
    let interp = Interpreter()

    func testHandlerCase() {
        XCTAssertEqual(ev(interp, """
            (handler-case (error "boom ~A" 1)
              (error (e) 'caught))
            """), "CAUGHT")
        XCTAssertEqual(ev(interp, """
            (handler-case (+ 1 2) (error (e) 'caught))
            """), "3")
        XCTAssertEqual(ev(interp, """
            (handler-case (error "x")
              (type-error (e) 'type)
              (simple-error (e) 'simple)
              (error (e) 'generic))
            """), "SIMPLE")
    }

    func testTypeErrorCondition() {
        XCTAssertEqual(ev(interp, """
            (handler-case (car 5)
              (type-error (e) 'te))
            """), "TE")
        XCTAssertEqual(ev(interp, """
            (handler-case (undefined-function-xyz)
              (undefined-function (e) 'uf))
            """), "UF")
        XCTAssertEqual(ev(interp, """
            (handler-case some-unbound-var-xyz
              (unbound-variable (e) 'uv))
            """), "UV")
        XCTAssertEqual(ev(interp, """
            (handler-case (/ 1 0)
              (division-by-zero (e) 'dbz))
            """), "DBZ")
    }

    func testIgnoreErrors() {
        XCTAssertEqual(ev(interp, "(ignore-errors (error \"x\") 1)"), "NIL")
        XCTAssertEqual(ev(interp, "(ignore-errors 42)"), "42")
    }

    func testUnwindProtectOrder() {
        XCTAssertEqual(ev(interp, """
            (defparameter *order* nil)
            (handler-case
                (unwind-protect
                     (progn (push 'body *order*) (error "x"))
                  (push 'cleanup *order*))
              (error (e) (push 'handler *order*)))
            (reverse *order*)
            """), "(BODY CLEANUP HANDLER)")
    }

    func testConditionSlots() {
        XCTAssertEqual(ev(interp, """
            (handler-case (error 'type-error :datum 5 :expected-type 'string
                                 :message "nope")
              (type-error (e) (slot-value e 'datum)))
            """), "5")
    }

    func testErrorMessageFormatting() {
        XCTAssertEqual(ev(interp, """
            (handler-case (error "value is ~A" 42)
              (error (e) (%condition-message e)))
            """), "\"value is 42\"")
    }
}

final class LoopTests: XCTestCase {
    let interp = Interpreter()

    func testLoopForCollect() {
        XCTAssertEqual(ev(interp,
            "(loop for i from 1 to 5 collect i)"), "(1 2 3 4 5)")
        XCTAssertEqual(ev(interp,
            "(loop for i from 0 below 3 collect i)"), "(0 1 2)")
        XCTAssertEqual(ev(interp,
            "(loop for i from 0 to 10 by 2 collect i)"), "(0 2 4 6 8 10)")
        XCTAssertEqual(ev(interp,
            "(loop for x in '(a b c) collect (list x x))"),
            "((A A) (B B) (C C))")
        XCTAssertEqual(ev(interp,
            "(loop for x on '(1 2 3) collect (length x))"), "(3 2 1)")
    }

    func testLoopSumCount() {
        XCTAssertEqual(ev(interp,
            "(loop for i from 1 to 10 sum i)"), "55")
        XCTAssertEqual(ev(interp,
            "(loop for i from 1 to 10 count (evenp i))"), "5")
        XCTAssertEqual(ev(interp,
            "(loop for x in '(3 1 4 1 5) maximize x)"), "5")
        XCTAssertEqual(ev(interp,
            "(loop for x in '(3 1 4 1 5) minimize x)"), "1")
    }

    func testLoopWhileUntil() {
        XCTAssertEqual(ev(interp, """
            (let ((n 0))
              (loop while (< n 5) do (setq n (1+ n)))
              n)
            """), "5")
        XCTAssertEqual(ev(interp, """
            (let ((n 0))
              (loop until (>= n 3) do (incf n))
              n)
            """), "3")
        XCTAssertEqual(ev(interp,
            "(loop repeat 4 collect 'x)"), "(X X X X)")
    }

    func testLoopEquals() {
        XCTAssertEqual(ev(interp, """
            (loop for i from 1 to 3
                  for sq = (* i i)
                  collect sq)
            """), "(1 4 9)")
        XCTAssertEqual(ev(interp, """
            (loop for x = 1 then (* x 2)
                  while (< x 20)
                  collect x)
            """), "(1 2 4 8 16)")
    }

    func testInfiniteLoopWithReturn() {
        XCTAssertEqual(ev(interp, """
            (let ((n 0))
              (loop
                (incf n)
                (when (> n 9) (return n))))
            """), "10")
        XCTAssertEqual(ev(interp, """
            (loop for i from 0
                  while (< i 100)
                  do (when (= i 5) (return i)))
            """), "5")
    }

    func testLoopWithAndFinally() {
        XCTAssertEqual(ev(interp, """
            (loop with acc = 0
                  for i from 1 to 3
                  do (incf acc i)
                  finally (return (* acc 10)))
            """), "60")
    }
}

final class GraphicsTests: XCTestCase {
    let interp = Interpreter()

    func testDrawCommandsRecorded() {
        _ = ev(interp, """
            (clear-graphics)
            (set-color 1 0 0)
            (set-line-width 2)
            (draw-line 0 0 100 100)
            (draw-rect 10 10 50 30 t)
            (draw-circle 50 50 20)
            (draw-text 5 5 "hello")
            """)
        let cmds = interp.graphics.snapshot()
        XCTAssertEqual(cmds.count, 6)
        if case .line(let x1, _, let x2, _) = cmds[2] {
            XCTAssertEqual(x1, 0)
            XCTAssertEqual(x2, 100)
        } else {
            XCTFail("expected a line command")
        }
    }

    func testSVGExport() {
        _ = ev(interp, """
            (clear-graphics)
            (set-color 0 0 1)
            (draw-circle 30 30 10 t)
            (draw-line 0 0 10 10)
            """)
        let svg = interp.graphics.renderSVG()
        XCTAssertTrue(svg.contains("<svg"))
        XCTAssertTrue(svg.contains("<circle"))
        XCTAssertTrue(svg.contains("<line"))
    }

    func testCanvasSize() {
        interp.graphics.canvasWidth = 800
        interp.graphics.canvasHeight = 400
        XCTAssertEqual(ev(interp,
            "(multiple-value-bind (w h) (canvas-size) (list w h))"),
            "(800.0 400.0)")
    }
}

final class CompilerFeatureTests: XCTestCase {
    let interp = Interpreter()

    func testDisassembleRuns() {
        _ = ev(interp, "(defun dtest (x) (+ x 1))")
        var captured = ""
        interp.outputHandler = { captured += $0 }
        _ = ev(interp, "(disassemble 'dtest)")
        interp.outputHandler = nil
        XCTAssertTrue(captured.contains("RETURN"))
    }

    func testCompileLambda() {
        XCTAssertEqual(ev(interp, """
            (funcall (compile nil '(lambda (x) (* x x))) 7)
            """), "49")
    }

    func testConstantsAndQuote() {
        XCTAssertEqual(ev(interp, "(let ((x 'a)) (eq x 'a))"), "T")
        XCTAssertEqual(ev(interp, "pi"),
                       Printer.formatDouble(Double.pi))
    }

    func testInterrupt() {
        interp.requestInterrupt()
        do {
            _ = try interp.evalAll("(loop (+ 1 1))")
            XCTFail("expected interrupt")
        } catch is InterruptSignal {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        interp.clearInterrupt()
        XCTAssertEqual(ev(interp, "(+ 1 2)"), "3")
    }

    func testDeepRecursionGuard() {
        // Non-tail recursion must fail gracefully, not crash.
        _ = ev(interp, "(defun deep (n) (if (= n 0) 0 (+ 1 (deep (- n 1)))))")
        let msg = evError(interp, "(deep 10000000)")
        XCTAssertTrue(msg.contains("exhausted") || msg.contains("deep"))
    }
}
