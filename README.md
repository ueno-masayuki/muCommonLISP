# muCommonLISP

Mac の GUI 環境で動作する、コンパイラ搭載のマイクロ Common Lisp 処理系です。
Swift + SwiftUI で実装されており、REPL とグラフィックスキャンバスを備えた
macOS アプリとして動作します。プロトタイプの実行を想定し、
**バイトコードコンパイラ＋スタック VM** による実行と **CLOS のフル実装
（ユーザレベル）** を特徴とします。

## 構成

| ターゲット | 内容 |
|---|---|
| `MuLispCore` | 処理系本体（リーダ・コンパイラ・VM・CLOS・組み込み関数） |
| `muCommonLISP` | macOS GUI アプリ（REPL ＋ グラフィックスキャンバス） |
| `mulisp` | コマンドライン REPL / ファイル実行（macOS・Linux） |

## ビルドと実行（macOS 13 以降 / Xcode 15 以降）

```sh
# GUI アプリを起動
swift run muCommonLISP

# コマンドライン REPL
swift run mulisp

# ファイルを実行
swift run mulisp Examples/hello.lisp

# テスト一式
swift test

# Lisp レベルの自己テスト
swift run mulisp Examples/suite.lisp

# ベンチマーク（release ビルド推奨）
swift run -c release mulisp Examples/bench.lisp

# 描画デモを SVG に書き出し（GUI なしで描画確認）
swift run mulisp --svg Examples/graphics-demo.lisp out.svg

# .app バンドルの作成
scripts/make-app.sh
open dist/muCommonLISP.app
```

Xcode で開く場合は `Package.swift` をダブルクリックし、
スキーム `muCommonLISP` を選んで実行してください。

## GUI の使い方

- 左ペイン: REPL。下の入力欄に式を書き **⌘⏎** で評価します。
  **⌘↑ / ⌘↓** で入力履歴を移動します。
- 右ペイン: グラフィックスキャンバス。`(draw-line ...)` などで描画されます。
- ツールバー: 実行中の評価の **中断**、キャンバス消去、履歴消去。
- 評価はバックグラウンドスレッドで行われるため、長い計算中も UI は固まりません。

### 描画関数

```lisp
(clear-graphics)                      ; キャンバスを消去
(set-color r g b [a])                 ; 色 (各成分 0.0〜1.0)
(set-line-width w)
(draw-line x1 y1 x2 y2)
(draw-rect x y w h [fill])            ; fill に t で塗り潰し
(draw-circle x y r [fill])
(draw-text x y "string" [size])
(draw-point x y)
(canvas-size)                         ; => (values width height)
```

`Examples/graphics-demo.lisp` にまとまったデモがあります。

## 実行エンジン（速度重視の設計）

- `read → マクロ展開 → バイトコードコンパイル → VM 実行` のパイプライン。
  `eval` も内部でコンパイルします（木構造インタプリタは持ちません）。
- レキシカル変数はコンパイル時にフレームのスロット番号へ解決され、
  実行時の名前探索はありません。
- **末尾呼び出し最適化**: 末尾再帰・末尾相互再帰は定数スタックで回ります
  （`Examples/bench.lisp` の 500 万回カウントダウン参照）。
- `car/cdr/cons/+/-/*//=/</>` 等は専用バイトコード命令に直接コンパイルされます。
- 総称関数は引数クラス列でメソッド探索結果をキャッシュします。
- `(disassemble 'f)` でバイトコードを確認、`(time expr)` で計測、
  `(compile nil '(lambda ...))` でクロージャをその場でコンパイルできます。

## CLOS

ユーザレベルの CLOS を一通りサポートします。

- `defclass`: **多重継承**（ANSI のクラス優先順位リスト計算）、スロットオプション
  `:initarg :initform :accessor :reader :writer :allocation (:instance / :class)
  :documentation`
- `defgeneric` / `defmethod`: 全必須引数での**多重ディスパッチ**、
  **EQL スペシャライザ** `((n (eql 0)))`、組み込み型
  （`integer` `string` `cons` …）へのディスパッチ
- **標準メソッド結合**: primary / `:before` / `:after` / `:around`、
  `call-next-method`、`next-method-p`
- `make-instance` → `initialize-instance` → `shared-initialize` プロトコル
  （`:after` メソッド等をユーザ定義可能）、`reinitialize-instance`
- `slot-value` `(setf slot-value)` `slot-boundp` `slot-makunbound`
  `slot-exists-p` `with-slots` `with-accessors`
- **クラス再定義**（既存インスタンスは遅延更新）、`change-class`
- `print-object` 総称関数（プリンタが自動的に呼びます）
- `defstruct` は構造体クラスとして CLOS に統合
  （`:include` `:conc-name` `:constructor` `:predicate` `:copier` 対応）

条件システム（`error` `signal` `handler-case` `ignore-errors`
`unwind-protect`）も条件クラス階層（`condition > error > type-error ...`）
ごと CLOS 上に実装されています。

## サポートする主な機能

- 特殊形式: `quote quasiquote if progn let let* lambda function setq setf
  defun defmacro defvar defparameter defconstant and or block return-from
  catch throw unwind-protect multiple-value-bind flet labels
  symbol-macrolet the locally eval-when`
- マクロ（prelude で定義）: `when unless cond case ecase typecase etypecase
  dolist dotimes do do* push pop incf decf prog1 prog2 return
  with-slots with-accessors handler-case ignore-errors assert check-type
  time with-output-to-string loop（サブセット）`
- `loop` サブセット: `for i from a to/below b by c` / `for x in/on lst` /
  `for x across vec` / `for x = e then e2` / `with` / `repeat` /
  `while` / `until` / `do` / `collect` / `append` / `sum` / `count` /
  `maximize` / `minimize` / `initially` / `finally`、
  および節なしの無限ループ `(loop ... )` ＋ `(return ...)`
- 数値: 整数（64bit）・浮動小数点数、`floor/ceiling/round/truncate`（多値）、
  超越関数、ビット演算、`random`
- データ: リスト・文字列・文字・シンボル・ベクタ（1 次元）・ハッシュ表・
  パッケージ（簡易版: `defpackage` `in-package` `intern` 等）
- `format` サブセット: `~A ~S ~D ~X ~O ~B ~F ~C ~% ~& ~~ ~{ ~} ~^`
  （`~10A` `~,2F` などの前置パラメータ対応）

## 非サポート（主なもの）

- 多倍長整数・分数・複素数（整数は 64bit、桁あふれは浮動小数点数に転化。
  `(/ 1 2)` は `0.5` になります）
- `tagbody` / `go` / `progv` / `macrolet` / `handler-bind` / restart 系
- MOP（メタオブジェクトプロトコル）と `define-method-combination`
- ファイル入出力ストリーム、`load`（CLI でのファイル実行で代用）
- 文字列の破壊的変更（文字列は不変）
- パッケージの export / internal 区別（全シンボルが見えます）
- `do` は `do*`（逐次束縛）の意味で動作します
- `setf` は値を場所の部分式より先に評価します

## REPL の例

```lisp
muCL> (defclass point ()
        ((x :initarg :x :accessor point-x)
         (y :initarg :y :accessor point-y)))
=> #<CLASS POINT>

muCL> (defmethod print-object ((p point) stream)
        (format stream "#<POINT ~A,~A>" (point-x p) (point-y p)))
=> PRINT-OBJECT

muCL> (make-instance 'point :x 1 :y 2)
=> #<POINT 1,2>

muCL> (loop for i from 1 to 10 collect (* i i))
=> (1 4 9 16 25 36 49 64 81 100)

muCL> (time (fib 25))   ; fib は Examples/bench.lisp 参照
```

## ライセンス・用途

教育・研究・プロトタイピング用途を想定しています。
