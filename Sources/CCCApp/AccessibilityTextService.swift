import AppKit
import ApplicationServices
import Foundation

enum ContextSource {
    case accessibility
    case liveFieldProbe
}

struct FocusedTextContext {
    let source: ContextSource
    let element: AXUIElement?
    let appPID: pid_t
    let appName: String
    let screenshotURL: URL?
    let fullText: String
    let selectedRange: CFRange
    let prefix: String
    let selectedText: String
    let caretRect: CGRect
}

final class AccessibilityTextService {
    func hasAccessibilityPermission() -> Bool {
        requestAccessibilityPermission(prompt: false)
    }

    func requestAccessibilityPermission(prompt: Bool) -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
        ] as CFDictionary
        let granted = AXIsProcessTrustedWithOptions(options)
        AppLogger.info("AX permission check. Prompt=\(prompt) Granted=\(granted)")
        return granted
    }

    func focusedTextContext() -> FocusedTextContext? {
        guard let focusedElement = resolveFocusedElement() else {
            AppLogger.error("Unable to resolve a focused UI element")
            return nil
        }
        var appPID: pid_t = 0
        AXUIElementGetPid(focusedElement, &appPID)
        let appName = NSRunningApplication(processIdentifier: appPID)?.localizedName ?? "unknown"
        AppLogger.info(
            "Focused element app: \(appName) pid=\(appPID) role=\(stringAttribute(kAXRoleAttribute, on: focusedElement) ?? "unknown")"
        )

        guard let fullText = copyAttribute(kAXValueAttribute, on: focusedElement) as? String,
              let selectedRange = selectedRange(on: focusedElement)
        else {
            AppLogger.error("Focused element does not expose text value or selected range")
            return nil
        }

        let insertionLocation = selectedRange.location + selectedRange.length
        let prefix = substring(in: fullText, utf16Range: CFRange(location: 0, length: insertionLocation))
        let selectedText = substring(in: fullText, utf16Range: selectedRange)

        let caretRange = CFRange(location: insertionLocation, length: 0)
        let caretRect = bounds(for: caretRange, on: focusedElement) ?? fallbackRect()

        return FocusedTextContext(
            source: .accessibility,
            element: focusedElement,
            appPID: appPID,
            appName: appName,
            screenshotURL: nil,
            fullText: fullText,
            selectedRange: selectedRange,
            prefix: prefix,
            selectedText: selectedText,
            caretRect: caretRect
        )
    }

    func liveFieldProbeContext(
        for prefix: String,
        targetPID: pid_t,
        targetAppName: String,
        screenshotURL: URL?
    ) -> FocusedTextContext {
        let caretRect: CGRect
        if let focusedContext = focusedTextContext(), focusedContext.appPID == targetPID {
            caretRect = focusedContext.caretRect
        } else {
            caretRect = fallbackRect()
        }

        return makeSyntheticContext(
            source: .liveFieldProbe,
            appPID: targetPID,
            appName: targetAppName,
            prefix: prefix,
            caretRect: caretRect,
            screenshotURL: screenshotURL
        )
    }

    func frontmostApplicationInfo() -> (pid: pid_t, name: String)? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        return (pid: app.processIdentifier, name: app.localizedName ?? "unknown")
    }

    private func resolveFocusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()

        if let element = axElementAttribute(kAXFocusedUIElementAttribute, on: system) {
            AppLogger.info("Focused element resolved via system-wide AX lookup")
            return element
        }

        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            AppLogger.error("No frontmost application available for AX fallback")
            return nil
        }

        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        AppLogger.info("Trying AX fallback through frontmost app: \(frontmostApp.localizedName ?? "unknown") pid=\(frontmostApp.processIdentifier)")

        if let element = axElementAttribute(kAXFocusedUIElementAttribute, on: appElement) {
            AppLogger.info("Focused element resolved via frontmost app AX lookup")
            return element
        }

        if let focusedWindow = axElementAttribute(kAXFocusedWindowAttribute, on: appElement),
           let element = axElementAttribute(kAXFocusedUIElementAttribute, on: focusedWindow) {
            AppLogger.info("Focused element resolved via focused window AX lookup")
            return element
        }

        AppLogger.error("Focused element fallback through frontmost app failed")
        return nil
    }

    func insertCompletion(_ completion: String, into context: FocusedTextContext) -> Bool {
        guard let element = context.element else {
            AppLogger.error("AX insertion skipped because no AX element is available for this context")
            return false
        }

        let fullText = context.fullText as NSString
        let range = NSRange(location: context.selectedRange.location, length: context.selectedRange.length)
        let newText = fullText.replacingCharacters(in: range, with: completion)

        let setValueResult = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            newText as CFTypeRef
        )

        guard setValueResult == .success else {
            AppLogger.error("Failed to set AX value. Result=\(setValueResult.rawValue)")
            return false
        }

        var newSelection = CFRange(
            location: context.selectedRange.location + (completion as NSString).length,
            length: 0
        )

        guard let selectionValue = AXValueCreate(.cfRange, &newSelection) else {
            return false
        }

        let setSelectionResult = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            selectionValue
        )

        if setSelectionResult != .success {
            AppLogger.error("Failed to set AX selected text range. Result=\(setSelectionResult.rawValue)")
        }

        return setSelectionResult == .success
    }

    private func selectedRange(on element: AXUIElement) -> CFRange? {
        guard let rawValue = copyAttribute(kAXSelectedTextRangeAttribute, on: element),
              CFGetTypeID(rawValue) == AXValueGetTypeID()
        else {
            AppLogger.error("Focused element does not expose kAXSelectedTextRangeAttribute")
            return nil
        }

        let value = unsafeBitCast(rawValue, to: AXValue.self)
        guard AXValueGetType(value) == .cfRange else {
            return nil
        }

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(value, .cfRange, &range) else {
            AppLogger.error("Failed to decode selected range AXValue")
            return nil
        }

        return range
    }

    private func bounds(for range: CFRange, on element: AXUIElement) -> CGRect? {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else {
            AppLogger.error("Failed to create AXValue for caret range")
            return nil
        }

        var value: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &value
        )

        guard result == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXValueGetTypeID()
        else {
            AppLogger.info("Caret bounds unavailable. Result=\(result.rawValue)")
            return nil
        }

        let axValue = unsafeBitCast(rawValue, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgRect else {
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else {
            AppLogger.error("Failed to decode caret bounds AXValue")
            return nil
        }

        return rect
    }

    private func fallbackRect() -> CGRect {
        let mouse = NSEvent.mouseLocation
        return CGRect(x: mouse.x, y: mouse.y, width: 1, height: 20)
    }

    private func makeSyntheticContext(
        source: ContextSource,
        appPID: pid_t,
        appName: String,
        prefix: String,
        caretRect: CGRect,
        screenshotURL: URL?
    ) -> FocusedTextContext {
        let nsPrefix = prefix as NSString
        return FocusedTextContext(
            source: source,
            element: nil,
            appPID: appPID,
            appName: appName,
            screenshotURL: screenshotURL,
            fullText: prefix,
            selectedRange: CFRange(location: nsPrefix.length, length: 0),
            prefix: prefix,
            selectedText: "",
            caretRect: caretRect
        )
    }

    private func copyAttribute(_ attribute: String, on element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else {
            AppLogger.info("AX attribute lookup failed. Attribute=\(attribute) Result=\(result.rawValue)")
            return nil
        }

        return value
    }

    private func axElementAttribute(_ attribute: String, on element: AXUIElement) -> AXUIElement? {
        guard let rawValue = copyAttribute(attribute, on: element),
              CFGetTypeID(rawValue) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return unsafeBitCast(rawValue, to: AXUIElement.self)
    }

    private func stringAttribute(_ attribute: String, on element: AXUIElement) -> String? {
        copyAttribute(attribute, on: element) as? String
    }

    private func substring(in text: String, utf16Range: CFRange) -> String {
        let nsRange = NSRange(
            location: max(0, min((text as NSString).length, utf16Range.location)),
            length: max(0, min((text as NSString).length - utf16Range.location, utf16Range.length))
        )

        return (text as NSString).substring(with: nsRange)
    }
}
