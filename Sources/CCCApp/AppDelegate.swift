import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    private let coordinator = CCCAppCoordinator()
    private let userNameKey = "user_name"
    private let devModeKey = "dev_mode"

    private var window: NSWindow?
    private var engineRow: CCCMetricRowView?
    private var visionRow: CCCMetricRowView?
    private var sleepButton: CCCButton?
    private var screenshotButton: CCCButton?
    private var accessibilityButton: CCCButton?
    private var resetButton: CCCButton?
    private var userNameField: NSTextField?
    private var devModeToggle: NSSwitch?
    private var loadingOverlay: CCCLoadingOverlayView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.info("Application launched. Log file: \(AppLogger.logFileURL.path)")
        NSApp.applicationIconImage = bundledApplicationIcon() ?? makeDockIcon()
        installMainMenu()
        installWindow()
        coordinator.start()
        updateUI()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        _ = coordinator.refreshPermissionsAndEventTap(promptForAccessibility: false)
        updateUI()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    @objc
    private func promptPermissions(_ sender: Any?) {
        guard let nextPermission = coordinator.nextMissingPermission else {
            updateUI()
            return
        }

        coordinator.promptForPermission(nextPermission)
        updateUI()

        let missingPermissions = coordinator.missingPermissions
        guard missingPermissions.contains(nextPermission) else {
            return
        }

        presentPermissionHelper(for: missingPermissions)
    }

    @objc
    private func hideSuggestion(_ sender: Any?) {
        coordinator.dismissSuggestion()
    }

    @objc
    private func toggleSleep(_ sender: Any?) {
        let isSleeping = coordinator.toggleSleeping()
        AppLogger.info("Window toggled sleep state. Sleeping=\(isSleeping)")
        updateUI()
    }

    @objc
    private func toggleScreenshotContext(_ sender: Any?) {
        let enabled = coordinator.toggleScreenshotContext()
        AppLogger.info("Window toggled screenshot context. Enabled=\(enabled)")
        updateUI()
    }

    @objc
    private func resetSession(_ sender: Any?) {
        showLoadingOverlay(message: "Resetting Codex session…")
        coordinator.resetSession { [weak self] in
            guard let self else { return }
            self.hideLoadingOverlay()
            self.updateUI()
        }
    }

    @objc
    private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    @objc
    private func showAboutPanel(_ sender: Any?) {
        let marketingVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        NSApp.orderFrontStandardAboutPanel(
            options: [
                .applicationName: "CCC",
                .applicationVersion: marketingVersion,
                .version: buildVersion,
                .credits: NSAttributedString(string: "Casual-Codex-Completion\nBy Roy Sadaka")
            ]
        )
    }

    @objc
    private func userNameFieldChanged(_ sender: NSTextField) {
        persistUserName(from: sender)
    }

    @objc
    private func devModeToggled(_ sender: NSSwitch) {
        persistDevMode(isEnabled: sender.state == .on)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field == userNameField else {
            return
        }

        persistUserName(from: field)
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About CCC", action: #selector(showAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Prompt For Required Permissions", action: #selector(promptPermissions(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem(title: "Dismiss Suggestion", action: #selector(hideSuggestion(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit CCC", action: #selector(quit(_:)), keyEquivalent: "q"))

        for item in appMenu.items {
            item.target = self
        }

        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    private func installWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 350),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CCC"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unifiedCompact
        window.isMovableByWindowBackground = true
        window.center()
        window.delegate = self
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let rootView = CCCWindowBackgroundView(frame: window.contentView?.bounds ?? .zero)
        rootView.autoresizingMask = [.width, .height]

        let contentStack = NSStackView()
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.spacing = 12
        contentStack.alignment = .leading
        rootView.addSubview(contentStack)

        let appBadge = CCCAppBadgeView()
        appBadge.widthAnchor.constraint(equalToConstant: 34).isActive = true
        appBadge.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let summaryLabel = makeLabel(
            "Casual Codex Completion",
            font: .systemFont(ofSize: 12, weight: .medium),
            color: .secondaryLabelColor
        )
        summaryLabel.maximumNumberOfLines = 1

        let headerRow = NSStackView(views: [appBadge, summaryLabel])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 10

        let metricsCard = CCCSectionCardView()
        let metricsStack = NSStackView()
        metricsStack.translatesAutoresizingMaskIntoConstraints = false
        metricsStack.orientation = .vertical
        metricsStack.spacing = 10
        metricsStack.alignment = .leading
        metricsCard.addSubview(metricsStack)

        let engineRow = CCCMetricRowView(title: "Engine")
        let visionRow = CCCMetricRowView(title: "Vision")
        self.engineRow = engineRow
        self.visionRow = visionRow

        let userNameTitle = makeLabel(
            "User Name",
            font: .systemFont(ofSize: 12, weight: .medium),
            color: .secondaryLabelColor
        )
        userNameTitle.maximumNumberOfLines = 1

        let userNameField = NSTextField(string: configuredUserName() ?? "")
        userNameField.translatesAutoresizingMaskIntoConstraints = false
        userNameField.placeholderString = "write name and press enter"
        userNameField.font = .systemFont(ofSize: 12)
        userNameField.controlSize = .regular
        userNameField.target = self
        userNameField.action = #selector(userNameFieldChanged(_:))
        userNameField.delegate = self
        self.userNameField = userNameField

        let userNameHint = makeLabel(
            "Used in every prompt so Codex can draft suggestions in your voice and identify you in screenshots.",
            font: .systemFont(ofSize: 11, weight: .regular),
            color: .tertiaryLabelColor
        )
        userNameHint.maximumNumberOfLines = 2

        let userNameStack = NSStackView(views: [userNameTitle, userNameField, userNameHint])
        userNameStack.orientation = .vertical
        userNameStack.spacing = 6
        userNameStack.alignment = .leading

        let devModeTitle = makeLabel(
            "Dev Mode",
            font: .systemFont(ofSize: 12, weight: .medium),
            color: .secondaryLabelColor
        )
        devModeTitle.maximumNumberOfLines = 1

        let devModeToggle = NSSwitch()
        devModeToggle.translatesAutoresizingMaskIntoConstraints = false
        devModeToggle.controlSize = .small
        devModeToggle.target = self
        devModeToggle.action = #selector(devModeToggled(_:))
        self.devModeToggle = devModeToggle

        let devModeSpacer = NSView()
        devModeSpacer.translatesAutoresizingMaskIntoConstraints = false
        devModeSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let devModeRow = NSStackView(views: [devModeTitle, devModeSpacer, devModeToggle])
        devModeRow.orientation = .horizontal
        devModeRow.alignment = .centerY
        devModeRow.spacing = 10

        let devModeHint = makeLabel(
            "When on, screenshots are also saved to Desktop.",
            font: .systemFont(ofSize: 11, weight: .regular),
            color: .tertiaryLabelColor
        )
        devModeHint.maximumNumberOfLines = 2

        let devModeStack = NSStackView(views: [devModeRow, devModeHint])
        devModeStack.orientation = .vertical
        devModeStack.spacing = 6
        devModeStack.alignment = .leading

        let separatorOne = CCCSeparatorView()
        let separatorTwo = CCCSeparatorView()
        let separatorThree = CCCSeparatorView()

        let sleepButton = CCCButton(title: "Sleep")
        sleepButton.target = self
        sleepButton.action = #selector(toggleSleep(_:))
        self.sleepButton = sleepButton

        let screenshotButton = CCCButton(title: "Screenshot")
        screenshotButton.target = self
        screenshotButton.action = #selector(toggleScreenshotContext(_:))
        self.screenshotButton = screenshotButton

        let accessibilityButton = CCCButton(title: "Permissions")
        accessibilityButton.target = self
        accessibilityButton.action = #selector(promptPermissions(_:))
        self.accessibilityButton = accessibilityButton

        let resetButton = CCCButton(title: "Reset Codex Session")
        resetButton.target = self
        resetButton.action = #selector(resetSession(_:))
        self.resetButton = resetButton

        let topButtons = NSStackView(views: [sleepButton, screenshotButton])
        topButtons.orientation = .horizontal
        topButtons.spacing = 8
        topButtons.distribution = .fillEqually

        let bottomButtons = NSStackView(views: [accessibilityButton, resetButton])
        bottomButtons.orientation = .horizontal
        bottomButtons.spacing = 8
        bottomButtons.distribution = .fillEqually

        [
            userNameStack,
            devModeStack,
            separatorOne,
            engineRow,
            separatorTwo,
            visionRow,
            separatorThree,
            topButtons,
            bottomButtons
        ].forEach(metricsStack.addArrangedSubview)

        let triggerBadge = CCCShortcutBadgeView(key: "ccc", caption: "Trigger")
        let acceptBadge = CCCShortcutBadgeView(key: "Tab", caption: "Insert")
        let alternateBadge = CCCShortcutBadgeView(key: "Shift+Tab", caption: "Alternative")
        let dismissBadge = CCCShortcutBadgeView(key: "Esc", caption: "Dismiss")

        let topShortcutRow = NSStackView(views: [triggerBadge, acceptBadge])
        topShortcutRow.orientation = .horizontal
        topShortcutRow.alignment = .centerY
        topShortcutRow.spacing = 12

        let bottomShortcutRow = NSStackView(views: [alternateBadge, dismissBadge])
        bottomShortcutRow.orientation = .horizontal
        bottomShortcutRow.alignment = .centerY
        bottomShortcutRow.spacing = 12

        let shortcutStack = NSStackView(views: [topShortcutRow, bottomShortcutRow])
        shortcutStack.orientation = .vertical
        shortcutStack.alignment = .leading
        shortcutStack.spacing = 8

        [headerRow, metricsCard, shortcutStack].forEach(contentStack.addArrangedSubview)

        sleepButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        screenshotButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        accessibilityButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        resetButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        userNameStack.widthAnchor.constraint(equalTo: metricsStack.widthAnchor).isActive = true
        devModeStack.widthAnchor.constraint(equalTo: metricsStack.widthAnchor).isActive = true
        engineRow.widthAnchor.constraint(equalTo: metricsStack.widthAnchor).isActive = true
        visionRow.widthAnchor.constraint(equalTo: metricsStack.widthAnchor).isActive = true
        topButtons.widthAnchor.constraint(equalTo: metricsStack.widthAnchor).isActive = true
        bottomButtons.widthAnchor.constraint(equalTo: metricsStack.widthAnchor).isActive = true
        userNameField.widthAnchor.constraint(equalTo: metricsStack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 18),
            contentStack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -18),
            contentStack.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 16),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: rootView.bottomAnchor, constant: -16),

            metricsCard.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            metricsCard.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),

            metricsStack.leadingAnchor.constraint(equalTo: metricsCard.leadingAnchor, constant: 12),
            metricsStack.trailingAnchor.constraint(equalTo: metricsCard.trailingAnchor, constant: -12),
            metricsStack.topAnchor.constraint(equalTo: metricsCard.topAnchor, constant: 12),
            metricsStack.bottomAnchor.constraint(equalTo: metricsCard.bottomAnchor, constant: -12)
        ])

        let loadingOverlay = CCCLoadingOverlayView()
        loadingOverlay.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.isHidden = true
        rootView.addSubview(loadingOverlay)
        NSLayoutConstraint.activate([
            loadingOverlay.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            loadingOverlay.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            loadingOverlay.topAnchor.constraint(equalTo: rootView.topAnchor),
            loadingOverlay.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])
        self.loadingOverlay = loadingOverlay

        window.contentView = rootView
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    private func updateUI() {
        let sleeping = coordinator.isSleeping
        let screenshotEnabled = coordinator.isScreenshotContextEnabled
        let hasScreenCapturePermission = coordinator.hasScreenCapturePermission
        let hasRequiredPermissions = coordinator.hasRequiredPermissions
        let devModeEnabled = configuredDevMode()

        engineRow?.update(
            value: sleeping ? "Paused" : "Live",
            tone: sleeping ? .neutral : .green
        )

        visionRow?.update(
            value: screenshotEnabled ? (hasScreenCapturePermission ? "On" : "Blocked") : "Off",
            tone: screenshotEnabled ? (hasScreenCapturePermission ? .blue : .danger) : .neutral
        )

        sleepButton?.title = sleeping ? "Wake" : "Sleep"
        sleepButton?.tone = sleeping ? .accent : .normal

        screenshotButton?.title = screenshotEnabled ? "Screenshot On" : "Screenshot Off"
        screenshotButton?.tone = screenshotEnabled ? .accent : .normal
        screenshotButton?.isEnabled = !sleeping

        accessibilityButton?.title = "Permissions"
        accessibilityButton?.tone = hasRequiredPermissions ? .success : .danger

        resetButton?.title = "Reset Codex Session"
        resetButton?.tone = .normal
        resetButton?.isEnabled = !sleeping
        devModeToggle?.state = devModeEnabled ? .on : .off

    }

    private func showLoadingOverlay(message: String) {
        window?.makeFirstResponder(nil)
        userNameField?.isEnabled = false
        devModeToggle?.isEnabled = false
        loadingOverlay?.setMessage(message)
        loadingOverlay?.isHidden = false
    }

    private func hideLoadingOverlay() {
        userNameField?.isEnabled = true
        devModeToggle?.isEnabled = true
        loadingOverlay?.isHidden = true
    }

    private func persistUserName(from field: NSTextField) {
        let trimmedValue = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try CCCConfig.setStringValue(trimmedValue.isEmpty ? nil : trimmedValue, forKey: userNameKey)
            AppLogger.info("Updated prompt user name to '\(trimmedValue)'")
            updateUI()
        } catch {
            AppLogger.error("Failed to persist prompt user name: \(error.localizedDescription)")
        }
    }

    private func persistDevMode(isEnabled: Bool) {
        do {
            try CCCConfig.setBoolValue(isEnabled, forKey: devModeKey)
            AppLogger.info("Updated dev mode to \(isEnabled)")
            updateUI()
        } catch {
            AppLogger.error("Failed to persist dev mode: \(error.localizedDescription)")
        }
    }

    private func configuredUserName() -> String? {
        CCCConfig.stringValue(forKey: userNameKey)
    }

    private func configuredDevMode() -> Bool {
        CCCConfig.requiredBoolValue(forKey: devModeKey)
    }

    private func presentPermissionHelper(for missingPermissions: [CCCPermissionRequirement]) {
        let alert = NSAlert()
        let nextPermission = missingPermissions[0]
        alert.messageText = "CCC still needs permission"
        alert.informativeText = permissionHelperMessage(for: missingPermissions)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open \(nextPermission.title)")
        alert.addButton(withTitle: "Reveal CCC.app")
        alert.addButton(withTitle: "Not Now")

        if let window {
            alert.beginSheetModal(for: window) { [weak self] response in
                self?.handlePermissionHelperResponse(
                    response,
                    nextPermission: nextPermission
                )
            }
        } else {
            let response = alert.runModal()
            handlePermissionHelperResponse(response, nextPermission: nextPermission)
        }
    }

    private func handlePermissionHelperResponse(
        _ response: NSApplication.ModalResponse,
        nextPermission: CCCPermissionRequirement
    ) {
        switch response {
        case .alertFirstButtonReturn:
            openSettings(for: nextPermission)
        case .alertSecondButtonReturn:
            revealAppInFinder()
        default:
            break
        }
    }

    private func permissionHelperMessage(for missingPermissions: [CCCPermissionRequirement]) -> String {
        let bulletLines = missingPermissions.map { permission in
            "• \(permission.title): \(permission.details)"
        }
        let bulletBlock = bulletLines.joined(separator: "\n")

        return """
        Missing right now:
        \(bulletBlock)

        Use Open Settings to jump to the next missing permission.
        Use Reveal CCC.app if the Settings page shows a + button and you need to choose the exact app bundle.
        """
    }

    private func openSettings(for permission: CCCPermissionRequirement) {
        guard let url = permission.settingsURL else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    private func makeLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = font
        label.textColor = color
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.lineBreakMode = .byWordWrapping
        return label
    }

    private func bundledApplicationIcon() -> NSImage? {
        if let icon = NSImage(named: "AppIcon") {
            return icon
        }

        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            return icon
        }

        if let projectRoot = ProcessInfo.processInfo.environment["CCC_PROJECT_ROOT"] {
            let iconURL = URL(fileURLWithPath: projectRoot, isDirectory: true)
                .appendingPathComponent("Resources/AppIcon.icns")
            if let icon = NSImage(contentsOf: iconURL) {
                return icon
            }
        }

        return nil
    }

    private func makeDockIcon() -> NSImage {
        let size = NSSize(width: 512, height: 512)
        let image = NSImage(size: size)
        image.lockFocus()

        let rect = NSRect(origin: .zero, size: size)
        let clipPath = NSBezierPath(roundedRect: rect, xRadius: 120, yRadius: 120)
        clipPath.addClip()

        let background = NSGradient(colors: [
            NSColor(calibratedWhite: 0.97, alpha: 1),
            NSColor(calibratedWhite: 0.90, alpha: 1)
        ])
        background?.draw(in: rect, angle: 90)

        let cardRect = NSRect(x: 102, y: 102, width: 308, height: 308)
        let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: 78, yRadius: 78)

        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -16), blur: 30, color: NSColor.black.withAlphaComponent(0.14).cgColor)
            NSColor.white.withAlphaComponent(0.95).setFill()
            cardPath.fill()
            context.restoreGState()
        }

        NSColor.white.withAlphaComponent(0.95).setFill()
        cardPath.fill()
        NSColor.separatorColor.withAlphaComponent(0.24).setStroke()
        cardPath.lineWidth = 1.5
        cardPath.stroke()

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 118, weight: .bold),
            .foregroundColor: NSColor(calibratedWhite: 0.16, alpha: 1),
            .paragraphStyle: paragraphStyle
        ]
        NSString(string: "CCC").draw(
            in: NSRect(x: 0, y: 174, width: 512, height: 128),
            withAttributes: titleAttributes
        )

        let accentPath = NSBezierPath(roundedRect: NSRect(x: 146, y: 132, width: 220, height: 24), xRadius: 12, yRadius: 12)
        let accentGradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.29, green: 0.60, blue: 0.97, alpha: 1),
            NSColor(calibratedRed: 0.28, green: 0.80, blue: 0.60, alpha: 1)
        ])
        accentGradient?.draw(in: accentPath, angle: 0)

        image.unlockFocus()
        return image
    }
}

private final class CCCWindowBackgroundView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .windowBackground
        blendingMode = .withinWindow
        state = .active
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

private final class CCCLoadingOverlayView: NSVisualEffectView {
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor

        let card = CCCSectionCardView()
        card.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        addSubview(card)

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        card.addSubview(stack)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor

        stack.addArrangedSubview(spinner)
        stack.addArrangedSubview(label)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 210),

            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setMessage(_ message: String) {
        label.stringValue = message
    }
}

private final class CCCSectionCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.20).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

private final class CCCAppBadgeView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor

        let label = NSTextField(labelWithString: "ccc")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        label.textColor = .controlAccentColor
        addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

private final class CCCMetricRowView: NSView {
    private let valuePill = CCCStatusPillView(text: "", tone: .neutral)

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor

        addSubview(titleLabel)
        addSubview(valuePill)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            valuePill.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
            valuePill.trailingAnchor.constraint(equalTo: trailingAnchor),
            valuePill.topAnchor.constraint(equalTo: topAnchor),
            valuePill.bottomAnchor.constraint(equalTo: bottomAnchor),

            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 2),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -2)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(value: String, tone: CCCStatusPillView.Tone) {
        valuePill.update(text: value, tone: tone)
    }
}

private final class CCCStatusPillView: NSView {
    enum Tone {
        case green
        case blue
        case danger
        case neutral
    }

    private let label: NSTextField
    private var tone: Tone

    init(text: String, tone: Tone) {
        label = NSTextField(labelWithString: text)
        self.tone = tone
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])

        update(text: text, tone: tone)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(text: String, tone: Tone) {
        self.tone = tone
        label.stringValue = text

        let fillColor: NSColor
        let textColor: NSColor
        let borderColor: NSColor

        switch tone {
        case .green:
            fillColor = NSColor.systemGreen.withAlphaComponent(0.14)
            textColor = NSColor.systemGreen
            borderColor = NSColor.systemGreen.withAlphaComponent(0.18)
        case .blue:
            fillColor = NSColor.systemBlue.withAlphaComponent(0.14)
            textColor = NSColor.systemBlue
            borderColor = NSColor.systemBlue.withAlphaComponent(0.18)
        case .danger:
            fillColor = NSColor.systemRed.withAlphaComponent(0.14)
            textColor = NSColor.systemRed
            borderColor = NSColor.systemRed.withAlphaComponent(0.18)
        case .neutral:
            fillColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.10)
            textColor = .secondaryLabelColor
            borderColor = NSColor.separatorColor.withAlphaComponent(0.18)
        }

        layer?.backgroundColor = fillColor.cgColor
        layer?.borderColor = borderColor.cgColor
        label.textColor = textColor
    }
}

private final class CCCSeparatorView: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 1)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

private final class CCCShortcutBadgeView: NSView {
    init(key: String, caption: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let keyCap = CCCKeyCapView(text: key)
        let captionLabel = NSTextField(labelWithString: caption)
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        captionLabel.textColor = .secondaryLabelColor

        addSubview(keyCap)
        addSubview(captionLabel)

        NSLayoutConstraint.activate([
            keyCap.leadingAnchor.constraint(equalTo: leadingAnchor),
            keyCap.centerYAnchor.constraint(equalTo: centerYAnchor),

            captionLabel.leadingAnchor.constraint(equalTo: keyCap.trailingAnchor, constant: 8),
            captionLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            captionLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            topAnchor.constraint(equalTo: keyCap.topAnchor),
            bottomAnchor.constraint(equalTo: keyCap.bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

private final class CCCKeyCapView: NSView {
    init(text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.22).cgColor

        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        label.textColor = .labelColor
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

private final class CCCButton: NSButton {
    enum Tone {
        case normal
        case accent
        case success
        case danger
    }

    var tone: Tone = .normal {
        didSet { applyStyle() }
    }

    override var isEnabled: Bool {
        didSet { applyStyle() }
    }

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        isBordered = true
        controlSize = .regular
        font = .systemFont(ofSize: 12, weight: .medium)
        translatesAutoresizingMaskIntoConstraints = false
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func applyStyle() {
        switch tone {
        case .normal:
            bezelColor = NSColor.controlColor
            contentTintColor = .labelColor
        case .accent:
            bezelColor = .controlAccentColor
            contentTintColor = .white
        case .success:
            bezelColor = NSColor.systemGreen
            contentTintColor = NSColor.systemGreen
        case .danger:
            bezelColor = NSColor.systemRed
            contentTintColor = NSColor.systemRed
        }

        alphaValue = isEnabled ? 1 : 0.55
    }
}
