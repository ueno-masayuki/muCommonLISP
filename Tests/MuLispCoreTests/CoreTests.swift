// CoreTests.swift
// Reader, evaluator, closures, special forms, builtins, format.

import XCTest
@testable import MuLispCore

final class ReaderTests: XCTestCase {
    let interp = Interpreter()

    func testBootstrap() {
        assertBootOK(interp)
    }

    func testNumbers() {
        XCTAssertEqual(ev(interp, "123"), "123")
        XCTAssertEqual(ev(interp, "-7"), "-7")
        XCTAssertEqual(ev(interp, "1.5"), "1.5")
        XCTAssertEqual(ev(interp, "-2.5e2"), "-250.0")
        XCTAssertEqual(ev(interp, "#x10"), "16")
        XCTAssertEqual(ev(interp, "#b101"), "5")
        XCTAssertEqual(ev(interp, "#o17"), "15")
    }

    func testStringsAndChars() {
        XCTAssertEqual(ev(interp, "\"hello\""), "\"hello\"")
        XCTAssertEqual(ev(interp, "#\\a"), "#\\a")
        XCTAssertEqual(ev(interp, "#\\Space"), "#\\Space")
        XCTAssertEqual(ev(interp, "#\\Newline"), "#\\Newline")
    }

    func testQuoteForms() {
        XCTAssertEqual(ev(interp, "'foo"), "FOO")
        XCTAssertEqual(ev(interp, "'(1 2 3)"), "(1 2 3)")
        XCTAssertEqual(ev(interp, "'(1 . 2)"), "(1 . 2)")
        XCTAssertEqual(ev(interp, "''x"), "'X")
        XCTAssertEqual(ev(interp, "'(a . (b . nil))"), "(A B)")
    }

    func testVectorsAndKeywords() {
        XCTAssertEqual(ev(interp, "#(1 2 3)"), "#(1 2 3)")
        XCTAssertEqual(ev(interp, ":foo"), ":FOO")
        XCTAssertEqual(ev(interp, "(eq :a ':a)"), "T")
    }

    func testComments() {
        XCTAssertEqual(ev(interp, "; comment\n 42"), "42")
        XCTAssertEqual(ev(interp, "#| block #| nested |# comment |# 7"), "7")
    }

    func testNumberLikeSymbols() {
        // 1+ and 1- are symbols (standard functions), not numbers.
        XCTAssertEqual(ev(interp, "(1+ 5)"), "6")
        XCTAssertEqual(ev(interp, "(1- 5)"), "4")
        XCTAssertEqual(ev(interp, "(symbol-name '1+)"), "\"1+\"")
        XCTAssertEqual(ev(interp, "(funcall #'1+ 41)"), "42")
        XCTAssertEqual(ev(interp, "'1d0"), "1D0")
        XCTAssertEqual(ev(interp, "123."), "123")
        XCTAssertEqual(ev(interp, ".5"), "0.5")
        XCTAssertEqual(ev(interp, "1.5e2"), "150.0")
    }

    func testSpecialFormsRecognizedFromUserPackage() {
        // These names never appear in the prelude source, so they must have
        // been interned into COMMON-LISP at bootstrap; otherwise the reader
        // would intern them into CL-USER and the compiler would not treat
        // them as special forms.
        XCTAssertEqual(ev(interp, "(catch 'tag-x (throw 'tag-x 9))"), "9")
        XCTAssertEqual(ev(interp, "(defvar *fresh-defvar-test* 3) *fresh-defvar-test*"), "3")
        XCTAssertEqual(ev(interp, "(defparameter *fresh-defparameter* 4)"),
                       "*FRESH-DEFPARAMETER*")
        XCTAssertEqual(ev(interp,
            "(multiple-value-bind (a b) (values 1 2) (+ a b))"), "3")
        XCTAssertEqual(ev(interp, "(flet ((fx () 1)) (fx))"), "1")
        XCTAssertEqual(ev(interp, "(the integer 5)"), "5")
        XCTAssertEqual(ev(interp, "(locally 8)"), "8")
    }
}

final class EvalTests: XCTestCase {
    let interp = Interpreter()

    func testArithmetic() {
        XCTAssertEqual(ev(interp, "(+ 1 2 3)"), "6")
        XCTAssertEqual(ev(interp, "(- 10 3 2)"), "5")
        XCTAssertEqual(ev(interp, "(* 2 3 4)"), "24")
        XCTAssertEqual(ev(interp, "(/ 10 2)"), "5")
        XCTAssertEqual(ev(interp, "(/ 1 2)"), "0.5")
        XCTAssertEqual(ev(interp, "(+ 1.5 2)"), "3.5")
        XCTAssertEqual(ev(interp, "(- 5)"), "-5")
        XCTAssertEqual(ev(interp, "(mod 7 3)"), "1")
        XCTAssertEqual(ev(interp, "(mod -7 3)"), "2")
        XCTAssertEqual(ev(interp, "(expt 2 10)"), "1024")
        XCTAssertEqual(ev(interp, "(max 1 5 3)"), "5")
    }

    func testComparisons() {
        XCTAssertEqual(ev(interp, "(< 1 2 3)"), "T")
        XCTAssertEqual(ev(interp, "(< 1 3 2)"), "NIL")
        XCTAssertEqual(ev(interp, "(= 2 2.0)"), "T")
        XCTAssertEqual(ev(interp, "(>= 3 3 2)"), "T")
        XCTAssertEqual(ev(interp, "(/= 1 2 3)"), "T")
        XCTAssertEqual(ev(interp, "(/= 1 2 1)"), "NIL")
    }

    func testLetAndScope() {
        XCTAssertEqual(ev(interp, "(let ((x 1) (y 2)) (+ x y))"), "3")
        XCTAssertEqual(ev(interp, "(let* ((x 1) (y (+ x 1))) y)"), "2")
        XCTAssertEqual(ev(interp, "(let ((x 1)) (let ((x 2)) x))"), "2")
        XCTAssertEqual(ev(interp, "(let ((x 1)) (let ((x 2))) x)"), "1")
        XCTAssertEqual(ev(interp, "(let ((x 5)) (setq x 9) x)"), "9")
    }

    func testClosures() {
        XCTAssertEqual(ev(interp, """
            (defun make-adder (n) (lambda (x) (+ x n)))
            (funcall (make-adder 10) 5)
            """), "15")
        XCTAssertEqual(ev(interp, """
            (defun make-counter ()
              (let ((n 0))
                (lambda () (setq n (+ n 1)) n)))
            (defparameter *c* (make-counter))
            (funcall *c*)
            (funcall *c*)
            (funcall *c*)
            """), "3")
    }

    func testLambdaLists() {
        XCTAssertEqual(ev(interp, """
            (defun f (a &optional (b 10) (c (* b 2))) (list a b c))
            (f 1)
            """), "(1 10 20)")
        XCTAssertEqual(ev(interp, "(f 1 2)"), "(1 2 4)")
        XCTAssertEqual(ev(interp, "(f 1 2 3)"), "(1 2 3)")
        XCTAssertEqual(ev(interp, """
            (defun g (a &rest rest) (list a rest))
            (g 1 2 3 4)
            """), "(1 (2 3 4))")
        XCTAssertEqual(ev(interp, """
            (defun h (a &key (b 1) c) (list a b c))
            (h 0 :c 9)
            """), "(0 1 9)")
        XCTAssertEqual(ev(interp, """
            (defun opt-p (a &optional (b nil b-p)) (list b b-p))
            (list (opt-p 1) (opt-p 1 2))
            """), "((NIL NIL) (2 T))")
    }

    func testRecursionAndTailCalls() {
        XCTAssertEqual(ev(interp, """
            (defun fact (n) (if (= n 0) 1 (* n (fact (- n 1)))))
            (fact 10)
            """), "3628800")
        XCTAssertEqual(ev(interp, """
            (defun count-down (n) (if (= n 0) 'done (count-down (- n 1))))
            (count-down 1000000)
            """), "DONE")
        XCTAssertEqual(ev(interp, """
            (defun fib (n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
            (fib 20)
            """), "6765")
    }

    func testBlockReturnCatchThrow() {
        XCTAssertEqual(ev(interp, "(block foo (return-from foo 42) 99)"), "42")
        XCTAssertEqual(ev(interp, """
            (defun early (lst)
              (dolist (x lst 'not-found)
                (when (> x 10) (return x))))
            (early '(1 5 20 3))
            """), "20")
        XCTAssertEqual(ev(interp, "(catch 'tag (throw 'tag 7) 1)"), "7")
        XCTAssertEqual(ev(interp, """
            (defparameter *log* nil)
            (catch 'out
              (unwind-protect
                   (throw 'out 1)
                (push 'cleaned *log*)))
            *log*
            """), "(CLEANED)")
    }

    func testMultipleValues() {
        XCTAssertEqual(ev(interp, """
            (multiple-value-bind (a b) (values 1 2) (list a b))
            """), "(1 2)")
        XCTAssertEqual(ev(interp, """
            (multiple-value-bind (q r) (floor 7 2) (list q r))
            """), "(3 1)")
        XCTAssertEqual(ev(interp, "(+ (values 1 2) 10)"), "11")
        XCTAssertEqual(ev(interp, """
            (defun two () (values 3 4))
            (multiple-value-bind (a b) (two) (* a b))
            """), "12")
    }

    func testFletLabels() {
        XCTAssertEqual(ev(interp, """
            (flet ((twice (x) (* 2 x))) (twice 21))
            """), "42")
        XCTAssertEqual(ev(interp, """
            (labels ((even-p (n) (if (= n 0) t (odd-p (- n 1))))
                     (odd-p (n) (if (= n 0) nil (even-p (- n 1)))))
              (even-p 10))
            """), "T")
    }

    func testSpecialVariables() {
        XCTAssertEqual(ev(interp, """
            (defvar *depth* 0)
            (defun show-depth () *depth*)
            (let ((*depth* 5)) (show-depth))
            """), "5")
        XCTAssertEqual(ev(interp, "(show-depth)"), "0")
    }

    func testSetf() {
        XCTAssertEqual(ev(interp, """
            (defparameter *l* (list 1 2 3))
            (setf (car *l*) 99)
            *l*
            """), "(99 2 3)")
        XCTAssertEqual(ev(interp, """
            (setf (nth 1 *l*) 'x)
            *l*
            """), "(99 X 3)")
        XCTAssertEqual(ev(interp, """
            (defparameter *v* (vector 1 2 3))
            (setf (aref *v* 0) 7)
            (aref *v* 0)
            """), "7")
    }

    func testEvalAndApply() {
        XCTAssertEqual(ev(interp, "(eval '(+ 1 2))"), "3")
        XCTAssertEqual(ev(interp, "(apply #'+ 1 2 '(3 4))"), "10")
        XCTAssertEqual(ev(interp, "(funcall #'cons 1 2)"), "(1 . 2)")
        XCTAssertEqual(ev(interp, "(mapcar #'1+ '(1 2 3))"), "(2 3 4)")
    }
}

final class MacroTests: XCTestCase {
    let interp = Interpreter()

    func testDefmacroAndBackquote() {
        XCTAssertEqual(ev(interp, """
            (defmacro swap (a b)
              (let ((tmp (gensym)))
                `(let ((,tmp ,a)) (setq ,a ,b) (setq ,b ,tmp))))
            (defparameter *x* 1)
            (defparameter *y* 2)
            (swap *x* *y*)
            (list *x* *y*)
            """), "(2 1)")
        XCTAssertEqual(ev(interp, "`(1 ,(+ 1 1) ,@(list 3 4))"), "(1 2 3 4)")
        XCTAssertEqual(ev(interp, "`(a . ,(+ 1 1))"), "(A . 2)")
    }

    func testControlMacros() {
        XCTAssertEqual(ev(interp, "(when t 1 2 3)"), "3")
        XCTAssertEqual(ev(interp, "(when nil 1)"), "NIL")
        XCTAssertEqual(ev(interp, "(unless nil 'yes)"), "YES")
        XCTAssertEqual(ev(interp, """
            (cond ((= 1 2) 'a)
                  ((= 1 1) 'b)
                  (t 'c))
            """), "B")
        XCTAssertEqual(ev(interp, "(cond (nil 'a))"), "NIL")
        XCTAssertEqual(ev(interp, """
            (case 3 ((1 2) 'low) ((3 4) 'mid) (otherwise 'high))
            """), "MID")
        XCTAssertEqual(ev(interp, "(and 1 2 3)"), "3")
        XCTAssertEqual(ev(interp, "(and 1 nil 3)"), "NIL")
        XCTAssertEqual(ev(interp, "(or nil nil 5)"), "5")
        XCTAssertEqual(ev(interp, "(or nil nil)"), "NIL")
        XCTAssertEqual(ev(interp, "(typecase 1.5 (integer 'int) (float 'flt))"),
                       "FLT")
    }

    func testIterationMacros() {
        XCTAssertEqual(ev(interp, """
            (let ((sum 0))
              (dotimes (i 5 sum) (setq sum (+ sum i))))
            """), "10")
        XCTAssertEqual(ev(interp, """
            (let ((acc nil))
              (dolist (x '(1 2 3) (reverse acc))
                (push (* x x) acc)))
            """), "(1 4 9)")
        XCTAssertEqual(ev(interp, """
            (do* ((i 0 (1+ i)) (sum 0 (+ sum i)))
                 ((> i 4) sum))
            """), "10")
    }

    func testPlaceMacros() {
        XCTAssertEqual(ev(interp, """
            (defparameter *s* nil)
            (push 1 *s*)
            (push 2 *s*)
            (list (pop *s*) *s*)
            """), "(2 (1))")
        XCTAssertEqual(ev(interp, """
            (defparameter *n* 10)
            (incf *n* 5)
            (decf *n*)
            *n*
            """), "14")
    }

    func testPrognPrognTopLevelMacroUse() {
        // A macro defined inside a top-level PROGN must be usable right away.
        XCTAssertEqual(ev(interp, """
            (progn
              (defmacro my-double (x) `(* 2 ,x))
              (my-double 21))
            """), "42")
    }

    func testSymbolMacrolet() {
        XCTAssertEqual(ev(interp, """
            (let ((lst (list 1 2 3)))
              (symbol-macrolet ((head (car lst)))
                (setf head 42)
                head))
            """), "42")
    }
}

final class BuiltinTests: XCTestCase {
    let interp = Interpreter()

    func testListOps() {
        XCTAssertEqual(ev(interp, "(append '(1 2) '(3) nil '(4))"), "(1 2 3 4)")
        XCTAssertEqual(ev(interp, "(reverse '(1 2 3))"), "(3 2 1)")
        XCTAssertEqual(ev(interp, "(length '(a b c))"), "3")
        XCTAssertEqual(ev(interp, "(nth 1 '(a b c))"), "B")
        XCTAssertEqual(ev(interp, "(last '(1 2 3))"), "(3)")
        XCTAssertEqual(ev(interp, "(butlast '(1 2 3))"), "(1 2)")
        XCTAssertEqual(ev(interp, "(assoc 'b '((a . 1) (b . 2)))"), "(B . 2)")
        XCTAssertEqual(ev(interp, "(member 2 '(1 2 3))"), "(2 3)")
        XCTAssertEqual(ev(interp, "(remove 2 '(1 2 3 2))"), "(1 3)")
        XCTAssertEqual(ev(interp, "(remove-if #'evenp '(1 2 3 4))"), "(1 3)")
        XCTAssertEqual(ev(interp, "(find-if #'oddp '(2 4 5 6))"), "5")
        XCTAssertEqual(ev(interp, "(position 'c '(a b c))"), "2")
        XCTAssertEqual(ev(interp, "(count 1 '(1 2 1 3 1))"), "3")
        XCTAssertEqual(ev(interp, "(sort (list 3 1 2) #'<)"), "(1 2 3)")
        XCTAssertEqual(ev(interp, "(sort (list 3 1 2) #'< :key #'-)"), "(3 2 1)")
        XCTAssertEqual(ev(interp, "(reduce #'+ '(1 2 3 4))"), "10")
        XCTAssertEqual(ev(interp,
            "(reduce #'+ '(1 2 3) :initial-value 10)"), "16")
        XCTAssertEqual(ev(interp, "(subseq '(1 2 3 4) 1 3)"), "(2 3)")
        XCTAssertEqual(ev(interp, "(list* 1 2 '(3 4))"), "(1 2 3 4)")
        XCTAssertEqual(ev(interp,
            "(remove-duplicates '(1 2 1 3 2))"), "(1 3 2)")
        XCTAssertEqual(ev(interp, "(every #'oddp '(1 3 5))"), "T")
        XCTAssertEqual(ev(interp, "(some #'evenp '(1 3 4))"), "T")
    }

    func testEquality() {
        XCTAssertEqual(ev(interp, "(equal '(1 (2 3)) '(1 (2 3)))"), "T")
        XCTAssertEqual(ev(interp, "(eql 1.5 1.5)"), "T")
        XCTAssertEqual(ev(interp, "(equalp \"abc\" \"ABC\")"), "T")
        XCTAssertEqual(ev(interp, "(equal \"abc\" \"ABC\")"), "NIL")
    }

    func testStrings() {
        XCTAssertEqual(ev(interp, "(string-upcase \"abc\")"), "\"ABC\"")
        XCTAssertEqual(ev(interp, "(string= \"ab\" \"ab\")"), "T")
        XCTAssertEqual(ev(interp, "(char \"abc\" 1)"), "#\\b")
        XCTAssertEqual(ev(interp, "(concatenate 'string \"foo\" \"bar\")"),
                       "\"foobar\"")
        XCTAssertEqual(ev(interp, "(parse-integer \"42\")"), "42")
        XCTAssertEqual(ev(interp, "(char-code #\\A)"), "65")
        XCTAssertEqual(ev(interp, "(code-char 97)"), "#\\a")
        XCTAssertEqual(ev(interp, "(subseq \"hello\" 1 3)"), "\"el\"")
    }

    func testHashTables() {
        XCTAssertEqual(ev(interp, """
            (defparameter *h* (make-hash-table :test 'equal))
            (setf (gethash "key" *h*) 42)
            (gethash "key" *h*)
            """), "42")
        XCTAssertEqual(ev(interp, "(hash-table-count *h*)"), "1")
        XCTAssertEqual(ev(interp, "(gethash \"nope\" *h* 'missing)"), "MISSING")
        XCTAssertEqual(ev(interp, "(remhash \"key\" *h*)"), "T")
        XCTAssertEqual(ev(interp, "(hash-table-count *h*)"), "0")
    }

    func testSymbolsAndPackages() {
        XCTAssertEqual(ev(interp, "(symbol-name 'foo)"), "\"FOO\"")
        XCTAssertEqual(ev(interp, "(keywordp :k)"), "T")
        XCTAssertEqual(ev(interp, "(eq (intern \"ZOT\") 'zot)"), "T")
        XCTAssertEqual(ev(interp, "(string= (symbol-name (gensym)) (symbol-name (gensym)))"), "NIL")
    }

    func testTypePredicates() {
        XCTAssertEqual(ev(interp, "(typep 1 'integer)"), "T")
        XCTAssertEqual(ev(interp, "(typep 1 'number)"), "T")
        XCTAssertEqual(ev(interp, "(typep 1.0 'integer)"), "NIL")
        XCTAssertEqual(ev(interp, "(typep nil 'list)"), "T")
        XCTAssertEqual(ev(interp, "(typep '(1) 'cons)"), "T")
        XCTAssertEqual(ev(interp, "(typep \"s\" 'string)"), "T")
        XCTAssertEqual(ev(interp, "(typep 5 '(or string integer))"), "T")
        XCTAssertEqual(ev(interp, "(typep 5 '(integer 0 10))"), "T")
        XCTAssertEqual(ev(interp, "(typep 50 '(integer 0 10))"), "NIL")
        XCTAssertEqual(ev(interp, "(type-of 1)"), "INTEGER")
    }
}

final class FormatTests: XCTestCase {
    let interp = Interpreter()

    func testBasics() {
        XCTAssertEqual(ev(interp, "(format nil \"~A\" 42)"), "\"42\"")
        XCTAssertEqual(ev(interp, "(format nil \"~S\" \"x\")"), "\"\\\"x\\\"\"")
        XCTAssertEqual(ev(interp, "(format nil \"~D + ~D\" 1 2)"), "\"1 + 2\"")
        XCTAssertEqual(ev(interp, "(format nil \"~,2F\" 3.14159)"), "\"3.14\"")
        // ~% emits a real newline; PRIN1 does not escape newlines in strings.
        XCTAssertEqual(ev(interp, "(format nil \"a~%b\")"), "\"a\nb\"")
        XCTAssertEqual(ev(interp, "(format nil \"~~\")"), "\"~\"")
        XCTAssertEqual(ev(interp, "(format nil \"~X\" 255)"), "\"FF\"")
    }

    func testIteration() {
        XCTAssertEqual(ev(interp, "(format nil \"~{~A~^, ~}\" '(1 2 3))"),
                       "\"1, 2, 3\"")
        XCTAssertEqual(ev(interp, "(format nil \"~{[~A]~}\" '(a b))"),
                       "\"[A][B]\"")
    }

    func testPrintToString() {
        XCTAssertEqual(ev(interp, "(princ-to-string '(1 \"a\"))"), "\"(1 a)\"")
        XCTAssertEqual(ev(interp, "(prin1-to-string '(1 \"a\"))"),
                       "\"(1 \\\"a\\\")\"")
    }

    func testWithOutputToString() {
        XCTAssertEqual(ev(interp, """
            (with-output-to-string (s)
              (write-string "ab" s)
              (princ 3 s))
            """), "\"ab3\"")
    }
}
