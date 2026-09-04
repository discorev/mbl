import Foundation

enum HistoryTimestamp {
    static let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSeconds = Date.ISO8601FormatStyle()

    static func date(from value: String) -> Date? {
        (try? format.parse(value)) ?? (try? wholeSeconds.parse(value))
    }
}

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
        ts = HistoryTimestamp.format.format(date)
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
    private static let writeLock = NSLock()

    static var fileURL: URL {
        Config.directoryURL.appendingPathComponent("history.jsonl")
    }

    static func append(
        _ entry: HistoryEntry,
        fileManager: FileManager = .default
    ) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
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

    static func remove(id: String, directoryURL: URL = Config.directoryURL) throws {
        // Serialize with dictation appends so a rewrite cannot discard a new entry.
        writeLock.lock()
        defer { writeLock.unlock() }
        let url = directoryURL.appendingPathComponent("history.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        // Preserve other records verbatim, including unknown fields and partial lines.
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        let retained = lines.filter { line in
            (try? JSONDecoder().decode(HistoryEntry.self, from: Data(line)))?.id != id
        }
        guard retained.count != lines.count else { return }
        try Data(retained.joined(separator: [UInt8(0x0A)])).write(to: url, options: .atomic)
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
