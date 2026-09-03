import AppKit
import ApplicationServices

/// Reads the text around the cursor in the focused element via Accessibility.
enum FocusedText {
    /// The character immediately before the insertion point, or nil when the
    /// focused element is empty at the cursor or does not expose its text.
    @MainActor
    static func characterBeforeCursor() -> Character? {
        let system = AXUIElementCreateSystemWide()
        guard
            let focused: AXUIElement = copy(system, kAXFocusedUIElementAttribute),
            let value: String = copy(focused, kAXValueAttribute),
            let rangeValue: AXValue = copy(focused, kAXSelectedTextRangeAttribute)
        else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range), range.location > 0 else {
            return range.location == 0 ? " " : nil
        }
        let utf16 = Array(value.utf16)
        guard range.location <= utf16.count else { return nil }
        return String(decoding: [utf16[range.location - 1]], as: UTF16.self).last
    }

    private static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }
}
