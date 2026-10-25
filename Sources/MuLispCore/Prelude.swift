// Prelude.swift
// The standard library written in Lisp itself, loaded at startup.

import Foundation

enum Prelude {
    static let source = """
;;; muCommonLISP prelude

(defmacro when (test &rest body)
  `(if ,test (progn ,@body) nil))

(defmacro unless (test &rest body)
  `(if ,test nil (progn ,@body)))

(defmacro return (&rest value)
  `(return-from nil ,(if value (car value) nil)))

(defmacro cond (&rest clauses)
  (if (null clauses)
      nil
      (let ((clause (car clauses)))
        (if (not (consp clause))
            (error "malformed cond clause")
            (if (null (cdr clause))
                `(or ,(car clause) (cond ,@(cdr clauses)))
                (if (eq (car clause) 't)
                    `(progn ,@(cdr clause))
                    `(if ,(car clause)
                         (progn ,@(cdr clause))
                         (cond ,@(cdr clauses)))))))))

(defmacro prog1 (first &rest body)
  (let ((v (gensym "V")))
    `(let ((,v ,first)) ,@body ,v)))

(defmacro prog2 (a b &rest body)
  (let ((v (gensym "V")))
    `(progn ,a (let ((,v ,b)) ,@body ,v))))

;;; NOTE: push/pop/incf/decf/pushnew/rotatef/shiftf/remf are implemented as
;;; built-in macros with single evaluation of place subforms.

(defmacro psetq (&rest pairs)
  (let ((temps nil)
        (sets nil)
        (rest pairs))
    (%while (consp rest)
      (let ((var (car rest))
            (val (cadr rest))
            (tmp (gensym "PSETQ")))
        (push (list tmp val) temps)
        (push (list 'setq var tmp) sets)
        (setq rest (cddr rest))))
    `(let ,(reverse temps)
       ,@(reverse sets)
       nil)))

(defmacro dolist (spec &rest body)
  (let ((lst (gensym "LIST")))
    `(block nil
       (let ((,lst ,(cadr spec)))
         (%while (consp ,lst)
           (let ((,(car spec) (car ,lst)))
             ,@body)
           (setq ,lst (cdr ,lst)))
         ,(if (cddr spec)
              `(let ((,(car spec) nil)) ,(caddr spec))
              nil)))))

(defmacro dotimes (spec &rest body)
  (let ((limit (gensym "LIMIT")))
    `(block nil
       (let ((,limit ,(cadr spec))
             (,(car spec) 0))
         (%while (< ,(car spec) ,limit)
           ,@body
           (setq ,(car spec) (1+ ,(car spec))))
         ,(if (cddr spec) (caddr spec) nil)))))

(defmacro do* (bindings end-clause &rest body)
  `(block nil
     (let* ,(mapcar (lambda (b)
                      (if (consp b)
                          (list (car b) (cadr b))
                          (list b nil)))
                    bindings)
       (%while (not ,(car end-clause))
         ,@body
         ,@(mapcan (lambda (b)
                     (if (and (consp b) (cddr b))
                         (list `(setq ,(car b) ,(caddr b)))
                         nil))
                   bindings))
       (progn ,@(cdr end-clause)))))

;; DO steps its variables in parallel (via PSETQ).
(defmacro do (bindings end-clause &rest body)
  `(block nil
     (let ,(mapcar (lambda (b)
                     (if (consp b)
                         (list (car b) (cadr b))
                         (list b nil)))
                   bindings)
       (%while (not ,(car end-clause))
         ,@body
         (psetq ,@(mapcan (lambda (b)
                            (if (and (consp b) (cddr b))
                                (list (car b) (caddr b))
                                nil))
                          bindings)))
       (progn ,@(cdr end-clause)))))

(defmacro prog (bindings &rest body)
  `(block nil (let ,bindings (tagbody ,@body))))

(defmacro prog* (bindings &rest body)
  `(block nil (let* ,bindings (tagbody ,@body))))

(defmacro nth-value (n form)
  `(nth ,n (multiple-value-list ,form)))

(defmacro multiple-value-list (form)
  `(multiple-value-call #'list ,form))

(defmacro multiple-value-setq (vars form)
  (let ((temps (mapcar (lambda (v) (gensym "MV")) vars)))
    `(multiple-value-bind ,temps ,form
       ,@(mapcar (lambda (v tmp) `(setq ,v ,tmp)) vars temps)
       ,(if temps (car temps) nil))))

(defmacro with-simple-restart (spec &rest body)
  `(restart-case (progn ,@body)
     (,(car spec) () (values nil t))))

(defmacro case (keyform &rest clauses)
  (let ((key (gensym "KEY")))
    `(let ((,key ,keyform))
       (cond ,@(mapcar
                (lambda (clause)
                  (let ((keys (car clause)))
                    (cond ((or (eq keys 't) (eq keys 'otherwise))
                           `(t ,@(cdr clause)))
                          ((consp keys)
                           `((member ,key ',keys) ,@(cdr clause)))
                          (t
                           `((eql ,key ',keys) ,@(cdr clause))))))
                clauses)))))

(defmacro ecase (keyform &rest clauses)
  (let ((key (gensym "KEY")))
    `(let ((,key ,keyform))
       (case ,key
         ,@clauses
         (otherwise (error "ecase: no matching clause for ~S" ,key))))))

(defmacro typecase (keyform &rest clauses)
  (let ((key (gensym "KEY")))
    `(let ((,key ,keyform))
       (cond ,@(mapcar
                (lambda (clause)
                  (if (or (eq (car clause) 't)
                          (eq (car clause) 'otherwise))
                      `(t ,@(cdr clause))
                      `((typep ,key ',(car clause)) ,@(cdr clause))))
                clauses)))))

(defmacro etypecase (keyform &rest clauses)
  (let ((key (gensym "KEY")))
    `(let ((,key ,keyform))
       (typecase ,key
         ,@clauses
         (otherwise (error "etypecase: no matching clause for ~S" ,key))))))

(defmacro with-slots (slots instance &rest body)
  (let ((obj (gensym "OBJ")))
    `(let ((,obj ,instance))
       (symbol-macrolet
           ,(mapcar (lambda (s)
                      (if (consp s)
                          (list (car s) `(slot-value ,obj ',(cadr s)))
                          (list s `(slot-value ,obj ',s))))
                    slots)
         ,@body))))

(defmacro with-accessors (specs instance &rest body)
  (let ((obj (gensym "OBJ")))
    `(let ((,obj ,instance))
       (symbol-macrolet
           ,(mapcar (lambda (s)
                      (list (car s) (list (cadr s) obj)))
                    specs)
         ,@body))))

(defmacro handler-case (form &rest clauses)
  (let ((cv (gensym "C")))
    `(%handler-case
      (lambda () ,form)
      (list ,@(mapcar
               (lambda (clause)
                 (let ((type (car clause))
                       (var-list (cadr clause))
                       (body (cddr clause)))
                   `(list ',type
                          (lambda (,cv)
                            ,(if (consp var-list)
                                 `(let ((,(car var-list) ,cv)) ,@body)
                                 `(progn ,@body))))))
               clauses)))))

(defmacro ignore-errors (&rest body)
  (let ((e (gensym "E")))
    `(handler-case (progn ,@body)
       (error (,e) (values nil ,e)))))

(defmacro assert (test &rest extra)
  `(unless ,test
     (error "Assertion failed: ~S" ',test)))

(defmacro check-type (place type &rest extra)
  `(unless (typep ,place ',type)
     (error 'type-error :datum ,place :expected-type ',type
            :message (format nil "~S is not of type ~S" ,place ',type))))

(defmacro time (form)
  (let ((start (gensym "START"))
        (result (gensym "RESULT")))
    `(let* ((,start (get-internal-real-time))
            (,result ,form))
       (format t "~&;; Elapsed time: ~,3F sec~%"
               (/ (float (- (get-internal-real-time) ,start))
                  internal-time-units-per-second))
       ,result)))

(defmacro with-output-to-string (spec &rest body)
  `(let ((,(car spec) (make-string-output-stream)))
     ,@body
     (get-output-stream-string ,(car spec))))

(defmacro with-open-file (spec &rest body)
  (let ((var (car spec)))
    `(let ((,var (open ,(cadr spec) ,@(cddr spec))))
       (unwind-protect (progn ,@body)
         (when ,var (close ,var))))))

(defmacro with-input-from-string (spec &rest body)
  `(let ((,(car spec) (make-string-input-stream ,(cadr spec))))
     ,@body))

(defmacro with-standard-io-syntax (&rest body)
  `(progn ,@body))

(defmacro do-symbols (spec &rest body)
  `(dolist (,(car spec) (%package-symbols ,(if (cdr spec) (cadr spec) '*package*)))
     ,@body))

(defmacro do-external-symbols (spec &rest body)
  `(dolist (,(car spec) (%package-external-symbols ,(if (cdr spec) (cadr spec) '*package*)))
     ,@body))

;;; ---------------- LOOP (subset) ----------------

(defun %loop-kw-p (x name)
  (and (symbolp x) (not (null x)) (string= (symbol-name x) name)))

(defun %loop-clause-keyword-p (x)
  (and (symbolp x)
       (not (null x))
       (member (symbol-name x)
               '("FOR" "AS" "WITH" "WHILE" "UNTIL" "REPEAT"
                 "DO" "DOING" "COLLECT" "COLLECTING"
                 "APPEND" "APPENDING" "SUM" "SUMMING"
                 "COUNT" "COUNTING" "MAXIMIZE" "MAXIMIZING"
                 "MINIMIZE" "MINIMIZING" "FINALLY" "INITIALLY")
               :test #'string=)))

(defun %loop-expand (clauses)
  (let ((bindings nil)     ; (var init) pairs, in order (reversed at end)
        (conditions nil)
        (presets nil)      ; run at start of each iteration
        (dos nil)          ; body forms (including accumulation steps)
        (steps nil)        ; run at end of each iteration
        (initiallys nil)
        (finallys nil)
        (acc (gensym "ACC"))
        (acc-kind nil)
        (rest clauses))
    (%while (consp rest)
      (let ((kw (car rest)))
        (cond
          ;; ---- FOR / AS ----
          ((or (%loop-kw-p kw "FOR") (%loop-kw-p kw "AS"))
           (let ((var (cadr rest))
                 (what (caddr rest)))
             (cond
               ((%loop-kw-p what "FROM")
                (let ((start (nth 3 rest))
                      (tail (nthcdr 4 rest))
                      (limit-var (gensym "LIMIT"))
                      (by-var (gensym "BY"))
                      (kind nil))
                  (push (list var start) bindings)
                  (when (or (%loop-kw-p (car tail) "TO")
                            (%loop-kw-p (car tail) "UPTO")
                            (%loop-kw-p (car tail) "BELOW"))
                    (setq kind (symbol-name (car tail)))
                    (push (list limit-var (cadr tail)) bindings)
                    (setq tail (cddr tail)))
                  (if (%loop-kw-p (car tail) "BY")
                      (progn
                        (push (list by-var (cadr tail)) bindings)
                        (setq tail (cddr tail)))
                      (push (list by-var 1) bindings))
                  (when kind
                    (if (string= kind "BELOW")
                        (push `(< ,var ,limit-var) conditions)
                        (push `(<= ,var ,limit-var) conditions)))
                  (push `(setq ,var (+ ,var ,by-var)) steps)
                  (setq rest tail)))
               ((%loop-kw-p what "IN")
                (let ((lst (gensym "LST")))
                  (push (list lst (nth 3 rest)) bindings)
                  (push (list var nil) bindings)
                  (push `(consp ,lst) conditions)
                  (push `(setq ,var (car ,lst)) presets)
                  (push `(setq ,lst (cdr ,lst)) steps)
                  (setq rest (nthcdr 4 rest))))
               ((%loop-kw-p what "ON")
                (let ((lst (gensym "LST")))
                  (push (list lst (nth 3 rest)) bindings)
                  (push (list var nil) bindings)
                  (push `(consp ,lst) conditions)
                  (push `(setq ,var ,lst) presets)
                  (push `(setq ,lst (cdr ,lst)) steps)
                  (setq rest (nthcdr 4 rest))))
               ((%loop-kw-p what "ACROSS")
                (let ((vec (gensym "VEC"))
                      (idx (gensym "IDX")))
                  (push (list vec (nth 3 rest)) bindings)
                  (push (list idx 0) bindings)
                  (push (list var nil) bindings)
                  (push `(< ,idx (length ,vec)) conditions)
                  (push `(setq ,var (elt ,vec ,idx)) presets)
                  (push `(setq ,idx (1+ ,idx)) steps)
                  (setq rest (nthcdr 4 rest))))
               ((%loop-kw-p what "=")
                (let ((init (nth 3 rest))
                      (tail (nthcdr 4 rest)))
                  (if (%loop-kw-p (car tail) "THEN")
                      (progn
                        (push (list var init) bindings)
                        (push `(setq ,var ,(cadr tail)) steps)
                        (setq rest (cddr tail)))
                      (progn
                        (push (list var nil) bindings)
                        (push `(setq ,var ,init) presets)
                        (setq rest tail)))))
               (t (error "loop: unsupported FOR clause near ~S" what)))))
          ;; ---- WITH var = expr ----
          ((%loop-kw-p kw "WITH")
           (let ((var (cadr rest)))
             (if (%loop-kw-p (caddr rest) "=")
                 (progn
                   (push (list var (nth 3 rest)) bindings)
                   (setq rest (nthcdr 4 rest)))
                 (progn
                   (push (list var nil) bindings)
                   (setq rest (cddr rest))))))
          ;; ---- REPEAT n ----
          ((%loop-kw-p kw "REPEAT")
           (let ((counter (gensym "COUNT"))
                 (limit (gensym "LIMIT")))
             (push (list limit (cadr rest)) bindings)
             (push (list counter 0) bindings)
             (push `(< ,counter ,limit) conditions)
             (push `(setq ,counter (1+ ,counter)) steps)
             (setq rest (cddr rest))))
          ;; ---- WHILE / UNTIL ----
          ((%loop-kw-p kw "WHILE")
           (push (cadr rest) conditions)
           (setq rest (cddr rest)))
          ((%loop-kw-p kw "UNTIL")
           (push `(not ,(cadr rest)) conditions)
           (setq rest (cddr rest)))
          ;; ---- DO ----
          ((or (%loop-kw-p kw "DO") (%loop-kw-p kw "DOING"))
           (setq rest (cdr rest))
           (%while (and (consp rest)
                        (not (%loop-clause-keyword-p (car rest))))
             (push (car rest) dos)
             (setq rest (cdr rest))))
          ;; ---- Accumulation ----
          ((or (%loop-kw-p kw "COLLECT") (%loop-kw-p kw "COLLECTING"))
           (setq acc-kind 'collect)
           (push `(setq ,acc (cons ,(cadr rest) ,acc)) dos)
           (setq rest (cddr rest)))
          ((or (%loop-kw-p kw "APPEND") (%loop-kw-p kw "APPENDING"))
           (setq acc-kind 'append)
           (push `(setq ,acc (append ,acc ,(cadr rest))) dos)
           (setq rest (cddr rest)))
          ((or (%loop-kw-p kw "SUM") (%loop-kw-p kw "SUMMING"))
           (setq acc-kind 'sum)
           (push `(setq ,acc (+ ,acc ,(cadr rest))) dos)
           (setq rest (cddr rest)))
          ((or (%loop-kw-p kw "COUNT") (%loop-kw-p kw "COUNTING"))
           (setq acc-kind 'sum)
           (push `(when ,(cadr rest) (setq ,acc (1+ ,acc))) dos)
           (setq rest (cddr rest)))
          ((or (%loop-kw-p kw "MAXIMIZE") (%loop-kw-p kw "MAXIMIZING"))
           (setq acc-kind 'extremum)
           (let ((v (gensym "V")))
             (push `(let ((,v ,(cadr rest)))
                      (setq ,acc (if (null ,acc) ,v (max ,acc ,v))))
                   dos))
           (setq rest (cddr rest)))
          ((or (%loop-kw-p kw "MINIMIZE") (%loop-kw-p kw "MINIMIZING"))
           (setq acc-kind 'extremum)
           (let ((v (gensym "V")))
             (push `(let ((,v ,(cadr rest)))
                      (setq ,acc (if (null ,acc) ,v (min ,acc ,v))))
                   dos))
           (setq rest (cddr rest)))
          ;; ---- INITIALLY / FINALLY ----
          ((%loop-kw-p kw "INITIALLY")
           (setq rest (cdr rest))
           (%while (and (consp rest)
                        (not (%loop-clause-keyword-p (car rest))))
             (push (car rest) initiallys)
             (setq rest (cdr rest))))
          ((%loop-kw-p kw "FINALLY")
           (setq rest (cdr rest))
           (%while (and (consp rest)
                        (not (%loop-clause-keyword-p (car rest))))
             (push (car rest) finallys)
             (setq rest (cdr rest))))
          (t
           (error "loop: unsupported clause ~S" kw)))))
    ;; Build the expansion.
    (let ((acc-init (case acc-kind
                      ((sum) 0)
                      (otherwise nil)))
          (result (case acc-kind
                    ((collect) `(reverse ,acc))
                    ((append sum extremum) acc)
                    (otherwise nil))))
      `(block nil
         (let* (,@(reverse bindings)
                (,acc ,acc-init))
           ,@(reverse initiallys)
           (%while ,(if conditions
                        `(and ,@(reverse conditions))
                        t)
             ,@(reverse presets)
             ,@(reverse dos)
             ,@(reverse steps))
           ,@(reverse finallys)
           ,result)))))

(defmacro loop (&rest clauses)
  (if (or (null clauses)
          (not (%loop-clause-keyword-p (car clauses))))
      `(block nil (%while t ,@clauses))
      (%loop-expand clauses)))

;;; Convenience aliases
(defun list-to-vector (lst) (apply #'vector lst))
(defun vector-to-list (v) (coerce-to-list v))
(defun coerce-to-list (seq) (concatenate 'list seq))

(defun coerce (value type)
  (case type
    ((list) (concatenate 'list value))
    ((vector simple-vector) (concatenate 'vector value))
    ((string simple-string) (if (stringp value) value (concatenate 'string value)))
    ((float double-float single-float) (float value))
    (otherwise value)))
"""
}
