import Foundation

enum CodexAppServerSideSuggestionError: Error {
    case executionFailed(String)
    case cancelled
}

extension CodexAppServerSideSuggestionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .executionFailed(let message):
            return message
        case .cancelled:
            return "Codex app-server side suggestion cancelled"
        }
    }
}

enum CodexAppServerSideSuggestion {
    static func suggest(
        codexPath: String,
        workingDirectory: URL,
        baseSessionID: String,
        model: String,
        reasoningEffort: String?,
        prompt: String,
        imageURL: URL?,
        memoryRecord: @escaping (CodexSideThreadSuggestion) -> String?,
        processWillStart: (Process) -> Void,
        processDidFinish: @escaping (Process) -> Bool,
        completion: @escaping (Result<CodexSideThreadSuggestion, Error>) -> Void
    ) {
        let process = Process()
        let inputPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let finishQueue = DispatchQueue(label: "ccc.codex_app_server_side_suggestion.finish")
        var stdoutText = ""
        var stdoutLineBuffer = ""
        var stderrText = ""
        var sideThreadID: String?
        var assistantText = ""
        var finalAssistantText: String?
        var pendingSuggestion: CodexSideThreadSuggestion?
        var didSendResume = false
        var didSendFork = false
        var didSendTurn = false
        var didSendMemory = false
        var didSendUnsubscribe = false
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
                "threadId": baseSessionID,
                "model": model,
                "cwd": workingDirectory.path,
                "approvalPolicy": "never",
                "sandbox": "read-only",
                "persistExtendedHistory": false,
                "excludeTurns": true
            ] as [String: Any]
        ]

        let forkRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 3,
            "method": "thread/fork",
            "params": [
                "threadId": baseSessionID,
                "model": model,
                "cwd": workingDirectory.path,
                "approvalPolicy": "never",
                "sandbox": "read-only",
                "ephemeral": true,
                "persistExtendedHistory": false,
                "excludeTurns": true
            ] as [String: Any]
        ]

        let initializeLine: Data
        let resumeLine: Data
        let forkLine: Data
        do {
            initializeLine = try jsonRPCLine(initializeRequest)
            resumeLine = try jsonRPCLine(resumeRequest)
            forkLine = try jsonRPCLine(forkRequest)
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

        func finishLocked(_ result: Result<CodexSideThreadSuggestion, Error>) {
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
                completion(.failure(CodexAppServerSideSuggestionError.cancelled))
            } else {
                completion(result)
            }
        }

        func send(_ object: [String: Any]) throws {
            inputPipe.fileHandleForWriting.write(try jsonRPCLine(object))
        }

        func sendTurnStart(threadID: String) throws {
            var input: [[String: Any]] = [
                [
                    "type": "text",
                    "text": prompt,
                    "text_elements": [] as [Any]
                ]
            ]

            if let imageURL {
                input.append([
                    "type": "localImage",
                    "path": imageURL.path
                ])
            }

            var params: [String: Any] = [
                "threadId": threadID,
                "input": input,
                "model": model,
                "approvalPolicy": "never",
                "outputSchema": outputSchema()
            ]

            if let reasoningEffort {
                params["effort"] = reasoningEffort
            }

            try send([
                "jsonrpc": "2.0",
                "id": 4,
                "method": "turn/start",
                "params": params
            ])
        }

        func sendMemoryRecord(_ suggestion: CodexSideThreadSuggestion) throws -> Bool {
            guard let record = memoryRecord(suggestion)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty else {
                return false
            }

            let items: [[String: Any]] = [
                [
                    "type": "message",
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": record
                        ]
                    ]
                ],
                [
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        [
                            "type": "output_text",
                            "text": "noted"
                        ]
                    ]
                ]
            ]

            try send([
                "jsonrpc": "2.0",
                "id": 5,
                "method": "thread/inject_items",
                "params": [
                    "threadId": baseSessionID,
                    "items": items
                ] as [String: Any]
            ])
            return true
        }

        func sendUnsubscribeIfNeeded() throws -> Bool {
            guard let sideThreadID, !didSendUnsubscribe else {
                return false
            }

            didSendUnsubscribe = true
            try send([
                "jsonrpc": "2.0",
                "id": 6,
                "method": "thread/unsubscribe",
                "params": [
                    "threadId": sideThreadID
                ]
            ])
            return true
        }

        func finishAfterSideTurn(_ suggestion: CodexSideThreadSuggestion) {
            pendingSuggestion = suggestion

            do {
                if !didSendMemory {
                    didSendMemory = true
                    if try sendMemoryRecord(suggestion) {
                        return
                    }
                }

                if try sendUnsubscribeIfNeeded() {
                    return
                }

                finishLocked(.success(suggestion))
            } catch {
                AppLogger.error("Failed to finalize Codex side suggestion cleanup: \(error.localizedDescription)")
                finishLocked(.success(suggestion))
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
                        continue
                    }

                    if let method = message["method"] as? String,
                       method == "error" {
                        finishLocked(.failure(CodexAppServerSideSuggestionError.executionFailed(describe(message["params"] ?? message))))
                        return
                    }

                    if let id = message["id"] as? Int {
                        if let error = jsonRPCError(in: message) {
                            if id == 5 || id == 6, let pendingSuggestion {
                                AppLogger.error("Codex side suggestion cleanup failed: \(describe(error))")
                                finishLocked(.success(pendingSuggestion))
                            } else {
                                finishLocked(.failure(CodexAppServerSideSuggestionError.executionFailed(describe(error))))
                            }
                            return
                        }

                        do {
                            switch id {
                            case 1 where !didSendResume:
                                didSendResume = true
                                inputPipe.fileHandleForWriting.write(resumeLine)
                            case 2 where !didSendFork:
                                didSendFork = true
                                inputPipe.fileHandleForWriting.write(forkLine)
                            case 3 where !didSendTurn:
                                guard let threadID = threadID(from: message) else {
                                    finishLocked(.failure(CodexAppServerSideSuggestionError.executionFailed("Codex app-server fork did not return a side thread id")))
                                    return
                                }

                                sideThreadID = threadID
                                didSendTurn = true
                                try sendTurnStart(threadID: threadID)
                            case 5:
                                if let pendingSuggestion {
                                    if try sendUnsubscribeIfNeeded() {
                                        break
                                    }
                                    finishLocked(.success(pendingSuggestion))
                                }
                            case 6:
                                if let pendingSuggestion {
                                    finishLocked(.success(pendingSuggestion))
                                }
                            default:
                                break
                            }
                        } catch {
                            finishLocked(.failure(error))
                            return
                        }
                    }

                    guard let method = message["method"] as? String else {
                        continue
                    }

                    switch method {
                    case "item/agentMessage/delta":
                        if let params = message["params"] as? [String: Any],
                           let delta = params["delta"] as? String {
                            assistantText += delta
                        }
                    case "item/completed":
                        if let params = message["params"] as? [String: Any],
                           let item = params["item"] as? [String: Any],
                           item["type"] as? String == "agentMessage",
                           let text = item["text"] as? String {
                            finalAssistantText = text
                        }
                    case "turn/completed":
                        let outputText = finalAssistantText ?? assistantText
                        let suggestion = parseSuggestion(from: outputText)
                        finishAfterSideTurn(suggestion)
                        return
                    default:
                        break
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
                finishLocked(.failure(CodexAppServerSideSuggestionError.executionFailed(message)))
            }
        }

        processWillStart(process)

        do {
            AppLogger.info("Starting Codex app-server side suggestion from session \(baseSessionID)")
            try process.run()
            inputPipe.fileHandleForWriting.write(initializeLine)
        } catch {
            _ = processDidFinish(process)
            AppLogger.error("Failed to start Codex app-server side suggestion: \(error.localizedDescription)")
            completion(.failure(error))
        }
    }

    private static func outputSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "suggestion": [
                    "type": "string"
                ],
                "situation_summary": [
                    "type": "string"
                ],
                "memory_update": [
                    "type": "string"
                ]
            ],
            "required": ["suggestion", "situation_summary", "memory_update"]
        ]
    }

    private static func parseSuggestion(from text: String) -> CodexSideThreadSuggestion {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText = stripCodeFence(from: trimmed)

        guard let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return CodexSideThreadSuggestion(
                suggestion: trimmed,
                situationSummary: "The side thread returned an unstructured suggestion.",
                memoryUpdate: ""
            )
        }

        return CodexSideThreadSuggestion(
            suggestion: object["suggestion"] as? String ?? "",
            situationSummary: object["situation_summary"] as? String ?? "",
            memoryUpdate: object["memory_update"] as? String ?? ""
        )
    }

    private static func stripCodeFence(from text: String) -> String {
        guard text.hasPrefix("```") else {
            return text
        }

        var lines = text.components(separatedBy: .newlines)
        if !lines.isEmpty {
            lines.removeFirst()
        }
        if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func threadID(from message: [String: Any]) -> String? {
        guard let result = message["result"] as? [String: Any],
              let thread = result["thread"] as? [String: Any],
              let id = thread["id"] as? String,
              !id.isEmpty else {
            return nil
        }

        return id
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

    private static func jsonRPCError(in message: [String: Any]) -> Any? {
        guard let error = message["error"], !(error is NSNull) else {
            return nil
        }

        return error
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
