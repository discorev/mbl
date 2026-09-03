import Foundation

struct CodexBinary: Sendable {
    let url: URL
    let source: String

    static func resolve(fileManager: FileManager = .default) -> CodexBinary? {
        let fixedPath = "/Users/ollie/Library/pnpm/bin/codex"
        if fileManager.isExecutableFile(atPath: fixedPath) {
            return CodexBinary(
                url: URL(fileURLWithPath: fixedPath),
                source: "configured pnpm path"
            )
        }

        if let path = resolveWithEnv(), fileManager.isExecutableFile(atPath: path) {
            return CodexBinary(
                url: URL(fileURLWithPath: path),
                source: "/usr/bin/env which codex"
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
        return CodexBinary(
            url: URL(fileURLWithPath: path),
            source: "common install location"
        )
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
