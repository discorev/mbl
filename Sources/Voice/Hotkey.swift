import CoreGraphics
import Foundation

private let escapeKeyCode: Int64 = 53

@MainActor
final class Hotkey {
    private let shortcut: Shortcut
    private var matcher: ShortcutMatcher
    private let onHold: () -> Void
    private let onRelease: () -> Void
    private let onCancel: () -> Void
    private let onUserKeyDown: (Int64) -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPaused = false
    private var isCancelledHold = false

    init(
        shortcut: Shortcut,
        matcher: ShortcutMatcher,
        onHold: @escaping () -> Void,
        onRelease: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onUserKeyDown: @escaping (Int64) -> Void = { _ in }
    ) {
        self.shortcut = shortcut
        self.matcher = matcher
        self.onHold = onHold
        self.onRelease = onRelease
        self.onCancel = onCancel
        self.onUserKeyDown = onUserKeyDown
    }

    func start() {
        let eventMask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            AppLog.write(
                "Unable to create the keyboard event tap. Grant Accessibility to mbl.app in "
                    + "System Settings > Privacy & Security > Accessibility; mbl will keep running."
            )
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        AppLog.write("hotkey listener started: \(shortcut.displayString)")
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        eventTap = nil
        matcher.reset()
        isCancelledHold = false
    }

    func pause() {
        guard !isPaused else {
            return
        }
        isPaused = true
        if matcher.isHeld, !isCancelledHold {
            onCancel()
        }
        matcher.reset()
        isCancelledHold = false
    }

    func resume() {
        isPaused = false
    }

    fileprivate func receive(
        type: CGEventType,
        keyCode: Int64,
        flags: CGEventFlags,
        isAutorepeat: Bool
    ) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return false
        }

        guard !isPaused else {
            return false
        }

        if type == .keyDown,
           keyCode == escapeKeyCode,
           matcher.isHeld,
           shortcut.keyCode != escapeKeyCode {
            if !isCancelledHold {
                isCancelledHold = true
                onCancel()
            }
            return false
        }

        let result = matcher.receive(
            type: type,
            keyCode: keyCode,
            flags: flags,
            isAutorepeat: isAutorepeat
        )
        switch result.event {
        case .hold:
            isCancelledHold = false
            onHold()
        case .release:
            if isCancelledHold {
                isCancelledHold = false
            } else {
                onRelease()
            }
        case .none:
            break
        }

        if type == .keyDown,
           !matcher.isHeld,
           !result.swallow,
           Self.isTypingKey(keyCode, flags: flags) {
            onUserKeyDown(keyCode)
        }
        return result.swallow
    }

    /// Escape, arrows, function keys and app shortcuts move focus or the
    /// cursor without leaving a character behind, so they say nothing about
    /// what sits before the insertion point.
    private static let nonTypingKeyCodes: Set<Int64> = [
        53,                     // Escape
        123, 124, 125, 126,     // arrows
        115, 116, 119, 121,     // Home, Page Up, End, Page Down
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113,
        114, 72, 73, 74, 71, 51, 117,  // Help, volume, mute, clear, Delete, Fwd Delete
    ]

    private static func isTypingKey(_ keyCode: Int64, flags: CGEventFlags) -> Bool {
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            return false
        }
        return !nonTypingKeyCodes.contains(keyCode)
    }
}

private func hotkeyEventCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let hotkey = Unmanaged<Hotkey>.fromOpaque(userInfo).takeUnretainedValue()
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let swallow = MainActor.assumeIsolated {
        hotkey.receive(
            type: type,
            keyCode: keyCode,
            flags: flags,
            isAutorepeat: isAutorepeat
        )
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
