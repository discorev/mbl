import CoreGraphics
import Foundation

private let escapeKeyCode: Int64 = 53

private extension HotkeyKey {
    var keyCode: Int64 {
        switch self {
        case .rightOption: 61
        case .rightControl: 62
        }
    }

    var deviceFlag: CGEventFlags {
        switch self {
        case .rightOption: CGEventFlags(rawValue: 0x00000040)
        case .rightControl: CGEventFlags(rawValue: 0x00002000)
        }
    }
}

@MainActor
final class Hotkey {
    private let key: HotkeyKey
    private let onHold: () -> Void
    private let onRelease: () -> Void
    private let onCancel: () -> Void
    private let onUserKeyDown: (Int64) -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isHeld = false

    init(
        key: HotkeyKey,
        onHold: @escaping () -> Void,
        onRelease: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onUserKeyDown: @escaping (Int64) -> Void = { _ in }
    ) {
        self.key = key
        self.onHold = onHold
        self.onRelease = onRelease
        self.onCancel = onCancel
        self.onUserKeyDown = onUserKeyDown
    }

    func start() {
        let eventMask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: hotkeyEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            AppLog.write(
                "Unable to create the keyboard event tap. Grant Accessibility to Voice.app in "
                    + "System Settings > Privacy & Security > Accessibility; Voice will keep running."
            )
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        AppLog.write("hotkey listener started: \(key.rawValue)")
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
        isHeld = false
    }

    fileprivate func receive(
        type: CGEventType,
        keyCode: Int64,
        flags: CGEventFlags
    ) {
        if type == .flagsChanged, keyCode == key.keyCode {
            let isPressed = flags.contains(key.deviceFlag)
            if isPressed, !isHeld {
                isHeld = true
                onHold()
            } else if !isPressed, isHeld {
                isHeld = false
                onRelease()
            }
            return
        }

        if type == .keyDown, keyCode == escapeKeyCode, isHeld {
            isHeld = false
            onCancel()
            return
        }

        if type == .keyDown, !isHeld, Self.isTypingKey(keyCode, flags: flags) {
            onUserKeyDown(keyCode)
        }
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
    proxy: CGEventTapProxy,
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
    MainActor.assumeIsolated {
        hotkey.receive(
            type: type,
            keyCode: keyCode,
            flags: flags
        )
    }
    return Unmanaged.passUnretained(event)
}
