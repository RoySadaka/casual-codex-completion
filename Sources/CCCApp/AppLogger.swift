import Foundation

enum AppLogger {
    private static let queue = DispatchQueue(label: "ccc.logger")
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let logFileURL = CCCPaths.logFileURL

    static func info(_ message: String) {
        write(level: "INFO", message: message)
    }

    static func error(_ message: String) {
        write(level: "ERROR", message: message)
    }

    private static func write(level: String, message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)"

        queue.async {
            fputs("\(line)\n", stderr)
            appendToFile(line + "\n")
        }
    }

    private static func appendToFile(_ line: String) {
        let directory = logFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: logFileURL) else {
            return
        }

        defer {
            try? handle.close()
        }

        do {
            try handle.seekToEnd()
            if let data = line.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        } catch {
            fputs("ccc logger failed to write: \(error)\n", stderr)
        }
    }
}
