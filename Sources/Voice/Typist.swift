import AppKit
import ApplicationServices

/// Delivers text by emulating keyboard input at the current cursor.
@MainActor
final class Typist {
    /// CGEvent accepts at most 20 UTF-16 units per keyboard event.
    private static let chunkSize = 20
    private static let returnKeyCode: CGKeyCode = 36

    private var lastTypedAt: Date?
    private var lastTypedEndedWithSpace = true
    private var isTyping = false

    /// Called for any real key press from the user; a keystroke after a
    /// dictation means the cursor has moved on, so drop the spacing memory.
    func userDidType() {
        guard !isTyping else { return }
        lastTypedAt = nil
    }

    func deliver(_ text: String) -> TypeDelivery {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .nothing
        }
        let text = needsLeadingSpace() ? " " + text : text

        guard AXIsProcessTrusted() else {
            AppLog.write(
                "Accessibility permission is missing; cannot type. Grant Voice in "
                    + "System Settings > Privacy & Security > Accessibility."
            )
            return .accessibilityRequired
        }

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            AppLog.write("unable to create a keyboard event source")
            return .eventUnavailable
        }

        isTyping = true
        defer { isTyping = false }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            for chunk in Array(String(line).utf16).chunked(into: Self.chunkSize) {
                post(unicode: chunk, source: source)
            }
            if index < lines.count - 1 {
                post(key: Self.returnKeyCode, source: source)
            }
        }
        lastTypedAt = Date()
        lastTypedEndedWithSpace = text.last?.isWhitespace ?? true
        return .typed
    }

    /// True when the character before the cursor is not whitespace, so the
    /// typed text would otherwise run into the previous word.
    private func needsLeadingSpace() -> Bool {
        if let previous = FocusedText.characterBeforeCursor() {
            AppLog.write("focused text: previous char=\(previous.debugDescription)")
            return !previous.isWhitespace && !previous.isNewline
        }
        guard let lastTypedAt, Date().timeIntervalSince(lastTypedAt) < 60 else {
            return false
        }
        AppLog.write("focused text unavailable; using recent-dictation heuristic")
        return !lastTypedEndedWithSpace
    }

    private func post(unicode: [UniChar], source: CGEventSource) {
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else {
            return
        }
        var units = unicode
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func post(key: CGKeyCode, source: CGEventSource) {
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap)
    }
}

enum TypeDelivery: Sendable {
    case nothing
    case typed
    case accessibilityRequired
    case eventUnavailable
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
