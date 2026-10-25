// main.swift
// mulisp — command-line REPL and file runner for muCommonLISP.
//
// Usage:
//   mulisp                        interactive REPL
//   mulisp file.lisp ...          run files
//   mulisp -e "(+ 1 2)"           evaluate an expression
//   mulisp --svg in.lisp out.svg  run a file and write the canvas as SVG

import Foundation
import MuLispCore

let interp = Interpreter()

if let bootError = interp.bootError {
    FileHandle.standardError.write(
        ";; BOOTSTRAP WARNING: \(bootError)\n".data(using: .utf8)!)
}

func reportError(_ error: Error) {
    let text: String
    switch error {
    case let e as LispError:
        text = ";; ERROR: \(e.message)"
    case let e as ReaderError:
        text = ";; READ ERROR: \(e.message)"
    case is InterruptSignal:
        text = ";; Interrupted"
    case let t as LispThrowSignal:
        text = ";; ERROR: uncaught throw to tag "
            + Printer.toString(t.tag, escape: true, interp: interp)
    case is BlockReturnSignal:
        text = ";; ERROR: return-from escaped its block"
    default:
        text = ";; ERROR: \(error)"
    }
    FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
}

func runFile(_ path: String) -> Bool {
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
        FileHandle.standardError.write(
            ";; cannot read file: \(path)\n".data(using: .utf8)!)
        return false
    }
    do {
        try interp.evalAll(source)
        return true
    } catch let e as ExitSignal {
        exit(Int32(e.code))
    } catch {
        reportError(error)
        return false
    }
}

func repl() {
    print("muCommonLISP — a micro Common Lisp with a bytecode compiler")
    print("Type (exit) to leave.")
    var pending = ""
    while true {
        print(pending.isEmpty ? "muCL> " : "....> ", terminator: "")
        guard let line = readLine(strippingNewline: false) else {
            print("")
            return
        }
        pending += line
        // Try to read the accumulated input; keep reading lines while the
        // form is incomplete.
        let probe = Reader(source: pending, registry: interp.registry) {
            interp.currentPackage
        }
        do {
            var forms: [LispValue] = []
            while let f = try probe.read() {
                forms.append(f)
            }
            pending = ""
            for form in forms {
                do {
                    let result = try interp.eval(form)
                    print(interp.printString(result))
                } catch let e as ExitSignal {
                    exit(Int32(e.code))
                } catch {
                    reportError(error)
                }
            }
        } catch let e as ReaderError where e.unexpectedEOF {
            continue   // incomplete form: read another line
        } catch {
            pending = ""
            reportError(error)
        }
    }
}

// MARK: - Argument parsing

var args = Array(CommandLine.arguments.dropFirst())

if args.isEmpty {
    repl()
    exit(0)
}

if args[0] == "-e" {
    guard args.count >= 2 else {
        FileHandle.standardError.write("usage: mulisp -e EXPR\n".data(using: .utf8)!)
        exit(2)
    }
    do {
        let result = try interp.evalAll(args[1])
        print(interp.printString(result))
        exit(0)
    } catch let e as ExitSignal {
        exit(Int32(e.code))
    } catch {
        reportError(error)
        exit(1)
    }
}

if args[0] == "--svg" {
    guard args.count >= 3 else {
        FileHandle.standardError.write(
            "usage: mulisp --svg in.lisp out.svg\n".data(using: .utf8)!)
        exit(2)
    }
    let ok = runFile(args[1])
    let svg = interp.graphics.renderSVG()
    do {
        try svg.write(toFile: args[2], atomically: true, encoding: .utf8)
        print(";; wrote \(args[2])")
    } catch {
        FileHandle.standardError.write(
            ";; cannot write \(args[2]): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    exit(ok ? 0 : 1)
}

var allOK = true
for path in args {
    if !runFile(path) {
        allOK = false
    }
}
exit(allOK ? 0 : 1)
