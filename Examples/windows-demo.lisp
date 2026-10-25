;;; windows-demo.lisp — multiple graphics windows
;;; GUI で REPL に貼り付けて評価してください（CLI ではウィンドウは
;;; 表示されませんが、save-graphics-svg で内容を書き出せます）。

;; メインキャンバスに描く（従来どおり）
(clear-graphics)
(set-color 0 0 0)
(draw-text 20 20 "main canvas" 16)
(draw-circle 100 100 40)

;; 新しいウィンドウを 2 枚開く
(defparameter *w1* (make-graphics-window :title "sine" :width 420 :height 240))
(defparameter *w2* (make-graphics-window :title "squares" :width 300 :height 300))

;; ウィンドウ 1: 正弦波
(set-color *w1* 0.1 0.3 0.8)
(set-line-width *w1* 2)
(loop for x from 0 to 400 by 4
      for y1 = (+ 120 (* 90 (sin (/ x 40.0))))
      for y2 = (+ 120 (* 90 (sin (/ (+ x 4) 40.0))))
      do (draw-line *w1* x y1 (+ x 4) y2))
(set-color *w1* 0 0 0)
(draw-text *w1* 10 10 "y = sin x" 14)

;; ウィンドウ 2: 色付きの正方形
(dotimes (i 10)
  (set-color *w2* (/ i 10.0) 0.2 (- 1 (/ i 10.0)) 0.9)
  (draw-rect *w2* (* i 14) (* i 14) 120 120))

;; with-graphics-window: スコープ付きで開く
(with-graphics-window (w :title "spiral" :width 260 :height 260)
  (set-color w 0.8 0.2 0.1)
  (loop for angle from 0.0 to 18.0 by 0.1
        for r = (* angle 6)
        do (draw-point w (+ 130 (* r (cos angle)))
                         (+ 130 (* r (sin angle))))))

(format t "3 つのウィンドウを開きました。(close-graphics-window *w1*) で閉じられます。~%")
