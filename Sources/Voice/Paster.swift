import AppKit
import ApplicationServices

@MainActor
final class Paster {
    private static let pasteKeyCode: CGKeyCode = 9

    private var pendingSnapshot: PasteboardSnapshot?
    private var restoreTimer: Timer?

    func deliver(_ text: String) -> PasteDelivery {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .nothing
        }

        restoreClipboard()

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        _ = pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            AppLog.write("unable to write transcript to the clipboard")
            return .clipboardUnavailable
        }

        guard AXIsProcessTrusted() else {
            AppLog.write(
                "Accessibility permission is missing; transcript copied to the clipboard, "
                    + "but no paste keystroke was sent. Grant Voice in System Settings > "
                    + "Privacy & Security > Accessibility."
            )
            return .copiedAccessibilityRequired
        }

        guard postPasteKeystroke() else {
            AppLog.write(
                "unable to create the Cmd+V events; transcript left on the clipboard"
            )
            return .copiedEventUnavailable
        }

        pendingSnapshot = snapshot
        let timer = Timer(
            timeInterval: 0.3,
            target: self,
            selector: #selector(restoreClipboard),
            userInfo: nil,
            repeats: false
        )
        RunLoop.main.add(timer, forMode: .common)
        restoreTimer = timer
        return .pasted
    }

    private func postPasteKeystroke() -> Bool {
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: Self.pasteKeyCode,
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: Self.pasteKeyCode,
                keyDown: false
            )
        else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    @objc
    private func restoreClipboard() {
        restoreTimer?.invalidate()
        restoreTimer = nil

        guard let pendingSnapshot else {
            return
        }
        self.pendingSnapshot = nil
        pendingSnapshot.restore(to: .general)
    }
}

enum PasteDelivery: Sendable {
    case nothing
    case pasted
    case copiedAccessibilityRequired
    case copiedEventUnavailable
    case clipboardUnavailable
}

private struct PasteboardSnapshot {
    private struct Item {
        let values: [NSPasteboard.PasteboardType: Data]
    }

    private let items: [Item]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { pasteboardItem in
            let values = pasteboardItem.types.reduce(
                into: [NSPasteboard.PasteboardType: Data]()
            ) { values, type in
                if let data = pasteboardItem.data(forType: type) {
                    values[type] = data
                }
            }
            return Item(values: values)
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        _ = pasteboard.clearContents()
        guard !items.isEmpty else {
            return
        }

        let pasteboardItems = items.map { item in
            let pasteboardItem = NSPasteboardItem()
            for (type, data) in item.values {
                pasteboardItem.setData(data, forType: type)
            }
            return pasteboardItem
        }
        pasteboard.writeObjects(pasteboardItems)
    }
}
