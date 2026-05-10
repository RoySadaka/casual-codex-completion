import Foundation

protocol CompletionEngine {
    func suggest(
        for context: FocusedTextContext,
        instanceOrder: Int,
        instanceID: String,
        completion: @escaping (Result<String?, Error>) -> Void
    )
    func retrySuggestion(completion: @escaping (Result<String?, Error>) -> Void)
    func start()
    func resetSession(completion: (() -> Void)?)
    func cancelInFlightRequest()
    func recordFeedback(_ feedback: CompletionFeedback, completion: (() -> Void)?)
    func compactSession(completion: @escaping (Result<Void, Error>) -> Void)
}

extension CompletionEngine {
    func start() {}
    func retrySuggestion(completion: @escaping (Result<String?, Error>) -> Void) {
        completion(.failure(CodexCLIError.executionFailed("Retry is unavailable")))
    }
    func resetSession() {
        resetSession(completion: nil)
    }

    func resetSession(completion: (() -> Void)?) {
        completion?()
    }

    func cancelInFlightRequest() {}

    func recordFeedback(_ feedback: CompletionFeedback, completion: (() -> Void)?) {
        completion?()
    }

    func compactSession(completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }
}

enum CompletionFeedback {
    case approved(CompletionFeedbackDetails)
    case ignored(CompletionFeedbackDetails)
    case retry
}

struct CompletionFeedbackDetails {
    let instanceOrder: Int
    let instanceID: String
    let appName: String
    let suggestion: String
}

struct CodexSideThreadSuggestion {
    let suggestion: String
    let visualContext: String
    let intentAnalysis: String
    let suggestionRationale: String
    let memoryUpdate: String
}

private enum PromptRole {
    private static let userNameKey = "user_name"

    private enum TemplateKind: CaseIterable {
        case initialization
        case continuation
        case appContext
        case screenshotContext
        case userIdentity
        case feedbackApproved
        case feedbackIgnored
        case feedbackRetry
        case defaultUserName

        var fileName: String {
            switch self {
            case .initialization:
                return "role_init.md"
            case .continuation:
                return "role_continue.md"
            case .appContext:
                return "helper_app_context.md"
            case .screenshotContext:
                return "helper_screenshot_context.md"
            case .userIdentity:
                return "helper_user_identity.md"
            case .feedbackApproved:
                return "feedback_approved.md"
            case .feedbackIgnored:
                return "feedback_ignored.md"
            case .feedbackRetry:
                return "feedback_retry.md"
            case .defaultUserName:
                return "helper_default_user_name.md"
            }
        }
    }

    private static let placeholder = "{{PREFIX}}"
    private static let userNamePlaceholder = "{{USER_NAME}}"
    private static let appNamePlaceholder = "{{APP_NAME}}"

    static func initializationPrompt() -> String {
        validateRequiredTemplates()
        return injectUserName(into: loadRequiredTemplate(.initialization))
    }

    static func continuationPrompt(
        for context: FocusedTextContext,
        instanceOrder: Int,
        instanceID: String
    ) -> String {
        let trimmedPrefix = String(context.prefix.suffix(CCCConfig.promptPrefixCharacterLimit))
        let template = injectUserName(into: loadRequiredTemplate(.continuation))
        guard template.contains(placeholder) else {
            fatalError("Required continuation prompt is missing placeholder \(placeholder)")
        }
        let instanceNotice = """
        CCC request metadata:
        - CCC request ID: \(instanceID)
        - CCC instance: \(instanceOrder)
        - Treat the request ID as the stable label for this specific suggestion request.
        - Do not include this metadata in the completion text.
        """
        let appContextNotice = appContextPrompt(for: context)
        let screenshotNotice: String
        if context.screenshotURL != nil {
            screenshotNotice = [instanceNotice, appContextNotice, screenshotContextPrompt(), userIdentityPrompt()]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        } else {
            screenshotNotice = [instanceNotice, appContextNotice]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }

        let filledTemplate = template.replacingOccurrences(of: placeholder, with: trimmedPrefix)
        guard !screenshotNotice.isEmpty else {
            return filledTemplate
        }

        return """
        \(screenshotNotice)

        \(filledTemplate)
        """
    }

    static func sideThreadPrompt(
        for context: FocusedTextContext,
        instanceOrder: Int,
        instanceID: String
    ) -> String {
        let trimmedPrefix = String(context.prefix.suffix(CCCConfig.promptPrefixCharacterLimit))
        let contextNotices = [
            """
            CCC request metadata:
            - CCC request ID: \(instanceID)
            - CCC instance: \(instanceOrder)
            - Treat the request ID as the stable label for this specific suggestion request.
            - Do not include this metadata in the suggestion text.
            """,
            appContextPrompt(for: context),
            context.screenshotURL == nil ? "" : screenshotContextPrompt(),
            context.screenshotURL == nil ? "" : userIdentityPrompt()
        ]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        let prompt = """
        You are running in a disposable CCC visual side thread.

        For this side-thread turn only, return JSON instead of raw insertion text. The main CCC thread will receive only the text summary from this JSON; screenshots must remain local to this side thread.

        Return a JSON object with exactly these string fields:
        - suggestion: the exact text to insert next
        - visual_context: a detailed text-only report of what is visible and relevant in the screenshot/app
        - intent_analysis: what {{USER_NAME}} appears to be trying to do in this field and who the text is for
        - suggestion_rationale: why this suggestion fits the visible context, or why an empty suggestion is necessary
        - memory_update: only stable writing-style or preference signal the main CCC thread should remember; do not turn one-off bad outputs into style

        Assistant rules:
        - Treat {{USER_NAME}} as the person using CCC.
        - Return the insertion text in suggestion only; never put explanations, labels, markdown, or JSON wrappers inside suggestion.
        - Do not repeat or restate text that already appears before the cursor.
        - Ignore any visible "ccc", "cc", or "c" trigger residue. Those letters are the invocation marker, not text to complete, copy, or learn from.
        - Never set suggestion to "c", "cc", "ccc", or a continuation of the invocation marker.
        - Behave like a capable personal assistant embedded at the cursor, not just an autocomplete system.
        - Decide whether the situation calls for continuing the current sentence, drafting on {{USER_NAME}}'s behalf, answering a question, turning an intent into a message, writing a task/prompt/note, or giving concise next-step help.
        - If the current field is addressed to someone else, write as {{USER_NAME}} to that person, not as an assistant speaking to {{USER_NAME}}.
        - If {{USER_NAME}} appears to be asking for help, write the helpful response that belongs in the current field.
        - Use the screenshot to infer the current task, relationship, surface, and intended audience when that is visually clear.
        - Make visual_context useful to the main CCC thread. Include the app, focused surface, visible conversation/document/task, relevant nearby text, intended audience, and whether trigger residue is visible. Do not compress it to one vague sentence.
        - Match {{USER_NAME}}'s language, tone, style, formatting, punctuation, and level of warmth or brevity.
        - Include a leading space, punctuation mark, or newline in suggestion if that is part of the correct insertion.
        - Preserve the current writing mode. If {{USER_NAME}} is writing code, keep writing code. If they are writing a message, keep writing the message.
        - CCC was explicitly invoked, so make a useful attempt. If the exact intent is unclear, write a short, safe, context-appropriate draft, starter, follow-up, clarification, or next-step text that belongs in the focused field.
        - Set suggestion to an empty string only when producing any text would be clearly wrong, impossible, or unsafe.

        \(contextNotices)

        Text before cursor:
        \(trimmedPrefix)
        """
        return injectUserName(into: prompt)
    }

    static func mainThreadMemoryRecord(
        for context: FocusedTextContext,
        instanceOrder: Int,
        instanceID: String,
        sideSuggestion: CodexSideThreadSuggestion
    ) -> String {
        let trimmedPrefix = String(context.prefix.suffix(1200))
        let record = """
        CCC text-only interaction update.

        Request:
        - CCC request ID: \(instanceID)
        - CCC instance: \(instanceOrder)
        - App: \(context.appName)

        Text before cursor tail:
        \(trimmedPrefix)

        Disposable side-thread visual context report:
        \(sideSuggestion.visualContext)

        Side-thread intent analysis:
        \(sideSuggestion.intentAnalysis)

        Suggestion shown to {{USER_NAME}}:
        \(sideSuggestion.suggestion)

        Side-thread suggestion rationale:
        \(sideSuggestion.suggestionRationale)

        Suggestion validity note:
        \(suggestionValidityNote(sideSuggestion.suggestion))

        Memory update:
        \(sideSuggestion.memoryUpdate)

        Note: any screenshot for this request was used only inside an ephemeral side thread and was not added to this main thread.
        """
        return injectUserName(into: record)
    }

    private static func suggestionValidityNote(_ suggestion: String) -> String {
        let normalized = suggestion
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if ["c", "cc", "ccc"].contains(normalized) {
            return "Invalid suggestion: this looks like CCC invocation trigger residue, not useful user text. Do not learn it as style."
        }

        return "No automatic invalidity detected."
    }

    static func feedbackPrompt(for feedback: CompletionFeedback) -> String {
        let basePrompt: String
        let details: CompletionFeedbackDetails?

        switch feedback {
        case .approved(let feedbackDetails):
            basePrompt = injectUserName(into: loadRequiredTemplate(.feedbackApproved))
            details = feedbackDetails
        case .ignored(let feedbackDetails):
            basePrompt = injectUserName(into: loadRequiredTemplate(.feedbackIgnored))
            details = feedbackDetails
        case .retry:
            basePrompt = injectUserName(into: loadRequiredTemplate(.feedbackRetry))
            details = nil
        }

        guard let details else {
            return basePrompt
        }

        return """
        \(basePrompt)

        Feedback context:
        - CCC instance: \(details.instanceOrder)
        - CCC request ID: \(details.instanceID)
        - App: \(details.appName)
        - Suggestion:
        \(details.suggestion)
        """
    }

    private static func validateRequiredTemplates() {
        TemplateKind.allCases.forEach { _ = loadRequiredTemplate($0) }
    }

    private static func loadRequiredTemplate(_ kind: TemplateKind) -> String {
        let candidateURLs = CCCPaths.promptTemplateSearchPaths(fileName: kind.fileName)

        for url in candidateURLs {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }

            let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }

            fatalError("Required prompt file is empty: \(url.path)")
        }

        let searchedPaths = candidateURLs.map(\.path).joined(separator: ", ")
        fatalError("Required prompt file '\(kind.fileName)' was not found. Searched: \(searchedPaths)")
    }

    private static func configuredUserName() -> String? {
        CCCConfig.stringValue(forKey: userNameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }

    private static func injectUserName(into template: String) -> String {
        let userName = configuredUserName() ?? loadRequiredTemplate(.defaultUserName)
        return template.replacingOccurrences(of: userNamePlaceholder, with: userName)
    }

    private static func appContextPrompt(for context: FocusedTextContext) -> String {
        guard context.appName != "unknown" else {
            return ""
        }

        let template = loadRequiredTemplate(.appContext)
        return template.replacingOccurrences(of: appNamePlaceholder, with: context.appName)
    }

    private static func screenshotContextPrompt() -> String {
        injectUserName(into: loadRequiredTemplate(.screenshotContext))
    }

    private static func userIdentityPrompt() -> String {
        guard configuredUserName() != nil else {
            return ""
        }

        let template = loadRequiredTemplate(.userIdentity)
        return injectUserName(into: template)
    }
}

final class CompositeCompletionEngine: CompletionEngine {
    private let codexCLIEngine = CodexCLICompletionEngine.fromConfiguration()

    func start() {
        codexCLIEngine.start()
    }

    func resetSession(completion: (() -> Void)?) {
        AppLogger.info("Composite completion engine resetting Codex session")
        codexCLIEngine.resetSession(completion: completion)
    }

    func cancelInFlightRequest() {
        codexCLIEngine.cancelInFlightRequest()
    }

    func recordFeedback(_ feedback: CompletionFeedback, completion: (() -> Void)?) {
        codexCLIEngine.recordFeedback(feedback, completion: completion)
    }

    func compactSession(completion: @escaping (Result<Void, Error>) -> Void) {
        codexCLIEngine.compactSession(completion: completion)
    }

    func retrySuggestion(completion: @escaping (Result<String?, Error>) -> Void) {
        codexCLIEngine.retrySuggestion(completion: completion)
    }

    func suggest(
        for context: FocusedTextContext,
        instanceOrder: Int,
        instanceID: String,
        completion: @escaping (Result<String?, Error>) -> Void
    ) {
        AppLogger.info("Using Codex CLI completion engine")
        codexCLIEngine.suggest(for: context, instanceOrder: instanceOrder, instanceID: instanceID) { result in
            switch result {
            case .success(let suggestion):
                if let suggestion, !suggestion.isEmpty {
                    completion(.success(suggestion))
                } else {
                    AppLogger.info("Codex CLI returned no suggestion")
                    completion(.success(nil))
                }
            case .failure(let error):
                if case CodexCLIError.cancelled = error {
                    AppLogger.info("Codex CLI request cancelled")
                } else {
                    AppLogger.error("Codex CLI engine failed: \(error.localizedDescription)")
                }
                completion(.failure(error))
            }
        }
    }
}

final class CodexCLICompletionEngine: CompletionEngine {
    private enum ContinuationPurpose: String {
        case suggestion
        case feedback
        case retry
    }

    private enum RequestKind {
        case warmup(epoch: Int)
        case continuation(sessionID: String, purpose: ContinuationPurpose)
    }

    private enum SessionRoutingDecision {
        case resume(sessionID: String)
        case waitForWarmup
        case waitForActiveContinuation
        case failMissingSession
    }

    private let codexPath: String
    private let model: String
    private let reasoningEffort: String?
    private let workingDirectory: URL
    private let sessionsRootURL: URL
    private let persistedSessionURL: URL
    private let stateQueue = DispatchQueue(label: "ccc.codex_cli.state")
    private let warmupGroup = DispatchGroup()
    private let continuationGroup = DispatchGroup()
    private var sessionID: String?
    private var sessionEpoch = 0
    private var warmupStarted = false
    private var warmupFinished = false
    private var activeContinuationProcess: Process?
    private var activeCompactionProcess: Process?
    private var cancelledProcessIdentifiers = Set<ObjectIdentifier>()

    init(
        codexPath: String,
        model: String,
        reasoningEffort: String?,
        workingDirectory: URL,
        sessionsRootURL: URL,
        persistedSessionURL: URL
    ) {
        self.codexPath = codexPath
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.workingDirectory = workingDirectory
        self.sessionsRootURL = sessionsRootURL
        self.persistedSessionURL = persistedSessionURL
        if let persistedSessionID = Self.loadPersistedSessionID(from: persistedSessionURL) {
            sessionID = persistedSessionID
            warmupStarted = true
            warmupFinished = true
        }
    }

    static func fromConfiguration() -> CodexCLICompletionEngine {
        let codexPath = CCCConfig.requiredStringValue(forKey: "codex_cli_path")
        guard FileManager.default.isExecutableFile(atPath: codexPath) else {
            fatalError("Configured codex_cli_path is not executable: \(codexPath)")
        }

        let model = CCCConfig.requiredStringValue(forKey: "model")
        let reasoningEffort = Self.normalizedCodexReasoningEffort(CCCConfig.stringValue(forKey: "reasoning_effort"))
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let workingDirectory = homeDirectory
        let sessionsRootURL = homeDirectory
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions")
        let persistedSessionURL = Self.persistedSessionURL()
        let loggedSessionID = Self.loadPersistedSessionID(from: persistedSessionURL) ?? "<none>"
        AppLogger.info(
            "Codex CLI mode enabled. Path=\(codexPath) Model=\(model) ReasoningEffort=\(reasoningEffort ?? "<unset>") SessionID=\(loggedSessionID)"
        )
        return CodexCLICompletionEngine(
            codexPath: codexPath,
            model: model,
            reasoningEffort: reasoningEffort,
            workingDirectory: workingDirectory,
            sessionsRootURL: sessionsRootURL,
            persistedSessionURL: persistedSessionURL
        )
    }

    func start() {
        guard let epoch = beginWarmupIfNeeded(reason: "startup") else {
            return
        }

        performWarmup(for: epoch)
    }

    func resetSession(completion: (() -> Void)?) {
        let resetState = stateQueue.sync { () -> (previousSessionID: String?, nextEpoch: Int) in
            let previousSessionID = sessionID
            sessionEpoch += 1
            sessionID = nil
            warmupStarted = false
            warmupFinished = false
            return (previousSessionID, sessionEpoch)
        }

        AppLogger.info(
            "Codex session reset requested. PreviousSessionID=\(resetState.previousSessionID ?? "<none>"). New warm-up epoch=\(resetState.nextEpoch)"
        )
        Self.clearPersistedSessionID(at: persistedSessionURL)

        guard let epoch = beginWarmupIfNeeded(reason: "explicit reset") else {
            completion?()
            return
        }

        performWarmup(for: epoch)
        warmupGroup.notify(queue: .main) {
            completion?()
        }
    }

    func cancelInFlightRequest() {
        let processToCancel = stateQueue.sync { () -> Process? in
            if let activeContinuationProcess, activeContinuationProcess.isRunning {
                cancelledProcessIdentifiers.insert(ObjectIdentifier(activeContinuationProcess))
                return activeContinuationProcess
            }

            if let activeCompactionProcess, activeCompactionProcess.isRunning {
                cancelledProcessIdentifiers.insert(ObjectIdentifier(activeCompactionProcess))
                return activeCompactionProcess
            }

            return nil
        }

        guard let processToCancel else {
            return
        }

        AppLogger.info("Stopping the active Codex CLI request")
        processToCancel.terminate()
    }

    func suggest(
        for context: FocusedTextContext,
        instanceOrder: Int,
        instanceID: String,
        completion: @escaping (Result<String?, Error>) -> Void
    ) {
        let route = stateQueue.sync { () -> SessionRoutingDecision in
            if let activeContinuationProcess,
               activeContinuationProcess.isRunning {
                return .waitForActiveContinuation
            }
            if let activeCompactionProcess,
               activeCompactionProcess.isRunning {
                return .waitForActiveContinuation
            }

            if let sessionID, !sessionID.isEmpty {
                return .resume(sessionID: sessionID)
            }

            if !warmupStarted {
                return .waitForWarmup
            }

            if !warmupFinished {
                return .waitForWarmup
            }

            return .failMissingSession
        }

        switch route {
        case .resume(let sessionID):
            let prompt = sideThreadPrompt(for: context, instanceOrder: instanceOrder, instanceID: instanceID)
            runSideSuggestionProcess(
                sessionID: sessionID,
                prompt: prompt,
                imageURL: context.screenshotURL,
                context: context,
                instanceOrder: instanceOrder,
                instanceID: instanceID
            ) { result in
                switch result {
                case .success(let payload):
                    AppLogger.info(
                        "Codex side suggestion decoded. SuggestionLength=\((payload.suggestion as NSString).length) SessionID=\(sessionID)"
                    )
                    completion(.success(payload.suggestion))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        case .waitForWarmup:
            start()
            AppLogger.info("Waiting for hidden Codex warm-up session before sending completion request")
            warmupGroup.notify(queue: .global(qos: .userInitiated)) { [weak self] in
                guard let self else { return }
                self.suggest(for: context, instanceOrder: instanceOrder, instanceID: instanceID, completion: completion)
            }
        case .waitForActiveContinuation:
            AppLogger.info("Waiting for active Codex continuation before sending completion request")
            continuationGroup.notify(queue: .global(qos: .userInitiated)) { [weak self] in
                guard let self else { return }
                self.suggest(for: context, instanceOrder: instanceOrder, instanceID: instanceID, completion: completion)
            }
        case .failMissingSession:
            let message = "No active Codex session is available. Reset the session to create a new one."
            AppLogger.error(message)
            completion(.failure(CodexCLIError.executionFailed(message)))
        }
    }

    func retrySuggestion(completion: @escaping (Result<String?, Error>) -> Void) {
        let route = stateQueue.sync { () -> SessionRoutingDecision in
            if let activeContinuationProcess,
               activeContinuationProcess.isRunning {
                return .waitForActiveContinuation
            }
            if let activeCompactionProcess,
               activeCompactionProcess.isRunning {
                return .waitForActiveContinuation
            }

            if let sessionID, !sessionID.isEmpty {
                return .resume(sessionID: sessionID)
            }

            if !warmupStarted || !warmupFinished {
                return .waitForWarmup
            }

            return .failMissingSession
        }

        switch route {
        case .resume(let sessionID):
            let prompt = PromptRole.feedbackPrompt(for: .retry)
            AppLogger.info("Requesting Codex retry alternative: \(prompt)")
            runProcess(
                prompt: prompt,
                imageURLs: [],
                requestKind: .continuation(sessionID: sessionID, purpose: .retry)
            ) { result in
                switch result {
                case .success(let payload):
                    AppLogger.info(
                        "Codex retry response decoded. SuggestionLength=\((payload.outputText ?? "") as NSString).length SessionID=\(sessionID)"
                    )
                    completion(.success(payload.outputText))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        case .waitForWarmup:
            start()
            AppLogger.info("Waiting for hidden Codex warm-up session before requesting retry alternative")
            warmupGroup.notify(queue: .global(qos: .userInitiated)) { [weak self] in
                self?.retrySuggestion(completion: completion)
            }
        case .waitForActiveContinuation:
            AppLogger.info("Waiting for active Codex continuation before requesting retry alternative")
            continuationGroup.notify(queue: .global(qos: .userInitiated)) { [weak self] in
                self?.retrySuggestion(completion: completion)
            }
        case .failMissingSession:
            let message = "No active Codex session is available. Reset the session to create a new one."
            AppLogger.error(message)
            completion(.failure(CodexCLIError.executionFailed(message)))
        }
    }

    func recordFeedback(_ feedback: CompletionFeedback, completion: (() -> Void)?) {
        let route = stateQueue.sync { () -> SessionRoutingDecision in
            if let activeContinuationProcess,
               activeContinuationProcess.isRunning {
                return .waitForActiveContinuation
            }
            if let activeCompactionProcess,
               activeCompactionProcess.isRunning {
                return .waitForActiveContinuation
            }

            if let sessionID, !sessionID.isEmpty {
                return .resume(sessionID: sessionID)
            }

            if !warmupStarted || !warmupFinished {
                return .waitForWarmup
            }

            return .failMissingSession
        }

        switch route {
        case .resume(let sessionID):
            let prompt = PromptRole.feedbackPrompt(for: feedback)
            AppLogger.info("Recording Codex feedback: \(prompt)")
            runProcess(
                prompt: prompt,
                imageURLs: [],
                requestKind: .continuation(sessionID: sessionID, purpose: .feedback)
            ) { result in
                switch result {
                case .success:
                    AppLogger.info("Codex feedback recorded for session \(sessionID)")
                case .failure(let error):
                    if case CodexCLIError.cancelled = error {
                        AppLogger.info("Codex feedback request cancelled")
                    } else {
                        AppLogger.error("Failed to record Codex feedback: \(error.localizedDescription)")
                    }
                }
                completion?()
            }
        case .waitForWarmup:
            start()
            AppLogger.info("Waiting for hidden Codex warm-up session before recording feedback")
            warmupGroup.notify(queue: .global(qos: .utility)) { [weak self] in
                self?.recordFeedback(feedback, completion: completion)
            }
        case .waitForActiveContinuation:
            AppLogger.info("Waiting for active Codex continuation before recording feedback")
            continuationGroup.notify(queue: .global(qos: .utility)) { [weak self] in
                self?.recordFeedback(feedback, completion: completion)
            }
        case .failMissingSession:
            AppLogger.error("Skipping Codex feedback because no active session is available")
            completion?()
        }
    }

    func compactSession(completion: @escaping (Result<Void, Error>) -> Void) {
        let route = stateQueue.sync { () -> SessionRoutingDecision in
            if let activeContinuationProcess,
               activeContinuationProcess.isRunning {
                return .waitForActiveContinuation
            }
            if let activeCompactionProcess,
               activeCompactionProcess.isRunning {
                return .waitForActiveContinuation
            }

            if let sessionID, !sessionID.isEmpty {
                return .resume(sessionID: sessionID)
            }

            if !warmupStarted || !warmupFinished {
                return .waitForWarmup
            }

            return .failMissingSession
        }

        switch route {
        case .resume(let sessionID):
            runCompactionProcess(sessionID: sessionID, completion: completion)
        case .waitForWarmup:
            start()
            AppLogger.info("Waiting for hidden Codex warm-up session before compacting Codex session")
            warmupGroup.notify(queue: .global(qos: .utility)) { [weak self] in
                self?.compactSession(completion: completion)
            }
        case .waitForActiveContinuation:
            AppLogger.info("Waiting for active Codex continuation before compacting Codex session")
            continuationGroup.notify(queue: .global(qos: .utility)) { [weak self] in
                self?.compactSession(completion: completion)
            }
        case .failMissingSession:
            let message = "No active Codex session is available. Skipping compaction."
            AppLogger.error(message)
            completion(.failure(CodexCLIError.executionFailed(message)))
        }
    }

    private func runProcess(
        prompt: String,
        imageURLs: [URL],
        requestKind: RequestKind,
        completion: @escaping (Result<(sessionID: String?, outputText: String?), Error>) -> Void
    ) {
        let outputFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccc-codex-\(UUID().uuidString).txt")
        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        let process = Process()
        let tracksContinuation: Bool = {
            if case .continuation = requestKind {
                return true
            }

            return false
        }()
        let sessionSnapshot = {
            switch requestKind {
            case .warmup:
                return Self.sessionSnapshot(at: sessionsRootURL)
            case .continuation:
                return Set<String>()
            }
        }()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.currentDirectoryURL = workingDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.arguments = commandArguments(
            prompt: prompt,
            imageURLs: imageURLs,
            outputFileURL: outputFileURL,
            requestKind: requestKind,
            reasoningEffort: reasoningEffort
        )

        if tracksContinuation {
            stateQueue.sync {
                activeContinuationProcess = process
                continuationGroup.enter()
            }
        }

        process.terminationHandler = { _ in
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
            let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
            let processIdentifier = ObjectIdentifier(process)
            let (wasCancelled, shouldLeaveContinuationGroup) = self.stateQueue.sync { () -> (Bool, Bool) in
                let shouldLeaveContinuationGroup = self.activeContinuationProcess === process
                if self.activeContinuationProcess === process {
                    self.activeContinuationProcess = nil
                }

                let wasCancelled = self.cancelledProcessIdentifiers.remove(processIdentifier) != nil
                return (wasCancelled, shouldLeaveContinuationGroup)
            }

            defer {
                try? FileManager.default.removeItem(at: outputFileURL)
                for imageURL in imageURLs {
                    try? FileManager.default.removeItem(at: imageURL)
                }
                if shouldLeaveContinuationGroup {
                    self.continuationGroup.leave()
                }
            }

            if wasCancelled {
                completion(.failure(CodexCLIError.cancelled))
                return
            }

            guard process.terminationStatus == 0 else {
                let message = stderrText.nonEmpty ?? stdoutText.nonEmpty ?? "Codex CLI exited with status \(process.terminationStatus)"
                AppLogger.error("Codex CLI failed. Status=\(process.terminationStatus) Message=\(message.prefix(500))")
                completion(.failure(CodexCLIError.executionFailed(message)))
                return
            }

            let resolvedSessionID =
                Self.extractSessionID(from: stdoutText)
                ?? Self.extractSessionID(from: stderrText)
                ?? Self.discoverNewSessionID(from: self.sessionsRootURL, previousSnapshot: sessionSnapshot)
                ?? {
                    switch requestKind {
                    case .warmup:
                        return nil
                    case .continuation(let sessionID, _):
                        return sessionID
                    }
                }()
            let outputText = (try? String(contentsOf: outputFileURL, encoding: .utf8))?.normalizedInlineCompletion

            completion(.success((sessionID: resolvedSessionID, outputText: outputText)))
        }

        do {
            try process.run()
        } catch {
            if tracksContinuation {
                let shouldLeaveContinuationGroup = stateQueue.sync { () -> Bool in
                    guard activeContinuationProcess === process else {
                        return false
                    }

                    activeContinuationProcess = nil
                    return true
                }

                if shouldLeaveContinuationGroup {
                    continuationGroup.leave()
                }
            }
            AppLogger.error("Failed to start Codex CLI process: \(error.localizedDescription)")
            completion(.failure(error))
        }
    }

    private func runCompactionProcess(
        sessionID: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        CodexAppServerCompactor.compact(
            codexPath: codexPath,
            workingDirectory: workingDirectory,
            sessionID: sessionID,
            processWillStart: { process in
                self.stateQueue.sync {
                    self.activeCompactionProcess = process
                    self.continuationGroup.enter()
                }
            },
            processDidFinish: { process in
                let (wasCancelled, shouldLeaveContinuationGroup) = self.stateQueue.sync { () -> (Bool, Bool) in
                    let shouldLeaveContinuationGroup = self.activeCompactionProcess === process
                    if self.activeCompactionProcess === process {
                        self.activeCompactionProcess = nil
                    }

                    let wasCancelled = self.cancelledProcessIdentifiers.remove(ObjectIdentifier(process)) != nil
                    return (wasCancelled, shouldLeaveContinuationGroup)
                }

                if shouldLeaveContinuationGroup {
                    self.continuationGroup.leave()
                }

                return wasCancelled
            },
            completion: completion
        )
    }

    private func runSideSuggestionProcess(
        sessionID: String,
        prompt: String,
        imageURL: URL?,
        context: FocusedTextContext,
        instanceOrder: Int,
        instanceID: String,
        completion: @escaping (Result<CodexSideThreadSuggestion, Error>) -> Void
    ) {
        CodexAppServerSideSuggestion.suggest(
            codexPath: codexPath,
            workingDirectory: workingDirectory,
            baseSessionID: sessionID,
            model: model,
            reasoningEffort: reasoningEffort,
            prompt: prompt,
            imageURL: imageURL,
            memoryRecord: { sideSuggestion in
                PromptRole.mainThreadMemoryRecord(
                    for: context,
                    instanceOrder: instanceOrder,
                    instanceID: instanceID,
                    sideSuggestion: sideSuggestion
                )
            },
            processWillStart: { process in
                self.stateQueue.sync {
                    self.activeContinuationProcess = process
                    self.continuationGroup.enter()
                }
            },
            processDidFinish: { process in
                let (wasCancelled, shouldLeaveContinuationGroup) = self.stateQueue.sync { () -> (Bool, Bool) in
                    let shouldLeaveContinuationGroup = self.activeContinuationProcess === process
                    if self.activeContinuationProcess === process {
                        self.activeContinuationProcess = nil
                    }

                    let wasCancelled = self.cancelledProcessIdentifiers.remove(ObjectIdentifier(process)) != nil
                    return (wasCancelled, shouldLeaveContinuationGroup)
                }

                if shouldLeaveContinuationGroup {
                    self.continuationGroup.leave()
                }

                return wasCancelled
            },
            completion: completion
        )
    }

    private func commandArguments(
        prompt: String,
        imageURLs: [URL],
        outputFileURL: URL,
        requestKind: RequestKind,
        reasoningEffort: String?
    ) -> [String] {
        var arguments = ["exec"]

        switch requestKind {
        case .continuation:
            arguments.append("resume")
        case .warmup:
            break
        }

        arguments.append(contentsOf: ["-m", model])
        if let reasoningEffort {
            arguments.append(contentsOf: ["-c", "model_reasoning_effort=\"\(reasoningEffort)\""])
        }
        arguments.append(contentsOf: ["--skip-git-repo-check", "-o", outputFileURL.path])
        for imageURL in imageURLs {
            arguments.append(contentsOf: ["-i", imageURL.path])
        }

        switch requestKind {
        case .continuation(let sessionID, let purpose):
            arguments.append(sessionID)
            arguments.append(prompt)
            AppLogger.info("Starting Codex \(purpose.rawValue) request with resumed session \(sessionID)")
        case .warmup(let epoch):
            arguments.append(contentsOf: ["--sandbox", "read-only", prompt])
            AppLogger.info("Starting Codex CLI request with a new session for warm-up epoch \(epoch)")
        }

        return arguments
    }

    private func prompt(for context: FocusedTextContext, instanceOrder: Int, instanceID: String) -> String {
        AppLogger.info("Codex prefix payload: <<<\(String(context.prefix.suffix(CCCConfig.promptPrefixCharacterLimit)).logEscaped)>>>")
        return PromptRole.continuationPrompt(for: context, instanceOrder: instanceOrder, instanceID: instanceID)
    }

    private func sideThreadPrompt(for context: FocusedTextContext, instanceOrder: Int, instanceID: String) -> String {
        AppLogger.info("Codex side-thread prefix payload: <<<\(String(context.prefix.suffix(CCCConfig.promptPrefixCharacterLimit)).logEscaped)>>>")
        return PromptRole.sideThreadPrompt(for: context, instanceOrder: instanceOrder, instanceID: instanceID)
    }

    private static func normalizedCodexReasoningEffort(_ rawValue: String?) -> String? {
        guard let rawValue else {
            return nil
        }

        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return nil
        }

        let allowedValues = ["none", "minimal", "low", "medium", "high"]
        guard allowedValues.contains(normalized) else {
            fatalError("Invalid reasoning_effort '\(rawValue)'. Expected one of: \(allowedValues.joined(separator: ", "))")
        }

        return normalized
    }

    private static func extractSessionID(from output: String) -> String? {
        guard let range = output.range(of: #"session id:\s*([0-9a-fA-F\-]{36})"#, options: .regularExpression) else {
            return nil
        }

        let match = String(output[range])
        return match.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sessionSnapshot(at sessionsRootURL: URL) -> Set<String> {
        guard let fileNames = try? FileManager.default.contentsOfDirectory(atPath: sessionsRootURL.path) else {
            return []
        }

        return Set(fileNames.filter { $0.hasSuffix(".jsonl") })
    }

    private static func discoverNewSessionID(from sessionsRootURL: URL, previousSnapshot: Set<String>) -> String? {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: sessionsRootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let jsonlURLs = fileURLs.filter { $0.pathExtension == "jsonl" }
        let candidateURLs = jsonlURLs.filter { !previousSnapshot.contains($0.lastPathComponent) }
        let preferredURLs = candidateURLs.isEmpty ? jsonlURLs : candidateURLs

        let sortedURLs = preferredURLs.sorted {
            let lhsDate = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate > rhsDate
        }

        for fileURL in sortedURLs {
            guard let body = try? String(contentsOf: fileURL, encoding: .utf8),
                  let firstLine = body.split(separator: "\n").first,
                  let data = String(firstLine).data(using: .utf8),
                  let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = jsonObject["payload"] as? [String: Any],
                  let identifier = payload["id"] as? String,
                  !identifier.isEmpty
            else {
                continue
            }

            return identifier
        }

        return nil
    }

    private static func persistedSessionURL() -> URL {
        CCCPaths.persistedSessionURL
    }

    private static func loadPersistedSessionID(from url: URL) -> String? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        return contents.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private static func persistSessionID(_ sessionID: String, to url: URL) {
        do {
            try CCCPaths.ensureParentDirectoryExists(for: url)
            try sessionID.appending("\n").write(to: url, atomically: true, encoding: .utf8)
            AppLogger.info("Persisted Codex session id to \(url.path)")
        } catch {
            AppLogger.error("Failed to persist Codex session id: \(error.localizedDescription)")
        }
    }

    private static func clearPersistedSessionID(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        do {
            try FileManager.default.removeItem(at: url)
            AppLogger.info("Cleared persisted Codex session id at \(url.path)")
        } catch {
            AppLogger.error("Failed to clear persisted Codex session id: \(error.localizedDescription)")
        }
    }

    private func beginWarmupIfNeeded(reason: String) -> Int? {
        let decision = stateQueue.sync { () -> (epoch: Int?, existingSessionID: String?) in
            if let sessionID, !sessionID.isEmpty {
                return (nil, sessionID)
            }

            guard !warmupStarted else {
                return (nil, nil)
            }

            warmupStarted = true
            warmupFinished = false
            let epoch = sessionEpoch
            warmupGroup.enter()
            return (epoch, nil)
        }

        if let existingSessionID = decision.existingSessionID {
            AppLogger.info("Warm-up skipped for \(reason). Reusing active SessionID=\(existingSessionID)")
        }

        return decision.epoch
    }

    private func performWarmup(for epoch: Int) {
        AppLogger.info("Starting hidden Codex warm-up session for epoch \(epoch)")
        let prompt = PromptRole.initializationPrompt()
        runProcess(prompt: prompt, imageURLs: [], requestKind: .warmup(epoch: epoch)) { [weak self] result in
            guard let self else { return }

            var logMessage: String
            switch result {
            case .success(let payload):
                let applied = self.stateQueue.sync { () -> Bool in
                    guard self.sessionEpoch == epoch else {
                        return false
                    }

                    self.warmupFinished = true
                    if let resolvedSessionID = payload.sessionID, !resolvedSessionID.isEmpty {
                        self.sessionID = resolvedSessionID
                        Self.persistSessionID(resolvedSessionID, to: self.persistedSessionURL)
                    }
                    return true
                }

                if applied {
                    if let resolvedSessionID = payload.sessionID, !resolvedSessionID.isEmpty {
                        logMessage = "Hidden Codex warm-up session ready. SessionID=\(resolvedSessionID)"
                    } else {
                        logMessage = "Hidden Codex warm-up completed without a session id. Reset is required before suggestions can resume."
                    }
                    AppLogger.info(logMessage)
                } else {
                    AppLogger.info("Ignoring stale warm-up result for superseded epoch \(epoch)")
                }
            case .failure(let error):
                let applied = self.stateQueue.sync { () -> Bool in
                    guard self.sessionEpoch == epoch else {
                        return false
                    }

                    self.warmupFinished = true
                    self.sessionID = nil
                    return true
                }

                if applied {
                    AppLogger.error("Hidden Codex warm-up session failed for epoch \(epoch): \(error.localizedDescription)")
                } else {
                    AppLogger.info("Ignoring stale warm-up failure for superseded epoch \(epoch)")
                }
            }

            self.warmupGroup.leave()
        }
    }
}

final class DemoCompletionEngine: CompletionEngine {
    func suggest(
        for context: FocusedTextContext,
        instanceOrder: Int,
        instanceID: String,
        completion: @escaping (Result<String?, Error>) -> Void
    ) {
        let text = context.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || context.source == .liveFieldProbe else {
            completion(.success(nil))
            return
        }

        let suggestion = heuristicSuggestion(for: context)
        completion(.success(suggestion))
    }

    private func heuristicSuggestion(for context: FocusedTextContext) -> String {
        let lastLine = context.prefix.components(separatedBy: .newlines).last ?? context.prefix
        let lowercased = lastLine.lowercased().trimmingCharacters(in: .whitespaces)

        if lowercased.hasSuffix("how can i") {
            return " make a small macOS CCC utility for any focused text field?"
        }

        if lowercased.hasSuffix("macos") {
            return " utility with accessibility-driven inline suggestions."
        }

        if lowercased.contains("completion") || lowercased.contains("inline suggestion") || lowercased.contains("ccc") {
            return " for the focused text field."
        }

        if lowercased.hasSuffix("thank") || lowercased.hasSuffix("thanks") {
            return " you for the context."
        }

        if context.source == .liveFieldProbe && context.appName == "Codex" {
            return " [live field completion]"
        }

        return " [demo completion]"
    }
}

private enum CodexCLIError: Error {
    case executionFailed(String)
    case cancelled
}

extension CodexCLIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .executionFailed(let message):
            return message
        case .cancelled:
            return "Codex request cancelled"
        }
    }
}

private extension String {
    var normalizedInlineCompletion: String {
        trimmingCharacters(in: .newlines)
    }

    var logEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
