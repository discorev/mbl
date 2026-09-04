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
            let original = store.codexPrompt
            let url = Prompts.codexURL(for: store.config.codexModel, directoryURL: directory)
            try Data("External prompt".utf8).write(to: url)
            store.refresh()
            #expect(throws: CompanionStoreError.self) {
                try store.savePrompt("My edited prompt", backend: .codex, originalText: original)
            }
            #expect(try String(contentsOf: url, encoding: .utf8) == "External prompt")
            try store.savePrompt("Accepted prompt", backend: .codex, originalText: "External prompt")
            #expect(store.codexPrompt == "Accepted prompt")
        }
    }
}
