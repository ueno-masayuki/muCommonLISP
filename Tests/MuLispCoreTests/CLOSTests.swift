// CLOSTests.swift
// Classes, generic functions, method combination, redefinition, structs.

import XCTest
@testable import MuLispCore

final class CLOSTests: XCTestCase {
    let interp = Interpreter()

    func testDefclassAndAccessors() {
        XCTAssertEqual(ev(interp, """
            (defclass point ()
              ((x :initarg :x :initform 0 :accessor point-x)
               (y :initarg :y :initform 0 :accessor point-y)))
            (defparameter *p* (make-instance 'point :x 3 :y 4))
            (list (point-x *p*) (point-y *p*))
            """), "(3 4)")
        XCTAssertEqual(ev(interp, """
            (setf (point-x *p*) 30)
            (point-x *p*)
            """), "30")
        XCTAssertEqual(ev(interp, "(slot-value *p* 'y)"), "4")
        XCTAssertEqual(ev(interp, """
            (setf (slot-value *p* 'y) 40)
            (slot-value *p* 'y)
            """), "40")
        XCTAssertEqual(ev(interp, "(typep *p* 'point)"), "T")
        XCTAssertEqual(ev(interp, "(typep *p* 'standard-object)"), "T")
        XCTAssertEqual(ev(interp, "(class-name (class-of *p*))"), "POINT")
    }

    func testInitforms() {
        XCTAssertEqual(ev(interp, """
            (defclass counter ()
              ((n :initform 100 :accessor counter-n)))
            (counter-n (make-instance 'counter))
            """), "100")
        XCTAssertEqual(ev(interp, """
            (slot-boundp (make-instance 'point) 'x)
            """), "T")
        XCTAssertEqual(ev(interp, """
            (defclass empty-slots () ((u)))
            (slot-boundp (make-instance 'empty-slots) 'u)
            """), "NIL")
    }

    func testInheritanceAndCPL() {
        XCTAssertEqual(ev(interp, """
            (defclass animal () ((name :initarg :name :accessor name-of)))
            (defclass dog (animal) ())
            (defparameter *d* (make-instance 'dog :name "pochi"))
            (name-of *d*)
            """), "\"pochi\"")
        XCTAssertEqual(ev(interp, "(typep *d* 'animal)"), "T")
    }

    func testMultipleInheritance() {
        XCTAssertEqual(ev(interp, """
            (defclass a () ((s :initform 'from-a :accessor s-of)))
            (defclass b () ((s :initform 'from-b :accessor s-of)))
            (defclass c (a b) ())
            (s-of (make-instance 'c))
            """), "FROM-A")
        XCTAssertEqual(ev(interp, """
            (defclass c2 (b a) ())
            (s-of (make-instance 'c2))
            """), "FROM-B")
    }

    func testGenericDispatch() {
        XCTAssertEqual(ev(interp, """
            (defgeneric speak (x))
            (defmethod speak ((x integer)) 'int)
            (defmethod speak ((x string)) 'str)
            (defmethod speak ((x t)) 'any)
            (list (speak 1) (speak "s") (speak 'sym))
            """), "(INT STR ANY)")
    }

    func testMultipleDispatch() {
        XCTAssertEqual(ev(interp, """
            (defgeneric combine (a b))
            (defmethod combine ((a integer) (b integer)) 'ii)
            (defmethod combine ((a integer) (b string)) 'is)
            (defmethod combine ((a t) (b t)) 'tt)
            (list (combine 1 2) (combine 1 "x") (combine "x" "y"))
            """), "(II IS TT)")
    }

    func testEqlSpecializer() {
        XCTAssertEqual(ev(interp, """
            (defgeneric fact2 (n))
            (defmethod fact2 ((n (eql 0))) 1)
            (defmethod fact2 ((n integer)) (* n (fact2 (- n 1))))
            (fact2 5)
            """), "120")
    }

    func testMethodCombination() {
        XCTAssertEqual(ev(interp, """
            (defparameter *trace* nil)
            (defclass base () ())
            (defclass derived (base) ())
            (defgeneric visit (x))
            (defmethod visit ((x base)) (push 'base-primary *trace*) 'base)
            (defmethod visit ((x derived))
              (push 'derived-primary *trace*)
              (call-next-method))
            (defmethod visit :before ((x base)) (push 'before-base *trace*))
            (defmethod visit :before ((x derived)) (push 'before-derived *trace*))
            (defmethod visit :after ((x base)) (push 'after-base *trace*))
            (defmethod visit :after ((x derived)) (push 'after-derived *trace*))
            (defmethod visit :around ((x derived))
              (push 'around-start *trace*)
              (prog1 (call-next-method)
                (push 'around-end *trace*)))
            (let ((result (visit (make-instance 'derived))))
              (list result (reverse *trace*)))
            """),
            "(BASE (AROUND-START BEFORE-DERIVED BEFORE-BASE DERIVED-PRIMARY "
            + "BASE-PRIMARY AFTER-BASE AFTER-DERIVED AROUND-END))")
    }

    func testCallNextMethodAndNextMethodP() {
        XCTAssertEqual(ev(interp, """
            (defgeneric nm (x))
            (defmethod nm ((x integer)) (if (next-method-p) 'has 'none))
            (nm 1)
            """), "NONE")
    }

    func testInitializeInstanceAfterMethod() {
        XCTAssertEqual(ev(interp, """
            (defclass widget ()
              ((w :initarg :w :initform 1 :accessor widget-w)
               (area :accessor widget-area)))
            (defmethod initialize-instance :after ((obj widget) &rest initargs)
              (setf (widget-area obj) (* (widget-w obj) 10)))
            (widget-area (make-instance 'widget :w 5))
            """), "50")
    }

    func testPrintObject() {
        XCTAssertEqual(ev(interp, """
            (defclass money () ((yen :initarg :yen)))
            (defmethod print-object ((m money) stream)
              (format stream "#<MONEY ~A yen>" (slot-value m 'yen)))
            (prin1-to-string (make-instance 'money :yen 100))
            """), "\"#<MONEY 100 yen>\"")
    }

    func testClassRedefinition() {
        XCTAssertEqual(ev(interp, """
            (defclass versioned () ((a :initform 1 :accessor v-a)))
            (defparameter *inst* (make-instance 'versioned))
            (defclass versioned ()
              ((a :initform 1 :accessor v-a)
               (b :initform 42 :accessor v-b)))
            (v-b *inst*)
            """), "42")
        XCTAssertEqual(ev(interp, "(v-a *inst*)"), "1")
    }

    func testChangeClass() {
        XCTAssertEqual(ev(interp, """
            (defclass shape-a () ((size :initarg :size :initform 1 :accessor size-of)))
            (defclass shape-b () ((size :initarg :size :initform 2 :accessor size-of)
                                  (extra :initform 'yes :accessor extra-of)))
            (defparameter *sh* (make-instance 'shape-a :size 9))
            (change-class *sh* 'shape-b)
            (list (size-of *sh*) (extra-of *sh*) (typep *sh* 'shape-b))
            """), "(9 YES T)")
    }

    func testClassAllocation() {
        XCTAssertEqual(ev(interp, """
            (defclass shared-slot ()
              ((n :initform 0 :accessor ss-n :allocation :class)))
            (defparameter *s1* (make-instance 'shared-slot))
            (defparameter *s2* (make-instance 'shared-slot))
            (setf (ss-n *s1*) 77)
            (ss-n *s2*)
            """), "77")
    }

    func testWithSlotsAndAccessors() {
        XCTAssertEqual(ev(interp, """
            (defclass rec () ((f :initform 3 :accessor rec-f)))
            (defparameter *r* (make-instance 'rec))
            (with-slots (f) *r*
              (setf f (* f 2))
              f)
            """), "6")
        XCTAssertEqual(ev(interp, """
            (with-accessors ((f rec-f)) *r*
              (incf f)
              f)
            """), "7")
    }

    func testDefstruct() {
        XCTAssertEqual(ev(interp, """
            (defstruct pt (x 0) (y 0))
            (defparameter *q* (make-pt :x 5))
            (list (pt-x *q*) (pt-y *q*) (pt-p *q*) (pt-p 42))
            """), "(5 0 T NIL)")
        XCTAssertEqual(ev(interp, """
            (setf (pt-y *q*) 9)
            (pt-y *q*)
            """), "9")
        XCTAssertEqual(ev(interp, """
            (defparameter *q2* (copy-pt *q*))
            (setf (pt-x *q2*) 100)
            (list (pt-x *q*) (pt-x *q2*))
            """), "(5 100)")
        XCTAssertEqual(ev(interp, """
            (defstruct (pt3 (:include pt)) (z 1))
            (defparameter *q3* (make-pt3 :x 7 :z 2))
            (list (pt-x *q3*) (pt3-z *q3*) (pt-p *q3*))
            """), "(7 2 T)")
    }

    func testConditionClassesAreClasses() {
        XCTAssertEqual(ev(interp, """
            (defclass my-error (error) ((code :initarg :code :reader my-error-code)))
            (handler-case (error 'my-error :code 42 :message "boom")
              (my-error (e) (my-error-code e)))
            """), "42")
    }
}
