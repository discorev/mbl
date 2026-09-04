import Foundation

enum CleanupBackend: String, Codable, Sendable {
    case codex
    case local
}

enum CleanupFallback: String, Codable, Sendable {
    case local
    case none
}

enum HotkeyKey: String, Codable, Sendable {
    case rightOption
    case rightControl
}

struct Config: Codable, Equatable, Sendable {
    var hotkey: HotkeyKey
    var backend: CleanupBackend
    var codexModel: String
    var codexThreadMaxTurns: Int
    var fallback: CleanupFallback
    var minWordsForCleanup: Int
    var cleanupTimeoutSeconds: Int
    var previewTickMs: Int
    var hudBottomInset: Int
    var minInputVolume: Float
    var autoDownloadUpdates: Bool

    static let fallbackValue = Config(
        hotkey: .rightOption,
        backend: .codex,
        codexModel: "gpt-5.6-luna",
        codexThreadMaxTurns: 50,
        fallback: .local,
        minWordsForCleanup: 4,
        cleanupTimeoutSeconds: 6,
        previewTickMs: 500,
        hudBottomInset: 80,
        minInputVolume: 0.5,
        autoDownloadUpdates: false
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

    @MainActor
    static func load(
        fileManager: FileManager = .default,
        directoryURL directory: URL = Config.directoryURL
    ) throws -> Config {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let configURL = directory.appendingPathComponent("config.json")
        let vocabularyURL = directory.appendingPathComponent("vocab.txt")

        try writeIfMissing(defaultConfigJSON, to: configURL, fileManager: fileManager)
        let data = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(Config.self, from: data)
        try Prompts.prepare(
            config: config,
            directoryURL: directory,
            fileManager: fileManager
        )
        try writeIfMissing("", to: vocabularyURL, fileManager: fileManager)
        return config
    }

    init(
        hotkey: HotkeyKey,
        backend: CleanupBackend,
        codexModel: String,
        codexThreadMaxTurns: Int,
        fallback: CleanupFallback,
        minWordsForCleanup: Int,
        cleanupTimeoutSeconds: Int,
        previewTickMs: Int,
        hudBottomInset: Int,
        minInputVolume: Float,
        autoDownloadUpdates: Bool = false
    ) {
        self.hotkey = hotkey
        self.backend = backend
        self.codexModel = codexModel
        self.codexThreadMaxTurns = codexThreadMaxTurns
        self.fallback = fallback
        self.minWordsForCleanup = minWordsForCleanup
        self.cleanupTimeoutSeconds = cleanupTimeoutSeconds
        self.previewTickMs = previewTickMs
        self.hudBottomInset = hudBottomInset
        self.minInputVolume = minInputVolume
        self.autoDownloadUpdates = autoDownloadUpdates
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hotkey = try container.decode(HotkeyKey.self, forKey: .hotkey)
        backend = try container.decode(CleanupBackend.self, forKey: .backend)
        codexModel = try container.decode(String.self, forKey: .codexModel)
        codexThreadMaxTurns = try container.decode(Int.self, forKey: .codexThreadMaxTurns)
        minWordsForCleanup = try container.decode(Int.self, forKey: .minWordsForCleanup)
        cleanupTimeoutSeconds = try container.decode(Int.self, forKey: .cleanupTimeoutSeconds)
        previewTickMs = try container.decode(Int.self, forKey: .previewTickMs)
        hudBottomInset = try container.decode(Int.self, forKey: .hudBottomInset)
        minInputVolume = try container.decodeIfPresent(
            Float.self,
            forKey: .minInputVolume
        ) ?? 0.5
        autoDownloadUpdates = try container.decodeIfPresent(
            Bool.self,
            forKey: .autoDownloadUpdates
        ) ?? false

        if let value = try? container.decode(CleanupFallback.self, forKey: .fallback) {
            fallback = value
        } else if let legacy = try? container.decode(Bool.self, forKey: .fallback) {
            fallback = legacy ? .local : .none
        } else {
            fallback = .local
        }
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
      "fallback": "local",
      "minWordsForCleanup": 4,
      "cleanupTimeoutSeconds": 6,
      "previewTickMs": 500,
      "hudBottomInset": 80,
      "minInputVolume": 0.5,
      "autoDownloadUpdates": false
    }

    """
}
