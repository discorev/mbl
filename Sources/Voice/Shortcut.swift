import Carbon.HIToolbox
import CoreGraphics
import Foundation

struct Shortcut: Codable, Equatable, Sendable {
    var modifiers: [Modifier]
    var keyCode: Int64?

    static let defaultValue = Shortcut(modifiers: [.rightOption], keyCode: nil)

    var validationMessage: String? {
        if modifiers.isEmpty {
            return "Add a modifier like ⌥ or ⌃"
        }
        if modifiers.count + (keyCode == nil ? 0 : 1) > 3 {
            return "Use up to three keys"
        }
        if let keyCode, Modifier.modifier(forKeyCode: keyCode) != nil {
            return "Modifiers only need listing once"
        }
        if let keyCode, !(0...127).contains(keyCode) {
            return "Unknown key"
        }
        return nil
    }

    var displayString: String {
        let sortedModifiers = modifiers.sorted { $0.displayOrder < $1.displayOrder }
        if keyCode == nil, sortedModifiers.count == 1, let modifier = sortedModifiers.first {
            return modifier == .fn ? "Fn" : "\(modifier.glyph) \(modifier.displayName)"
        }

        let modifierText = sortedModifiers.map(\.glyph).joined()
        guard let keyCode else {
            return modifierText
        }
        return modifierText + " " + Self.keyName(for: keyCode)
    }

    /// Arrows, F-keys and navigation keys carry the Fn flag on their own.
    static func isFunctionKey(_ keyCode: Int64) -> Bool {
        functionKeyCodes.contains(keyCode)
    }

    private static let functionKeyCodes: Set<Int64> = [
        123, 124, 125, 126, 115, 119, 116, 121, 117,
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
        105, 107, 113, 106, 64, 79, 80, 90,
    ]

    private static func keyName(for keyCode: Int64) -> String {
        if let fixed = fixedKeyNames[keyCode] {
            return fixed
        }
        return translatedKeyName(for: keyCode) ?? "Key \(keyCode)"
    }

    private static func translatedKeyName(for keyCode: Int64) -> String? {
        guard
            keyCode >= 0,
            keyCode <= Int64(UInt16.max),
            let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let property = TISGetInputSourceProperty(
                source,
                kTISPropertyUnicodeKeyLayoutData
            )
        else {
            return nil
        }

        let data: CFData = Unmanaged.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else {
            return nil
        }

        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(
            to: UCKeyboardLayout.self
        )
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(
            layout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            characters.count,
            &length,
            &characters
        )
        guard status == noErr, length > 0 else {
            return nil
        }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }

    private static let fixedKeyNames: [Int64: String] = [
        49: "Space",
        36: "Return",
        48: "Tab",
        51: "Delete",
        117: "Forward Delete",
        53: "Escape",
        123: "Left Arrow",
        124: "Right Arrow",
        125: "Down Arrow",
        126: "Up Arrow",
        115: "Home",
        119: "End",
        116: "Page Up",
        121: "Page Down",
        122: "F1",
        120: "F2",
        99: "F3",
        118: "F4",
        96: "F5",
        97: "F6",
        98: "F7",
        100: "F8",
        101: "F9",
        109: "F10",
        103: "F11",
        111: "F12",
        105: "F13",
        107: "F14",
        113: "F15",
        106: "F16",
        64: "F17",
        79: "F18",
        80: "F19",
        90: "F20",
    ]
}

enum Modifier: String, Codable, CaseIterable, Sendable {
    case command
    case option
    case control
    case shift
    case fn
    case leftCommand
    case rightCommand
    case leftOption
    case rightOption
    case leftControl
    case rightControl
    case leftShift
    case rightShift

    var eventFlag: CGEventFlags {
        switch self {
        case .command: .maskCommand
        case .option: .maskAlternate
        case .control: .maskControl
        case .shift: .maskShift
        case .fn: .maskSecondaryFn
        case .leftControl: CGEventFlags(rawValue: 0x00000001)
        case .leftShift: CGEventFlags(rawValue: 0x00000002)
        case .rightShift: CGEventFlags(rawValue: 0x00000004)
        case .leftCommand: CGEventFlags(rawValue: 0x00000008)
        case .rightCommand: CGEventFlags(rawValue: 0x00000010)
        case .leftOption: CGEventFlags(rawValue: 0x00000020)
        case .rightOption: CGEventFlags(rawValue: 0x00000040)
        case .rightControl: CGEventFlags(rawValue: 0x00002000)
        }
    }

    var comboEventFlag: CGEventFlags {
        switch self {
        case .command, .leftCommand, .rightCommand: .maskCommand
        case .option, .leftOption, .rightOption: .maskAlternate
        case .control, .leftControl, .rightControl: .maskControl
        case .shift, .leftShift, .rightShift: .maskShift
        case .fn: .maskSecondaryFn
        }
    }

    var keyCode: Int64? {
        switch self {
        case .leftCommand: 55
        case .rightCommand: 54
        case .leftOption: 58
        case .rightOption: 61
        case .leftControl: 59
        case .rightControl: 62
        case .leftShift: 56
        case .rightShift: 60
        case .fn: 63
        case .command, .option, .control, .shift: nil
        }
    }

    static func modifier(forKeyCode keyCode: Int64) -> Modifier? {
        allCases.first { $0.keyCode == keyCode }
    }

    fileprivate var glyph: String {
        switch self {
        case .control, .leftControl, .rightControl: "⌃"
        case .option, .leftOption, .rightOption: "⌥"
        case .shift, .leftShift, .rightShift: "⇧"
        case .command, .leftCommand, .rightCommand: "⌘"
        case .fn: "Fn"
        }
    }

    fileprivate var displayName: String {
        switch self {
        case .command: "Command"
        case .option: "Option"
        case .control: "Control"
        case .shift: "Shift"
        case .fn: "Fn"
        case .leftCommand: "Left Command"
        case .rightCommand: "Right Command"
        case .leftOption: "Left Option"
        case .rightOption: "Right Option"
        case .leftControl: "Left Control"
        case .rightControl: "Right Control"
        case .leftShift: "Left Shift"
        case .rightShift: "Right Shift"
        }
    }

    fileprivate var displayOrder: Int {
        switch self {
        case .control, .leftControl, .rightControl: 0
        case .option, .leftOption, .rightOption: 1
        case .shift, .leftShift, .rightShift: 2
        case .command, .leftCommand, .rightCommand: 3
        case .fn: 4
        }
    }
}

struct ShortcutMatcher {
    enum Event: Equatable {
        case none
        case hold
        case release
    }

    struct Result: Equatable {
        let event: Event
        let swallow: Bool
    }

    let shortcut: Shortcut
    private(set) var isHeld = false

    mutating func receive(
        type: CGEventType,
        keyCode: Int64,
        flags: CGEventFlags,
        isAutorepeat: Bool
    ) -> Result {
        guard shortcut.validationMessage == nil else {
            return Result(event: .none, swallow: false)
        }

        guard let triggerKeyCode = shortcut.keyCode else {
            guard type == .flagsChanged else {
                return Result(event: .none, swallow: false)
            }
            let allModifiersPressed = shortcut.modifiers.allSatisfy {
                flags.contains($0.eventFlag)
            }
            if allModifiersPressed, !isHeld {
                isHeld = true
                return Result(event: .hold, swallow: false)
            }
            if !allModifiersPressed, isHeld {
                isHeld = false
                return Result(event: .release, swallow: false)
            }
            return Result(event: .none, swallow: false)
        }

        if type == .keyDown, keyCode == triggerKeyCode {
            if isHeld {
                return Result(event: .none, swallow: true)
            }
            guard
                !isAutorepeat,
                shortcut.modifiers.allSatisfy({ flags.contains($0.comboEventFlag) })
            else {
                return Result(event: .none, swallow: false)
            }
            isHeld = true
            return Result(event: .hold, swallow: true)
        }

        if type == .keyUp, keyCode == triggerKeyCode, isHeld {
            isHeld = false
            return Result(event: .release, swallow: true)
        }

        return Result(event: .none, swallow: false)
    }

    mutating func reset() {
        isHeld = false
    }
}
