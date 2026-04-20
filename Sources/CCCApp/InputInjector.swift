import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

final class InputInjector {
    func insertUsingPasteboard(_ text: String, targetPID: pid_t) -> Bool {
        guard !text.isEmpty else {
            AppLogger.error("Paste fallback failed because text was empty")
            return false
        }

        let targetApplication = NSRunningApplication(processIdentifier: targetPID) ?? NSWorkspace.shared.frontmostApplication
        AppLogger.info(
            "Paste fallback targeting app: \(targetApplication?.localizedName ?? "unknown") pid=\(targetApplication?.processIdentifier ?? 0)"
        )

        let previousContents = capturePasteboardContents()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            AppLogger.error("Paste fallback failed because clipboard write was rejected")
            restorePasteboardContents(previousContents)
            return false
        }

        waitForTriggerModifiersToRelease()
        usleep(100_000)

        NSApp.deactivate()
        targetApplication?.activate(options: [.activateIgnoringOtherApps])
        usleep(120_000)

        let didPaste = pasteWithAppleScript() || pasteWithCGEvents()
        AppLogger.info("Paste fallback result: \(didPaste)")

        usleep(220_000)
        restorePasteboardContents(previousContents)
        return didPaste
    }

    func capturePrefixUntilCursor(targetPID: pid_t) -> String? {
        let targetApplication = NSRunningApplication(processIdentifier: targetPID) ?? NSWorkspace.shared.frontmostApplication
        AppLogger.info(
            "Live field probe targeting app: \(targetApplication?.localizedName ?? "unknown") pid=\(targetApplication?.processIdentifier ?? 0)"
        )

        let previousContents = capturePasteboardContents()
        let pasteboard = NSPasteboard.general
        let sentinel = "__CC_PROBE_SENTINEL__\(UUID().uuidString)__"

        pasteboard.clearContents()
        guard pasteboard.setString(sentinel, forType: .string) else {
            AppLogger.error("Live field probe failed to seed clipboard sentinel")
            restorePasteboardContents(previousContents)
            return nil
        }
        let sentinelChangeCount = pasteboard.changeCount

        waitForTriggerModifiersToRelease()
        usleep(100_000)

        NSApp.deactivate()
        targetApplication?.activate(options: [.activateIgnoringOtherApps])
        usleep(120_000)

        guard sendModifiedShortcut(keyCode: CGKeyCode(kVK_UpArrow), flags: [.maskCommand, .maskShift]) else {
            AppLogger.error("Live field probe failed to post Shift-Command-Up")
            restorePasteboardContents(previousContents)
            return nil
        }
        usleep(90_000)

        guard sendModifiedShortcut(keyCode: CGKeyCode(kVK_ANSI_C), flags: .maskCommand) else {
            AppLogger.error("Live field probe failed to post Cmd-C")
            restorePasteboardContents(previousContents)
            return nil
        }
        let capturedText = waitForProbeClipboardText(
            afterChangeCount: sentinelChangeCount,
            rejectingSentinel: sentinel
        )

        if !sendPlainKey(keyCode: CGKeyCode(kVK_RightArrow)) {
            AppLogger.error("Live field probe failed to collapse selection")
        }
        usleep(60_000)

        restorePasteboardContents(previousContents)
        if capturedText == nil {
            AppLogger.error("Live field probe rejected clipboard contents because copy did not produce fresh text")
        }
        AppLogger.info("Live field probe captured length=\(((capturedText ?? "") as NSString).length)")
        return capturedText
    }

    private func capturePasteboardContents() -> [[NSPasteboard.PasteboardType: Data]] {
        let pasteboard = NSPasteboard.general
        return pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { result, type in
                if let data = item.data(forType: type) {
                    result[type] = data
                }
            }
        } ?? []
    }

    private func restorePasteboardContents(_ items: [[NSPasteboard.PasteboardType: Data]]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        guard !items.isEmpty else {
            return
        }

        for itemData in items {
            let item = NSPasteboardItem()
            for (type, data) in itemData {
                item.setData(data, forType: type)
            }
            pasteboard.writeObjects([item])
        }
    }

    private func waitForTriggerModifiersToRelease() {
        for _ in 0 ..< 12 {
            let leftControlDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Control))
            let rightControlDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_RightControl))
            let commandDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Command))
            let rightCommandDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_RightCommand))

            guard leftControlDown || rightControlDown || commandDown || rightCommandDown else {
                return
            }

            usleep(25_000)
        }
    }

    private func pasteWithAppleScript() -> Bool {
        let source = """
        tell application id "com.apple.systemevents"
            keystroke "v" using command down
        end tell
        """

        guard let script = NSAppleScript(source: source) else {
            return false
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            AppLogger.error("AppleScript paste failed: \(error)")
        } else {
            AppLogger.info("AppleScript paste succeeded")
        }

        return error == nil
    }

    private func pasteWithCGEvents() -> Bool {
        guard sendModifiedShortcut(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand) else {
            return false
        }
        AppLogger.info("CGEvent paste posted")
        return true
    }

    private func sendModifiedShortcut(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
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

    private func sendPlainKey(keyCode: CGKeyCode) -> Bool {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else {
            return false
        }

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func waitForProbeClipboardText(afterChangeCount baseline: Int, rejectingSentinel sentinel: String) -> String? {
        let pasteboard = NSPasteboard.general

        for _ in 0 ..< 40 {
            usleep(25_000)

            guard pasteboard.changeCount > baseline else {
                continue
            }

            guard let candidate = pasteboard.string(forType: .string) else {
                continue
            }

            guard candidate != sentinel else {
                continue
            }

            return candidate.nonEmpty
        }

        return nil
    }
}
