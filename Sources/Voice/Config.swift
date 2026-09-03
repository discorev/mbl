import Foundation

struct Config: Codable, Sendable {
    let hotkey: String
    let backend: String
    let codexModel: String
    let codexThreadMaxTurns: Int
    let claudeModel: String
    let fallback: Bool
    let minWordsForCleanup: Int
    let cleanupTimeoutSeconds: Int
    let previewTickMs: Int
    let hudBottomInset: Int

    static let fallbackValue = Config(
        hotkey: "rightOption",
        backend: "codex",
        codexModel: "gpt-5.6-luna",
        codexThreadMaxTurns: 50,
        claudeModel: "sonnet",
        fallback: false,
        minWordsForCleanup: 4,
        cleanupTimeoutSeconds: 8,
        previewTickMs: 500,
        hudBottomInset: 80
    )

    static var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/voice", isDirectory: true)
    }

    static func load(fileManager: FileManager = .default) throws -> Config {
        let directory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/voice", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let configURL = directory.appendingPathComponent("config.json")
        let promptURL = directory.appendingPathComponent("prompt.md")
        let vocabularyURL = directory.appendingPathComponent("vocab.txt")

        try writeIfMissing(defaultConfigJSON, to: configURL, fileManager: fileManager)
        try writeIfMissing(defaultPrompt, to: promptURL, fileManager: fileManager)
        try writeIfMissing("", to: vocabularyURL, fileManager: fileManager)

        let data = try Data(contentsOf: configURL)
        return try JSONDecoder().decode(Config.self, from: data)
    }

    private static func writeIfMissing(
        _ contents: String,
        to url: URL,
        fileManager: FileManager
    ) throws {
        guard !fileManager.fileExists(atPath: url.path) else {
            return
        }
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

    private static let defaultConfigJSON = """
    {
      "hotkey": "rightOption",
      "backend": "codex",
      "codexModel": "gpt-5.6-luna",
      "codexThreadMaxTurns": 50,
      "claudeModel": "sonnet",
      "fallback": false,
      "minWordsForCleanup": 4,
      "cleanupTimeoutSeconds": 8,
      "previewTickMs": 500,
      "hudBottomInset": 80
    }

    """

    private static let defaultPrompt = """
    You are a dictation cleaner. Clean the user's raw dictated speech for insertion at the cursor.

    Remove filler words, false starts, repeated words, and self-corrections. When the speaker corrects something, keep only the last version. Keep the speaker's wording, meaning, and tone. Fix punctuation and casing. Do not expand, answer, summarize, explain, or add anything. Output only the cleaned text.

    """
}
