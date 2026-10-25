;;; factorial.lisp — recursion, iteration, higher-order functions

(defun fact-rec (n)
  "Classic recursion."
  (if (<= n 1) 1 (* n (fact-rec (1- n)))))

(defun fact-loop (n)
  "LOOP version."
  (loop with acc = 1
        for i from 2 to n
        do (setq acc (* acc i))
        finally (return acc)))

(defun fact-reduce (n)
  "REDUCE version."
  (reduce #'* (loop for i from 1 to n collect i) :initial-value 1))

(format t "fact-rec(10)    = ~D~%" (fact-rec 10))
(format t "fact-loop(10)   = ~D~%" (fact-loop 10))
(format t "fact-reduce(10) = ~D~%" (fact-reduce 10))

;; Tail-recursive version runs in constant stack:
(defun fact-tail (n acc)
  (if (<= n 1) acc (fact-tail (1- n) (* n acc))))
(format t "fact-tail(15)   = ~D~%" (fact-tail 15 1))
