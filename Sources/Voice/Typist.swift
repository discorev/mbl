import AppKit
import ApplicationServices

/// Delivers text by emulating keyboard input at the current cursor.
@MainActor
final class Typist {
    /// CGEvent accepts at most 20 UTF-16 units per keyboard event.
    private static let chunkSize = 20
    private static let returnKeyCode: CGKeyCode = 36

    private enum CursorContext {
        case unknown          // nothing typed or dictated recently
        case afterDictation   // our last output is still under the cursor
        case freshLine        // user pressed Return (or Enter) since
        case midLine          // user typed characters since
    }

    private static let returnKeyCodes: Set<Int64> = [36, 76]
    private var context: CursorContext = .unknown
    private var contextAt: Date?
    private var lastTypedEndedWithSpace = true
    private var isTyping = false

    /// Called for any real key press from the user. Return means the cursor
    /// is on a fresh line; anything else means the user is mid-line.
    func userDidType(keyCode: Int64) {
        guard !isTyping else { return }
        context = Self.returnKeyCodes.contains(keyCode) ? .freshLine : .midLine
        contextAt = Date()
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
        context = .afterDictation
        contextAt = Date()
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
        guard let contextAt, Date().timeIntervalSince(contextAt) < 120 else {
            return false
        }
        let needsSpace: Bool
        switch context {
        case .unknown, .freshLine: needsSpace = false
        case .afterDictation: needsSpace = !lastTypedEndedWithSpace
        case .midLine: needsSpace = true
        }
        AppLog.write("focused text unavailable; cursor context=\(context) -> space=\(needsSpace)")
        return needsSpace
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
