;;; clos-demo.lisp — CLOS: classes, multiple dispatch, method combination

(defclass shape ()
  ((name :initarg :name :initform "shape" :accessor shape-name)))

(defclass circle (shape)
  ((radius :initarg :radius :initform 1 :accessor circle-radius)))

(defclass rectangle (shape)
  ((width  :initarg :width  :initform 1 :accessor rect-width)
   (height :initarg :height :initform 1 :accessor rect-height)))

(defgeneric area (s)
  (:documentation "Area of a shape."))

(defmethod area ((s circle))
  (* pi (circle-radius s) (circle-radius s)))

(defmethod area ((s rectangle))
  (* (rect-width s) (rect-height s)))

(defmethod area :around ((s shape))
  (format t ";; computing area of ~A...~%" (shape-name s))
  (call-next-method))

(defmethod print-object ((s shape) stream)
  (format stream "#<~A>" (shape-name s)))

;; Multiple dispatch
(defgeneric overlaps-p (a b))
(defmethod overlaps-p ((a circle) (b circle)) 'circle-circle)
(defmethod overlaps-p ((a circle) (b rectangle)) 'circle-rect)
(defmethod overlaps-p ((a t) (b t)) 'generic)

(let ((c (make-instance 'circle :name "C1" :radius 2))
      (r (make-instance 'rectangle :name "R1" :width 3 :height 4)))
  (format t "~A area = ~,2F~%" c (area c))
  (format t "~A area = ~,2F~%" r (area r))
  (format t "dispatch: ~A ~A ~A~%"
          (overlaps-p c c) (overlaps-p c r) (overlaps-p r r)))

;; defstruct is integrated with CLOS
(defstruct point (x 0) (y 0))
(defgeneric magnitude (p))
(defmethod magnitude ((p point))
  (sqrt (+ (* (point-x p) (point-x p))
           (* (point-y p) (point-y p)))))
(format t "magnitude = ~,3F~%" (magnitude (make-point :x 3 :y 4)))
