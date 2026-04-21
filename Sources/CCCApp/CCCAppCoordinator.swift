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
    private let overlay = OverlayWindowController()
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

    private var pendingRequestID = UUID()
    private var visibleSuggestion: VisibleSuggestion?
    private var composeBuffer = ""
    private var composeTargetPID: pid_t?
    private var composeTargetAppName = "unknown"
    private var suggestionWorkItem: DispatchWorkItem?
    private var isCompletionRequestInFlight = false
    private var needsSuggestionRefreshAfterCurrentRequest = false
    private var explicitPrefixOverride: String?
    private var explicitScreenshotURL: URL?
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

        guard syncTrackingTarget(seedFromAccessibility: true) else {
            AppLogger.error("Cannot refresh suggestion because no frontmost app was found")
            NSSound.beep()
            return
        }

        scheduleSuggestionRefresh(immediate: true)
    }

    func dismissSuggestion() {
        let hadVisibleSuggestion = visibleSuggestion != nil || overlay.isVisible
        visibleSuggestion = nil
        if hadVisibleSuggestion {
            AppLogger.info("Dismissing suggestion")
        }
        overlay.hide()
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
        dismissSuggestion()
        pendingRequestID = UUID()
        isCompletionRequestInFlight = false
        needsSuggestionRefreshAfterCurrentRequest = false
    }

    private func handleDismiss() -> Bool {
        guard !sleeping else {
            return false
        }

        if visibleSuggestion != nil {
            completionEngine.recordFeedback(.ignored)
            dismissSuggestion()
            return true
        }

        if overlay.isVisible {
            dismissSuggestion()
            return true
        }

        return false
    }

    private func retrySuggestion() -> Bool {
        guard !sleeping else {
            return false
        }

        guard let visibleSuggestion else {
            return false
        }

        let retryContext = visibleSuggestion.context
        let retryRevision = userEditRevision
        let requestID = UUID()
        pendingRequestID = requestID
        isCompletionRequestInFlight = true
        needsSuggestionRefreshAfterCurrentRequest = false
        composeTargetPID = retryContext.appPID
        composeTargetAppName = retryContext.appName

        dismissSuggestion()
        overlay.showLoading(near: retryContext.caretRect)

        completionEngine.retrySuggestion { [weak self] result in
            guard let self else { return }

            DispatchQueue.main.async {
                self.isCompletionRequestInFlight = false

                guard !self.sleeping else {
                    return
                }

                guard self.pendingRequestID == requestID else {
                    return
                }

                guard retryRevision == self.userEditRevision else {
                    AppLogger.info(
                        "Discarding stale retry result. RequestedRevision=\(retryRevision) CurrentRevision=\(self.userEditRevision)"
                    )
                    return
                }

                switch result {
                case .success(let suggestion):
                    let normalizedSuggestion = suggestion?.trimmingCharacters(in: .newlines) ?? ""
                    guard normalizedSuggestion.contains(where: { !$0.isNewline }) else {
                        AppLogger.info("Retry returned an empty suggestion")
                        self.dismissSuggestion()
                        return
                    }

                    AppLogger.info("Showing retry suggestion: \(normalizedSuggestion)")
                    self.visibleSuggestion = VisibleSuggestion(
                        context: retryContext,
                        suggestion: normalizedSuggestion,
                        revision: self.userEditRevision
                    )
                    self.overlay.show(suggestion: normalizedSuggestion, near: retryContext.caretRect)
                case .failure(let error):
                    AppLogger.error("Retry request failed: \(error.localizedDescription)")
                    self.visibleSuggestion = nil
                    self.overlay.showStatus(message: "x retry failed", near: retryContext.caretRect)
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

        explicitPrefixOverride = capture?.prefix
        explicitScreenshotURL = capture?.screenshotURL
        requestCompletion()
        return true
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> Bool {
        guard !sleeping else {
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
            AppLogger.info("Navigation key pressed. Hiding suggestion until further typing")
            dismissSuggestion()
            return false
        default:
            break
        }

        let insertedText = sanitizedCharacters(from: keyPress)
        guard !insertedText.isEmpty else {
            return false
        }

        noteUserEdit()
        dismissSuggestion()
        return false
    }

    private func scheduleSuggestionRefresh(immediate: Bool = false) {
        scheduleSuggestionRefresh(delay: immediate ? 0.0 : 0.5)
    }

    private func scheduleSuggestionRefresh(delay: TimeInterval) {
        guard !sleeping else {
            return
        }

        suggestionWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshSuggestion()
        }

        suggestionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func refreshSuggestion() {
        guard !sleeping else {
            return
        }

        guard let frontmostApp = accessibilityService.frontmostApplicationInfo() else {
            AppLogger.error("Unable to refresh suggestion because there is no frontmost app")
            visibleSuggestion = nil
            overlay.showStatus(message: "x unable to resolve app", near: .zero)
            return
        }

        syncTrackingTarget(for: frontmostApp, seedFromAccessibility: true)

        let targetPID = frontmostApp.pid
        let targetAppName = frontmostApp.name
        composeTargetPID = targetPID
        composeTargetAppName = targetAppName

        guard composeTargetPID != nil else {
            return
        }

        if isCompletionRequestInFlight {
            needsSuggestionRefreshAfterCurrentRequest = true
            pendingRequestID = UUID()
            AppLogger.info("A Codex request is already running")
            AppLogger.info("Stopping it now")
            completionEngine.cancelInFlightRequest()
            AppLogger.info("When the current request finishes, the latest buffer will be refreshed")
            return
        }

        let context: FocusedTextContext
        if let explicitPrefixOverride {
            let clippedPrefix = String(explicitPrefixOverride.suffix(600))
            context = accessibilityService.liveFieldProbeContext(
                for: clippedPrefix,
                targetPID: targetPID,
                targetAppName: targetAppName,
                screenshotURL: explicitScreenshotURL
            )
            composeBuffer = String(clippedPrefix.suffix(1200))
            self.explicitPrefixOverride = nil
            self.explicitScreenshotURL = nil
        } else if let probedPrefix = inputInjector.capturePrefixUntilCursor(targetPID: targetPID) {
            let clippedPrefix = String(probedPrefix.suffix(600))
            context = accessibilityService.liveFieldProbeContext(
                for: clippedPrefix,
                targetPID: targetPID,
                targetAppName: targetAppName,
                screenshotURL: nil
            )
            composeBuffer = String(clippedPrefix.suffix(1200))
        } else {
            explicitPrefixOverride = nil
            explicitScreenshotURL = nil
            AppLogger.error("Unable to capture text before cursor from the live field")
            visibleSuggestion = nil
            overlay.showStatus(message: "x unable to read text field", near: .zero)
            return
        }

        AppLogger.info(
            "Refreshing suggestion. Source=\(String(describing: context.source)) App=\(context.appName) PrefixLength=\((context.prefix as NSString).length)"
        )

        overlay.showLoading(near: context.caretRect)

        let requestID = UUID()
        let requestedRevision = userEditRevision
        pendingRequestID = requestID
        isCompletionRequestInFlight = true
        needsSuggestionRefreshAfterCurrentRequest = false

        completionEngine.suggest(for: context) { [weak self] result in
            guard let self else { return }

            DispatchQueue.main.async {
                defer {
                    if let screenshotURL = context.screenshotURL {
                        ScreenCaptureService.deleteScreenshot(at: screenshotURL, reason: "post-codex-request")
                    }
                }

                self.isCompletionRequestInFlight = false

                guard !self.sleeping else {
                    return
                }

                if self.pendingRequestID != requestID {
                    if self.needsSuggestionRefreshAfterCurrentRequest {
                        self.needsSuggestionRefreshAfterCurrentRequest = false
                        self.scheduleSuggestionRefresh(immediate: true)
                    }
                    return
                }

                if requestedRevision != self.userEditRevision {
                    AppLogger.info(
                        "Discarding stale suggestion result. RequestedRevision=\(requestedRevision) CurrentRevision=\(self.userEditRevision)"
                    )
                    if self.needsSuggestionRefreshAfterCurrentRequest {
                        self.needsSuggestionRefreshAfterCurrentRequest = false
                        self.scheduleSuggestionRefresh(immediate: true)
                    }
                    return
                }

                switch result {
                case .success(let suggestion):
                    let normalizedSuggestion = suggestion?.trimmingCharacters(in: .newlines) ?? ""
                    guard normalizedSuggestion.contains(where: { !$0.isNewline }) else {
                        AppLogger.info("Completion engine returned an empty suggestion")
                        self.dismissSuggestion()
                        return
                    }

                    let displayText = normalizedSuggestion
                    AppLogger.info("Showing suggestion: \(displayText)")
                    self.visibleSuggestion = VisibleSuggestion(
                        context: context,
                        suggestion: displayText,
                        revision: self.userEditRevision
                    )
                    self.overlay.show(suggestion: displayText, near: context.caretRect)
                case .failure(let error):
                    AppLogger.error("Completion engine failed: \(error.localizedDescription)")
                    self.visibleSuggestion = nil
                    self.overlay.showStatus(message: "x ccc failed", near: context.caretRect)
                }

                if self.needsSuggestionRefreshAfterCurrentRequest {
                    self.needsSuggestionRefreshAfterCurrentRequest = false
                    self.scheduleSuggestionRefresh(immediate: true)
                }
            }
        }
    }

    private func acceptSuggestion() -> Bool {
        guard !sleeping else {
            return false
        }

        guard let visibleSuggestion, let targetPID = composeTargetPID else {
            AppLogger.info("Accept requested but no suggestion is visible")
            return false
        }

        AppLogger.info("Attempting to insert suggestion: \(visibleSuggestion.suggestion)")
        let inserted: Bool
        if let focusedContext = accessibilityService.focusedTextContext(),
           focusedContext.appPID == targetPID,
           accessibilityService.insertCompletion(visibleSuggestion.suggestion, into: focusedContext) {
            AppLogger.info("Suggestion inserted successfully via accessibility")
            inserted = true
        } else {
            inserted = inputInjector.insertUsingPasteboard(
                visibleSuggestion.suggestion,
                targetPID: targetPID
            )
        }

        if inserted {
            composeBuffer = String((composeBuffer + visibleSuggestion.suggestion).suffix(1200))
            if visibleSuggestion.context.source == .accessibility {
                AppLogger.info("Suggestion accepted with AX-aware context")
            }
            completionEngine.recordFeedback(.approved)
            dismissSuggestion()
        } else {
            AppLogger.error("Suggestion insertion failed")
            NSSound.beep()
        }

        return inserted
    }

    private func initialComposeBuffer(for targetPID: pid_t) -> String {
        _ = targetPID
        return ""
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

        composeBuffer = seedFromAccessibility ? initialComposeBuffer(for: frontmostApp.pid) : ""
        pendingRequestID = UUID()
        userEditRevision = 0
        suggestionWorkItem?.cancel()
        suggestionWorkItem = nil
        isCompletionRequestInFlight = false
        needsSuggestionRefreshAfterCurrentRequest = false

        AppLogger.info(
            "Tracking armed for \(frontmostApp.name) pid=\(frontmostApp.pid) SeedLength=\((composeBuffer as NSString).length) InvocationMode=explicit"
        )

        dismissSuggestion()
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
        suggestionWorkItem?.cancel()
        suggestionWorkItem = nil
        pendingRequestID = UUID()
        needsSuggestionRefreshAfterCurrentRequest = false
        isCompletionRequestInFlight = false
        composeBuffer = ""
        userEditRevision = 0
        composeTargetPID = nil
        composeTargetAppName = "unknown"
        dismissSuggestion()
        AppLogger.info("ccc is sleeping")
    }
}

private struct VisibleSuggestion {
    let context: FocusedTextContext
    let suggestion: String
    let revision: Int
}
