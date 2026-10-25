// StreamsIO.swift
// File streams, input streams, READ and LOAD.

import Foundation

extension Interpreter {

    func registerStreamBuiltins() {
        let lisp = registry.lisp

        func requireStream(_ v: LispValue) throws -> LispStream {
            guard case .stream(let s) = v.firstValue else {
                throw self.typeError(v, expected: "STREAM")
            }
            return s
        }

        func pathString(_ v: LispValue) throws -> String {
            return try self.requireStringDesignator(v)
        }

        // --- Opening and closing ---

        defBuiltin("OPEN", 1, nil) { [unowned self] args in
            let path = try pathString(args[0])
            let keys = try self.parseKeys(args, from: 1)
            var direction = "INPUT"
            if case .symbol(let d)? = keys["DIRECTION"]?.firstValue {
                direction = d.name
            }
            let fm = FileManager.default
            switch direction {
            case "INPUT":
                guard let data = fm.contents(atPath: path),
                      let text = String(data: data, encoding: .utf8) else {
                    if case .null? = keys["IF-DOES-NOT-EXIST"]?.firstValue {
                        return .null
                    }
                    throw self.lispError("STREAM-ERROR",
                                         "cannot open file: \(path)")
                }
                let s = LispStream(kind: .stringInput)
                s.inputChars = Array(text)
                s.path = path
                return .stream(s)
            case "OUTPUT", "IO":
                var ifExists = "SUPERSEDE"
                if case .symbol(let e)? = keys["IF-EXISTS"]?.firstValue {
                    ifExists = e.name
                }
                let exists = fm.fileExists(atPath: path)
                if exists {
                    switch ifExists {
                    case "ERROR":
                        throw self.lispError("STREAM-ERROR",
                                             "file exists: \(path)")
                    case "NIL":
                        return .null
                    case "APPEND":
                        break
                    default:   // SUPERSEDE / OVERWRITE / NEW-VERSION
                        try? fm.removeItem(atPath: path)
                        fm.createFile(atPath: path, contents: nil)
                    }
                } else {
                    fm.createFile(atPath: path, contents: nil)
                }
                guard let handle = FileHandle(forWritingAtPath: path) else {
                    throw self.lispError("STREAM-ERROR",
                                         "cannot open file for writing: \(path)")
                }
                if ifExists == "APPEND" {
                    handle.seekToEndOfFile()
                }
                let s = LispStream(kind: .fileOutput)
                s.fileHandle = handle
                s.path = path
                return .stream(s)
            default:
                throw self.lispError("ERROR",
                                     "unsupported :direction :\(direction)")
            }
        }

        defBuiltin("CLOSE", 1, nil) { [unowned self] args in
            let s = try requireStream(args[0])
            if s.kind == .fileOutput, let h = s.fileHandle {
                try? h.close()
            }
            s.isOpen = false
            return self.tValue
        }

        defBuiltin("OPEN-STREAM-P", 1, 1) { [unowned self] args in
            let s = try requireStream(args[0])
            return s.isOpen ? self.tValue : .null
        }

        defBuiltin("INPUT-STREAM-P", 1, 1) { [unowned self] args in
            let s = try requireStream(args[0])
            return s.kind == .stringInput ? self.tValue : .null
        }

        defBuiltin("OUTPUT-STREAM-P", 1, 1) { [unowned self] args in
            let s = try requireStream(args[0])
            switch s.kind {
            case .stringOutput, .standardOutput, .fileOutput:
                return self.tValue
            default:
                return .null
            }
        }

        defBuiltin("MAKE-STRING-INPUT-STREAM", 1, 3) { [unowned self] args in
            guard case .string(let str) = args[0].firstValue else {
                throw self.typeError(args[0], expected: "STRING")
            }
            let s = LispStream(kind: .stringInput)
            s.inputChars = str.chars
            return .stream(s)
        }

        defBuiltin("FINISH-OUTPUT", 0, 1) { _ in .null }
        lisp.intern("FORCE-OUTPUT").function =
            lisp.intern("FINISH-OUTPUT").function
        lisp.intern("CLEAR-OUTPUT").function =
            lisp.intern("FINISH-OUTPUT").function

        // --- Character input ---

        func eofResult(_ args: [LispValue], errorIndex: Int) throws -> LispValue {
            // args[errorIndex] = eof-error-p (default T), next = eof-value
            let eofErrorP = args.count > errorIndex
                ? args[errorIndex].isTrue : true
            if eofErrorP {
                throw self.lispError("END-OF-FILE", "end of file")
            }
            return args.count > errorIndex + 1 ? args[errorIndex + 1] : .null
        }

        defBuiltin("READ-CHAR", 1, 3) { [unowned self] args in
            let s = try requireStream(args[0])
            if let c = s.readChar() {
                return .character(c)
            }
            _ = self
            return try eofResult(args, errorIndex: 1)
        }

        defBuiltin("PEEK-CHAR", 0, nil) { [unowned self] args in
            // (peek-char &optional peek-type stream eof-error-p eof-value)
            var skipWhitespace = false
            var streamIndex = 0
            if !args.isEmpty {
                switch args[0].firstValue {
                case .stream:
                    streamIndex = 0
                default:
                    skipWhitespace = args[0].isTrue
                    streamIndex = 1
                }
            }
            guard args.count > streamIndex else {
                throw self.lispError("ERROR", "peek-char needs a stream")
            }
            let s = try requireStream(args[streamIndex])
            if skipWhitespace {
                while let c = s.peekChar(), c.isWhitespace {
                    _ = s.readChar()
                }
            }
            if let c = s.peekChar() {
                return .character(c)
            }
            return try eofResult(args, errorIndex: streamIndex + 1)
        }

        defBuiltin("UNREAD-CHAR", 1, 2) { [unowned self] args in
            // (unread-char char stream) — char is ignored, we just step back.
            if args.count >= 2 {
                let s = try requireStream(args[1])
                s.unreadChar()
            } else if case .stream(let s) = args[0].firstValue {
                s.unreadChar()
            }
            return .null
        }

        defBuiltin("READ-LINE", 1, 3) { [unowned self] args in
            let s = try requireStream(args[0])
            var line = ""
            var sawAny = false
            while let c = s.readChar() {
                sawAny = true
                if c == "\n" {
                    return .values([.str(line), .null])
                }
                line.append(c)
            }
            if sawAny {
                return .values([.str(line), self.tValue])
            }
            return try eofResult(args, errorIndex: 1)
        }

        defBuiltin("LISTEN", 1, 1) { [unowned self] args in
            let s = try requireStream(args[0])
            return s.peekChar() != nil ? self.tValue : .null
        }

        defBuiltin("READ", 0, nil) { [unowned self] args in
            guard !args.isEmpty, case .stream(let s) = args[0].firstValue else {
                throw self.lispError("STREAM-ERROR",
                    "READ needs an explicit input stream in muCommonLISP")
            }
            if let backing = s.backingReader {
                do {
                    return try backing.readSubForm()
                } catch let e as ReaderError {
                    if e.unexpectedEOF {
                        return try eofResult(args, errorIndex: 1)
                    }
                    throw self.lispError("READER-ERROR", e.message)
                }
            }
            let remaining = String(s.inputChars[s.inputPos...])
            let reader = self.makeReader(source: remaining)
            do {
                guard let form = try reader.read() else {
                    return try eofResult(args, errorIndex: 1)
                }
                s.inputPos += reader.position
                return form
            } catch let e as ReaderError {
                if e.unexpectedEOF {
                    return try eofResult(args, errorIndex: 1)
                }
                throw self.lispError("READER-ERROR", e.message)
            }
        }

        // --- Files ---

        defBuiltin("LOAD", 1, nil) { [unowned self] args in
            let path = try pathString(args[0])
            guard let source = try? String(contentsOfFile: path,
                                           encoding: .utf8) else {
                throw self.lispError("STREAM-ERROR", "cannot load \(path)")
            }
            let loadSym = self.registry.lisp.intern("*LOAD-PATHNAME*")
            loadSym.isSpecial = true
            let saved = loadSym.value
            loadSym.value = .str(path)
            defer { loadSym.value = saved }
            _ = try self.evalAll(source)
            return self.tValue
        }

        defBuiltin("PROBE-FILE", 1, 1) { args in
            let path = try pathString(args[0])
            if FileManager.default.fileExists(atPath: path) {
                return .str(path)
            }
            return .null
        }

        defBuiltin("DELETE-FILE", 1, 1) { [unowned self] args in
            let path = try pathString(args[0])
            do {
                try FileManager.default.removeItem(atPath: path)
                return self.tValue
            } catch {
                throw self.lispError("STREAM-ERROR",
                                     "cannot delete \(path)")
            }
        }

        defBuiltin("DIRECTORY", 1, 1) { args in
            let path = try pathString(args[0])
            let fm = FileManager.default
            // Expand a trailing wildcard component, else list the directory.
            var dir = path
            var pattern: String? = nil
            if path.contains("*") {
                let url = URL(fileURLWithPath: path)
                pattern = url.lastPathComponent
                dir = url.deletingLastPathComponent().path
            }
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else {
                return .null
            }
            var result: [LispValue] = []
            for entry in entries.sorted() {
                if let pat = pattern {
                    // Simple glob: * matches anything.
                    let regexPattern = "^" + pat
                        .replacingOccurrences(of: ".", with: "\\.")
                        .replacingOccurrences(of: "*", with: ".*") + "$"
                    if entry.range(of: regexPattern,
                                   options: .regularExpression) == nil {
                        continue
                    }
                }
                result.append(.str(dir + "/" + entry))
            }
            return LispValue.list(result)
        }

        defBuiltin("ENSURE-DIRECTORIES-EXIST", 1, 1) { [unowned self] args in
            let path = try pathString(args[0])
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(
                atPath: dir.isEmpty ? path : dir,
                withIntermediateDirectories: true)
            _ = self
            return args[0]
        }

        // --- Minimal pathname support (pathnames are strings) ---

        defBuiltin("NAMESTRING", 1, 1) { args in
            return .str(try pathString(args[0]))
        }
        lisp.intern("PATHNAME").function = lisp.intern("NAMESTRING").function
        lisp.intern("TRUENAME").function = lisp.intern("NAMESTRING").function

        defBuiltin("MERGE-PATHNAMES", 1, 2) { args in
            let name = try pathString(args[0])
            if args.count == 2 {
                let base = try pathString(args[1])
                if name.hasPrefix("/") {
                    return .str(name)
                }
                let baseDir = (base as NSString).deletingLastPathComponent
                if baseDir.isEmpty {
                    return .str(name)
                }
                return .str(baseDir + "/" + name)
            }
            return .str(name)
        }

        defBuiltin("PATHNAME-NAME", 1, 1) { args in
            let path = try pathString(args[0])
            let base = (path as NSString).lastPathComponent
            let name = (base as NSString).deletingPathExtension
            return name.isEmpty ? .null : .str(name)
        }

        defBuiltin("PATHNAME-TYPE", 1, 1) { args in
            let path = try pathString(args[0])
            let ext = (path as NSString).pathExtension
            return ext.isEmpty ? .null : .str(ext)
        }

        defBuiltin("PATHNAME-DIRECTORY", 1, 1) { args in
            let path = try pathString(args[0])
            let dir = (path as NSString).deletingLastPathComponent
            return dir.isEmpty ? .null : .str(dir)
        }

        defBuiltin("FILE-NAMESTRING", 1, 1) { args in
            let path = try pathString(args[0])
            return .str((path as NSString).lastPathComponent)
        }
    }
}
