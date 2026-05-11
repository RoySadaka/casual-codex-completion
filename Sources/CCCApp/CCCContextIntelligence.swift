import Foundation

enum CCCContextIntelligence {
    static func promptNotice(for context: FocusedTextContext) -> String {
        let prefixTail = String(context.prefix.suffix(1400))
        let surface = surfaceKind(appName: context.appName, prefix: prefixTail)
        let writingMode = writingMode(for: prefixTail)
        let language = languageHint(for: prefixTail)
        let expectedShape = expectedShape(surface: surface, writingMode: writingMode, prefix: prefixTail)
        let hazards = hazards(for: prefixTail)

        return """
        CCC deterministic context read:
        - Surface: \(surface.description)
        - Writing mode: \(writingMode.description)
        - Language hint: \(language)
        - Expected insertion shape: \(expectedShape)
        - Guardrails: \(hazards.isEmpty ? "No special local hazards detected." : hazards.joined(separator: " "))
        """
    }

    private enum SurfaceKind {
        case chat
        case email
        case codeEditor
        case terminal
        case assistantPrompt
        case taskTracker
        case document
        case generic

        var description: String {
            switch self {
            case .chat:
                return "chat or direct message"
            case .email:
                return "email compose"
            case .codeEditor:
                return "code editor"
            case .terminal:
                return "terminal or shell"
            case .assistantPrompt:
                return "AI assistant prompt"
            case .taskTracker:
                return "task, issue, or project tracker"
            case .document:
                return "document or note"
            case .generic:
                return "generic text field"
            }
        }
    }

    private enum WritingMode {
        case prose
        case code
        case command
        case list
        case question
        case empty

        var description: String {
            switch self {
            case .prose:
                return "natural language"
            case .code:
                return "code"
            case .command:
                return "command"
            case .list:
                return "list or structured notes"
            case .question:
                return "question or request"
            case .empty:
                return "empty or nearly empty field"
            }
        }
    }

    private static func surfaceKind(appName: String, prefix: String) -> SurfaceKind {
        let app = appName.lowercased()
        if ["teams", "slack", "messages", "discord", "whatsapp", "telegram"].contains(where: app.contains) {
            return .chat
        }
        if ["mail", "outlook", "gmail", "spark"].contains(where: app.contains) {
            return .email
        }
        if ["xcode", "code", "cursor", "zed", "sublime", "textmate"].contains(where: app.contains) {
            return .codeEditor
        }
        if ["terminal", "iterm", "warp"].contains(where: app.contains) {
            return .terminal
        }
        if ["codex", "chatgpt", "claude"].contains(where: app.contains) {
            return .assistantPrompt
        }
        if ["linear", "jira", "github", "sourcetree", "notion"].contains(where: app.contains) {
            return .taskTracker
        }
        if ["notes", "pages", "word", "docs", "obsidian"].contains(where: app.contains) {
            return .document
        }
        if looksLikeCode(prefix) {
            return .codeEditor
        }
        return .generic
    }

    private static func writingMode(for prefix: String) -> WritingMode {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .empty
        }
        if looksLikeCode(trimmed) {
            return .code
        }
        if looksLikeCommand(trimmed) {
            return .command
        }
        if looksLikeList(trimmed) {
            return .list
        }
        if trimmed.hasSuffix("?") || trimmed.lowercased().hasPrefix("can you ") || trimmed.lowercased().hasPrefix("please ") {
            return .question
        }
        return .prose
    }

    private static func expectedShape(surface: SurfaceKind, writingMode: WritingMode, prefix: String) -> String {
        switch (surface, writingMode) {
        case (.chat, _):
            return "short reply in the user's voice, usually one message-sized continuation"
        case (.email, _):
            return "email-appropriate continuation with the same greeting/body/signoff style already present"
        case (.codeEditor, .code):
            return "code only, preserving indentation and syntax"
        case (.terminal, _), (_, .command):
            return "shell-ready text only, no explanation unless the field text clearly asks for prose"
        case (.assistantPrompt, _):
            return "clear prompt or instruction continuation, not an answer unless the user is drafting one"
        case (.taskTracker, _):
            return "concise task/ticket wording with concrete next step or acceptance-detail shape"
        case (_, .list):
            return "next bullet or list item with matching marker style"
        case (_, .question):
            return "direct useful answer that belongs in the current field"
        case (_, .empty):
            return "brief starter text appropriate to the visible surface"
        default:
            return "natural continuation, concise and directly insertable"
        }
    }

    private static func hazards(for prefix: String) -> [String] {
        var values = [String]()
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("ccc") || trimmed.hasSuffix("cc") || trimmed.hasSuffix(" c") {
            values.append("Ignore trailing CCC trigger residue.")
        }
        if trimmed.contains("```") {
            values.append("Preserve code-fence structure if continuing a fenced block.")
        }
        if trimmed.last == ":" {
            values.append("The cursor follows a colon, so a concrete item or newline may be better than prose.")
        }
        if trimmed.hasSuffix("-") || trimmed.hasSuffix("*") {
            values.append("Continue as a list item without restating the marker unless needed.")
        }
        return values
    }

    private static func languageHint(for prefix: String) -> String {
        let scalars = prefix.unicodeScalars
        guard !scalars.isEmpty else {
            return "unknown; infer from visible context"
        }

        if scalars.contains(where: { (0x0590...0x05FF).contains(Int($0.value)) }) {
            return "Hebrew appears in the current field; preserve that language unless context says otherwise"
        }
        if scalars.contains(where: { (0x0600...0x06FF).contains(Int($0.value)) }) {
            return "Arabic-script text appears in the current field; preserve that language unless context says otherwise"
        }
        if scalars.contains(where: { (0x0400...0x04FF).contains(Int($0.value)) }) {
            return "Cyrillic text appears in the current field; preserve that language unless context says otherwise"
        }
        return "use the current field's language and tone"
    }

    private static func looksLikeCode(_ text: String) -> Bool {
        let codeMarkers = ["func ", "class ", "struct ", "let ", "var ", "import ", "def ", "const ", "=>", "{", "}", "</", "```"]
        return codeMarkers.contains { text.contains($0) }
    }

    private static func looksLikeCommand(_ text: String) -> Bool {
        let lastLine = text.components(separatedBy: .newlines).last?.trimmingCharacters(in: .whitespaces) ?? text
        let commandPrefixes = ["git ", "npm ", "pnpm ", "yarn ", "swift ", "python ", "node ", "cd ", "ls ", "rg ", "curl ", "docker "]
        return commandPrefixes.contains { lastLine.hasPrefix($0) }
    }

    private static func looksLikeList(_ text: String) -> Bool {
        let lastLine = text.components(separatedBy: .newlines).last?.trimmingCharacters(in: .whitespaces) ?? text
        return lastLine.hasPrefix("- ")
            || lastLine.hasPrefix("* ")
            || lastLine.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
    }
}
