import Foundation
import Testing
@testable import Voice

struct ReplacementsTests {
    @Test func matchesWholePhrasesIgnoringCaseAndKeepsLiteralOutput() {
        let rules = [TextReplacement(phrase: "the github repo", replacement: "https://github.com/discorev/mbl/$1")]
        #expect(Replacements.apply(rules, to: "Open THE GITHUB REPO, then the github repository.")
            == "Open https://github.com/discorev/mbl/$1, then the github repository.")
    }

    @Test func prefersLongestPhraseWithoutCascading() {
        let rules = [
            TextReplacement(phrase: "repo", replacement: "repository"),
            TextReplacement(phrase: "the repo", replacement: "repo"),
            TextReplacement(phrase: "repository", replacement: "other")
        ]
        #expect(Replacements.apply(rules, to: "the repo repo") == "repo repository")
    }

    @Test func handlesUnicodeLiteralPunctuationAndDeletion() {
        let rules = [TextReplacement(phrase: "cat", replacement: "dog"),
                     TextReplacement(phrase: "c++", replacement: "C Plus Plus"),
                     TextReplacement(phrase: "oops", replacement: "")]
        #expect(Replacements.apply(rules, to: "🐈 cat cafécat caté cat_2 (c++), oops")
            == "🐈 dog cafécat caté cat_2 (C Plus Plus), ")
    }

    @Test func preservesResultMetadataAndRecordsFinalRawOutput() {
        let rules = [TextReplacement(phrase: "repo", replacement: "https://example.com/")]
        for backend in [TranscriptBackend.raw, .local, .codex] {
            let original = CleanupResult(output: "repo", cleaned: backend == .raw ? nil : "repo",
                backend: backend, fallback: true, duration: 1, error: "cleanup error")
            let result = Replacements.apply(rules, to: original)
            #expect(result.output == "https://example.com/")
            #expect(result.cleaned == result.output)
            #expect(result.backend == backend)
            #expect(result.fallback && result.duration == 1 && result.error == original.error)
        }
    }

    @Test @MainActor func persistenceRefreshAndExternalChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CompanionStore(directoryURL: directory)
        try store.addReplacement(phrase: "the repo", replacement: "https://example.com/")
        #expect(throws: CompanionStoreError.self) { try store.addReplacement(phrase: "THE REPO", replacement: "other") }
        let second = CompanionStore(directoryURL: directory)
        #expect(second.replacements == store.replacements)
        try second.addReplacement(phrase: "oops", replacement: "")
        try store.removeReplacement(store.replacements[0])
        #expect(store.replacements == [TextReplacement(phrase: "oops", replacement: "")])
        second.refresh()
        #expect(second.replacements == store.replacements)
        let url = directory.appendingPathComponent("vocab.json")
        try Data("broken".utf8).write(to: url)
        store.refresh()
        #expect(store.errorMessage?.contains("Could not read vocabulary or replacements") == true)
        #expect(throws: (any Error).self) { try store.addReplacement(phrase: "new", replacement: "text") }
        #expect(try String(contentsOf: url, encoding: .utf8) == "broken")
    }
}
