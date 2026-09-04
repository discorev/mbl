import Foundation
import Observation

/// The companion edits the same files used by dictation and its existing watcher.
@MainActor
@Observable
final class CompanionStore {
    var config: Config = .fallbackValue
    var history: [HistoryEntry] = []
    var vocabulary: [String] = []
    var codexPrompt = ""
    var localPrompt = ""
    var errorMessage: String?

    @ObservationIgnored private let directoryURL: URL
    @ObservationIgnored private var previousReadError: String?
    @ObservationIgnored private var historyWarning: String?
    private struct HistorySignature: Equatable {
        let date: Date?
        let size: UInt64?
    }
    @ObservationIgnored private var historySignature: HistorySignature?
    @ObservationIgnored private var loadedConfig: Config = .fallbackValue
    @ObservationIgnored private var loadedPrompts: [CleanupBackend: (url: URL, text: String)] = [:]

    init(directoryURL: URL = Config.directoryURL) {
        self.directoryURL = directoryURL
        refresh()
    }

    func refresh() {
        var errors: [String] = []
        do {
            let value = try Config.load(directoryURL: directoryURL)
            config = value
            loadedConfig = value
        } catch {
            errors.append("Could not read settings: \(error.localizedDescription)")
        }
        do {
            vocabulary = Self.terms(in: try vocabularyText())
        } catch {
            errors.append("Could not read vocabulary: \(error.localizedDescription)")
        }
        for backend in [CleanupBackend.codex, .local] {
            do {
                let url = try promptURL(for: backend)
                let text = try String(contentsOf: url, encoding: .utf8)
                loadedPrompts[backend] = (url, text)
                if backend == .codex { codexPrompt = text } else { localPrompt = text }
            } catch {
                errors.append("Could not read \(backend.rawValue) prompt: \(error.localizedDescription)")
            }
        }
        do {
            let url = directoryURL.appendingPathComponent("history.jsonl")
            if FileManager.default.fileExists(atPath: url.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let signature = HistorySignature(date: attributes[.modificationDate] as? Date, size: attributes[.size] as? UInt64)
                if signature == historySignature {
                    if let historyWarning { errors.append(historyWarning) }
                    reportReadErrors(errors)
                    return
                }
                let text = try String(contentsOf: url, encoding: .utf8)
                var entries: [HistoryEntry] = []
                var invalid = 0
                let lines = text.split(whereSeparator: \.isNewline)
                for (index, line) in lines.enumerated() {
                    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                    do {
                        entries.append(try JSONDecoder().decode(HistoryEntry.self, from: Data(line.utf8)))
                    } catch {
                        if index != lines.count - 1 || text.hasSuffix("\n") { invalid += 1 }
                    }
                }
                history = entries.reversed()
                historySignature = signature
                historyWarning = invalid > 0 ? "Skipped \(invalid) unreadable history entries." : nil
                if let historyWarning { errors.append(historyWarning) }
            } else {
                history = []
                historySignature = nil
                historyWarning = nil
            }
        } catch {
            errors.append("Could not read history: \(error.localizedDescription)")
        }
        reportReadErrors(errors)
    }

    func saveConfig(_ value: Config, original: Config? = nil) throws {
        try Self.validate(value)
        let url = directoryURL.appendingPathComponent("config.json")
        let currentData = try Data(contentsOf: url)
        // Refuse to overwrite a broken config, and preserve settings changed externally.
        let diskConfig = try JSONDecoder().decode(Config.self, from: currentData)
        let normalized = try Self.jsonObject(JSONEncoder().encode(diskConfig))
        var current = try Self.jsonObject(currentData)
        let baseline = try Self.jsonObject(JSONEncoder().encode(original ?? loadedConfig))
        let proposed = try Self.jsonObject(JSONEncoder().encode(value))
        for (key, next) in proposed {
            if !Self.equalJSON(baseline[key], next) {
                guard Self.equalJSON(normalized[key], baseline[key]) || Self.equalJSON(normalized[key], next)
                    || current[key] == nil else {
                    throw CompanionStoreError.conflict("Settings changed outside this window. Reopen Settings and try again.")
                }
                current[key] = next
            }
        }
        let data = try JSONSerialization.data(withJSONObject: current, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let merged = try JSONDecoder().decode(Config.self, from: data)
        try Self.validate(merged)
        try Prompts.prepare(config: merged, directoryURL: directoryURL, fileManager: .default)
        try data.write(to: url, options: .atomic)
        refresh()
    }

    func addWord(_ word: String) throws {
        let term = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !term.hasPrefix("#"), !term.contains(where: \.isNewline) else {
            throw CompanionStoreError.invalid("Enter one vocabulary term on a single line.")
        }
        var text = try vocabularyText()
        guard !Self.terms(in: text).contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else { return }
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += term + "\n"
        try Data(text.utf8).write(to: directoryURL.appendingPathComponent("vocab.txt"), options: .atomic)
        vocabulary = Self.terms(in: text)
        errorMessage = nil
    }

    func removeWord(_ word: String) throws {
        let text = try vocabularyText()
        // Retain comments, whitespace and the order of all other terms.
        let updated = text.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines) != word }
            .joined(separator: "\n")
        try Data(updated.utf8).write(to: directoryURL.appendingPathComponent("vocab.txt"), options: .atomic)
        vocabulary = Self.terms(in: updated)
        errorMessage = nil
    }

    func savePrompt(_ text: String, backend: CleanupBackend, originalText: String? = nil) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CompanionStoreError.invalid("The cleanup prompt cannot be empty.")
        }
        let url = try promptURL(for: backend)
        guard let original = loadedPrompts[backend], original.url == url,
              try String(contentsOf: url, encoding: .utf8) == (originalText ?? original.text) else {
            throw CompanionStoreError.conflict("These instructions changed outside this window. Copy any edits you want to keep, then choose Reload instructions and try again.")
        }
        try Data(text.utf8).write(to: url, options: .atomic)
        loadedPrompts[backend] = (url, text)
        if backend == .codex { codexPrompt = text } else { localPrompt = text }
        errorMessage = nil
    }

    private func reportReadErrors(_ errors: [String]) {
        let message = errors.isEmpty ? nil : errors.joined(separator: "\n")
        // Polling must not dismiss a save error, or repeatedly reopen a dismissed read alert.
        if let message, message != previousReadError, errorMessage == nil {
            errorMessage = message
        }
        previousReadError = message
    }

    private func promptURL(for backend: CleanupBackend) throws -> URL {
        switch backend {
        case .codex: Prompts.codexURL(for: loadedConfig.codexModel, directoryURL: directoryURL)
        case .local: try Prompts.localLocation(directoryURL: directoryURL).url
        }
    }

    private func vocabularyText() throws -> String {
        try String(contentsOf: directoryURL.appendingPathComponent("vocab.txt"), encoding: .utf8)
    }

    private static func terms(in text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && seen.insert($0).inserted }
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CompanionStoreError.invalid("Settings must be a JSON object.")
        }
        return object
    }

    private static func equalJSON(_ lhs: Any?, _ rhs: Any?) -> Bool {
        guard let lhs = lhs as? NSObject, let rhs = rhs as? NSObject else { return lhs == nil && rhs == nil }
        return lhs == rhs
    }

    private static func validate(_ value: Config) throws {
        guard !value.codexModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.codexModel.contains("/"), !value.codexModel.contains("\\"),
              value.codexThreadMaxTurns > 0, value.minWordsForCleanup >= 0,
              value.cleanupTimeoutSeconds > 0, value.previewTickMs > 0,
              value.hudBottomInset >= 0, value.minInputVolume.isFinite,
              (0...1).contains(value.minInputVolume) else {
            throw CompanionStoreError.invalid("Use a model name, positive timeout, preview interval and turn limit, nonnegative word count and HUD inset, and an input volume between 0 and 1.")
        }
    }
}

enum CompanionStoreError: LocalizedError {
    case invalid(String)
    case conflict(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message), .conflict(let message): message
        }
    }
}
