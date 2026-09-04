import Foundation
import Testing
@testable import Voice

@Suite @MainActor
struct CompanionStoreTests {
    private func withStore(_ body: (CompanionStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CompanionStore(directoryURL: directory)
        try body(store, directory)
    }

    @Test func settingsPreserveUnknownKeysAndExternalEdits() throws {
        try withStore { store, directory in
            let original = store.config
            let url = directory.appendingPathComponent("config.json")
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            object["futureFeature"] = ["enabled": true]
            object["hudBottomInset"] = 120
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            var draft = original
            draft.hotkey = .rightControl
            try store.saveConfig(draft, original: original)
            let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            #expect(saved["futureFeature"] as? [String: Bool] == ["enabled": true])
            #expect(store.config.hudBottomInset == 120)
            #expect(store.config.hotkey == .rightControl)
        }
    }

    @Test func settingsRejectBrokenFileWithoutOverwriting() throws {
        try withStore { store, directory in
            let url = directory.appendingPathComponent("config.json")
            try Data("broken".utf8).write(to: url)
            var draft = store.config
            draft.autoDownloadUpdates = true
            #expect(throws: (any Error).self) { try store.saveConfig(draft) }
            #expect(try String(contentsOf: url, encoding: .utf8) == "broken")
        }
    }

    @Test func settingsDetectConflictAfterRefreshWithOriginalDraft() throws {
        try withStore { store, directory in
            let original = store.config
            var external = original
            external.hudBottomInset = 100
            try JSONEncoder().encode(external).write(to: directory.appendingPathComponent("config.json"))
            store.refresh()
            var draft = original
            draft.hudBottomInset = 200
            #expect(throws: CompanionStoreError.self) { try store.saveConfig(draft, original: original) }
            #expect(store.config.hudBottomInset == 100)
        }
    }

    @Test func vocabularyEditsPreserveCommentsAndDeduplicate() throws {
        try withStore { store, directory in
            let url = directory.appendingPathComponent("vocab.txt")
            try Data("# Names\nOllie\nOllie\n\n# Products\nmbl\n".utf8).write(to: url)
            store.refresh()
            #expect(store.vocabulary == ["Ollie", "mbl"])
            try store.addWord("Codex")
            try store.removeWord("Ollie")
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text == "# Names\n\n# Products\nmbl\nCodex\n")
            #expect(throws: CompanionStoreError.self) { try store.addWord("one\ntwo") }
        }
    }

    @Test func historyLoadsRawAndFallbackSkipsCorruptAndPartialRows() throws {
        try withStore { store, directory in
            let url = directory.appendingPathComponent("history.jsonl")
            let raw = #"{"ts":"2026-09-04T12:00:00Z","audioSeconds":1.2,"raw":"hello","cleaned":null,"backend":"raw","fallback":false,"transcribeMs":20,"cleanupMs":null}"#
            let fallback = #"{"ts":"2026-09-04T12:01:00Z","audioSeconds":2,"raw":"um hi","cleaned":"Hi.","backend":"local","fallback":true,"transcribeMs":30,"cleanupMs":40,"error":"Codex timed out"}"#
            try Data((raw + "\ninvalid\n" + fallback + "\n{\"ts\":").utf8).write(to: url)
            store.refresh()
            #expect(store.history.count == 2)
            #expect(store.history.first?.fallback == true)
            #expect(store.history.first?.error == "Codex timed out")
            #expect(store.history.last?.cleaned == nil)
            #expect(store.errorMessage == "Skipped 1 unreadable history entries.")
        }
    }

    @Test func deletingHistoryPreservesUnloadedEntriesAndOriginalBytes() throws {
        try withStore { store, directory in
            let url = directory.appendingPathComponent("history.jsonl")
            let first = #"{"ts":"2026-09-04T12:00:00Z","audioSeconds":1,"raw":"first","backend":"raw","fallback":false,"transcribeMs":20}"#
            let second = #"{"ts":"2026-09-04T12:01:00Z","audioSeconds":1,"raw":"second","backend":"raw","fallback":false,"transcribeMs":20,"futureField":true}"#
            try Data((first + "\n").utf8).write(to: url)
            store.refresh()
            let entry = try #require(store.history.first)
            let suffix = second + "\ninvalid\n{\"ts\":"
            try Data((first + "\n" + suffix).utf8).write(to: url)
            try store.removeHistoryEntry(entry)
            #expect(try Data(contentsOf: url) == Data(suffix.utf8))
            #expect(store.history.map(\.raw) == ["second"])
            try store.removeHistoryEntry(entry)
            #expect(try Data(contentsOf: url) == Data(suffix.utf8))
        }
    }

    @Test func deletingLastHistoryEntryPersistsEmptyHistory() throws {
        try withStore { store, directory in
            let url = directory.appendingPathComponent("history.jsonl")
            let row = #"{"ts":"2026-09-04T12:00:00Z","audioSeconds":1,"raw":"last","backend":"raw","fallback":false,"transcribeMs":20}"#
            try Data((row + "\n").utf8).write(to: url)
            store.refresh()
            try store.removeHistoryEntry(#require(store.history.first))
            #expect(try Data(contentsOf: url).isEmpty)
            #expect(store.history.isEmpty)
            #expect(CompanionStore(directoryURL: directory).history.isEmpty)
        }
    }

    @Test func failedHistoryDeletionKeepsVisibleEntry() throws {
        try withStore { store, directory in
            let url = directory.appendingPathComponent("history.jsonl")
            let row = #"{"ts":"2026-09-04T12:00:00Z","audioSeconds":1,"raw":"keep","backend":"raw","fallback":false,"transcribeMs":20}"#
            try Data((row + "\n").utf8).write(to: url)
            store.refresh()
            let entry = try #require(store.history.first)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            #expect(throws: (any Error).self) { try store.removeHistoryEntry(entry) }
            #expect(store.history.map(\.id) == [entry.id])
        }
    }

    @Test func pollingPreservesSaveErrorsAndDoesNotRepeatReadAlerts() throws {
        try withStore { store, directory in
            store.errorMessage = "Save failed"
            store.refresh()
            #expect(store.errorMessage == "Save failed")
            store.errorMessage = nil
            try Data("broken".utf8).write(to: directory.appendingPathComponent("config.json"))
            store.refresh()
            #expect(store.errorMessage != nil)
            store.errorMessage = nil
            store.refresh()
            #expect(store.errorMessage == nil)
        }
    }

    @Test func promptConflictSurvivesRefresh() throws {
        try withStore { store, directory in
            let original = try #require(store.promptSnapshot(for: .codex))
            let url = Prompts.codexURL(for: store.config.codexModel, directoryURL: directory)
            try Data("External prompt".utf8).write(to: url)
            store.refresh()
            #expect(throws: CompanionStoreError.self) {
                try store.savePrompt("My edited prompt", original: original)
            }
            #expect(try String(contentsOf: url, encoding: .utf8) == "External prompt")
            try store.savePrompt("Accepted prompt", original: try #require(store.promptSnapshot(for: .codex)))
            #expect(store.codexPrompt == "Accepted prompt")
        }
    }
    @Test func promptDraftKeepsItsFileWhenModelChanges() throws {
        try withStore { store, directory in
            let original = try #require(store.promptSnapshot(for: .codex))
            var external = store.config
            external.codexModel = "another-model"
            try JSONEncoder().encode(external).write(to: directory.appendingPathComponent("config.json"))
            store.refresh()
            let active = try #require(store.promptSnapshot(for: .codex))
            #expect(active.url != original.url)
            try store.savePrompt("Edited original model", original: original)
            #expect(try String(contentsOf: original.url, encoding: .utf8) == "Edited original model")
            #expect(try String(contentsOf: active.url, encoding: .utf8) == active.text)
            #expect(store.codexPrompt == active.text)
            // Switching back must load the original model even if its signature is cached.
            external.codexModel = Config.fallbackValue.codexModel
            try JSONEncoder().encode(external).write(to: directory.appendingPathComponent("config.json"))
            store.refresh()
            #expect(store.codexPrompt == "Edited original model")
        }
    }

    @Test func suppressedReadErrorAppearsAfterOpenAlertIsDismissed() throws {
        try withStore { store, directory in
            let url = directory.appendingPathComponent("vocab.txt")
            store.errorMessage = "Settings save failed"
            try Data([0xff]).write(to: url)
            store.refresh()
            #expect(store.errorMessage == "Settings save failed")
            store.errorMessage = nil
            store.refresh()
            #expect(store.errorMessage?.contains("Could not read vocabulary") == true)
            store.errorMessage = nil
            store.refresh()
            #expect(store.errorMessage == nil)
            try Data("Recovered".utf8).write(to: url)
            store.refresh()
            #expect(store.vocabulary == ["Recovered"])
        }
    }

    @Test func pollingDetectsInPlaceVocabularyAndPromptChanges() throws {
        try withStore { store, directory in
            let prompt = try #require(store.promptSnapshot(for: .codex))
            for url in [directory.appendingPathComponent("vocab.txt"), prompt.url] {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("Appended".utf8))
                try handle.close()
            }
            store.refresh()
            #expect(store.vocabulary == ["Appended"])
            #expect(store.codexPrompt == prompt.text + "Appended")
        }
    }

    @Test func pollingRepairsMissingPromptsAndMigratesLegacyPrompt() throws {
        try withStore { store, directory in
            let promptURL = try #require(store.promptSnapshot(for: .codex)).url
            let configURL = directory.appendingPathComponent("config.json")
            let configBefore = try Data(contentsOf: configURL)
            try FileManager.default.removeItem(at: directory.appendingPathComponent("prompts"))
            try Data("Legacy instructions".utf8).write(to: directory.appendingPathComponent("prompt.md"))
            store.refresh()
            #expect(store.codexPrompt == "Legacy instructions")
            #expect(try String(contentsOf: promptURL, encoding: .utf8) == "Legacy instructions")
            #expect(!store.localPrompt.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("prompt.md").path))
            #expect(try Data(contentsOf: configURL) == configBefore)
            #expect(store.errorMessage == nil)
        }
    }

    @Test func vocabularyListMatchesCleanupInstructions() throws {
        try withStore { store, directory in
            try Data("  # Names\r\n Ollie \r\nOllie\n\n\tCodex\t\n".utf8)
                .write(to: directory.appendingPathComponent("vocab.txt"))
            store.refresh()
            let prompt = try #require(store.promptSnapshot(for: .codex))
            let instructions = try Prompts.instructions(at: prompt.url, directoryURL: directory)
            #expect(store.vocabulary == ["Ollie", "Codex"])
            #expect(instructions.vocabularyCount == store.vocabulary.count)
            #expect(instructions.text.hasSuffix("- Ollie\n- Codex\n"))
        }
    }

    @Test func historyTimestampsRoundTripAndAcceptLegacySeconds() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000.125)
        let timestamp = HistoryTimestamp.format.format(date)
        let decoded = try #require(HistoryTimestamp.date(from: timestamp))
        #expect(abs(decoded.timeIntervalSince(date)) < 0.001)
        #expect(HistoryTimestamp.date(from: "2026-09-04T12:00:00Z") != nil)
        #expect(HistoryTimestamp.date(from: "invalid") == nil)
    }

}
