;;; bench.lisp — simple performance checks
;;; run: swift run -c release mulisp Examples/bench.lisp

(format t "~&== muCommonLISP benchmarks ==~%")

(defun fib (n)
  (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))

(format t "~&(fib 25):~%")
(time (fib 25))

(defun tak (x y z)
  (if (not (< y x))
      z
      (tak (tak (1- x) y z)
           (tak (1- y) z x)
           (tak (1- z) x y))))

(format t "~&(tak 18 12 6):~%")
(time (tak 18 12 6))

(format t "~&tail-recursive countdown of 5,000,000:~%")
(defun count-down (n) (if (= n 0) 'done (count-down (- n 1))))
(time (count-down 5000000))

(format t "~&LOOP sum of 1..1,000,000:~%")
(time (loop for i from 1 to 1000000 sum i))

(format t "~&sort 10,000 random numbers:~%")
(defparameter *data* (loop repeat 10000 collect (random 1000000)))
(time (progn (sort *data* #'<) 'sorted))

(format t "~&generic dispatch x 100,000:~%")
(defclass gd-a () ())
(defclass gd-b (gd-a) ())
(defgeneric gd (x))
(defmethod gd ((x gd-a)) 1)
(defmethod gd ((x gd-b)) (+ 1 (call-next-method)))
(defparameter *gd-inst* (make-instance 'gd-b))
(time (dotimes (i 100000) (gd *gd-inst*)))

(format t "~&done.~%")
