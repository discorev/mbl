import Foundation
import Testing
@testable import Voice

struct VocabularyTests {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test func migratesLegacyTermsWhenJSONIsMissingAndIsIdempotent() throws {
        try withDirectory { directory in
            let text = directory.appendingPathComponent("vocab.txt")
            try Data("# Names\nMBL\nOllie\n".utf8).write(to: text)
            try Vocabulary.prepare(directoryURL: directory)
            let first = try Vocabulary.load(directoryURL: directory)
            try Vocabulary.prepare(directoryURL: directory)
            let second = try Vocabulary.load(directoryURL: directory)
            #expect(first.terms == ["MBL", "Ollie"])
            #expect(first.replacements.isEmpty)
            #expect(first.terms == second.terms && first.replacements == second.replacements)
            #expect(!FileManager.default.fileExists(atPath: text.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["vocab.json"])
        }
    }

    @Test func brokenJSONDoesNotRetireLegacyFile() throws {
        try withDirectory { directory in
            let json = directory.appendingPathComponent("vocab.json")
            let text = directory.appendingPathComponent("vocab.txt")
            try Data("broken".utf8).write(to: json)
            try Data("Ollie".utf8).write(to: text)
            #expect(throws: (any Error).self) { try Vocabulary.prepare(directoryURL: directory) }
            #expect(try String(contentsOf: json, encoding: .utf8) == "broken")
            #expect(try String(contentsOf: text, encoding: .utf8) == "Ollie")
        }
    }

    @Test @MainActor func UIEditsPreserveOtherListAndUnknownFields() throws {
        try withDirectory { directory in
            let store = CompanionStore(directoryURL: directory)
            let url = directory.appendingPathComponent("vocab.json")
            try Data(#"{"terms":["Ollie"],"replacements":[],"future":true}"#.utf8).write(to: url)
            try store.addReplacement(phrase: "repo", replacement: "url")
            try store.addWord("mbl")
            let value = try Vocabulary.load(directoryURL: directory)
            #expect(value.terms == ["Ollie", "mbl"])
            #expect(value.replacements == [.init(phrase: "repo", replacement: "url")])
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            #expect(object?["future"] as? Bool == true)
            #expect(object?["terms"] as? [String] == ["Ollie", "mbl"])
            #expect(object?["replacements"] as? [[String: String]] == [["phrase": "repo", "replacement": "url"]])
        }
    }

    @Test @MainActor func configLoadDoesNotDependOnVocabularyJSON() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("vocab.json")
            try Data("broken".utf8).write(to: url)
            #expect(try Config.load(directoryURL: directory) == .fallbackValue)

            let duplicates = #"{"terms":[],"replacements":[{"phrase":"repo","replacement":"one"},{"phrase":"REPO","replacement":"two"}]}"#
            try Data(duplicates.utf8).write(to: url)
            #expect(try Config.load(directoryURL: directory) == .fallbackValue)
            #expect(try String(contentsOf: url, encoding: .utf8) == duplicates)
        }
    }
}
