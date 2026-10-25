;;; hello.lisp — first steps

(format t "Hello, muCommonLISP!~%")

(defun greet (name)
  (format t "こんにちは, ~A さん~%" name))

(greet "世界")

(print (mapcar (lambda (x) (* x x)) '(1 2 3 4 5)))
(terpri)
