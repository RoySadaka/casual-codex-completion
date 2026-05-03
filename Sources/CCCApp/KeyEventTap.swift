import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

enum KeyboardAction {
    case requestCompletion
    case requestCompletionWithCapturedContext(CompletionCapture)
    case acceptSuggestion
    case retrySuggestion
    case dismissSuggestion
    case keyPress(KeyPress)
}

struct CompletionCapture {
    let prefix: String
    let screenshotURL: URL?
}

struct KeyPress {
    let keyCode: Int64
    let flags: CGEventFlags
    let characters: String
}

final class KeyEventTap {
    private let tripleCThreshold: TimeInterval = 1.0
    private let triggerEraseDelay: TimeInterval = 0.03
    private let triggerSelectDelay: TimeInterval = 0.08
    private let triggerCopyDelay: TimeInterval = 0.18
    private let triggerCollapseDelay: TimeInterval = 0.03
    private let triggerSubmitDelay: TimeInterval = 0.04
    private let postCopyTimeoutMicros: useconds_t = 1_000_000
    private let postCopyPollIntervalMicros: useconds_t = 25_000
    private let handler: (KeyboardAction) -> Bool
    private let screenCaptureService = ScreenCaptureService()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var recentCTimestamps: [TimeInterval] = []
    private var tripleCTriggerEnabled = true
    private var screenshotContextEnabled = false

    init(handler: @escaping (KeyboardAction) -> Bool) {
        self.handler = handler
    }

    var isActive: Bool {
        eventTap != nil
    }

    func start() {
        guard eventTap == nil else { return }

        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard type == .keyDown, let refcon else {
                return Unmanaged.passUnretained(event)
            }

            let tap = Unmanaged<KeyEventTap>.fromOpaque(refcon).takeUnretainedValue()
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            let characters = tap.unicodeCharacters(for: event)

            if keyCode == 48 {
                let disallowedFlags: CGEventFlags = [
                    .maskCommand,
                    .maskControl,
                    .maskAlternate,
                    .maskSecondaryFn
                ]

                guard flags.intersection(disallowedFlags).isEmpty else {
                    let keyPress = KeyPress(keyCode: keyCode, flags: flags, characters: characters)
                    return tap.handler(.keyPress(keyPress)) ? nil : Unmanaged.passUnretained(event)
                }

                if flags.contains(.maskShift) {
                    AppLogger.info("Hotkey detected: Shift-Tab")
                    return tap.handler(.retrySuggestion) ? nil : Unmanaged.passUnretained(event)
                }

                AppLogger.info("Hotkey detected: Tab")
                return tap.handler(.acceptSuggestion) ? nil : Unmanaged.passUnretained(event)
            }

            if keyCode == 53 {
                AppLogger.info("Hotkey detected: Escape")
                return tap.handler(.dismissSuggestion) ? nil : Unmanaged.passUnretained(event)
            }

            if tap.shouldTreatAsTripleCTriggerCandidate(keyCode: keyCode, flags: flags, characters: characters) {
                guard tap.tripleCTriggerEnabled else {
                    tap.recentCTimestamps.removeAll()
                    let keyPress = KeyPress(keyCode: keyCode, flags: flags, characters: characters)
                    return tap.handler(.keyPress(keyPress)) ? nil : Unmanaged.passUnretained(event)
                }

                if tap.registerPassiveTripleCTrigger() {
                    AppLogger.info("Hotkey detected: triple-c")
                    tap.captureTripleCTrigger()
                }
            }

            let keyPress = KeyPress(keyCode: keyCode, flags: flags, characters: characters)
            return tap.handler(.keyPress(keyPress)) ? nil : Unmanaged.passUnretained(event)
        }

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: refcon
        ) else {
            AppLogger.error("Failed to create CGEvent tap. Input Monitoring may be missing")
            return
        }

        self.eventTap = eventTap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        self.runLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        AppLogger.info("CGEvent tap started successfully")
    }

    func setTripleCTriggerEnabled(_ enabled: Bool) {
        guard tripleCTriggerEnabled != enabled else {
            return
        }

        tripleCTriggerEnabled = enabled
        recentCTimestamps.removeAll()
    }

    func setScreenshotContextEnabled(_ enabled: Bool, promptForPermission: Bool = false) {
        screenshotContextEnabled = enabled
        if enabled && promptForPermission {
            let granted = screenCaptureService.requestPermission(prompt: true)
            AppLogger.info("Screen capture permission requested. Granted=\(granted)")
        }
    }

    private func shouldTreatAsTripleCTriggerCandidate(keyCode: Int64, flags: CGEventFlags, characters: String) -> Bool {
        if keyCode != Int64(kVK_ANSI_C) {
            return false
        }

        let disallowedFlags: CGEventFlags = [
            .maskCommand,
            .maskControl,
            .maskAlternate,
            .maskShift,
            .maskSecondaryFn
        ]

        if !flags.intersection(disallowedFlags).isEmpty {
            return false
        }

        return characters.lowercased() == "c"
    }

    private func registerPassiveTripleCTrigger() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        recentCTimestamps.append(now)
        recentCTimestamps = recentCTimestamps.filter { now - $0 <= tripleCThreshold }

        guard recentCTimestamps.count >= 3 else {
            return false
        }

        recentCTimestamps.removeAll()
        return true
    }

    private func captureTripleCTrigger() {
        let screenshotGroup = DispatchGroup()
        var capturedScreenshotURL: URL?

        if screenshotContextEnabled {
            screenshotGroup.enter()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + triggerEraseDelay + 0.02) { [weak self] in
                defer { screenshotGroup.leave() }
                guard let self else { return }
                capturedScreenshotURL = self.screenCaptureService.captureFocusedWindowOrDisplay()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + triggerSelectDelay) { [weak self] in
            guard let self else { return }
            _ = self.postModifiedShortcut(
                keyCode: CGKeyCode(kVK_UpArrow),
                flags: [.maskCommand, .maskShift]
            )
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + triggerCopyDelay) { [weak self] in
            guard let self else { return }
            let pasteboard = NSPasteboard.general
            let baselineChangeCount = pasteboard.changeCount
            _ = self.postModifiedShortcut(
                keyCode: CGKeyCode(kVK_ANSI_C),
                flags: .maskCommand
            )

            DispatchQueue.global(qos: .userInitiated).async {
                let clipboardText = self.waitForFreshClipboardText(afterChangeCount: baselineChangeCount) ?? ""
                AppLogger.info("Clipboard after ccc copy: <<<\(clipboardText.logEscaped)>>>")
                let trimmedClipboardText = self.trimTriggerSuffix(from: clipboardText)
                DispatchQueue.main.async {
                    _ = self.postPlainKey(keyCode: CGKeyCode(kVK_RightArrow))
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.triggerCollapseDelay) { [weak self] in
                        guard let self else { return }
                        self.postBackspace(count: 3)

                        DispatchQueue.main.asyncAfter(deadline: .now() + self.triggerSubmitDelay) {
                            screenshotGroup.notify(queue: .main) {
                                let handled = self.handler(
                                    .requestCompletionWithCapturedContext(
                                        CompletionCapture(prefix: trimmedClipboardText, screenshotURL: capturedScreenshotURL)
                                    )
                                )
                                if !handled, let capturedScreenshotURL {
                                    ScreenCaptureService.deleteScreenshot(at: capturedScreenshotURL, reason: "request-not-handled")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func postBackspace(count: Int) {
        guard count > 0 else { return }

        for _ in 0 ..< count {
            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Delete), keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Delete), keyDown: false)
            else {
                return
            }

            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
    }

    private func postModifiedShortcut(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        let modifierKeyCodes: [CGKeyCode] = [
            flags.contains(.maskCommand) ? CGKeyCode(kVK_Command) : nil,
            flags.contains(.maskShift) ? CGKeyCode(kVK_Shift) : nil,
            flags.contains(.maskAlternate) ? CGKeyCode(kVK_Option) : nil,
            flags.contains(.maskControl) ? CGKeyCode(kVK_Control) : nil
        ].compactMap { $0 }

        let modifierDownEvents = modifierKeyCodes.compactMap { modifierKeyCode -> CGEvent? in
            let event = CGEvent(keyboardEventSource: nil, virtualKey: modifierKeyCode, keyDown: true)
            event?.flags = flags
            return event
        }

        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = flags
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = flags
        let modifierUpEvents = modifierKeyCodes.reversed().compactMap { modifierKeyCode -> CGEvent? in
            CGEvent(keyboardEventSource: nil, virtualKey: modifierKeyCode, keyDown: false)
        }

        guard modifierDownEvents.count == modifierKeyCodes.count,
              modifierUpEvents.count == modifierKeyCodes.count,
              let keyDown,
              let keyUp
        else {
            return false
        }

        for event in modifierDownEvents {
            event.post(tap: .cghidEventTap)
        }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        for event in modifierUpEvents {
            event.post(tap: .cghidEventTap)
        }
        return true
    }

    private func postPlainKey(keyCode: CGKeyCode) -> Bool {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else {
            return false
        }

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func unicodeCharacters(for event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0 else {
            return ""
        }

        return String(utf16CodeUnits: buffer, count: length)
    }

    private func trimTriggerSuffix(from text: String) -> String {
        guard text.hasSuffix("ccc") else {
            return text
        }

        return String(text.dropLast(3))
    }

    private func waitForFreshClipboardText(afterChangeCount baseline: Int) -> String? {
        let pasteboard = NSPasteboard.general
        let attempts = max(1, Int(postCopyTimeoutMicros / postCopyPollIntervalMicros))

        for _ in 0 ..< attempts {
            usleep(postCopyPollIntervalMicros)

            guard pasteboard.changeCount > baseline else {
                continue
            }

            if let text = pasteboard.string(forType: .string) {
                return text
            }
        }

        AppLogger.error("Timed out waiting for fresh clipboard text after ccc copy")
        return nil
    }
}

private extension String {
    var logEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
