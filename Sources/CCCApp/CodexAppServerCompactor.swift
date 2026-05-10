import Foundation

enum CodexAppServerCompactorError: Error {
    case executionFailed(String)
    case cancelled
}

extension CodexAppServerCompactorError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .executionFailed(let message):
            return message
        case .cancelled:
            return "Codex app-server compaction cancelled"
        }
    }
}

enum CodexAppServerCompactor {
    static func compact(
        codexPath: String,
        workingDirectory: URL,
        sessionID: String,
        processWillStart: (Process) -> Void,
        processDidFinish: @escaping (Process) -> Bool,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let process = Process()
        let inputPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let finishQueue = DispatchQueue(label: "ccc.codex_app_server_compactor.finish")
        var stdoutText = ""
        var stdoutLineBuffer = ""
        var stderrText = ""
        var sentResume = false
        var sentCompaction = false
        var didFinish = false

        let initializeRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "ccc",
                    "title": NSNull(),
                    "version": "0"
                ] as [String: Any],
                "capabilities": [
                    "experimentalApi": true
                ] as [String: Any]
            ] as [String: Any]
        ]
        let resumeRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "thread/resume",
            "params": [
                "threadId": sessionID,
                "persistExtendedHistory": false,
                "excludeTurns": true
            ] as [String: Any]
        ]
        let compactRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 3,
            "method": "thread/compact/start",
            "params": [
                "threadId": sessionID
            ] as [String: Any]
        ]

        let initializeLine: Data
        let resumeLine: Data
        let compactLine: Data
        do {
            initializeLine = try jsonRPCLine(initializeRequest)
            resumeLine = try jsonRPCLine(resumeRequest)
            compactLine = try jsonRPCLine(compactRequest)
        } catch {
            completion(.failure(error))
            return
        }

        process.executableURL = URL(fileURLWithPath: codexPath)
        process.currentDirectoryURL = workingDirectory
        process.standardInput = inputPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.arguments = ["app-server", "--listen", "stdio://"]

        func finishLocked(_ result: Result<Void, Error>) {
            guard !didFinish else {
                return
            }

            didFinish = true
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            try? inputPipe.fileHandleForWriting.close()

            let wasCancelled = processDidFinish(process)

            if process.isRunning {
                process.terminate()
            }

            if wasCancelled {
                completion(.failure(CodexAppServerCompactorError.cancelled))
            } else {
                completion(result)
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }

            let text = String(data: data, encoding: .utf8) ?? ""
            finishQueue.async {
                stdoutText += text
                stdoutLineBuffer += text

                while let newlineRange = stdoutLineBuffer.range(of: "\n") {
                    let rawLine = String(stdoutLineBuffer[..<newlineRange.lowerBound])
                    stdoutLineBuffer.removeSubrange(...newlineRange.lowerBound)
                    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty else {
                        continue
                    }

                    guard let message = jsonObject(from: line) else {
                        if line.contains("context_compacted") {
                            finishLocked(.success(()))
                            return
                        }
                        continue
                    }

                    if let id = message["id"] as? Int {
                        if let error = message["error"] {
                            finishLocked(.failure(CodexAppServerCompactorError.executionFailed(describe(error))))
                            return
                        }

                        switch id {
                        case 1 where !sentResume:
                            sentResume = true
                            inputPipe.fileHandleForWriting.write(resumeLine)
                        case 2 where !sentCompaction:
                            sentCompaction = true
                            inputPipe.fileHandleForWriting.write(compactLine)
                        default:
                            break
                        }
                    }

                    if let method = message["method"] as? String,
                       method == "turn/completed" || method == "thread/compacted" {
                        finishLocked(.success(()))
                        return
                    }

                    if line.contains("context_compacted") {
                        finishLocked(.success(()))
                        return
                    }
                }
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }

            let text = String(data: data, encoding: .utf8) ?? ""
            finishQueue.async {
                stderrText += text
            }
        }

        process.terminationHandler = { _ in
            finishQueue.async {
                guard !didFinish else {
                    return
                }

                let message = stderrText.nonEmpty
                    ?? stdoutText.nonEmpty
                    ?? "Codex app-server exited with status \(process.terminationStatus)"
                finishLocked(.failure(CodexAppServerCompactorError.executionFailed(message)))
            }
        }

        processWillStart(process)

        do {
            AppLogger.info("Starting Codex app-server compaction for session \(sessionID)")
            try process.run()
            inputPipe.fileHandleForWriting.write(initializeLine)
        } catch {
            _ = processDidFinish(process)
            AppLogger.error("Failed to start Codex app-server compaction: \(error.localizedDescription)")
            completion(.failure(error))
        }
    }

    private static func jsonRPCLine(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [])
        data.append(0x0A)
        return data
    }

    private static func jsonObject(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return object
    }

    private static func describe(_ value: Any) -> String {
        if let string = value as? String {
            return string
        }

        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }

        return String(describing: value)
    }
}
