;;; graphics-demo.lisp — drawing on the canvas
;;; GUI:  paste into the REPL pane, or run
;;; CLI:  swift run mulisp --svg Examples/graphics-demo.lisp out.svg

(clear-graphics)

;; Fan of lines
(set-line-width 1)
(dotimes (i 20)
  (let ((hue (/ (float i) 20)))
    (set-color hue 0.2 (- 1 hue))
    (draw-line 50 350 (+ 50 (* i 25)) 50)))

;; Concentric circles
(set-line-width 2)
(dotimes (i 8)
  (set-color 0.1 (+ 0.2 (* i 0.1)) 0.4)
  (draw-circle 420 180 (+ 10 (* i 14))))

;; Grid of filled squares
(dotimes (row 5)
  (dotimes (col 5)
    (set-color (/ (float row) 5) (/ (float col) 5) 0.5)
    (draw-rect (+ 60 (* col 32)) (+ 380 (* row 32)) 28 28 t)))

;; Spiral of points
(set-color 0.8 0.3 0.1)
(set-line-width 3)
(let ((cx 420.0) (cy 430.0))
  (loop for angle from 0.0 to 25.0 by 0.15
        for r = (* angle 4.5)
        do (draw-point (+ cx (* r (cos angle)))
                       (+ cy (* r (sin angle))))))

(set-color 0 0 0)
(draw-text 50 20 "muCommonLISP graphics demo" 18)
(format t "描画しました。GUI では右側のキャンバスを見てください。~%")
