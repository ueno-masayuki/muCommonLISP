# muCommonLISP

Mac の GUI 環境で動作する、コンパイラ搭載の Common Lisp 処理系です。
Swift + SwiftUI で実装され、**ビルトインエディタ・REPL・複数のグラフィックス
ウィンドウ**を備えた macOS アプリとして動作します。実行エンジンは
**バイトコードコンパイラ＋スタック VM**、オブジェクトシステムは
**ユーザレベル CLOS フル実装＋基本 MOP** です。

## 構成

| ターゲット | 内容 |
|---|---|
| `MuLispCore` | 処理系本体（リーダ・コンパイラ・VM・CLOS・条件/再起動系・数値塔） |
| `muCommonLISP` | macOS GUI アプリ（エディタ ＋ REPL ＋ グラフィックス） |
| `mulisp` | コマンドライン REPL / ファイル実行（macOS・Linux） |

依存パッケージ: [attaswift/BigInt](https://github.com/attaswift/BigInt)（多倍長整数。初回ビルド時に自動取得）

## ビルドと実行（macOS 13 以降 / Xcode 15 以降）

```sh
swift run muCommonLISP                       # GUI アプリ
swift run mulisp                             # CLI REPL
swift run mulisp Examples/fullcl-demo.lisp   # 新機能ツアー
swift test                                   # テスト一式（約150項目）
swift run mulisp Examples/suite.lisp         # Lisp 自己テスト
swift run -c release mulisp Examples/bench.lisp   # ベンチマーク
swift run mulisp --svg Examples/graphics-demo.lisp out.svg
scripts/make-app.sh                          # .app バンドル生成
```

## GUI の使い方

- **エディタ（左上）**: 複数タブ、開く/保存/別名保存、シンタックスハイライト、
  括弧対応表示、自動インデント、**Tab でシンボル補完**、**⌘J で定義ジャンプ**。
  **⌘E** でカーソル位置のトップレベル式（または選択範囲）を評価、
  **⌘⇧E** でバッファ全体を評価。結果は REPL に表示されます。
- **REPL（左下）**: ⌘⏎ で評価、⌘↑/⌘↓ で履歴。
- **キャンバス（右）**: メインの描画先。ツールバーでエディタ表示切替・中断・消去。
- **グラフィックスウィンドウ**: `(make-graphics-window ...)` で独立した
  ウィンドウをいくつでも生成できます（下記）。

### グラフィックス API

```lisp
;; メインキャンバスへ（従来どおり）
(draw-line x1 y1 x2 y2)  (draw-rect x y w h [fill])  (draw-circle x y r [fill])
(draw-text x y "str" [size])  (draw-point x y)
(set-color r g b [a])  (set-line-width w)  (clear-graphics)  (canvas-size)

;; ウィンドウ生成と描画（全描画関数は第1引数にウィンドウを取れる）
(defparameter *w* (make-graphics-window :title "plot" :width 400 :height 300))
(set-color *w* 1 0 0)
(draw-line *w* 0 0 100 100)
(close-graphics-window *w*)
(with-graphics-window (w :title "temp") (draw-circle w 50 50 20))
(save-graphics-svg "out.svg" [*w*])   ; SVG 書き出し（CLI でも使用可）
```

## 言語機能（ANSI Common Lisp のサブセット — 広範囲）

### 数値塔
- **多倍長整数**（fixnum があふれると自動で bignum へ）
- **分数**: `(/ 1 3)` → `1/3`、正確な `floor/ceiling/round/truncate`（多値）、
  `numerator/denominator/rational`
- **複素数**: `#C(1 2)`、`complex/realpart/imagpart/conjugate/phase/cis`、
  `(sqrt -1)` → `#C(0.0 1.0)`
- `gcd/lcm/ash/logand...`（bignum 対応）、`signum/isqrt/integer-length`

### データ型
- **可変文字列**: `(setf (char s i) c)`、`make-string`、`nstring-upcase` 等
- **多次元配列**: `(make-array '(2 3))`、`#2A((1 2)(3 4))` リテラル、
  **フィルポインタ**（`vector-push/-extend/-pop`）、`adjust-array`
- ハッシュ表（4種のテスト、`maphash`、loop 連携）、構造体（CLOS 統合）

### 制御構造
- `tagbody/go`（クロージャ越しの go も可）、`prog/prog*`、`psetq`、並列 `do`
- **条件システム＋再起動**: `handler-case` `handler-bind` `restart-case`
  `invoke-restart` `find-restart` `compute-restarts` `abort` `continue`
  `use-value` `store-value` `muffle-warning` `cerror` `with-simple-restart`
- `macrolet` `symbol-macrolet` `define-symbol-macro` `progv`
- 多値: `multiple-value-bind/-call/-prog1/-list/-setq` `nth-value` `values-list`
- 場所系（部分式は一度だけ評価）: `push pop incf decf pushnew rotatef shiftf
  remf (setf getf)`、`defsetf`（短縮形）

### LOOP（拡張サブセット）
`for from/downfrom to/downto/below/above by` / `in` / `on` / `across` /
`= then` / **破壊パターン** `for (a b) in` / **ハッシュ**
`being the hash-keys of h using (hash-value v)` / `with...and` / `repeat` /
`while until` / `collect append nconc sum count maximize minimize` /
**`into`** / **`when if unless else end`** / **`always never thereis`** /
`named` / `initially finally [return]` / 節なし無限ループ＋`return`

### FORMAT（拡張サブセット）
`~A ~S ~D ~B ~O ~X ~R`（基数・英語数詞・`~@R` ローマ数字・`~:D` 桁区切り）
`~F ~E ~G ~$ ~C ~P`（複数形）`~T ~% ~& ~| ~~ ~*`（引数移動）`~?`
`~{ ~}`（`~:{` `~@{` 対応）`~[ ~; ~]`（`~:[` `~@[`）`~( ~)`（大文字小文字変換）
`~^`、数値・文字パラメータ（`~10A` `~,2F` `~'0,4D` `v` `#`）、`:`/`@` 修飾子

### CLOS ＋ MOP
- フル CLOS: 多重継承（ANSI CPL）、多重ディスパッチ、EQL スペシャライザ、
  `:before/:after/:around`、`call-next-method`、クラス再定義、`change-class`、
  `initialize-instance` プロトコル、`print-object`、`:allocation :class`
- **メソッド結合**: 短縮形オペレータ結合 `+ and or list progn max min append`
  ＋ `define-method-combination`（短縮形）、
  `defgeneric (:method-combination x)`、`(defmethod f + ((x c)) ...)`
- **MOP（基本）**: `class-direct-superclasses/-subclasses`
  `class-precedence-list` `class-(direct-)slots`＋`slot-definition-*`
  `generic-function-methods` `allocate-instance`

### パッケージ・入出力・その他
- パッケージ: external/internal 区別、`defpackage (:use :export :nicknames
  :shadow)` `export/import/shadow/use-package/unintern`
  `do-symbols/do-external-symbols` `apropos`
- ファイル IO: `open/close/with-open-file`（`:direction :if-exists`）
  `read-char/read-line/peek-char/read` `load` `probe-file/delete-file/directory`
  `with-input-from-string`、`*standard-output*` の再束縛が全出力関数に反映
- リーダ: `#x #o #b #nR #C #nA #. #+/#- #\\ #' #( #:`、分数/多倍長リテラル、
  `set-macro-character` によるユーザリーダマクロ
- 内省: `describe/inspect` `documentation`（defun の docstring 保存）
  `trace/untrace` `apropos` `*features*` `time` `disassemble` `compile`
- 時刻: `get-universal-time` `decode/encode-universal-time` `get-decoded-time`

## 非サポート（主なもの）

- 完全な MOP（ユーザ定義メタクラスによるスロットアクセスのフック等）と
  `define-method-combination` の完全（長い）形式
- `compile-file` / fasl、論理パスネーム、双方向・ソケットストリーム
- `handler-bind` は `error`/`signal`/`warn`/`cerror` で通知された条件には
  通知時点で介入できますが、組み込み関数が直接投げたエラーには
  巻き戻し後にしか介入できません（restart との併用は `error` 経由を推奨）
- 文字列は Unicode 書記素単位（CL の char-code 系は先頭スカラで近似）
- `setf` は一部の場所で値を場所の部分式より先に評価します
- メモリ管理は ARC（循環参照を作るクロージャは解放されません）

## REPL の例

```lisp
muCL> (expt 2 100)
=> 1267650600228229401496703205376

muCL> (+ 1/2 1/3)
=> 5/6

muCL> (loop for i from 10 downto 1 when (evenp i) collect i)
=> (10 8 6 4 2)

muCL> (format nil "~@R 年 (~:D)" 2026 1234567)
=> "MMXXVI 年 (1,234,567)"

muCL> (handler-bind ((error (lambda (c) (invoke-restart 'use-value 0))))
        (restart-case (error "no data") (use-value (v) v)))
=> 0

muCL> (make-graphics-window :title "plot")
=> #<GRAPHICS-WINDOW "plot">
```

## ライセンス・用途

教育・研究・プロトタイピング用途を想定しています。
