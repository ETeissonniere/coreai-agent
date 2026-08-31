import Foundation

enum ApplicationSupportLocation {
    static let currentDirectoryName = "CoreAI Agent"
    static let legacyDirectoryName = "Qwen Core AI"

    static func resolve(
        in applicationSupportDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let current = applicationSupportDirectory.appending(
            path: currentDirectoryName,
            directoryHint: .isDirectory
        )
        let legacy = applicationSupportDirectory.appending(
            path: legacyDirectoryName,
            directoryHint: .isDirectory
        )
        if fileManager.fileExists(atPath: current.path) {
            migrateMissingData(from: legacy, to: current, fileManager: fileManager)
            return current
        }
        guard fileManager.fileExists(atPath: legacy.path) else { return current }

        do {
            try fileManager.moveItem(at: legacy, to: current)
            return current
        } catch {
            do {
                try fileManager.copyItem(at: legacy, to: current)
                return current
            } catch {
                // Keep the existing data usable when directory migration is
                // blocked by permissions. A partial copy is not treated as canonical.
                try? fileManager.removeItem(at: current)
                return legacy
            }
        }
    }

    private static func migrateMissingData(
        from legacy: URL,
        to current: URL,
        fileManager: FileManager
    ) {
        guard fileManager.fileExists(atPath: legacy.path) else { return }
        for name in ["AppState.json", "AgentHarness"] {
            let source = legacy.appending(path: name)
            let destination = current.appending(path: name)
            guard fileManager.fileExists(atPath: source.path),
                  !fileManager.fileExists(atPath: destination.path) else { continue }
            try? fileManager.moveItem(at: source, to: destination)
        }
    }
}
