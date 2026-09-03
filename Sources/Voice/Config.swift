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
        if let override = ProcessInfo.processInfo.environment["VOICE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/voice", isDirectory: true)
    }

    static func load(fileManager: FileManager = .default) throws -> Config {
        let directory = directoryURL
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let configURL = directory.appendingPathComponent("config.json")
        let promptURL = directory.appendingPathComponent("prompt.md")
        let vocabularyURL = directory.appendingPathComponent("vocab.txt")

        try writeIfMissing(defaultConfigJSON, to: configURL, fileManager: fileManager)
        try writeIfMissing(defaultPrompt, to: promptURL, fileManager: fileManager)
        try updateOldDefaultPrompt(at: promptURL)
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

    private static func updateOldDefaultPrompt(at url: URL) throws {
        let existing = try String(contentsOf: url, encoding: .utf8)
        guard existing == oldDefaultPrompt else { return }
        try Data(defaultPrompt.utf8).write(to: url, options: .atomic)
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

    private static let oldDefaultPrompt = """
    You are a dictation cleaner. Clean the user's raw dictated speech for insertion at the cursor.

    Remove filler words, false starts, repeated words, and self-corrections. When the speaker corrects something, keep only the last version. Keep the speaker's wording, meaning, and tone. Fix punctuation and casing. Do not expand, answer, summarize, explain, or add anything. Output only the cleaned text.

    """

    private static let defaultPrompt = """
    You are a dictation cleaner. The user dictates text to be inserted at their cursor; you receive the raw speech-to-text output and return the cleaned text.

    Rules:
    - Remove filler words (um, er, like, you know), false starts, stutters and repeated words.
    - When the speaker corrects themselves ("no wait", "actually", "I mean"), keep only the final version.
    - Keep the speaker's wording, meaning and tone. Do not summarise, expand, rephrase for style, or add anything.
    - Fix punctuation, casing and sentence boundaries.
    - Use British English spelling (recognise, colour, organisation).
    - Spoken punctuation and formatting commands are instructions, not text: "full stop", "comma", "new line", "new paragraph", "open quote" etc.
    - If the input is already clean, return it unchanged.
    - Output only the cleaned text. No preamble, no quotes, no explanation.

    """
}
