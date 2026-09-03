import Foundation

struct CodexBinary: Sendable {
    let url: URL
    let source: String
    let environment: [String: String]

    static func resolve(fileManager: FileManager = .default) -> CodexBinary? {
        let fixedPath = "/Users/ollie/Library/pnpm/bin/codex"
        if fileManager.isExecutableFile(atPath: fixedPath) {
            return make(
                path: fixedPath,
                source: "configured pnpm path",
                fileManager: fileManager
            )
        }

        if let path = resolveWithEnv(), fileManager.isExecutableFile(atPath: path) {
            return make(
                path: path,
                source: "/usr/bin/env which codex",
                fileManager: fileManager
            )
        }

        let home = fileManager.homeDirectoryForCurrentUser.path
        let commonPaths = [
            "\(home)/Library/pnpm/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.bun/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        guard let path = commonPaths.first(where: fileManager.isExecutableFile) else {
            return nil
        }
        return make(
            path: path,
            source: "common install location",
            fileManager: fileManager
        )
    }

    private static func make(
        path: String,
        source: String,
        fileManager: FileManager
    ) -> CodexBinary {
        let url = URL(fileURLWithPath: path)
        return CodexBinary(
            url: url,
            source: source,
            environment: processEnvironment(
                codexURL: url,
                fileManager: fileManager
            )
        )
    }

    private static func processEnvironment(
        codexURL: URL,
        fileManager: FileManager
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = fileManager.homeDirectoryForCurrentUser
        var searchDirectories = [
            codexURL.deletingLastPathComponent().path,
            home.appendingPathComponent(".volta/bin").path,
            home.appendingPathComponent(".local/bin").path,
            home.appendingPathComponent(".bun/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]

        let nvmVersions = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? fileManager.contentsOfDirectory(
            at: nvmVersions,
            includingPropertiesForKeys: nil
        ) {
            searchDirectories.insert(
                contentsOf: versions
                    .map { $0.appendingPathComponent("bin").path }
                    .sorted(by: >),
                at: 1
            )
        }

        let existing = environment["PATH"]?.split(separator: ":").map(String.init)
            ?? []
        searchDirectories.append(contentsOf: existing)
        var seen: Set<String> = []
        environment["PATH"] = searchDirectories
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
        return environment
    }

    private static func resolveWithEnv() -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "codex"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let value = String(data: data, encoding: .utf8) else { return nil }
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
