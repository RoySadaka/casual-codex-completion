import Foundation

final class CCCMemoryStore {
    static let shared = CCCMemoryStore()

    private struct ActivityRecord: Codable {
        let id: String
        let timestamp: String
        let appName: String
        let source: String
        let prefixTail: String
        let selectedText: String
        let suggestion: String
        let visualContext: String
        let intentAnalysis: String
        let suggestionRationale: String
        let memoryUpdate: String
    }

    private struct FeedbackRecord: Codable {
        let timestamp: String
        let requestID: String
        let appName: String
        let outcome: String
        let suggestion: String
    }

    private let queue = DispatchQueue(label: "ccc.memory_store", qos: .utility)
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()
    private init() {}

    func recordInteraction(
        context: FocusedTextContext,
        instanceID: String,
        sideSuggestion: CodexSideThreadSuggestion
    ) {
        guard CCCConfig.memoryEnabled else {
            return
        }

        let record = ActivityRecord(
            id: instanceID,
            timestamp: Self.nowTimestamp(),
            appName: context.appName,
            source: String(describing: context.source),
            prefixTail: Self.trimForStorage(context.prefix, limit: 1800),
            selectedText: Self.trimForStorage(context.selectedText, limit: 800),
            suggestion: Self.trimForStorage(sideSuggestion.suggestion, limit: 1200),
            visualContext: Self.trimForStorage(sideSuggestion.visualContext, limit: 2400),
            intentAnalysis: Self.trimForStorage(sideSuggestion.intentAnalysis, limit: 1600),
            suggestionRationale: Self.trimForStorage(sideSuggestion.suggestionRationale, limit: 1200),
            memoryUpdate: Self.trimForStorage(sideSuggestion.memoryUpdate, limit: 1200)
        )

        queue.async {
            self.appendJSONLine(record, to: CCCPaths.memoryActivityLogURL)
            self.trimActivityLogIfNeeded()
            self.rebuildSnapshot()
        }
    }

    func recordFeedback(_ feedback: CompletionFeedback) {
        guard CCCConfig.memoryEnabled else {
            return
        }

        let record: FeedbackRecord?
        switch feedback {
        case .approved(let details):
            record = FeedbackRecord(
                timestamp: Self.nowTimestamp(),
                requestID: details.instanceID,
                appName: details.appName,
                outcome: "approved",
                suggestion: Self.trimForStorage(details.suggestion, limit: 1200)
            )
        case .ignored(let details):
            record = FeedbackRecord(
                timestamp: Self.nowTimestamp(),
                requestID: details.instanceID,
                appName: details.appName,
                outcome: "ignored",
                suggestion: Self.trimForStorage(details.suggestion, limit: 1200)
            )
        case .retry:
            record = nil
        }

        guard let record else {
            return
        }

        queue.async {
            self.appendJSONLine(record, to: CCCPaths.memoryFeedbackLogURL)
            self.rebuildSnapshot()
        }
    }

    func clear(completion: (() -> Void)? = nil) {
        queue.async {
            do {
                if FileManager.default.fileExists(atPath: CCCPaths.memoryDirectoryURL.path) {
                    try FileManager.default.removeItem(at: CCCPaths.memoryDirectoryURL)
                }
                AppLogger.info("CCC durable memory cleared")
            } catch {
                AppLogger.error("Failed to clear CCC durable memory: \(error.localizedDescription)")
            }

            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    func activityCount() -> Int {
        guard CCCConfig.memoryEnabled else {
            return 0
        }

        return queue.sync {
            self.loadActivityRecords(limit: CCCConfig.memoryActivityLimit * 3).count
        }
    }

    func hasDurableMemory() -> Bool {
        activityCount() > 0
    }

    func promptContext(for appName: String?) -> String? {
        guard CCCConfig.memoryEnabled else {
            return nil
        }

        if !FileManager.default.fileExists(atPath: CCCPaths.memorySnapshotURL.path) {
            queue.sync {
                self.rebuildSnapshot()
            }
        }

        let baseSnapshot = (try? String(contentsOf: CCCPaths.memorySnapshotURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let appContext = appName.flatMap { currentAppContext(for: $0) }

        let pieces = [baseSnapshot, appContext].compactMap { $0?.nonEmpty }
        guard !pieces.isEmpty else {
            return nil
        }

        let joined = pieces.joined(separator: "\n\n")
        return """
        CCC durable local memory:
        These notes are rebuilt from recent local CCC interactions and should guide personalization without overriding the current field, visible screen, or explicit user text.

        \(Self.trimForPrompt(joined, limit: CCCConfig.memoryPromptCharacterLimit))
        """
    }

    private func rebuildSnapshot() {
        let records = loadActivityRecords(limit: CCCConfig.memoryActivityLimit)
        guard !records.isEmpty else {
            try? FileManager.default.removeItem(at: CCCPaths.memorySnapshotURL)
            return
        }

        let snapshot = Self.buildSnapshot(from: records, feedback: loadFeedbackRecords(limit: 160))
        do {
            try CCCPaths.ensureParentDirectoryExists(for: CCCPaths.memorySnapshotURL)
            try snapshot.write(to: CCCPaths.memorySnapshotURL, atomically: true, encoding: .utf8)
            AppLogger.info("CCC memory snapshot rebuilt with \(records.count) activity records")
        } catch {
            AppLogger.error("Failed to write CCC memory snapshot: \(error.localizedDescription)")
        }
    }

    private func currentAppContext(for appName: String) -> String? {
        let matching = loadActivityRecords(limit: CCCConfig.memoryActivityLimit)
            .filter { $0.appName == appName }
            .suffix(6)

        guard !matching.isEmpty else {
            return nil
        }

        let lines = matching.map { record in
            "- \(Self.shortTimestamp(record.timestamp)) \(Self.oneLine(record.intentAnalysis.nonEmpty ?? record.prefixTail, limit: 180))"
        }

        return """
        Current app recent CCC context for \(appName):
        \(lines.joined(separator: "\n"))
        """
    }

    private func appendJSONLine<T: Encodable>(_ value: T, to url: URL) {
        do {
            try CCCPaths.ensureParentDirectoryExists(for: url)
            let data = try encoder.encode(value)
            guard var line = String(data: data, encoding: .utf8) else {
                return
            }
            line.append("\n")

            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } else {
                try line.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            AppLogger.error("Failed to append CCC memory record: \(error.localizedDescription)")
        }
    }

    private func trimActivityLogIfNeeded() {
        let maxRecords = max(CCCConfig.memoryActivityLimit * 3, CCCConfig.memoryActivityLimit)
        let records = loadActivityRecords(limit: maxRecords + 40)
        guard records.count > maxRecords else {
            return
        }

        let retained = Array(records.suffix(maxRecords))
        let lines = retained.compactMap { record -> String? in
            guard let data = try? encoder.encode(record),
                  let line = String(data: data, encoding: .utf8) else {
                return nil
            }
            return line
        }

        do {
            try CCCPaths.ensureParentDirectoryExists(for: CCCPaths.memoryActivityLogURL)
            try (lines.joined(separator: "\n") + "\n").write(
                to: CCCPaths.memoryActivityLogURL,
                atomically: true,
                encoding: .utf8
            )
        } catch {
            AppLogger.error("Failed to trim CCC memory activity log: \(error.localizedDescription)")
        }
    }

    private func loadActivityRecords(limit: Int) -> [ActivityRecord] {
        loadJSONL(ActivityRecord.self, from: CCCPaths.memoryActivityLogURL, limit: limit)
    }

    private func loadFeedbackRecords(limit: Int) -> [FeedbackRecord] {
        loadJSONL(FeedbackRecord.self, from: CCCPaths.memoryFeedbackLogURL, limit: limit)
    }

    private func loadJSONL<T: Decodable>(_ type: T.Type, from url: URL, limit: Int) -> [T] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }

        let lines = contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(limit)

        return lines.compactMap { line in
            guard let data = String(line).data(using: .utf8) else {
                return nil
            }
            return try? decoder.decode(type, from: data)
        }
    }

    private static func buildSnapshot(from records: [ActivityRecord], feedback: [FeedbackRecord]) -> String {
        let recent = records.suffix(min(12, records.count))
        let appCounts = counted(records.map(\.appName)).prefix(8)
        let people = extractRankedEntities(from: records, kind: .people).prefix(8)
        let projects = extractRankedEntities(from: records, kind: .projects).prefix(10)
        let styleSignals = records
            .map(\.memoryUpdate)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(10)
            .map { "- \(oneLine($0, limit: 180))" }
        let approvals = Dictionary(grouping: feedback, by: \.requestID)

        let recentLines = recent.map { record in
            let outcome = approvals[record.id]?.last?.outcome
            let outcomeText = outcome.map { " [\($0)]" } ?? ""
            let intent = record.intentAnalysis.nonEmpty ?? record.prefixTail
            return "- \(shortTimestamp(record.timestamp)) \(record.appName)\(outcomeText): \(oneLine(intent, limit: 220))"
        }
        let appLines = appCounts.map { "- \($0.key): \($0.value) recent interactions" }
        let peopleLines = people.map { "- \($0.key)" }
        let projectLines = projects.map { "- \($0.key)" }

        return """
        # CCC Chronicle Snapshot

        Recent activity:
        \(recentLines.joined(separator: "\n"))

        Active surfaces:
        \(appLines.isEmpty ? "- No strong app pattern yet." : appLines.joined(separator: "\n"))

        People signals:
        \(peopleLines.isEmpty ? "- No stable people signals yet." : peopleLines.joined(separator: "\n"))

        Projects and topics:
        \(projectLines.isEmpty ? "- No stable project/topic signals yet." : projectLines.joined(separator: "\n"))

        Writing and preference signals:
        \(styleSignals.isEmpty ? "- No stable writing preference signals yet." : styleSignals.joined(separator: "\n"))
        """
    }

    private enum EntityKind {
        case people
        case projects
    }

    private static func extractRankedEntities(from records: [ActivityRecord], kind: EntityKind) -> [(key: String, value: Int)] {
        var counts = [String: Int]()
        for record in records {
            let text = [
                record.prefixTail,
                record.visualContext,
                record.intentAnalysis,
                record.memoryUpdate
            ].joined(separator: "\n")

            let candidates: [String]
            switch kind {
            case .people:
                candidates = extractPeopleCandidates(from: text)
            case .projects:
                candidates = extractProjectCandidates(from: text)
            }

            for candidate in candidates {
                counts[candidate, default: 0] += 1
            }
        }

        return counts
            .filter { $0.value >= 1 }
            .sorted {
                if $0.value == $1.value {
                    return $0.key < $1.key
                }
                return $0.value > $1.value
            }
    }

    private static func extractPeopleCandidates(from text: String) -> [String] {
        let patterns = [
            #"@([A-Za-z][A-Za-z0-9._-]{1,40})"#,
            #"\b(?:to|from|with|for|by)\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+){0,2})\b"#
        ]
        return regexCaptures(patterns: patterns, in: text)
            .map(cleanEntity)
            .filter { !$0.isEmpty && !commonEntityStopwords.contains($0.lowercased()) }
    }

    private static func extractProjectCandidates(from text: String) -> [String] {
        let patterns = [
            #"\b([A-Z]{2,}-\d+)\b"#,
            #"\b(?:project|repo|repository|ticket|issue|pr|task|feature|app)\s*[:#-]?\s*([A-Za-z0-9][A-Za-z0-9 _./-]{2,48})"#
        ]
        return regexCaptures(patterns: patterns, in: text)
            .map(cleanEntity)
            .filter { !$0.isEmpty && !commonEntityStopwords.contains($0.lowercased()) }
    }

    private static func regexCaptures(patterns: [String], in text: String) -> [String] {
        let nsText = text as NSString
        return patterns.flatMap { pattern -> [String] in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return []
            }

            return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
                guard match.numberOfRanges > 1 else {
                    return nil
                }
                return nsText.substring(with: match.range(at: 1))
            }
        }
    }

    private static func cleanEntity(_ value: String) -> String {
        value
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\r.,:;!?()[]{}<>\"'`"))
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func counted(_ values: [String]) -> [(key: String, value: Int)] {
        var counts = [String: Int]()
        values.forEach { counts[$0, default: 0] += 1 }
        return counts.sorted {
            if $0.value == $1.value {
                return $0.key < $1.key
            }
            return $0.value > $1.value
        }
    }

    private static func trimForStorage(_ text: String, limit: Int) -> String {
        trim(text, limit: limit)
    }

    private static func trimForPrompt(_ text: String, limit: Int) -> String {
        trim(text, limit: limit)
    }

    private static func trim(_ text: String, limit: Int) -> String {
        guard text.count > limit else {
            return text
        }

        return String(text.suffix(limit))
    }

    private static func oneLine(_ text: String, limit: Int) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return trim(collapsed, limit: limit)
    }

    private static func shortTimestamp(_ timestamp: String) -> String {
        String(timestamp.prefix(16))
    }

    private static func nowTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static let commonEntityStopwords: Set<String> = [
        "the", "this", "that", "current", "codex", "ccc", "app", "user", "assistant",
        "text", "field", "screen", "message", "chat", "new", "default", "permissions"
    ]
}
