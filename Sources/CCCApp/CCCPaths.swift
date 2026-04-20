import Foundation

enum CCCPaths {
    private static let appDirectoryName = "CCC"

    static var appSupportDirectoryURL: URL {
        if let override = ProcessInfo.processInfo.environment["CCC_APP_SUPPORT_DIR"]?.nonEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        if let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return directory.appendingPathComponent(appDirectoryName, isDirectory: true)
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(appDirectoryName, isDirectory: true)
    }

    static var logsDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(appDirectoryName, isDirectory: true)
    }

    static var logFileURL: URL {
        logsDirectoryURL.appendingPathComponent("ccc.log")
    }

    static var configFileURL: URL {
        if let explicitPath = ProcessInfo.processInfo.environment["CCC_CONFIG_FILE"]?.nonEmpty {
            return URL(fileURLWithPath: explicitPath)
        }

        return appSupportDirectoryURL.appendingPathComponent("config.toml")
    }

    static var persistedSessionURL: URL {
        appSupportDirectoryURL.appendingPathComponent("session_id.txt")
    }

    static func promptTemplateURL(named fileName: String) -> URL? {
        promptTemplateSearchPaths(fileName: fileName).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func promptTemplateSearchPaths(fileName: String) -> [URL] {
        promptDirectories().map { $0.appendingPathComponent(fileName) }
    }

    static func ensureParentDirectoryExists(for fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private static func promptDirectories() -> [URL] {
        let fileManager = FileManager.default
        let currentDirectoryURL = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let executableDirectoryURL = URL(fileURLWithPath: CommandLine.arguments.first ?? "", isDirectory: false)
            .deletingLastPathComponent()
        let projectRootURL = ProcessInfo.processInfo.environment["CCC_PROJECT_ROOT"]?.nonEmpty.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        let resourceRootOverrideURL = ProcessInfo.processInfo.environment["CCC_RESOURCE_ROOT"]?.nonEmpty.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }

        let candidateDirectories = [
            Bundle.main.resourceURL?.appendingPathComponent("Prompts", isDirectory: true),
            resourceRootOverrideURL?.appendingPathComponent("Prompts", isDirectory: true),
            projectRootURL?.appendingPathComponent("Resources/Prompts", isDirectory: true),
            currentDirectoryURL.appendingPathComponent("Resources/Prompts", isDirectory: true),
            executableDirectoryURL.appendingPathComponent("Resources/Prompts", isDirectory: true),
            executableDirectoryURL
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/Prompts", isDirectory: true)
        ].compactMap { $0 }

        var seen = Set<String>()
        return candidateDirectories.filter { directory in
            seen.insert(directory.path).inserted
        }
    }
}
