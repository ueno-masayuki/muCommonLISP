;;; fullcl-demo.lisp — a tour of the extended Common Lisp features
;;; run: swift run mulisp Examples/fullcl-demo.lisp

(format t "~&== numeric tower ==~%")
(format t "(expt 2 100)   = ~D~%" (expt 2 100))
(format t "(/ 1 3)        = ~A~%" (/ 1 3))
(format t "(+ 1/2 1/3)    = ~A~%" (+ 1/2 1/3))
(format t "(sqrt -4)      = ~A~%" (sqrt -4))
(format t "(* #C(0 1) #C(0 1)) = ~A~%" (* #C(0 1) #C(0 1)))

(format t "~&== format ==~%")
(format t "~R bottles / ~@R / ~:D~%" 99 1994 1234567)
(format t "~D item~:P, ~D item~:P~%" 1 3)
(format t "[~{~A~^, ~}]~%" '(a b c))
(format t "~:[off~;on~] / ~:(~A~)~%" t "hello world")

(format t "~&== loop ==~%")
(format t "evens: ~A~%"
        (loop for i from 1 to 10 when (evenp i) collect i))
(format t "countdown: ~A~%" (loop for i from 5 downto 1 collect i))
(format t "pairs: ~A~%"
        (loop for (a b) in '((1 2) (3 4)) collect (+ a b)))
(let ((h (make-hash-table)))
  (setf (gethash 'x h) 10
        (gethash 'y h) 20)
  (format t "hash sum: ~D~%"
          (loop for k being the hash-keys of h using (hash-value v)
                sum v)))

(format t "~&== tagbody / restarts ==~%")
(let ((n 0))
  (tagbody
     again
     (incf n)
     (when (< n 3) (go again)))
  (format t "tagbody loops: ~D~%" n))

(format t "restart result: ~A~%"
        (handler-bind ((error (lambda (c)
                                (invoke-restart 'use-value 42))))
          (restart-case (error "no value available")
            (use-value (v) v))))

(format t "~&== CLOS method combination ==~%")
(defclass base-cost () ())
(defclass with-tax (base-cost) ())
(defgeneric cost (x) (:method-combination +))
(defmethod cost + ((x base-cost)) 100)
(defmethod cost + ((x with-tax)) 10)
(format t "(cost with-tax) = ~D~%" (cost (make-instance 'with-tax)))

(format t "~&== structures / arrays / strings ==~%")
(defstruct point3 (x 0) (y 0) (z 0))
(let ((p (make-point3 :x 1 :y 2 :z 3)))
  (format t "struct: ~A~%" p))
(let ((grid (make-array '(2 2) :initial-contents '((1 2) (3 4)))))
  (format t "grid: ~A, (aref grid 1 0) = ~A~%" grid (aref grid 1 0)))
(let ((s (make-string 5 :initial-element #\-)))
  (setf (char s 2) #\*)
  (format t "string: ~A~%" s))

(format t "~&done.~%")
