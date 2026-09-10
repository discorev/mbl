import CoreGraphics
import Foundation
import Testing
@testable import Voice

@Suite
struct ShortcutTests {
    @Test func validationRejectsMissingModifierAndFourKeys() {
        #expect(Shortcut(modifiers: [], keyCode: 49).validationMessage == "Add a modifier like ⌥ or ⌃")
        #expect(
            Shortcut(
                modifiers: [.control, .option, .shift],
                keyCode: 49
            ).validationMessage == "Use up to three keys"
        )
    }

    @Test func validationAcceptsSupportedShortcutShapes() {
        #expect(Shortcut(modifiers: [.fn], keyCode: nil).validationMessage == nil)
        #expect(Shortcut.defaultValue.validationMessage == nil)
        #expect(Shortcut(modifiers: [.control, .option], keyCode: 49).validationMessage == nil)
    }

    @Test func displayStringUsesMacGlyphOrderAndSidedModifierName() {
        #expect(Shortcut.defaultValue.displayString == "⌥ Right Option")
        #expect(
            Shortcut(
                modifiers: [.option, .control],
                keyCode: 49
            ).displayString == "⌃⌥ Space"
        )
    }

    @Test func modifierOnlyMatcherHoldsAndReleases() {
        var matcher = ShortcutMatcher(shortcut: .defaultValue)
        let pressedFlags = Modifier.rightOption.eventFlag.union(.maskAlternate)

        #expect(
            matcher.receive(
                type: .flagsChanged,
                keyCode: 61,
                flags: pressedFlags,
                isAutorepeat: false
            ) == .init(event: .hold, swallow: false)
        )
        #expect(matcher.isHeld)
        #expect(
            matcher.receive(
                type: .flagsChanged,
                keyCode: 61,
                flags: [],
                isAutorepeat: false
            ) == .init(event: .release, swallow: false)
        )
        #expect(!matcher.isHeld)
    }

    @Test func comboMatcherSwallowsHoldReleaseAndAutorepeat() {
        let shortcut = Shortcut(modifiers: [.control, .option], keyCode: 49)
        var matcher = ShortcutMatcher(shortcut: shortcut)
        let flags = CGEventFlags.maskControl.union(.maskAlternate)

        #expect(
            matcher.receive(
                type: .keyDown,
                keyCode: 49,
                flags: flags,
                isAutorepeat: false
            ) == .init(event: .hold, swallow: true)
        )
        #expect(
            matcher.receive(
                type: .keyDown,
                keyCode: 49,
                flags: flags,
                isAutorepeat: true
            ) == .init(event: .none, swallow: true)
        )
        #expect(
            matcher.receive(
                type: .flagsChanged,
                keyCode: 58,
                flags: .maskControl,
                isAutorepeat: false
            ) == .init(event: .none, swallow: false)
        )
        #expect(matcher.isHeld)
        #expect(
            matcher.receive(
                type: .keyUp,
                keyCode: 49,
                flags: [],
                isAutorepeat: false
            ) == .init(event: .release, swallow: true)
        )
        #expect(!matcher.isHeld)

        var sidedMatcher = ShortcutMatcher(
            shortcut: Shortcut(modifiers: [.rightOption], keyCode: 49)
        )
        #expect(
            sidedMatcher.receive(
                type: .keyDown,
                keyCode: 49,
                flags: .maskAlternate,
                isAutorepeat: false
            ) == .init(event: .hold, swallow: true)
        )
    }
}

@Suite @MainActor
struct ShortcutConfigMigrationTests {
    @Test func migratesBothLegacyHotkeyStrings() throws {
        try expectMigration(
            legacy: "rightOption",
            modifier: .rightOption
        )
        try expectMigration(
            legacy: "rightControl",
            modifier: .rightControl
        )
    }

    private func expectMigration(legacy: String, modifier: Modifier) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        var object = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(Config.fallbackValue)
            ) as? [String: Any]
        )
        object["hotkey"] = legacy
        let url = directory.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let config = try Config.load(directoryURL: directory)
        #expect(config.hotkey == Shortcut(modifiers: [modifier], keyCode: nil))

        let rewritten = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let hotkey = try #require(rewritten["hotkey"] as? [String: Any])
        #expect(hotkey["modifiers"] as? [String] == [legacy])
        #expect(rewritten["backend"] as? String == CleanupBackend.codex.rawValue)
    }
}
