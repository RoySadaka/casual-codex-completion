import AppKit
import Foundation

enum CCCPermissionRequirement {
    case accessibility
    case inputMonitoring
    case screenRecording

    var title: String {
        switch self {
        case .accessibility:
            return "Accessibility"
        case .inputMonitoring:
            return "Input Monitoring"
        case .screenRecording:
            return "Screen Recording"
        }
    }

    var details: String {
        switch self {
        case .accessibility:
            return "Lets CCC inspect and edit the focused text field."
        case .inputMonitoring:
            return "Lets CCC listen for ccc, Tab, Shift-Tab, and Escape while you type."
        case .screenRecording:
            return "Lets CCC capture screenshots when Screenshot mode is enabled."
        }
    }

    var settingsURL: URL? {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .inputMonitoring:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
    }
}

final class CCCAppCoordinator {
    private enum SleepChangeSource: String {
        case manual = "manual"
        case internalState = "internal"
    }

    private let accessibilityService = AccessibilityTextService()
    private let inputInjector = InputInjector()
    private let completionEngine = CompositeCompletionEngine()
    private let screenCaptureService = ScreenCaptureService()
    private lazy var keyEventTap = KeyEventTap { [weak self] action in
        guard let self else { return false }

        switch action {
        case .requestCompletion:
            return self.handleExplicitCompletionRequest()
        case .requestCompletionWithCapturedContext(let capture):
            return self.handleExplicitCompletionRequest(capture: capture)
        case .acceptSuggestion:
            return self.acceptSuggestion()
        case .retrySuggestion:
            return self.retrySuggestion()
        case .dismissSuggestion:
            return self.handleDismiss()
        case .keyPress(let keyPress):
            return self.handleKeyPress(keyPress)
        }
    }

    private var completionInstances = [UUID: CompletionInstance]()
    private var activeCompletionID: UUID?
    private var queuedCodexWorkItems = [QueuedCodexWorkItem]()
    private var isProcessingCodexWorkItem = false
    private var composeTargetPID: pid_t?
    private var composeTargetAppName = "unknown"
    private var sleeping = false
    private var screenshotContextEnabled = true
    private var userEditRevision = 0

    func start() {
        AppLogger.info("Coordinator starting")
        _ = refreshPermissionsAndEventTap(promptForAccessibility: true)
        completionEngine.start()
        AppLogger.info("Typing monitor enabled. InvocationMode=explicit")
        keyEventTap.setTripleCTriggerEnabled(!sleeping)
        keyEventTap.setScreenshotContextEnabled(
            screenshotContextEnabled,
            promptForPermission: screenshotContextEnabled
        )
    }

    var isSleeping: Bool {
        sleeping
    }

    var isScreenshotContextEnabled: Bool {
        screenshotContextEnabled
    }

    var hasAccessibilityPermission: Bool {
        accessibilityService.hasAccessibilityPermission()
    }

    var hasScreenCapturePermission: Bool {
        screenCaptureService.hasPermission()
    }

    var hasInputMonitoringPermission: Bool {
        keyEventTap.isActive
    }

    var missingPermissions: [CCCPermissionRequirement] {
        var missing = [CCCPermissionRequirement]()

        if !hasAccessibilityPermission {
            missing.append(.accessibility)
        }

        if !hasInputMonitoringPermission {
            missing.append(.inputMonitoring)
        }

        if screenshotContextEnabled && !hasScreenCapturePermission {
            missing.append(.screenRecording)
        }

        return missing
    }

    var hasRequiredPermissions: Bool {
        missingPermissions.isEmpty
    }

    var nextMissingPermission: CCCPermissionRequirement? {
        missingPermissions.first
    }

    @discardableResult
    func promptForAccessibilityPermission() -> Bool {
        refreshPermissionsAndEventTap(promptForAccessibility: true)
    }

    func promptForPermission(_ permission: CCCPermissionRequirement) {
        switch permission {
        case .accessibility:
            _ = refreshPermissionsAndEventTap(promptForAccessibility: true)
        case .inputMonitoring:
            AppLogger.info("Rechecking Input Monitoring permission via CGEvent tap start")
            keyEventTap.start()
        case .screenRecording:
            let granted = screenCaptureService.requestPermission(prompt: true)
            AppLogger.info("Screen capture permission status: \(granted)")
        }
    }

    @discardableResult
    func refreshPermissionsAndEventTap(promptForAccessibility: Bool) -> Bool {
        let granted = accessibilityService.requestAccessibilityPermission(prompt: promptForAccessibility)
        AppLogger.info("Accessibility permission status: \(granted)")
        keyEventTap.start()
        return granted
    }

    func requestCompletion() {
        guard !sleeping else {
            return
        }

        startCompletionInstance(capture: nil)
    }

    func dismissSuggestion() {
        guard let activeCompletionID else {
            return
        }

        dismissCompletionInstance(activeCompletionID, recordsIgnoredFeedback: false)
    }

    func sleep() {
        setSleeping(true, source: .manual)
    }

    func wake() {
        setSleeping(false, source: .manual)
    }

    @discardableResult
    func toggleSleeping() -> Bool {
        let nextState = !sleeping
        setSleeping(nextState, source: .manual)
        return nextState
    }

    @discardableResult
    func toggleScreenshotContext() -> Bool {
        screenshotContextEnabled.toggle()
        keyEventTap.setScreenshotContextEnabled(screenshotContextEnabled, promptForPermission: screenshotContextEnabled)
        AppLogger.info("Screenshot context toggled. Enabled=\(screenshotContextEnabled)")
        return screenshotContextEnabled
    }

    func resetSession(completion: (() -> Void)? = nil) {
        AppLogger.info("Resetting Codex session from coordinator")
        completionEngine.resetSession(completion: completion)
        dismissAllCompletionInstances(recordsIgnoredFeedback: false)
        queuedCodexWorkItems.removeAll()
        isProcessingCodexWorkItem = false
    }

    private func handleDismiss() -> Bool {
        guard !sleeping else {
            return false
        }

        if let activeCompletionID {
            dismissCompletionInstance(activeCompletionID, recordsIgnoredFeedback: true)
            return true
        }

        return false
    }

    private func retrySuggestion() -> Bool {
        guard !sleeping else {
            return false
        }

        guard let activeCompletionID,
              let activeCompletion = completionInstances[activeCompletionID],
              let activeSuggestion = activeCompletion.suggestion
        else {
            return false
        }

        _ = activeSuggestion
        let retryContext = activeCompletion.context
        var retryInstance = activeCompletion
        retryInstance.suggestion = nil
        retryInstance.isLoading = true
        completionInstances[activeCompletionID] = retryInstance
        retryInstance.overlay.showLoading(near: retryContext.caretRect, order: retryInstance.loadingOrder)

        completionEngine.retrySuggestion { [weak self] result in
            guard let self else { return }

            DispatchQueue.main.async {
                guard !self.sleeping else {
                    return
                }

                guard var completionInstance = self.completionInstances[activeCompletionID] else {
                    return
                }

                completionInstance.isLoading = false

                switch result {
                case .success(let suggestion):
                    let normalizedSuggestion = suggestion?.trimmingCharacters(in: .newlines) ?? ""
                    guard normalizedSuggestion.contains(where: { !$0.isNewline }) else {
                        AppLogger.info("Retry returned an empty suggestion")
                        self.dismissCompletionInstance(activeCompletionID, recordsIgnoredFeedback: false)
                        return
                    }

                    AppLogger.info("Showing retry suggestion: \(normalizedSuggestion)")
                    completionInstance.suggestion = normalizedSuggestion
                    self.completionInstances[activeCompletionID] = completionInstance
                    completionInstance.overlay.show(suggestion: normalizedSuggestion, near: retryContext.caretRect)
                case .failure(let error):
                    AppLogger.error("Retry request failed: \(error.localizedDescription)")
                    completionInstance.suggestion = nil
                    self.completionInstances[activeCompletionID] = completionInstance
                    completionInstance.overlay.showStatus(message: "x retry failed", near: retryContext.caretRect)
                }
            }
        }

        return true
    }

    private func handleExplicitCompletionRequest() -> Bool {
        handleExplicitCompletionRequest(capture: nil)
    }

    private func handleExplicitCompletionRequest(capture: CompletionCapture?) -> Bool {
        guard !sleeping else {
            return false
        }

        return startCompletionInstance(capture: capture)
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> Bool {
        guard !sleeping else {
            return false
        }

        guard completionInstances.isEmpty else {
            return false
        }

        guard let frontmostApp = accessibilityService.frontmostApplicationInfo() else {
            return false
        }

        syncTrackingTarget(for: frontmostApp, seedFromAccessibility: true)

        if keyPress.flags.contains(.maskCommand) || keyPress.flags.contains(.maskControl) || keyPress.flags.contains(.maskSecondaryFn) {
            return false
        }

        switch keyPress.keyCode {
        case 51:
            noteUserEdit()
            return false
        case 123, 124, 125, 126, 115, 116, 119, 121:
            return false
        default:
            break
        }

        let insertedText = sanitizedCharacters(from: keyPress)
        guard !insertedText.isEmpty else {
            return false
        }

        noteUserEdit()
        return false
    }

    @discardableResult
    private func startCompletionInstance(capture: CompletionCapture?) -> Bool {
        guard !sleeping else {
            return false
        }

        guard let frontmostApp = accessibilityService.frontmostApplicationInfo() else {
            AppLogger.error("Unable to start completion because there is no frontmost app")
            let overlay = OverlayWindowController()
            overlay.showStatus(message: "x unable to resolve app", near: .zero)
            return false
        }

        composeTargetPID = frontmostApp.pid
        composeTargetAppName = frontmostApp.name

        let context: FocusedTextContext
        if let capture {
            let clippedPrefix = String(capture.prefix.suffix(CCCConfig.promptPrefixCharacterLimit))
            context = accessibilityService.liveFieldProbeContext(
                for: clippedPrefix,
                targetPID: frontmostApp.pid,
                targetAppName: frontmostApp.name,
                screenshotURL: capture.screenshotURL
            )
        } else if let probedPrefix = inputInjector.capturePrefixUntilCursor(targetPID: frontmostApp.pid) {
            let clippedPrefix = String(probedPrefix.suffix(CCCConfig.promptPrefixCharacterLimit))
            context = accessibilityService.liveFieldProbeContext(
                for: clippedPrefix,
                targetPID: frontmostApp.pid,
                targetAppName: frontmostApp.name,
                screenshotURL: nil
            )
        } else {
            AppLogger.error("Unable to capture text before cursor from the live field")
            let overlay = OverlayWindowController()
            overlay.showStatus(message: "x unable to read text field", near: .zero)
            return false
        }

        AppLogger.info(
            "Starting completion instance. App=\(context.appName) Source=\(String(describing: context.source)) PrefixLength=\((context.prefix as NSString).length)"
        )

        let id = UUID()
        let loadingOrder = completionInstances.count + 1
        let codexRequestID = Self.codexRequestID(for: id)
        let overlay = OverlayWindowController()
        overlay.onInteract = { [weak self] in
            self?.activeCompletionID = id
        }

        let instance = CompletionInstance(
            id: id,
            context: context,
            overlay: overlay,
            loadingOrder: loadingOrder,
            codexRequestID: codexRequestID,
            suggestion: nil,
            isLoading: true
        )
        completionInstances[id] = instance
        activeCompletionID = id
        overlay.showLoading(near: context.caretRect, order: loadingOrder)
        enqueueCodexWorkItem(.completion(id))

        return true
    }

    private func enqueueCodexWorkItem(_ item: QueuedCodexWorkItem) {
        queuedCodexWorkItems.append(item)
        processNextCodexWorkItemIfNeeded()
    }

    private func processNextCodexWorkItemIfNeeded() {
        guard !sleeping, !isProcessingCodexWorkItem else {
            return
        }

        while !queuedCodexWorkItems.isEmpty {
            let item = queuedCodexWorkItems.removeFirst()

            switch item {
            case .completion(let id):
                guard let instance = completionInstances[id] else {
                    continue
                }

                isProcessingCodexWorkItem = true
                processCompletionInstance(id, instance: instance)
                return

            case .feedback(let feedback):
                isProcessingCodexWorkItem = true
                processFeedback(feedback)
                return
            }
        }
    }

    private func processCompletionInstance(_ id: UUID, instance: CompletionInstance) {
        let context = instance.context
        completionEngine.suggest(
            for: context,
            instanceOrder: instance.loadingOrder,
            instanceID: instance.codexRequestID
        ) { [weak self] result in
            guard let self else { return }

            DispatchQueue.main.async {
                defer {
                    if let screenshotURL = context.screenshotURL {
                        ScreenCaptureService.deleteScreenshot(at: screenshotURL, reason: "post-codex-request")
                    }
                    self.isProcessingCodexWorkItem = false
                    self.processNextCodexWorkItemIfNeeded()
                }

                guard !self.sleeping else {
                    return
                }

                guard var completionInstance = self.completionInstances[id] else {
                    return
                }

                completionInstance.isLoading = false

                switch result {
                case .success(let suggestion):
                    let normalizedSuggestion = suggestion?.trimmingCharacters(in: .newlines) ?? ""
                    guard normalizedSuggestion.contains(where: { !$0.isNewline }) else {
                        AppLogger.info("Completion instance returned an empty suggestion")
                        self.dismissCompletionInstance(id, recordsIgnoredFeedback: false)
                        return
                    }

                    AppLogger.info("Showing completion instance suggestion: \(normalizedSuggestion)")
                    completionInstance.suggestion = normalizedSuggestion
                    self.completionInstances[id] = completionInstance
                    self.activeCompletionID = id
                    completionInstance.overlay.show(suggestion: normalizedSuggestion, near: context.caretRect)

                case .failure(let error):
                    AppLogger.error("Completion instance failed: \(error.localizedDescription)")
                    completionInstance.suggestion = nil
                    self.completionInstances[id] = completionInstance
                    self.activeCompletionID = id
                    completionInstance.overlay.showStatus(message: "x ccc failed", near: context.caretRect)
                }
            }
        }
    }

    private func processFeedback(_ feedback: CompletionFeedback) {
        completionEngine.recordFeedback(feedback) { [weak self] in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                self.isProcessingCodexWorkItem = false
                self.processNextCodexWorkItemIfNeeded()
            }
        }
    }

    private func acceptSuggestion() -> Bool {
        guard !sleeping else {
            return false
        }

        guard let activeCompletionID,
              let activeCompletion = completionInstances[activeCompletionID],
              let suggestion = activeCompletion.suggestion
        else {
            AppLogger.info("Accept requested but no suggestion is visible")
            return false
        }

        AppLogger.info("Attempting to insert suggestion: \(suggestion)")
        AppLogger.info("Using paste-only insertion mode")
        let inserted = inputInjector.insertUsingPasteboard(
            suggestion,
            targetPID: activeCompletion.context.appPID
        )

        if inserted {
            enqueueCodexWorkItem(
                .feedback(.approved(feedbackDetails(for: activeCompletion, suggestion: suggestion)))
            )
            dismissCompletionInstance(activeCompletionID, recordsIgnoredFeedback: false)
        } else {
            AppLogger.error("Suggestion insertion failed")
            NSSound.beep()
        }

        return inserted
    }

    private func dismissCompletionInstance(_ id: UUID, recordsIgnoredFeedback: Bool) {
        guard let instance = completionInstances.removeValue(forKey: id) else {
            return
        }

        queuedCodexWorkItems.removeAll { item in
            if case .completion(let queuedID) = item {
                return queuedID == id
            }

            return false
        }

        if recordsIgnoredFeedback, let suggestion = instance.suggestion {
            enqueueCodexWorkItem(
                .feedback(.ignored(feedbackDetails(for: instance, suggestion: suggestion)))
            )
        }

        AppLogger.info("Dismissing completion instance \(id)")
        instance.overlay.hide()

        if activeCompletionID == id {
            activeCompletionID = completionInstances.keys.first
        }
    }

    private func dismissAllCompletionInstances(recordsIgnoredFeedback: Bool) {
        let ids = Array(completionInstances.keys)
        for id in ids {
            dismissCompletionInstance(id, recordsIgnoredFeedback: recordsIgnoredFeedback)
        }
        activeCompletionID = nil
    }

    private func feedbackDetails(
        for instance: CompletionInstance,
        suggestion: String
    ) -> CompletionFeedbackDetails {
        CompletionFeedbackDetails(
            instanceOrder: instance.loadingOrder,
            instanceID: instance.codexRequestID,
            appName: instance.context.appName,
            suggestion: suggestion
        )
    }

    private static func codexRequestID(for id: UUID) -> String {
        "ccc-\(String(id.uuidString.prefix(8)).lowercased())"
    }

    private func noteUserEdit() {
        userEditRevision += 1
    }

    private func sanitizedCharacters(from keyPress: KeyPress) -> String {
        if keyPress.keyCode == 36 || keyPress.keyCode == 76 {
            return "\n"
        }

        let filteredScalars = keyPress.characters.unicodeScalars.filter { scalar in
            if scalar == "\n" || scalar == "\t" {
                return false
            }

            return !CharacterSet.controlCharacters.contains(scalar)
        }

        return String(String.UnicodeScalarView(filteredScalars))
    }

    @discardableResult
    private func syncTrackingTarget(seedFromAccessibility: Bool) -> Bool {
        guard let frontmostApp = accessibilityService.frontmostApplicationInfo() else {
            return false
        }

        syncTrackingTarget(for: frontmostApp, seedFromAccessibility: seedFromAccessibility)
        return true
    }

    private func syncTrackingTarget(
        for frontmostApp: (pid: pid_t, name: String),
        seedFromAccessibility: Bool
    ) {
        guard !sleeping else {
            return
        }

        let appChanged = composeTargetPID != frontmostApp.pid
        if appChanged {
            let previousAppName = composeTargetPID == nil ? "<none>" : composeTargetAppName
            AppLogger.info(
                "Tracking target switched from \(previousAppName) to \(frontmostApp.name) pid=\(frontmostApp.pid)"
            )
        }

        composeTargetPID = frontmostApp.pid
        composeTargetAppName = frontmostApp.name

        guard appChanged else {
            return
        }

        _ = seedFromAccessibility
        userEditRevision = 0

        AppLogger.info("Tracking armed for \(frontmostApp.name) pid=\(frontmostApp.pid) InvocationMode=explicit")
    }

    private func setSleeping(_ newValue: Bool, source: SleepChangeSource) {
        guard sleeping != newValue else {
            return
        }

        sleeping = newValue
        keyEventTap.setTripleCTriggerEnabled(!sleeping)

        if sleeping {
            resetStateForSleep()
        } else {
            AppLogger.info("ccc woke up (\(source.rawValue))")
        }
    }

    private func resetStateForSleep() {
        queuedCodexWorkItems.removeAll()
        isProcessingCodexWorkItem = false
        userEditRevision = 0
        composeTargetPID = nil
        composeTargetAppName = "unknown"
        dismissAllCompletionInstances(recordsIgnoredFeedback: false)
        AppLogger.info("ccc is sleeping")
    }
}

private enum QueuedCodexWorkItem {
    case completion(UUID)
    case feedback(CompletionFeedback)
}

private struct CompletionInstance {
    let id: UUID
    let context: FocusedTextContext
    let overlay: OverlayWindowController
    let loadingOrder: Int
    let codexRequestID: String
    var suggestion: String?
    var isLoading: Bool
}
