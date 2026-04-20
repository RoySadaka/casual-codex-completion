import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

final class ScreenCaptureService {
    func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestPermission(prompt: Bool) -> Bool {
        if hasPermission() {
            return true
        }

        guard prompt else {
            return false
        }

        return CGRequestScreenCaptureAccess()
    }

    func captureFocusedWindowOrDisplay() -> URL? {
        guard CGPreflightScreenCaptureAccess() else {
            AppLogger.error("Screen capture skipped because Screen Recording permission is missing")
            return nil
        }

        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            AppLogger.error("Screen capture skipped because there is no frontmost application")
            return nil
        }

        let windows = windowInfoList()
        guard !windows.isEmpty else {
            AppLogger.error("Screen capture skipped because no onscreen window metadata was found")
            return nil
        }

        if let window = bestWindow(for: frontmostApp.processIdentifier, windows: windows),
           let image = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                window.id,
                [.bestResolution, .boundsIgnoreFraming]
           ),
           let url = persist(image: image) {
            AppLogger.info(
                "Captured screenshot of focused window. App=\(frontmostApp.localizedName ?? "unknown") pid=\(frontmostApp.processIdentifier) WindowID=\(window.id) Path=\(url.path)"
            )
            return url
        }

        if let window = bestWindow(for: frontmostApp.processIdentifier, windows: windows) {
            let displayID = displayID(containing: window.bounds) ?? CGMainDisplayID()
            if let image = CGDisplayCreateImage(displayID),
               let url = persist(image: image) {
                AppLogger.info(
                    "Captured screenshot of containing display. App=\(frontmostApp.localizedName ?? "unknown") pid=\(frontmostApp.processIdentifier) DisplayID=\(displayID) Path=\(url.path)"
                )
                return url
            }
        }

        let mainDisplayID = CGMainDisplayID()
        guard let image = CGDisplayCreateImage(mainDisplayID),
              let url = persist(image: image)
        else {
            AppLogger.error("Screen capture failed for both focused window and fallback display")
            return nil
        }

        AppLogger.info("Captured screenshot of main display fallback. DisplayID=\(mainDisplayID) Path=\(url.path)")
        return url
    }

    private func windowInfoList() -> [WindowInfo] {
        guard let rawList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return rawList.compactMap { item in
            guard let id = item[kCGWindowNumber as String] as? UInt32,
                  let ownerPID = item[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = item[kCGWindowLayer as String] as? Int,
                  let isOnscreen = item[kCGWindowIsOnscreen as String] as? Bool,
                  isOnscreen,
                  layer == 0,
                  let boundsDictionary = item[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width > 1,
                  bounds.height > 1
            else {
                return nil
            }

            let alpha = item[kCGWindowAlpha as String] as? Double ?? 1.0
            guard alpha > 0.01 else {
                return nil
            }

            return WindowInfo(
                id: CGWindowID(id),
                ownerPID: ownerPID,
                bounds: bounds,
                ownerName: item[kCGWindowOwnerName as String] as? String ?? "unknown",
                title: item[kCGWindowName as String] as? String
            )
        }
    }

    private func bestWindow(for pid: pid_t, windows: [WindowInfo]) -> WindowInfo? {
        windows.first { $0.ownerPID == pid }
    }

    private func displayID(containing rect: CGRect) -> CGDirectDisplayID? {
        var displayCount: UInt32 = 0
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 8)
        let result = CGGetDisplaysWithRect(rect, UInt32(displayIDs.count), &displayIDs, &displayCount)
        guard result == .success, displayCount > 0 else {
            return nil
        }

        return displayIDs[Int(0)]
    }

    private func persist(image: CGImage) -> URL? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            AppLogger.error("Failed to encode screenshot as PNG")
            return nil
        }

        let screenshotsDirectory = FileManager.default.temporaryDirectory
        let url = screenshotsDirectory
            .appendingPathComponent("ccc-screenshot-\(UUID().uuidString)")
            .appendingPathExtension("png")

        do {
            try pngData.write(to: url, options: .atomic)
            if CCCConfig.requiredBoolValue(forKey: "dev_mode") {
                persistDesktopCopy(pngData: pngData)
            }
            return url
        } catch {
            AppLogger.error("Failed to write screenshot file: \(error.localizedDescription)")
            return nil
        }
    }

    private func persistDesktopCopy(pngData: Data) {
        let desktopDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
        let timestamp = desktopTimestamp()
        let desktopURL = desktopDirectory
            .appendingPathComponent("ccc-screenshot-\(timestamp)-\(UUID().uuidString.prefix(6))")
            .appendingPathExtension("png")

        do {
            try pngData.write(to: desktopURL, options: .atomic)
            AppLogger.info("Saved dev-mode desktop screenshot copy at \(desktopURL.path)")
        } catch {
            AppLogger.error("Failed to save dev-mode desktop screenshot copy: \(error.localizedDescription)")
        }
    }

    private func desktopTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    static func deleteScreenshot(at url: URL, reason: String) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        do {
            try FileManager.default.removeItem(at: url)
            AppLogger.info("Deleted screenshot file. Path=\(url.path) Reason=\(reason)")
        } catch {
            AppLogger.error("Failed to delete screenshot file at \(url.path): \(error.localizedDescription)")
        }
    }
}

private struct WindowInfo {
    let id: CGWindowID
    let ownerPID: pid_t
    let bounds: CGRect
    let ownerName: String
    let title: String?
}
