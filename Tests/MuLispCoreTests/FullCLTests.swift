// FullCLTests.swift
// Tests for the extended Common Lisp coverage: numeric tower, mutable
// strings, arrays, control flow, restarts, LOOP/FORMAT extensions, MOP,
// method combinations, packages, files.

import XCTest
@testable import MuLispCore

final class NumericTowerTests: XCTestCase {
    let interp = Interpreter()

    func testBignums() {
        XCTAssertEqual(ev(interp, "(* 1000000000000 1000000000000)"),
                       "1000000000000000000000000")
        XCTAssertEqual(ev(interp, "(expt 2 100)"),
                       "1267650600228229401496703205376")
        XCTAssertEqual(ev(interp, "(+ most-positive-fixnum 1)"),
                       "9223372036854775808")
        XCTAssertEqual(ev(interp, "(integerp (expt 2 100))"), "T")
        XCTAssertEqual(ev(interp, "(- (+ most-positive-fixnum 1) 1)"),
                       "9223372036854775807")
        XCTAssertEqual(ev(interp, """
            (defun fact (n) (if (= n 0) 1 (* n (fact (1- n)))))
            (fact 25)
            """), "15511210043330985984000000")
    }

    func testRatios() {
        XCTAssertEqual(ev(interp, "(/ 1 3)"), "1/3")
        XCTAssertEqual(ev(interp, "(+ 1/2 1/3)"), "5/6")
        XCTAssertEqual(ev(interp, "(* 2/3 3/2)"), "1")
        XCTAssertEqual(ev(interp, "(- 1/2 1/2)"), "0")
        XCTAssertEqual(ev(interp, "(numerator 3/4)"), "3")
        XCTAssertEqual(ev(interp, "(denominator 3/4)"), "4")
        XCTAssertEqual(ev(interp, "(< 1/3 1/2)"), "T")
        XCTAssertEqual(ev(interp, "(float 1/2)"), "0.5")
        XCTAssertEqual(ev(interp, "(floor 7/2)"), "3")
        XCTAssertEqual(ev(interp, "(typep 1/2 'ratio)"), "T")
        XCTAssertEqual(ev(interp, "(typep 1/2 'rational)"), "T")
        XCTAssertEqual(ev(interp, "(+ 1/2 0.5)"), "1.0")
    }

    func testComplex() {
        XCTAssertEqual(ev(interp, "#C(1 2)"), "#C(1 2)")
        XCTAssertEqual(ev(interp, "(complex 1 2)"), "#C(1 2)")
        XCTAssertEqual(ev(interp, "(realpart #C(3 4))"), "3")
        XCTAssertEqual(ev(interp, "(imagpart #C(3 4))"), "4")
        XCTAssertEqual(ev(interp, "(+ #C(1 2) #C(3 4))"), "#C(4 6)")
        XCTAssertEqual(ev(interp, "(* #C(0 1) #C(0 1))"), "-1")
        XCTAssertEqual(ev(interp, "(sqrt -4)"), "#C(0.0 2.0)")
        XCTAssertEqual(ev(interp, "(abs #C(3 4))"), "5.0")
        XCTAssertEqual(ev(interp, "(conjugate #C(1 2))"), "#C(1 -2)")
        XCTAssertEqual(ev(interp, "(complex 5 0)"), "5")
        XCTAssertEqual(ev(interp, "(= #C(1 2) #C(1 2))"), "T")
    }

    func testFloorFamily() {
        XCTAssertEqual(ev(interp,
            "(multiple-value-bind (q r) (floor -7 2) (list q r))"), "(-4 1)")
        XCTAssertEqual(ev(interp,
            "(multiple-value-bind (q r) (ceiling 7 2) (list q r))"), "(4 -1)")
        XCTAssertEqual(ev(interp,
            "(multiple-value-bind (q r) (truncate -7 2) (list q r))"),
            "(-3 -1)")
        XCTAssertEqual(ev(interp, "(round 5/2)"), "2")
        XCTAssertEqual(ev(interp, "(round 7/2)"), "4")
    }
}

final class DataTypeTests: XCTestCase {
    let interp = Interpreter()

    func testMutableStrings() {
        XCTAssertEqual(ev(interp, """
            (defparameter *s* (make-string 3 :initial-element #\\a))
            *s*
            """), "\"aaa\"")
        XCTAssertEqual(ev(interp, """
            (setf (char *s* 1) #\\b)
            *s*
            """), "\"aba\"")
        XCTAssertEqual(ev(interp, "(string-left-trim \" \" \"  hi \")"),
                       "\"hi \"")
        XCTAssertEqual(ev(interp, "(string-right-trim \" \" \"  hi \")"),
                       "\"  hi\"")
        XCTAssertEqual(ev(interp, "(char-name #\\Space)"), "\"Space\"")
        XCTAssertEqual(ev(interp, "(name-char \"Newline\")"), "#\\Newline")
    }

    func testMultidimensionalArrays() {
        XCTAssertEqual(ev(interp, """
            (defparameter *a* (make-array '(2 3) :initial-element 0))
            (array-dimensions *a*)
            """), "(2 3)")
        XCTAssertEqual(ev(interp, """
            (setf (aref *a* 1 2) 42)
            (aref *a* 1 2)
            """), "42")
        XCTAssertEqual(ev(interp, "(array-rank *a*)"), "2")
        XCTAssertEqual(ev(interp, "(array-total-size *a*)"), "6")
        XCTAssertEqual(ev(interp, "(aref #2A((1 2) (3 4)) 1 0)"), "3")
    }

    func testFillPointers() {
        XCTAssertEqual(ev(interp, """
            (defparameter *v* (make-array 5 :fill-pointer 0))
            (vector-push 'a *v*)
            (vector-push 'b *v*)
            (length *v*)
            """), "2")
        XCTAssertEqual(ev(interp, "(vector-pop *v*)"), "B")
        XCTAssertEqual(ev(interp, "(fill-pointer *v*)"), "1")
        XCTAssertEqual(ev(interp, """
            (vector-push-extend 'c *v*)
            (concatenate 'list *v*)
            """), "(A C)")
    }

    func testSequenceFunctions() {
        XCTAssertEqual(ev(interp, "(substitute 0 1 '(1 2 1 3))"), "(0 2 0 3)")
        XCTAssertEqual(ev(interp, "(mismatch \"abcd\" \"abXd\")"), "2")
        XCTAssertEqual(ev(interp,
            "(merge 'list '(1 3 5) '(2 4) #'<)"), "(1 2 3 4 5)")
        XCTAssertEqual(ev(interp,
            "(map 'vector #'1+ '(1 2 3))"), "#(2 3 4)")
        XCTAssertEqual(ev(interp, "(adjoin 1 '(1 2))"), "(1 2)")
        XCTAssertEqual(ev(interp, "(adjoin 0 '(1 2))"), "(0 1 2)")
        XCTAssertEqual(ev(interp,
            "(subst 'x 'a '(a (b a) c))"), "(X (B X) C)")
        XCTAssertEqual(ev(interp, "(find-if-not #'evenp '(2 4 5))"), "5")
        XCTAssertEqual(ev(interp,
            "(let ((l (list 1 2 3))) (fill l 0) l)"), "(0 0 0)")
        XCTAssertEqual(ev(interp, "(copy-tree '(1 (2 3)))"), "(1 (2 3))")
        XCTAssertEqual(ev(interp, "(tree-equal '(1 (2)) '(1 (2)))"), "T")
    }

    func testPlaceMacros() {
        // Single evaluation of place subforms.
        XCTAssertEqual(ev(interp, """
            (defparameter *calls* 0)
            (defparameter *vec* (vector (list 1 2)))
            (defun get-vec () (incf *calls*) *vec*)
            (push 0 (aref (get-vec) 0))
            (list *calls* (aref *vec* 0))
            """), "(1 (0 1 2))")
        XCTAssertEqual(ev(interp, """
            (let ((a 1) (b 2))
              (rotatef a b)
              (list a b))
            """), "(2 1)")
        XCTAssertEqual(ev(interp, """
            (let ((a 1) (b 2) (c 3))
              (list (shiftf a b c 99) a b c))
            """), "(1 2 3 99)")
        XCTAssertEqual(ev(interp, """
            (let ((pl (list :a 1)))
              (setf (getf pl :b) 2)
              (getf pl :b))
            """), "2")
        XCTAssertEqual(ev(interp, """
            (let ((l '(1 2)))
              (pushnew 1 l)
              (pushnew 3 l)
              l)
            """), "(3 1 2)")
    }
}

final class ControlFlowTests: XCTestCase {
    let interp = Interpreter()

    func testTagbodyGo() {
        XCTAssertEqual(ev(interp, """
            (let ((n 0) (acc nil))
              (tagbody
                 top
                 (push n acc)
                 (incf n)
                 (when (< n 4) (go top)))
              (reverse acc))
            """), "(0 1 2 3)")
        XCTAssertEqual(ev(interp, """
            (let ((out nil))
              (tagbody
                 (push 'a out)
                 (go skip)
                 (push 'b out)
                 skip
                 (push 'c out))
              (reverse out))
            """), "(A C)")
    }

    func testProg() {
        XCTAssertEqual(ev(interp, """
            (prog ((i 0) (acc nil))
               loop
               (when (>= i 3) (return (reverse acc)))
               (push i acc)
               (incf i)
               (go loop))
            """), "(0 1 2)")
    }

    func testRestarts() {
        // An unhandled error propagates when no restart is invoked.
        _ = evError(interp, """
            (restart-case (error "boom")
              (use-value (v) (list 'used v)))
            """)
        XCTAssertEqual(ev(interp, """
            (handler-bind ((error (lambda (c) (invoke-restart 'use-value 42))))
              (restart-case (error "boom")
                (use-value (v) (list 'used v))))
            """), "(USED 42)")
        XCTAssertEqual(ev(interp, """
            (restart-case (invoke-restart 'give-up 7)
              (give-up (n) (* n 2)))
            """), "14")
        XCTAssertEqual(ev(interp, """
            (multiple-value-bind (v aborted)
                (with-simple-restart (bail "stop")
                  (invoke-restart 'bail)
                  'unreached)
              (list v aborted))
            """), "(NIL T)")
        XCTAssertEqual(ev(interp, """
            (handler-case
                (handler-bind ((error (lambda (c) (abort))))
                  (restart-case (error "x")
                    (abort () 'aborted)))
              (error (e) 'propagated))
            """), "ABORTED")
    }

    func testHandlerBindDecline() {
        // A handler that declines lets the error propagate to handler-case.
        XCTAssertEqual(ev(interp, """
            (defparameter *saw* nil)
            (handler-case
                (handler-bind ((error (lambda (c) (setq *saw* t))))
                  (error "boom"))
              (error (e) (list 'caught *saw*)))
            """), "(CAUGHT T)")
    }

    func testCerrorAndWarn() {
        XCTAssertEqual(ev(interp, """
            (handler-bind ((error (lambda (c) (continue))))
              (progn (cerror "keep going" "oops") 'after))
            """), "AFTER")
        XCTAssertEqual(ev(interp, """
            (handler-bind ((warning (lambda (c) (muffle-warning))))
              (progn (warn "noisy") 'done))
            """), "DONE")
    }

    func testMacroletAndSymbolMacros() {
        XCTAssertEqual(ev(interp, """
            (macrolet ((twice (x) `(* 2 ,x)))
              (twice 21))
            """), "42")
        XCTAssertEqual(ev(interp, """
            (define-symbol-macro %%half-pi%% (/ pi 2))
            (< 1.5 %%half-pi%% 1.6)
            """), "T")
    }

    func testProgv() {
        XCTAssertEqual(ev(interp, """
            (defvar *pv* 'global)
            (list (progv '(*pv*) '(local) *pv*) *pv*)
            """), "(LOCAL GLOBAL)")
    }

    func testMultipleValueForms() {
        XCTAssertEqual(ev(interp,
            "(multiple-value-call #'+ (values 1 2) 3 (values 4))"), "10")
        XCTAssertEqual(ev(interp, "(multiple-value-list (floor 7 2))"),
                       "(3 1)")
        XCTAssertEqual(ev(interp,
            "(multiple-value-list (multiple-value-prog1 (values 1 2) 'ignored))"),
            "(1 2)")
        XCTAssertEqual(ev(interp, "(nth-value 1 (floor 7 2))"), "1")
        XCTAssertEqual(ev(interp, """
            (defparameter *mv-a* nil)
            (defparameter *mv-b* nil)
            (multiple-value-setq (*mv-a* *mv-b*) (values 10 20))
            (list *mv-a* *mv-b*)
            """), "(10 20)")
    }

    func testPsetqAndParallelDo() {
        XCTAssertEqual(ev(interp, """
            (let ((a 1) (b 2))
              (psetq a b b a)
              (list a b))
            """), "(2 1)")
        // Parallel DO: sum sees the previous i.
        XCTAssertEqual(ev(interp, """
            (do ((i 0 (1+ i)) (sum 0 (+ sum i)))
                ((> i 4) sum))
            """), "10")
    }
}

final class LoopExtensionTests: XCTestCase {
    let interp = Interpreter()

    func testConditionalClauses() {
        XCTAssertEqual(ev(interp,
            "(loop for i from 1 to 10 when (evenp i) collect i)"),
            "(2 4 6 8 10)")
        XCTAssertEqual(ev(interp,
            "(loop for i from 1 to 5 unless (evenp i) sum i)"), "9")
        XCTAssertEqual(ev(interp, """
            (loop for i from 1 to 4
                  when (evenp i) collect i
                  else collect (- i))
            """), "(-1 2 -3 4)")
    }

    func testIntoAndFinally() {
        XCTAssertEqual(ev(interp, """
            (loop for i from 1 to 5
                  collect i into items
                  sum i into total
                  finally (return (list items total)))
            """), "((1 2 3 4 5) 15)")
    }

    func testAlwaysNeverThereis() {
        XCTAssertEqual(ev(interp,
            "(loop for x in '(2 4 6) always (evenp x))"), "T")
        XCTAssertEqual(ev(interp,
            "(loop for x in '(2 3 6) always (evenp x))"), "NIL")
        XCTAssertEqual(ev(interp,
            "(loop for x in '(1 3 5) never (evenp x))"), "T")
        XCTAssertEqual(ev(interp,
            "(loop for x in '(1 2 3) thereis (and (evenp x) x))"), "2")
    }

    func testDownToAndNamed() {
        XCTAssertEqual(ev(interp,
            "(loop for i from 5 downto 1 collect i)"), "(5 4 3 2 1)")
        XCTAssertEqual(ev(interp,
            "(loop for i downfrom 3 above 0 collect i)"), "(3 2 1)")
        XCTAssertEqual(ev(interp, """
            (loop named outer for i from 1 to 10
                  do (when (= i 3) (return-from outer (* i 100))))
            """), "300")
    }

    func testHashIteration() {
        XCTAssertEqual(ev(interp, """
            (defparameter *h* (make-hash-table))
            (setf (gethash 'a *h*) 1)
            (setf (gethash 'b *h*) 2)
            (sort (loop for k being the hash-keys of *h* collect k)
                  #'string< :key #'symbol-name)
            """), "(A B)")
        XCTAssertEqual(ev(interp, """
            (loop for k being the hash-keys of *h* using (hash-value v)
                  sum v)
            """), "3")
    }

    func testDestructuring() {
        XCTAssertEqual(ev(interp, """
            (loop for (a b) in '((1 2) (3 4)) collect (+ a b))
            """), "(3 7)")
    }

    func testWithAnd() {
        XCTAssertEqual(ev(interp, """
            (loop with a = 1 and b = 2
                  repeat 1
                  collect (+ a b))
            """), "(3)")
    }
}

final class FormatExtensionTests: XCTestCase {
    let interp = Interpreter()

    func testRadixAndEnglish() {
        XCTAssertEqual(ev(interp, "(format nil \"~R\" 42)"), "\"forty-two\"")
        XCTAssertEqual(ev(interp, "(format nil \"~@R\" 1994)"), "\"MCMXCIV\"")
        XCTAssertEqual(ev(interp, "(format nil \"~2R\" 10)"), "\"1010\"")
        XCTAssertEqual(ev(interp, "(format nil \"~:D\" 1234567)"),
                       "\"1,234,567\"")
    }

    func testConditionalsAndCase() {
        XCTAssertEqual(ev(interp,
            "(format nil \"~[zero~;one~;two~]\" 1)"), "\"one\"")
        XCTAssertEqual(ev(interp,
            "(format nil \"~:[no~;yes~]\" t)"), "\"yes\"")
        XCTAssertEqual(ev(interp,
            "(format nil \"~@[value: ~A~]\" 5)"), "\"value: 5\"")
        XCTAssertEqual(ev(interp,
            "(format nil \"~@[value: ~A~]\" nil)"), "\"\"")
        XCTAssertEqual(ev(interp,
            "(format nil \"~(~A~)\" 'hello)"), "\"hello\"")
        XCTAssertEqual(ev(interp,
            "(format nil \"~:(~A~)\" \"foo bar\")"), "\"Foo Bar\"")
    }

    func testPluralsAndMisc() {
        XCTAssertEqual(ev(interp,
            "(format nil \"~D item~:P\" 3)"), "\"3 items\"")
        XCTAssertEqual(ev(interp,
            "(format nil \"~D item~:P\" 1)"), "\"1 item\"")
        XCTAssertEqual(ev(interp, "(format nil \"~A~*~A\" 1 2 3)"), "\"13\"")
        XCTAssertEqual(ev(interp, "(format nil \"~$\" 3.14159)"), "\"3.14\"")
        XCTAssertEqual(ev(interp, "(format nil \"~5D\" 42)"), "\"   42\"")
    }
}

final class MOPAndCombinationTests: XCTestCase {
    let interp = Interpreter()

    func testMOPIntrospection() {
        XCTAssertEqual(ev(interp, """
            (defclass mop-a () ((x :initarg :x)))
            (defclass mop-b (mop-a) ())
            (class-name (car (class-direct-superclasses (find-class 'mop-b))))
            """), "MOP-A")
        XCTAssertEqual(ev(interp, """
            (member (find-class 'mop-a)
                    (class-precedence-list (find-class 'mop-b))
                    :test #'eq)
            """).hasPrefix("(") ? "found" : "missing", "found")
        XCTAssertEqual(ev(interp, """
            (slot-definition-name (car (class-slots (find-class 'mop-a))))
            """), "X")
        XCTAssertEqual(ev(interp, """
            (let ((i (allocate-instance (find-class 'mop-a))))
              (slot-boundp i 'x))
            """), "NIL")
    }

    func testOperatorMethodCombination() {
        XCTAssertEqual(ev(interp, """
            (defclass mc-base () ())
            (defclass mc-sub (mc-base) ())
            (defgeneric score (x) (:method-combination +))
            (defmethod score + ((x mc-base)) 10)
            (defmethod score + ((x mc-sub)) 1)
            (score (make-instance 'mc-sub))
            """), "11")
        XCTAssertEqual(ev(interp, """
            (defgeneric names (x) (:method-combination list))
            (defmethod names list ((x mc-base)) 'base)
            (defmethod names list ((x mc-sub)) 'sub)
            (names (make-instance 'mc-sub))
            """), "(SUB BASE)")
    }

    func testDefineMethodCombination() {
        XCTAssertEqual(ev(interp, """
            (define-method-combination mult :operator *
                                            :identity-with-one-argument t)
            (defclass dm-a () ())
            (defgeneric factor (x) (:method-combination mult))
            (defmethod factor mult ((x dm-a)) 6)
            (defmethod factor mult ((x t)) 7)
            (factor (make-instance 'dm-a))
            """), "42")
    }

    func testDefsetf() {
        XCTAssertEqual(ev(interp, """
            (defparameter *cell* (cons 1 2))
            (defun cell-a () (car *cell*))
            (defun set-cell-a (v) (rplaca *cell* v) v)
            (defsetf cell-a set-cell-a)
            (setf (cell-a) 99)
            (car *cell*)
            """), "99")
    }
}

final class PackageAndIOTests: XCTestCase {
    let interp = Interpreter()

    func testPackages() {
        XCTAssertEqual(ev(interp, """
            (defpackage :mylib (:use :cl) (:export :hello))
            (in-package :mylib)
            (defun hello () 'hi)
            (defun private-fn () 'secret)
            (in-package :cl-user)
            (mylib:hello)
            """), "HI")
        XCTAssertEqual(ev(interp, "(packagep (find-package :mylib))"), "T")
        XCTAssertEqual(ev(interp,
            "(string= (package-name (symbol-package 'mylib:hello)) \"MYLIB\")"),
            "T")
        XCTAssertEqual(ev(interp, """
            (let ((count 0))
              (do-external-symbols (s (find-package :mylib))
                (incf count))
              count)
            """), "1")
    }

    func testFileIO() {
        let tmp = NSTemporaryDirectory() + "mulisp-test-\(UUID().uuidString).txt"
        XCTAssertEqual(ev(interp, """
            (with-open-file (s "\(tmp)" :direction :output)
              (write-line "hello" s)
              (write-line "world" s))
            (with-open-file (s "\(tmp)")
              (list (read-line s) (read-line s) (read-line s nil 'eof)))
            """), "(\"hello\" \"world\" EOF)")
        XCTAssertEqual(ev(interp, "(and (probe-file \"\(tmp)\") t)"), "T")
        XCTAssertEqual(ev(interp, "(delete-file \"\(tmp)\")"), "T")
        XCTAssertEqual(ev(interp, "(probe-file \"\(tmp)\")"), "NIL")
    }

    func testLoad() {
        let tmp = NSTemporaryDirectory() + "mulisp-load-\(UUID().uuidString).lisp"
        try? "(defparameter *loaded-value* 123)\n(defun loaded-fn (x) (* x 2))"
            .write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        XCTAssertEqual(ev(interp, "(load \"\(tmp)\")"), "T")
        XCTAssertEqual(ev(interp, "(loaded-fn *loaded-value*)"), "246")
    }

    func testReadFromStream() {
        XCTAssertEqual(ev(interp, """
            (with-input-from-string (s "(+ 1 2) foo")
              (list (read s) (read s) (read s nil 'done)))
            """), "((+ 1 2) FOO DONE)")
        XCTAssertEqual(ev(interp, """
            (with-input-from-string (s "ab")
              (list (read-char s) (read-char s) (read-char s nil #\\z)))
            """), "(#\\a #\\b #\\z)")
    }

    func testStandardOutputRebinding() {
        XCTAssertEqual(ev(interp, """
            (let ((s (make-string-output-stream)))
              (let ((*standard-output* s))
                (princ "captured"))
              (get-output-stream-string s))
            """), "\"captured\"")
    }

    func testReaderMacro() {
        XCTAssertEqual(ev(interp, """
            (set-macro-character #\\$
              (lambda (stream char)
                (declare (ignore char))
                (list 'dollars (read stream))))
            (car (list $5))
            """), "(DOLLARS 5)")
        XCTAssertEqual(ev(interp, "'#.(+ 1 2)"), "3")
    }

    func testGraphicsWindows() {
        XCTAssertEqual(ev(interp, """
            (defparameter *w* (make-graphics-window :title "test"
                                                    :width 100 :height 80))
            (graphics-window-p *w*)
            """), "T")
        XCTAssertEqual(ev(interp, "(graphics-window-title *w*)"), "\"test\"")
        _ = ev(interp, """
            (draw-line *w* 0 0 50 50)
            (set-color *w* 1 0 0)
            (draw-circle *w* 20 20 5 t)
            """)
        XCTAssertEqual(interp.graphicsWindows.count, 1)
        XCTAssertEqual(interp.graphicsWindows[0].context.snapshot().count, 3)
        XCTAssertEqual(ev(interp,
            "(multiple-value-bind (w h) (canvas-size *w*) (list w h))"),
            "(100.0 80.0)")
        XCTAssertEqual(ev(interp, "(close-graphics-window *w*)"), "NIL")
        XCTAssertEqual(interp.graphicsWindows.count, 0)
    }
}
