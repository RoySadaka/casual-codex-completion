import Foundation

enum CCCConfig {
    static let defaultPromptPrefixCharacterLimit = 4096

    static func stringValue(forKey key: String) -> String? {
        guard var value = rawValue(forKey: key) ?? defaultStringValue(forKey: key) else {
            return nil
        }

        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }

        return value
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    static func requiredStringValue(forKey key: String) -> String {
        guard let value = stringValue(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty else {
            fatalError("Missing required config key '\(key)' in \(configPathDescription())")
        }

        return value
    }

    static func boolValue(forKey key: String) -> Bool? {
        guard let rawValue = rawValue(forKey: key) else {
            return defaultBoolValue(forKey: key)
        }

        let value = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch value {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    static func requiredBoolValue(forKey key: String) -> Bool {
        guard let value = boolValue(forKey: key) else {
            fatalError("Missing or invalid boolean config key '\(key)' in \(configPathDescription())")
        }

        return value
    }

    static func intValue(forKey key: String) -> Int? {
        let configuredValue: String?
        if let configured = rawValue(forKey: key) {
            configuredValue = configured
        } else if let defaultValue = defaultIntValue(forKey: key) {
            configuredValue = String(defaultValue)
        } else {
            configuredValue = nil
        }

        guard let configuredValue else {
            return nil
        }

        return Int(configuredValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static var promptPrefixCharacterLimit: Int {
        guard let value = intValue(forKey: "prompt_prefix_char_limit"), value > 0 else {
            return defaultPromptPrefixCharacterLimit
        }

        return value
    }

    static func setStringValue(_ value: String?, forKey key: String) throws {
        let assignment = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
            .flatMap { nonEmpty -> String? in
            guard !nonEmpty.isEmpty else { return nil }
            return "\(key) = \"\(escape(nonEmpty))\""
        }

        try setAssignment(assignment, forKey: key)
    }

    static func setBoolValue(_ value: Bool, forKey key: String) throws {
        try setAssignment("\(key) = \(value ? "true" : "false")", forKey: key)
    }

    private static func rawValue(forKey key: String) -> String? {
        let url = CCCPaths.configFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                continue
            }

            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                continue
            }

            let candidateKey = parts[0].trimmingCharacters(in: .whitespaces)
            guard candidateKey == key else {
                continue
            }

            return parts[1].trimmingCharacters(in: .whitespaces)
        }

        return nil
    }

    private static func setAssignment(_ assignment: String?, forKey key: String) throws {
        let url = CCCPaths.configFileURL
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            try CCCPaths.ensureParentDirectoryExists(for: url)
            try "".write(to: url, atomically: true, encoding: .utf8)
        }

        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = contents.components(separatedBy: .newlines)
        if lines.last == "" {
            lines.removeLast()
        }

        var replaced = false
        lines = lines.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                return line
            }

            let candidateKey = parts[0].trimmingCharacters(in: .whitespaces)
            guard candidateKey == key else {
                return line
            }

            replaced = true
            return assignment
        }

        if !replaced, let assignment {
            if !lines.isEmpty {
                lines.append("")
            }
            lines.append(assignment)
        }

        let newContents = lines.joined(separator: "\n") + "\n"
        try newContents.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func configPathDescription() -> String {
        CCCPaths.configFileURL.path
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func defaultStringValue(forKey key: String) -> String? {
        switch key {
        case "codex_cli_path":
            let defaultPath = "/Applications/Codex.app/Contents/Resources/codex"
            return FileManager.default.isExecutableFile(atPath: defaultPath) ? defaultPath : nil
        case "model":
            return "gpt-5.5"
        case "reasoning_effort":
            return "medium"
        default:
            return nil
        }
    }

    private static func defaultBoolValue(forKey key: String) -> Bool? {
        switch key {
        case "dev_mode":
            return false
        default:
            return nil
        }
    }

    private static func defaultIntValue(forKey key: String) -> Int? {
        switch key {
        case "prompt_prefix_char_limit":
            return defaultPromptPrefixCharacterLimit
        default:
            return nil
        }
    }
}

extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
