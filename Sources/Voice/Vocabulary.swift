import Foundation

struct Vocabulary: Codable, Sendable {
    var terms: [String] = []
    var replacements: [TextReplacement] = []

    init(terms: [String] = [], replacements: [TextReplacement] = []) {
        self.terms = terms
        self.replacements = replacements
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        terms = try container.decodeIfPresent([String].self, forKey: .terms) ?? []
        replacements = try container.decodeIfPresent([TextReplacement].self, forKey: .replacements) ?? []
    }

    static func prepare(directoryURL: URL = Config.directoryURL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let url = directoryURL.appendingPathComponent("vocab.json")
        guard !fileManager.fileExists(atPath: url.path) else {
            _ = try load(directoryURL: directoryURL)
            return
        }

        let legacyURL = directoryURL.appendingPathComponent("vocab.txt")
        let terms = fileManager.fileExists(atPath: legacyURL.path)
            ? Prompts.vocabularyTerms(in: try String(contentsOf: legacyURL, encoding: .utf8))
            : []
        try Self(terms: terms).save(directoryURL: directoryURL)
        // Delete the legacy file only after the atomic JSON save succeeds.
        if fileManager.fileExists(atPath: legacyURL.path) {
            try fileManager.removeItem(at: legacyURL)
        }
    }

    static func load(directoryURL: URL = Config.directoryURL) throws -> Vocabulary {
        let url = directoryURL.appendingPathComponent("vocab.json").standardizedFileURL
        return try cache.load(url: url) {
            guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
            let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            try Replacements.validate(value.replacements)
            return value
        }
    }

    func save(directoryURL: URL) throws {
        try Replacements.validate(replacements)
        let url = directoryURL.appendingPathComponent("vocab.json").standardizedFileURL
        var object: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CompanionStoreError.invalid("Vocabulary must be a JSON object.")
            }
            object = existing
        }
        object["terms"] = terms
        object["replacements"] = replacements.map {
            ["phrase": $0.phrase, "replacement": $0.replacement]
        }
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url, options: .atomic)
        Self.cache.store(self, for: url)
    }

    private static let cache = VocabularyCache()
}

private final class VocabularyCache: @unchecked Sendable {
    private struct Signature: Equatable {
        let modificationDate: Date?
        let size: UInt64?
    }

    private enum CachedResult {
        case value(Vocabulary)
        case error(any Error)

        func get() throws -> Vocabulary {
            switch self {
            case .value(let value): value
            case .error(let error): throw error
            }
        }
    }

    private struct Entry {
        let signature: Signature?
        let result: CachedResult
    }

    private let lock = NSLock()
    private var entries: [URL: Entry] = [:]

    func load(url: URL, read: () throws -> Vocabulary) throws -> Vocabulary {
        lock.lock()
        defer { lock.unlock() }
        let signature = signature(at: url)
        if let entry = entries[url], entry.signature == signature {
            return try entry.result.get()
        }
        let result: CachedResult
        do { result = .value(try read()) }
        catch { result = .error(error) }
        entries[url] = Entry(signature: signature, result: result)
        return try result.get()
    }

    func store(_ value: Vocabulary, for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        entries[url] = Entry(signature: signature(at: url), result: .value(value))
    }

    private func signature(at url: URL) -> Signature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return Signature(
            modificationDate: attributes[.modificationDate] as? Date,
            size: attributes[.size] as? UInt64
        )
    }
}
