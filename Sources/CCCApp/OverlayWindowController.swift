import AppKit
import Foundation

private enum OverlayPresentationState {
    case loading
    case suggestion
    case status
}

private let cccAccentColor = NSColor(
    calibratedRed: 0.18,
    green: 0.82,
    blue: 1.0,
    alpha: 1.0
)

final class OverlayWindowController {
    private let loadingMessage = "cccchecking"
    private let panel: NSPanel
    private let contentView: OverlayContentView
    private let logoView: CCCMarkView
    private let titleLabel: NSTextField
    private let statusDot: DotView
    private let statusLabel: NSTextField
    private let shortcutStack: NSStackView
    private let headerStack: NSStackView
    private let suggestionBoxView: SuggestionBoxView
    private let suggestionTextView: SuggestionTextView
    private let centeredStatusLabel: NSTextField
    private let loadingIndicator: LoadingSpinnerView
    private let loadingLabel: NSTextField
    private let loadingStack: NSStackView
    private let loadingOrderBadgeView: LoadingOrderBadgeView
    private let suggestionLineCharacterLimit = 128
    private let suggestionPreferredWidthCharacterLimit = 80
    private let suggestionPanelMaximumWidth: CGFloat = 560
    private var presentationState: OverlayPresentationState = .status
    private var loadingOrder: Int?
    var onInteract: (() -> Void)?

    var isVisible: Bool {
        panel.isVisible
    }

    init() {
        contentView = OverlayContentView(frame: NSRect(x: 0, y: 0, width: 360, height: 96))

        logoView = CCCMarkView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        logoView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel = NSTextField(labelWithString: "ccc")
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byClipping
        titleLabel.backgroundColor = .clear

        statusDot = DotView(color: NSColor(calibratedRed: 0.42, green: 0.55, blue: 0.92, alpha: 1.0))
        statusDot.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "Suggested reply")
        statusLabel.font = .systemFont(ofSize: 13, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byClipping
        statusLabel.backgroundColor = .clear

        shortcutStack = NSStackView(views: [
            ShortcutHintView(key: "Tab", action: "Accept"),
            ShortcutHintView(key: "Shift Tab", action: "Retry"),
            ShortcutHintView(key: "Esc", action: "Dismiss")
        ])
        shortcutStack.translatesAutoresizingMaskIntoConstraints = false
        shortcutStack.orientation = .horizontal
        shortcutStack.alignment = .centerY
        shortcutStack.spacing = 8
        shortcutStack.setContentHuggingPriority(.required, for: .horizontal)
        shortcutStack.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let identityStack = NSStackView(views: [logoView, titleLabel])
        identityStack.translatesAutoresizingMaskIntoConstraints = false
        identityStack.orientation = .horizontal
        identityStack.alignment = .centerY
        identityStack.spacing = 8

        let statusStack = NSStackView(views: [statusDot, statusLabel])
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 7

        headerStack = NSStackView(views: [identityStack, statusStack, shortcutStack])
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 12
        headerStack.distribution = .gravityAreas

        suggestionTextView = SuggestionTextView()
        suggestionTextView.translatesAutoresizingMaskIntoConstraints = false
        suggestionTextView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        suggestionTextView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        suggestionTextView.setContentHuggingPriority(.required, for: .vertical)
        suggestionTextView.setContentCompressionResistancePriority(.required, for: .vertical)

        suggestionBoxView = SuggestionBoxView(frame: .zero)
        suggestionBoxView.translatesAutoresizingMaskIntoConstraints = false
        suggestionBoxView.addSubview(suggestionTextView)

        centeredStatusLabel = NSTextField(labelWithString: "")
        centeredStatusLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        centeredStatusLabel.textColor = .labelColor
        centeredStatusLabel.alignment = .center
        centeredStatusLabel.lineBreakMode = .byClipping
        centeredStatusLabel.backgroundColor = .clear
        centeredStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        loadingIndicator = LoadingSpinnerView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.setContentHuggingPriority(.required, for: .horizontal)
        loadingIndicator.setContentCompressionResistancePriority(.required, for: .horizontal)

        loadingLabel = NSTextField(labelWithString: loadingMessage)
        loadingLabel.font = .systemFont(ofSize: 17, weight: .medium)
        loadingLabel.textColor = .labelColor
        loadingLabel.lineBreakMode = .byClipping
        loadingLabel.backgroundColor = .clear
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingLabel.setContentHuggingPriority(.required, for: .horizontal)
        loadingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        loadingStack = NSStackView(views: [loadingIndicator, loadingLabel])
        loadingStack.translatesAutoresizingMaskIntoConstraints = false
        loadingStack.orientation = .horizontal
        loadingStack.alignment = .centerY
        loadingStack.spacing = 14
        loadingStack.isHidden = true

        loadingOrderBadgeView = LoadingOrderBadgeView()
        loadingOrderBadgeView.translatesAutoresizingMaskIntoConstraints = false
        loadingOrderBadgeView.isHidden = true

        contentView.addSubview(headerStack)
        contentView.addSubview(suggestionBoxView)
        contentView.addSubview(centeredStatusLabel)
        contentView.addSubview(loadingStack)
        contentView.addSubview(loadingOrderBadgeView)

        NSLayoutConstraint.activate([
            logoView.widthAnchor.constraint(equalToConstant: 24),
            logoView.heightAnchor.constraint(equalToConstant: 24),
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),

            headerStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            headerStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            headerStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),

            suggestionBoxView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            suggestionBoxView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            suggestionBoxView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 12),
            suggestionBoxView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),

            suggestionTextView.leadingAnchor.constraint(equalTo: suggestionBoxView.leadingAnchor, constant: 16),
            suggestionTextView.trailingAnchor.constraint(equalTo: suggestionBoxView.trailingAnchor, constant: -16),
            suggestionTextView.topAnchor.constraint(equalTo: suggestionBoxView.topAnchor, constant: 12),
            suggestionTextView.bottomAnchor.constraint(equalTo: suggestionBoxView.bottomAnchor, constant: -12),

            centeredStatusLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            centeredStatusLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            centeredStatusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 24),
            centeredStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -24),

            loadingStack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            loadingStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            loadingStack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 24),
            loadingStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -24),
            loadingIndicator.widthAnchor.constraint(equalToConstant: 32),
            loadingIndicator.heightAnchor.constraint(equalToConstant: 32),

            loadingOrderBadgeView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            loadingOrderBadgeView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 96),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.alphaValue = 0
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = contentView
        contentView.onInteract = { [weak self] in
            self?.onInteract?()
        }
    }

    func show(suggestion: String, near accessibilityRect: CGRect) {
        stopLoadingAnimation()
        show(
            message: suggestion,
            near: accessibilityRect,
            animated: true,
            logFrame: true,
            state: .suggestion
        )
    }

    func showStatus(message: String, near accessibilityRect: CGRect) {
        stopLoadingAnimation()
        show(
            message: message,
            near: accessibilityRect,
            animated: true,
            logFrame: true,
            state: .status
        )
    }

    func showLoading(near accessibilityRect: CGRect, order: Int? = nil) {
        loadingOrder = order
        show(
            message: loadingMessage,
            near: accessibilityRect,
            animated: true,
            logFrame: true,
            state: .loading
        )
        startLoadingAnimation()
    }

    private func show(
        message: String,
        near accessibilityRect: CGRect,
        animated: Bool,
        logFrame: Bool,
        state: OverlayPresentationState
    ) {
        presentationState = state
        contentView.presentationState = state

        headerStack.isHidden = state != .suggestion
        suggestionBoxView.isHidden = state != .suggestion
        centeredStatusLabel.isHidden = state != .status
        loadingStack.isHidden = state != .loading
        loadingOrderBadgeView.isHidden = state != .loading || (loadingOrder ?? 1) <= 1

        let displayMessage = state == .suggestion
            ? wrappedSuggestionText(message, limit: suggestionLineCharacterLimit)
            : message

        suggestionTextView.stringValue = displayMessage
        centeredStatusLabel.stringValue = message
        loadingLabel.stringValue = loadingMessage
        loadingOrderBadgeView.value = loadingOrder

        let caretRect = convertToAppKitCoordinates(accessibilityRect)
        let frame = constrainedFrame(
            preferredFrame(
                for: displayMessage,
                near: caretRect,
                state: state
            ),
            near: caretRect
        )
        if logFrame {
            AppLogger.info("Overlay frame: \(NSStringFromRect(frame))")
        }

        if panel.isVisible {
            panel.contentView?.frame = CGRect(origin: .zero, size: frame.size)
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(frame, display: true)
                }
            } else {
                panel.setFrame(frame, display: true)
            }
            contentView.startAnimating()
            panel.orderFrontRegardless()
            return
        }

        let startFrame = frame.offsetBy(dx: 0, dy: -10)
        panel.alphaValue = 0
        panel.contentView?.frame = CGRect(origin: .zero, size: frame.size)
        panel.setFrame(startFrame, display: true)
        panel.orderFrontRegardless()
        animateAppearance(to: frame)
        contentView.startAnimating()
    }

    func hide() {
        guard panel.isVisible else {
            return
        }

        AppLogger.info("Overlay hidden")
        stopLoadingAnimation()
        contentView.stopAnimating()
        panel.orderOut(nil)
        panel.alphaValue = 0
        contentView.layer?.transform = CATransform3DIdentity
    }

    private func startLoadingAnimation() {
        loadingIndicator.startAnimating()
    }

    private func stopLoadingAnimation() {
        loadingIndicator.stopAnimating()
    }

    private func animateAppearance(to finalFrame: CGRect) {
        contentView.layer?.transform = CATransform3DMakeScale(0.96, 0.96, 1)
        contentView.layer?.opacity = 0.0

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: true)
        }

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.96
        scale.toValue = 1.0
        scale.duration = 0.22
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0
        fade.duration = 0.22
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        contentView.layer?.transform = CATransform3DIdentity
        contentView.layer?.opacity = 1.0
        contentView.layer?.add(scale, forKey: "overlay.scale")
        contentView.layer?.add(fade, forKey: "overlay.fade")
    }

    private func preferredFrame(
        for message: String,
        near rect: CGRect,
        state: OverlayPresentationState
    ) -> CGRect {
        let targetFrame = screenFrame(containing: rect) ?? fallbackScreenFrame()
        let size = preferredSize(for: message, in: targetFrame, state: state)
        let anchor = normalizedAnchor(from: rect, in: targetFrame)
        let verticalGap: CGFloat = state == .suggestion ? 12 : 10
        let canFitAbove = anchor.maxY + verticalGap + size.height <= targetFrame.maxY - 16
        let y = canFitAbove
            ? anchor.maxY + verticalGap
            : anchor.minY - verticalGap - size.height

        let anchorFraction: CGFloat = state == .suggestion ? 0.10 : 0.50
        let x = anchor.midX - (size.width * anchorFraction)

        return CGRect(
            x: floor(x),
            y: floor(y),
            width: size.width,
            height: size.height
        )
    }

    private func wrappedSuggestionText(_ text: String, limit: Int) -> String {
        text.components(separatedBy: .newlines)
            .map { line in
                var remaining = line
                var wrappedLines = [String]()

                while remaining.count > limit {
                    let breakIndex = remaining.index(
                        remaining.startIndex,
                        offsetBy: limit
                    )
                    wrappedLines.append(String(remaining[..<breakIndex]).trimmingCharacters(in: .whitespaces))
                    remaining = String(remaining[breakIndex...])
                    while remaining.first == " " {
                        remaining.removeFirst()
                    }
                }

                wrappedLines.append(remaining)
                return wrappedLines.joined(separator: "\n")
            }
            .joined(separator: "\n")
    }

    private func preferredSize(
        for message: String,
        in targetFrame: CGRect,
        state: OverlayPresentationState
    ) -> CGSize {
        switch state {
        case .loading:
            let textWidth = ceil(loadingLabel.attributedStringValue.boundingRect(
                with: NSSize(width: 10_000, height: 40),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).width)
            let badgeWidth = (loadingOrder ?? 1) > 1
                ? loadingOrderBadgeView.intrinsicContentSize.width + 20
                : 0
            return CGSize(width: max(336, textWidth + 130 + badgeWidth), height: 96)

        case .status:
            let textWidth = ceil(centeredStatusLabel.attributedStringValue.boundingRect(
                with: NSSize(width: 10_000, height: 40),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).width)
            return CGSize(width: min(max(260, textWidth + 72), min(520, targetFrame.width - 32)), height: 72)

        case .suggestion:
            let maxWidth = min(max(280, targetFrame.width - 32), suggestionPanelMaximumWidth)
            let minWidth: CGFloat = min(360, maxWidth)
            let panelVerticalChrome: CGFloat = 18 + 28 + 12 + 28 + 18
            let maxPanelHeight = max(136, targetFrame.height - 52)
            let maxTextHeight = max(96, maxPanelHeight - panelVerticalChrome)
            let sizingMessage = wrappedSuggestionText(
                message,
                limit: suggestionPreferredWidthCharacterLimit
            )
            let measuredLineWidth = SuggestionTextView.maxLineWidth(for: sizingMessage)
            let naturalWidth = min(maxWidth, max(minWidth, ceil(measuredLineWidth) + 80))
            let textWidth = naturalWidth - 80
            let textRect = SuggestionTextView.boundingRect(for: message, width: textWidth, height: maxTextHeight)
            let suggestionBoxHeight = max(58, ceil(textRect.height) + 28)
            let height = max(136, min(maxPanelHeight, 18 + 28 + 12 + suggestionBoxHeight + 18))
            return CGSize(width: naturalWidth, height: height)
        }
    }

    private func normalizedAnchor(from rect: CGRect, in targetFrame: CGRect) -> CGRect {
        if rect == .zero || rect.isNull || rect.isInfinite {
            let mouse = NSEvent.mouseLocation
            return CGRect(x: mouse.x, y: mouse.y, width: 1, height: 22)
        }

        let minWidth: CGFloat = max(rect.width, 1)
        let minHeight: CGFloat = max(rect.height, 20)
        let x = min(max(rect.minX, targetFrame.minX + 16), targetFrame.maxX - 16)
        let y = min(max(rect.minY, targetFrame.minY + 16), targetFrame.maxY - 16)
        return CGRect(x: x, y: y, width: minWidth, height: minHeight)
    }

    private func convertToAppKitCoordinates(_ rect: CGRect) -> CGRect {
        let desktopFrame = NSScreen.screens.reduce(CGRect.null) { partialResult, screen in
            partialResult.union(screen.frame)
        }

        guard !desktopFrame.isNull else {
            return rect
        }

        return CGRect(
            x: rect.origin.x,
            y: desktopFrame.maxY - rect.origin.y - rect.size.height,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    private func screenFrame(containing rect: CGRect) -> CGRect? {
        NSScreen.screens.first(where: { $0.frame.intersects(rect) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
    }

    private func fallbackScreenFrame() -> CGRect {
        NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 720)
    }

    private func constrainedFrame(_ proposedFrame: CGRect, near rect: CGRect) -> CGRect {
        let targetFrame = screenFrame(containing: rect) ?? fallbackScreenFrame()
        let maxAllowedWidth = max(240 as CGFloat, targetFrame.width - 32)
        let maxAllowedHeight = max(64 as CGFloat, targetFrame.height - 52)
        let width = min(proposedFrame.width, maxAllowedWidth)
        let height = min(proposedFrame.height, maxAllowedHeight)
        let x = min(
            max(targetFrame.minX + 16, proposedFrame.minX),
            targetFrame.maxX - width - 16
        )
        let y = min(
            max(targetFrame.minY + 16, proposedFrame.minY),
            targetFrame.maxY - height - 16
        )

        return CGRect(x: floor(x), y: floor(y), width: floor(width), height: floor(height))
    }
}

private final class LoadingSpinnerView: NSView {
    private let spinnerLayer = CAShapeLayer()
    private let animationKey = "ccc.spinner.rotation"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        spinnerLayer.fillColor = nil
        spinnerLayer.lineCap = .round
        spinnerLayer.lineWidth = 3
        spinnerLayer.strokeColor = cccAccentColor.cgColor
        spinnerLayer.strokeStart = 0.12
        spinnerLayer.strokeEnd = 0.82
        layer?.addSublayer(spinnerLayer)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        spinnerLayer.frame = bounds
        spinnerLayer.path = CGPath(
            ellipseIn: bounds.insetBy(dx: 4, dy: 4),
            transform: nil
        )
    }

    func startAnimating() {
        isHidden = false

        guard spinnerLayer.animation(forKey: animationKey) == nil else {
            return
        }

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = Double.pi * 2
        rotation.duration = 0.85
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        spinnerLayer.add(rotation, forKey: animationKey)
    }

    func stopAnimating() {
        spinnerLayer.removeAnimation(forKey: animationKey)
        isHidden = true
    }
}

private final class OverlayContentView: NSView {
    var onInteract: (() -> Void)?
    var presentationState: OverlayPresentationState = .status {
        didSet {
            needsLayout = true
        }
    }

    private let cardLayer = CALayer()
    private let borderLayer = CAShapeLayer()
    private let cardInset: CGFloat = 8
    private var dragStartMouseLocation: NSPoint?
    private var dragStartWindowOrigin: NSPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.backgroundColor = NSColor.clear.cgColor

        cardLayer.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        cardLayer.shadowColor = NSColor.black.cgColor
        cardLayer.shadowOpacity = 0.22
        cardLayer.shadowRadius = 18
        cardLayer.shadowOffset = CGSize(width: 0, height: -8)

        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.strokeColor = cccAccentColor.withAlphaComponent(0.72).cgColor
        borderLayer.lineWidth = 1.5

        layer?.addSublayer(cardLayer)
        layer?.addSublayer(borderLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func startAnimating() {}

    func stopAnimating() {}

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        onInteract?()
        dragStartMouseLocation = NSEvent.mouseLocation
        dragStartWindowOrigin = window?.frame.origin
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartMouseLocation,
              let dragStartWindowOrigin,
              let window
        else {
            return
        }

        let currentMouseLocation = NSEvent.mouseLocation
        let deltaX = currentMouseLocation.x - dragStartMouseLocation.x
        let deltaY = currentMouseLocation.y - dragStartMouseLocation.y
        window.setFrameOrigin(
            NSPoint(
                x: dragStartWindowOrigin.x + deltaX,
                y: dragStartWindowOrigin.y + deltaY
            )
        )
    }

    override func mouseUp(with event: NSEvent) {
        dragStartMouseLocation = nil
        dragStartWindowOrigin = nil
        NSCursor.pop()
    }

    override func layout() {
        super.layout()

        let cardBounds = bounds.insetBy(dx: cardInset, dy: cardInset)
        let cornerRadius: CGFloat = presentationState == .suggestion ? 12 : 13
        let cardPath = CGPath(
            roundedRect: cardBounds,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        cardLayer.frame = cardBounds
        cardLayer.cornerRadius = cornerRadius
        cardLayer.shadowPath = cardPath

        borderLayer.frame = bounds
        borderLayer.path = cardPath
    }
}

private final class SuggestionTextView: NSView {
    static let textFont = NSFont.systemFont(ofSize: 14, weight: .regular)

    var stringValue = "" {
        didSet {
            needsDisplay = true
        }
    }

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard !stringValue.isEmpty else {
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        (stringValue as NSString).draw(
            with: bounds,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: Self.textAttributes()
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    static func boundingRect(for text: String, width: CGFloat, height: CGFloat) -> CGRect {
        (text as NSString).boundingRect(
            with: NSSize(width: width, height: height),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: textAttributes()
        )
    }

    static func maxLineWidth(for text: String) -> CGFloat {
        text.components(separatedBy: .newlines).reduce(0) { maxWidth, line in
            let width = (line as NSString).size(withAttributes: textAttributes()).width
            return max(maxWidth, width)
        }
    }

    private static func textAttributes() -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byCharWrapping
        paragraphStyle.alignment = .left

        return [
            .font: textFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
    }
}

private final class SuggestionBoxView: NSView {
    private let backgroundLayer = CALayer()
    private let borderLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        backgroundLayer.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.62).cgColor
        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.strokeColor = NSColor.black.withAlphaComponent(0.18).cgColor
        borderLayer.lineWidth = 1

        layer?.addSublayer(backgroundLayer)
        layer?.addSublayer(borderLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let path = CGPath(
            roundedRect: bounds,
            cornerWidth: 7,
            cornerHeight: 7,
            transform: nil
        )
        backgroundLayer.frame = bounds
        backgroundLayer.cornerRadius = 7
        borderLayer.frame = bounds
        borderLayer.path = path
    }
}

private final class CCCMarkView: NSImageView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        image = Self.smallIcon()
        imageScaling = .scaleProportionallyUpOrDown
        imageAlignment = .alignCenter
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private static func smallIcon() -> NSImage {
        if let icon = NSImage(named: "AppIcon") {
            return icon
        }

        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            return icon
        }

        if let projectRoot = ProcessInfo.processInfo.environment["CCC_PROJECT_ROOT"] {
            let iconURL = URL(fileURLWithPath: projectRoot, isDirectory: true)
                .appendingPathComponent("Resources/AppIcon.iconset/icon_32x32.png")
            if let icon = NSImage(contentsOf: iconURL) {
                return icon
            }
        }

        let image = NSImage(size: NSSize(width: 24, height: 24))
        image.lockFocus()
        NSColor.labelColor.set()
        NSString(string: "ccc").draw(
            in: NSRect(x: 0, y: 3, width: 24, height: 18),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
        )
        image.unlockFocus()
        return image
    }
}

private final class DotView: NSView {
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

private final class LoadingOrderBadgeView: NSView {
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)

    var value: Int? {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        let text = "\(value ?? 0)" as NSString
        let textSize = text.size(withAttributes: [.font: font])
        return NSSize(width: max(24, ceil(textSize.width) + 14), height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let value, value > 1 else {
            return
        }

        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        cccAccentColor.withAlphaComponent(0.13).setFill()
        path.fill()
        cccAccentColor.withAlphaComponent(0.72).setStroke()
        path.lineWidth = 1
        path.stroke()

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: cccAccentColor.withAlphaComponent(0.95),
            .paragraphStyle: paragraphStyle
        ]
        let text = "\(value)" as NSString
        let textSize = text.size(withAttributes: attributes)
        let textRect = NSRect(
            x: bounds.minX,
            y: floor(bounds.midY - (textSize.height / 2)) + 1,
            width: bounds.width,
            height: ceil(textSize.height)
        )
        text.draw(in: textRect, withAttributes: attributes)
    }
}

private final class ShortcutHintView: NSStackView {
    init(key: String, action: String) {
        let keyLabel = KeyCapLabel(key)
        let actionLabel = NSTextField(labelWithString: action)
        actionLabel.font = .systemFont(ofSize: 12, weight: .regular)
        actionLabel.textColor = .secondaryLabelColor
        actionLabel.backgroundColor = .clear

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        orientation = .horizontal
        alignment = .centerY
        spacing = 5
        addArrangedSubview(keyLabel)
        addArrangedSubview(actionLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

private final class KeyCapLabel: NSView {
    private let text: String
    private let font = NSFont.systemFont(ofSize: 11, weight: .medium)

    init(_ text: String) {
        self.text = text
        super.init(frame: .zero)
        wantsLayer = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        return NSSize(width: max(28, ceil(textSize.width) + 12), height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        NSColor.controlBackgroundColor.withAlphaComponent(0.78).setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.18).setStroke()
        path.lineWidth = 1
        path.stroke()

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let textRect = NSRect(
            x: bounds.minX,
            y: floor(bounds.midY - (textSize.height / 2)) + 1,
            width: bounds.width,
            height: ceil(textSize.height)
        )
        (text as NSString).draw(in: textRect, withAttributes: attributes)
    }
}
