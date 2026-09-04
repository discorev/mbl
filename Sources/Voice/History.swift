import Foundation

struct HistoryEntry: Codable, Identifiable, Sendable {
    var id: String { ts + "|" + raw }

    private enum CodingKeys: String, CodingKey {
        case ts
        case audioSeconds
        case raw
        case cleaned
        case backend
        case fallback
        case transcribeMs
        case cleanupMs
        case error
    }

    let ts: String
    let audioSeconds: TimeInterval
    let raw: String
    let cleaned: String?
    let backend: TranscriptBackend
    let fallback: Bool
    let transcribeMs: Int
    let cleanupMs: Int?
    let error: String?

    init(
        date: Date = Date(),
        audioSeconds: TimeInterval,
        raw: String,
        result: CleanupResult,
        transcribeDuration: TimeInterval
    ) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        ts = formatter.string(from: date)
        self.audioSeconds = audioSeconds
        self.raw = raw
        cleaned = result.cleaned
        backend = result.backend
        fallback = result.fallback
        transcribeMs = Self.milliseconds(transcribeDuration)
        cleanupMs = result.duration.map(Self.milliseconds)
        error = result.error
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ts, forKey: .ts)
        try container.encode(audioSeconds, forKey: .audioSeconds)
        try container.encode(raw, forKey: .raw)
        if let cleaned {
            try container.encode(cleaned, forKey: .cleaned)
        } else {
            try container.encodeNil(forKey: .cleaned)
        }
        try container.encode(backend, forKey: .backend)
        try container.encode(fallback, forKey: .fallback)
        try container.encode(transcribeMs, forKey: .transcribeMs)
        if let cleanupMs {
            try container.encode(cleanupMs, forKey: .cleanupMs)
        } else {
            try container.encodeNil(forKey: .cleanupMs)
        }
        if let error {
            try container.encode(error, forKey: .error)
        } else {
            try container.encodeNil(forKey: .error)
        }
    }

    private static func milliseconds(_ duration: TimeInterval) -> Int {
        Int((duration * 1_000).rounded())
    }
}

enum History {
    static var fileURL: URL {
        Config.directoryURL.appendingPathComponent("history.jsonl")
    }

    static func append(
        _ entry: HistoryEntry,
        fileManager: FileManager = .default
    ) throws {
        let url = fileURL
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil) else {
                throw HistoryError.couldNotCreateFile(url)
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(entry)
        data.append(0x0A)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }

    static func ensureFileExists(fileManager: FileManager = .default) throws {
        let url = fileURL
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: url.path),
           !fileManager.createFile(atPath: url.path, contents: nil) {
            throw HistoryError.couldNotCreateFile(url)
        }
    }
}

enum HistoryError: LocalizedError {
    case couldNotCreateFile(URL)

    var errorDescription: String? {
        switch self {
        case .couldNotCreateFile(let url):
            "Could not create history file at \(url.path)"
        }
    }
}
