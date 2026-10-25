;;; suite.lisp — self test suite in Lisp
;;; run: swift run mulisp Examples/suite.lisp
;;; exits with an error (non-zero status) when any check fails.

(defparameter *pass* 0)
(defparameter *fail* 0)

(defmacro check (expect form)
  `(let ((expected ,expect)
         (result (handler-case ,form
                   (error (e) (list 'error (%condition-message e))))))
     (if (equal result expected)
         (incf *pass*)
         (progn
           (incf *fail*)
           (format t "~&FAIL: ~S~%  => ~S~%  expected ~S~%"
                   ',form result expected)))))

;;; --- basics ---
(check 6 (+ 1 2 3))
(check 3628800 (let ((acc 1)) (dotimes (i 10 acc) (setq acc (* acc (1+ i))))))
(check '(1 4 9) (mapcar (lambda (x) (* x x)) '(1 2 3)))
(check 10 (reduce #'+ '(1 2 3 4)))
(check '(1 2 3 4) (append '(1 2) '(3 4)))
(check "ABC" (string-upcase "abc"))
(check 1/2 (/ 1 2))
(check 5 (/ 10 2))
(check 5/6 (+ 1/2 1/3))
(check 265252859812191058636308480000000 (let ((acc 1)) (dotimes (i 30 acc) (setq acc (* acc (1+ i))))))

;;; --- closures / scope ---
(defun make-acc (n) (lambda (x) (setq n (+ n x)) n))
(defparameter *acc* (make-acc 100))
(check 105 (funcall *acc* 5))
(check 115 (funcall *acc* 10))

;;; --- macros ---
(defmacro square (x) `(* ,x ,x))
(check 49 (square 7))
(check '(1 2 3) `(1 ,(+ 1 1) ,@(list 3)))

;;; --- multiple values ---
(check '(3 1) (multiple-value-bind (q r) (floor 7 2) (list q r)))
(check '(1 2) (multiple-value-bind (a b) (values 1 2) (list a b)))

;;; --- loop ---
(check '(1 2 3 4 5) (loop for i from 1 to 5 collect i))
(check 55 (loop for i from 1 to 10 sum i))
(check '(2 4 6) (loop for x in '(1 2 3) collect (* 2 x)))

;;; --- conditions ---
(check 'caught (handler-case (error "boom") (error (e) 'caught)))
(check 'dbz (handler-case (/ 1 0) (division-by-zero (e) 'dbz)))
(check '(body cleanup)
       (let ((log nil))
         (ignore-errors
           (unwind-protect (progn (push 'body log) (error "x"))
             (push 'cleanup log)))
         (reverse log)))

;;; --- CLOS ---
(defclass st-animal () ((name :initarg :name :accessor st-name)))
(defclass st-dog (st-animal) ())
(defgeneric st-speak (x))
(defmethod st-speak ((x st-animal)) 'generic-animal)
(defmethod st-speak ((x st-dog)) (list 'dog (call-next-method)))
(check '(dog generic-animal) (st-speak (make-instance 'st-dog :name "p")))
(check "p" (st-name (make-instance 'st-dog :name "p")))

(defgeneric st-f (n))
(defmethod st-f ((n (eql 0))) 'zero)
(defmethod st-f ((n integer)) 'nonzero)
(check 'zero (st-f 0))
(check 'nonzero (st-f 5))

(defstruct st-pt (x 0) (y 0))
(check 3 (st-pt-x (make-st-pt :x 3)))
(check t (st-pt-p (make-st-pt)))

;;; --- method combination order ---
(defparameter *mc* nil)
(defclass mc-a () ())
(defgeneric mc-run (x))
(defmethod mc-run ((x mc-a)) (push 'primary *mc*) 'ok)
(defmethod mc-run :before ((x mc-a)) (push 'before *mc*))
(defmethod mc-run :after ((x mc-a)) (push 'after *mc*))
(check 'ok (mc-run (make-instance 'mc-a)))
(check '(before primary after) (reverse *mc*))

;;; --- full CL extensions ---
(check '(2 4 6 8 10) (loop for i from 1 to 10 when (evenp i) collect i))
(check '(5 4 3 2 1) (loop for i from 5 downto 1 collect i))
(check '(3 7) (loop for (a b) in '((1 2) (3 4)) collect (+ a b)))
(check "forty-two" (format nil "~R" 42))
(check "1,234,567" (format nil "~:D" 1234567))
(check "yes" (format nil "~:[no~;yes~]" t))
(check 42 (handler-bind ((error (lambda (c) (invoke-restart 'use-value 42))))
            (restart-case (error "x") (use-value (v) v))))
(check 3 (let ((n 0)) (tagbody top (incf n) (when (< n 3) (go top))) n))
(check #C(0.0 2.0) (sqrt -4))
(check 1267650600228229401496703205376 (expt 2 100))
(check "a*c" (let ((s (make-string 3 :initial-element #\a)))
               (setf (char s 1) #\*)
               (setf (char s 2) #\c)
               s))
(check 42 (let ((a (make-array '(2 2) :initial-element 0)))
            (setf (aref a 1 1) 42)
            (aref a 1 1)))
(check '(2 1) (let ((x 1) (y 2)) (rotatef x y) (list x y)))
(check 11 (progn (defclass sc-a () ())
                 (defclass sc-b (sc-a) ())
                 (defgeneric sc (x) (:method-combination +))
                 (defmethod sc + ((x sc-a)) 10)
                 (defmethod sc + ((x sc-b)) 1)
                 (sc (make-instance 'sc-b))))

;;; --- report ---
(format t "~&== suite: ~D passed, ~D failed ==~%" *pass* *fail*)
(when (> *fail* 0)
  (error "test suite failed: ~D failure(s)" *fail*))
(format t "all tests passed~%")
