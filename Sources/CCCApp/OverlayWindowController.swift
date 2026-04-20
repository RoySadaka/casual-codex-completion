import AppKit
import Foundation

final class OverlayWindowController {
    private let panel: NSPanel
    private let contentView: OverlayContentView
    private let suggestionLabel: NSTextField
    private let hintLabel: NSTextField
    private var loadingTimer: Timer?
    private var loadingFrameIndex = 0

    var isVisible: Bool {
        panel.isVisible
    }

    init() {
        suggestionLabel = NSTextField(wrappingLabelWithString: "")
        suggestionLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        suggestionLabel.textColor = NSColor(
            calibratedRed: 0.11,
            green: 0.19,
            blue: 0.36,
            alpha: 1.0
        )
        suggestionLabel.alignment = .center
        suggestionLabel.lineBreakMode = .byWordWrapping
        suggestionLabel.maximumNumberOfLines = 0
        suggestionLabel.backgroundColor = .clear
        suggestionLabel.translatesAutoresizingMaskIntoConstraints = false
        suggestionLabel.cell?.wraps = true
        suggestionLabel.cell?.usesSingleLineMode = false
        suggestionLabel.cell?.isScrollable = false
        suggestionLabel.cell?.truncatesLastVisibleLine = false
        suggestionLabel.cell?.lineBreakMode = .byWordWrapping
        suggestionLabel.setContentHuggingPriority(.required, for: .vertical)
        suggestionLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        hintLabel = NSTextField(labelWithString: "Tab to insert")
        hintLabel.font = .systemFont(ofSize: 11, weight: .medium)
        hintLabel.textColor = NSColor(
            calibratedRed: 0.35,
            green: 0.47,
            blue: 0.67,
            alpha: 0.95
        )
        hintLabel.lineBreakMode = .byClipping
        hintLabel.backgroundColor = .clear
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.setContentHuggingPriority(.required, for: .vertical)
        hintLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        contentView = OverlayContentView(frame: NSRect(x: 0, y: 0, width: 320, height: 72))
        contentView.addSubview(suggestionLabel)
        contentView.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            suggestionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            suggestionLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            suggestionLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),

            hintLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            hintLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
            hintLabel.topAnchor.constraint(greaterThanOrEqualTo: suggestionLabel.bottomAnchor, constant: 6)
        ])

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = contentView
    }

    func show(suggestion: String, near accessibilityRect: CGRect) {
        stopLoadingAnimation()
        show(message: suggestion, hint: "Tab to insert", near: accessibilityRect, animated: true, logFrame: true)
    }

    func showStatus(message: String, near accessibilityRect: CGRect) {
        stopLoadingAnimation()
        show(message: message, hint: nil, near: accessibilityRect, animated: true, logFrame: true)
    }

    func showLoading(near accessibilityRect: CGRect) {
        loadingFrameIndex = 0
        show(message: loadingMessage(for: loadingFrameIndex), hint: nil, near: accessibilityRect, animated: true, logFrame: true)
        startLoadingAnimation(near: accessibilityRect)
    }

    private func show(
        message: String,
        hint: String?,
        near accessibilityRect: CGRect,
        animated: Bool,
        logFrame: Bool
    ) {
        hintLabel.isHidden = hint == nil
        hintLabel.stringValue = hint ?? ""
        suggestionLabel.stringValue = message
        let frame = constrainedFrame(
            preferredFrame(for: message, hint: hint, near: convertToAppKitCoordinates(accessibilityRect)),
            near: convertToAppKitCoordinates(accessibilityRect)
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

        let startFrame = frame.offsetBy(dx: 0, dy: 14)
        panel.alphaValue = 0
        panel.contentView?.frame = CGRect(origin: .zero, size: frame.size)
        panel.setFrame(startFrame, display: true)
        panel.orderFrontRegardless()
        animateAppearance()
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

    private func startLoadingAnimation(near accessibilityRect: CGRect) {
        stopLoadingAnimation()

        loadingTimer = Timer.scheduledTimer(withTimeInterval: 0.28, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.loadingFrameIndex = (self.loadingFrameIndex + 1) % 4
            self.show(
                message: self.loadingMessage(for: self.loadingFrameIndex),
                hint: nil,
                near: accessibilityRect,
                animated: false,
                logFrame: false
            )
        }
        if let loadingTimer {
            RunLoop.main.add(loadingTimer, forMode: .common)
        }
    }

    private func stopLoadingAnimation() {
        loadingTimer?.invalidate()
        loadingTimer = nil
    }

    private func loadingMessage(for frame: Int) -> String {
        "cccchecking" + String(repeating: ".", count: frame)
    }

    private func animateAppearance() {
        let finalFrame = panel.frame.offsetBy(dx: 0, dy: -14)
        contentView.layer?.transform = CATransform3DMakeScale(0.96, 0.96, 1)
        contentView.layer?.opacity = 0.0

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.26
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: true)
        }

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.96
        scale.toValue = 1.0
        scale.duration = 0.26
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0
        fade.duration = 0.26
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        contentView.layer?.transform = CATransform3DIdentity
        contentView.layer?.opacity = 1.0
        contentView.layer?.add(scale, forKey: "overlay.scale")
        contentView.layer?.add(fade, forKey: "overlay.fade")
    }

    private func preferredFrame(for suggestion: String, hint: String?, near rect: CGRect) -> CGRect {
        let targetFrame = screenFrame(containing: rect) ?? fallbackScreenFrame()
        let maxWidth = min(720 as CGFloat, max(260, targetFrame.width - 32))
        let minWidth: CGFloat = 220
        let horizontalPadding: CGFloat = 32
        let maxContentWidth = maxWidth - horizontalPadding
        let naturalSuggestionRect = suggestionLabel.attributedStringValue.boundingRect(
            with: NSSize(width: 10_000, height: 260),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let hintRect: CGRect
        if let hint, !hint.isEmpty {
            hintRect = hintLabel.attributedStringValue.boundingRect(
                with: NSSize(width: 10_000, height: 30),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
        } else {
            hintRect = .zero
        }

        let shouldWrap = suggestion.contains("\n") || ceil(naturalSuggestionRect.width) > maxContentWidth
        let contentWidth = shouldWrap
            ? maxContentWidth
            : max(ceil(max(naturalSuggestionRect.width, hintRect.width)), minWidth - horizontalPadding)
        let suggestionRect = shouldWrap
            ? suggestionLabel.attributedStringValue.boundingRect(
                with: NSSize(width: contentWidth, height: 260),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            : naturalSuggestionRect
        let width = max(minWidth, min(maxWidth, ceil(max(contentWidth, hintRect.width)) + horizontalPadding))
        let hintSpacing: CGFloat = hintRect == .zero ? 0 : 6
        let bottomPadding: CGFloat = hintRect == .zero ? 14 : 10
        let height = max(58, ceil(suggestionRect.height) + ceil(hintRect.height) + 14 + hintSpacing + bottomPadding)

        let centeredX = floor(targetFrame.midX - (width / 2))
        let clampedX = min(
            max(targetFrame.minX + 16, centeredX),
            targetFrame.maxX - width - 16
        )
        let origin = CGPoint(x: clampedX, y: floor(targetFrame.maxY - height - 26))

        return CGRect(origin: origin, size: CGSize(width: width, height: height))
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
        let maxAllowedWidth = max(220 as CGFloat, targetFrame.width - 32)
        let maxAllowedHeight = max(58 as CGFloat, targetFrame.height - 52)
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

private final class OverlayContentView: NSView {
    private let haloContainerLayer = CALayer()
    private let haloMaskLayer = CAShapeLayer()
    private let colorDiskLayer = CAGradientLayer()
    private let cardLayer = CALayer()
    private var isAnimating = false
    private let cardInset: CGFloat = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.backgroundColor = NSColor.clear.cgColor

        let siriColors = [
            NSColor(calibratedRed: 0.20, green: 0.82, blue: 1.0, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.08, green: 0.67, blue: 1.0, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.40, green: 0.50, blue: 1.0, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.98, green: 0.38, blue: 0.98, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.18, green: 0.94, blue: 0.78, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.20, green: 0.82, blue: 1.0, alpha: 1.0).cgColor
        ]

        haloContainerLayer.masksToBounds = false
        haloContainerLayer.mask = haloMaskLayer

        colorDiskLayer.type = .conic
        colorDiskLayer.colors = siriColors
        colorDiskLayer.locations = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]
        colorDiskLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        colorDiskLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
        colorDiskLayer.opacity = 1.0

        cardLayer.backgroundColor = NSColor.white.withAlphaComponent(0.98).cgColor
        cardLayer.shadowColor = NSColor.black.withAlphaComponent(0.12).cgColor
        cardLayer.shadowOpacity = 1
        cardLayer.shadowRadius = 24
        cardLayer.shadowOffset = CGSize(width: 0, height: -8)

        haloContainerLayer.addSublayer(colorDiskLayer)
        layer?.addSublayer(haloContainerLayer)
        layer?.addSublayer(cardLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func startAnimating() {
        guard !isAnimating else { return }
        isAnimating = true

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0.0
        spin.toValue = Double.pi * 2
        spin.duration = 4.6
        spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        spin.isRemovedOnCompletion = false

        colorDiskLayer.add(spin, forKey: "siri.spin")
    }

    func stopAnimating() {
        isAnimating = false
        colorDiskLayer.removeAnimation(forKey: "siri.spin")
    }

    override func layout() {
        super.layout()

        guard let layer else { return }

        let cardBounds = bounds.insetBy(dx: cardInset, dy: cardInset)
        let cardPath = CGPath(
            roundedRect: cardBounds,
            cornerWidth: 16,
            cornerHeight: 16,
            transform: nil
        )

        let outerBounds = bounds
        let innerBounds = cardBounds
        let haloRingPath = CGMutablePath()
        haloRingPath.addPath(
            CGPath(
                roundedRect: outerBounds,
                cornerWidth: 20,
                cornerHeight: 20,
                transform: nil
            )
        )
        haloRingPath.addPath(
            CGPath(
                roundedRect: innerBounds,
                cornerWidth: 16,
                cornerHeight: 16,
                transform: nil
            )
        )

        haloContainerLayer.frame = bounds
        haloMaskLayer.frame = bounds
        haloMaskLayer.path = haloRingPath
        haloMaskLayer.fillRule = .evenOdd
        haloMaskLayer.fillColor = NSColor.white.cgColor

        let diskDiameter = max(bounds.width, bounds.height) * 1.25
        colorDiskLayer.bounds = CGRect(x: 0, y: 0, width: diskDiameter, height: diskDiameter)
        colorDiskLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        colorDiskLayer.cornerRadius = diskDiameter / 2

        cardLayer.frame = cardBounds
        cardLayer.cornerRadius = 16
        cardLayer.shadowPath = cardPath

        layer.shadowPath = nil
    }
}
