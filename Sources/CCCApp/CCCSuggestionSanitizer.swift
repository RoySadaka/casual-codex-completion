import Foundation

enum CCCSuggestionSanitizer {
    static func sanitize(_ rawSuggestion: String?, for context: FocusedTextContext) -> String? {
        guard var suggestion = rawSuggestion?.trimmingCharacters(in: .newlines) else {
            return nil
        }

        suggestion = extractSuggestionIfStructured(suggestion)
        suggestion = stripCodeFenceIfOnlyWrapper(suggestion)
        suggestion = stripSurroundingQuotes(suggestion)
        suggestion = stripKnownLabels(suggestion)
        suggestion = removeRepeatedPrefix(from: suggestion, prefix: context.prefix)
        suggestion = trimTriggerResidue(suggestion)

        guard suggestion.contains(where: { !$0.isNewline }) else {
            return nil
        }

        let normalized = suggestion.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !["c", "cc", "ccc"].contains(normalized) else {
            AppLogger.error("Rejected CCC suggestion because it only contained trigger residue")
            return nil
        }

        let prefixTail = context.prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !prefixTail.isEmpty && normalized == String(prefixTail.suffix(normalized.count)) {
            AppLogger.error("Rejected CCC suggestion because it only repeated text before the cursor")
            return nil
        }

        return suggestion
    }

    private static func extractSuggestionIfStructured(_ text: String) -> String {
        let trimmed = stripCodeFenceIfOnlyWrapper(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return text
        }

        return object["suggestion"] as? String
            ?? object["completion"] as? String
            ?? object["text"] as? String
            ?? text
    }

    private static func stripCodeFenceIfOnlyWrapper(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else {
            return text
        }

        var lines = trimmed.components(separatedBy: .newlines)
        guard lines.count >= 2 else {
            return text
        }

        lines.removeFirst()
        if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    private static func stripSurroundingQuotes(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            return text
        }

        let quotePairs: [(Character, Character)] = [("\"", "\""), ("'", "'")]
        for pair in quotePairs where trimmed.first == pair.0 && trimmed.last == pair.1 {
            return String(trimmed.dropFirst().dropLast())
        }
        return text
    }

    private static func stripKnownLabels(_ text: String) -> String {
        let labels = ["suggestion:", "completion:", "insert:", "text:"]
        let trimmedLeading = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmedLeading.lowercased()

        for label in labels where lowercased.hasPrefix(label) {
            return String(trimmedLeading.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return text
    }

    private static func removeRepeatedPrefix(from suggestion: String, prefix: String) -> String {
        let prefixLastLine = prefix
            .components(separatedBy: .newlines)
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard prefixLastLine.count >= 8 else {
            return suggestion
        }

        let suggestionTrimmedLeading = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard suggestionTrimmedLeading.hasPrefix(prefixLastLine) else {
            return suggestion
        }

        let remainder = suggestionTrimmedLeading.dropFirst(prefixLastLine.count)
        guard !remainder.isEmpty else {
            return suggestion
        }

        AppLogger.info("Trimmed repeated prefix from CCC suggestion")
        return String(remainder)
    }

    private static func trimTriggerResidue(_ text: String) -> String {
        var value = text
        let leadingTrimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if leadingTrimmed.lowercased().hasPrefix("ccc ") {
            value = String(leadingTrimmed.dropFirst(4))
        }
        return value
    }
}
