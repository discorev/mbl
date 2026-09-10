import AppKit
import SwiftUI

@MainActor
struct ShortcutRecorder: View {
    private enum State: Equatable {
        case idle
        case recording
        case invalid(String)
        case saved
    }

    @Bindable var store: CompanionStore
    var onRecordingChanged: (Bool) -> Void

    @State private var state = State.idle
    @State private var monitor: Any?
    @State private var ownsKeyboard = false
    @State private var heldModifierKeyCodes: Set<Int64> = []
    @State private var capturedModifierKeyCodes: Set<Int64> = []
    @State private var didPressKey = false
    @State private var savedTask: Task<Void, Never>?

    var body: some View {
        settingRow("Push-to-talk shortcut", subtitle: subtitle) {
            VStack(alignment: .trailing, spacing: 7) {
                Button(buttonTitle) {
                    if !isRecording {
                        beginRecording()
                    }
                }
                .frame(minWidth: 150)
                .accessibilityLabel(isRecording ? "Press a shortcut" : "Record push-to-talk shortcut")

                if store.config.hotkey != .defaultValue {
                    Button("Reset to default") {
                        save(.defaultValue)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
            }
        }
        .onDisappear {
            savedTask?.cancel()
            cancelRecording()
        }
    }

    private var isRecording: Bool {
        switch state {
        case .recording, .invalid: true
        case .idle, .saved: false
        }
    }

    private var buttonTitle: String {
        isRecording ? "Press a shortcut…" : store.config.hotkey.displayString
    }

    private var subtitle: String {
        switch state {
        case .idle: "Hold to talk. Release to type."
        case .recording: "Esc to cancel"
        case .invalid(let message): message
        case .saved: "✓ Shortcut saved"
        }
    }

    private func beginRecording() {
        savedTask?.cancel()
        state = .recording
        heldModifierKeyCodes.removeAll()
        capturedModifierKeyCodes.removeAll()
        didPressKey = false
        ownsKeyboard = true
        onRecordingChanged(true)
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { event in
            handle(event)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            receiveKeyDown(event)
        case .flagsChanged:
            receiveFlagsChanged(event)
        default:
            break
        }
        return nil
    }

    private func receiveKeyDown(_ event: NSEvent) {
        if event.keyCode == 53 {
            cancelRecording()
            return
        }

        didPressKey = true
        let modifiers = genericModifiers(from: event.modifierFlags)
        guard !modifiers.isEmpty else {
            state = .invalid("Add a modifier like ⌥ or ⌃")
            return
        }

        validateAndSave(
            Shortcut(modifiers: modifiers, keyCode: Int64(event.keyCode))
        )
    }

    private func receiveFlagsChanged(_ event: NSEvent) {
        let keyCode = Int64(event.keyCode)
        guard let modifier = Modifier.modifier(forKeyCode: keyCode) else {
            return
        }

        let flags = event.cgEvent?.flags ?? []
        if flags.contains(modifier.eventFlag) {
            if heldModifierKeyCodes.isEmpty {
                capturedModifierKeyCodes.removeAll()
                didPressKey = false
            }
            heldModifierKeyCodes.insert(keyCode)
            capturedModifierKeyCodes.insert(keyCode)
            if case .invalid = state {
                state = .recording
            }
            return
        }

        heldModifierKeyCodes.remove(keyCode)
        guard
            heldModifierKeyCodes.isEmpty,
            !capturedModifierKeyCodes.isEmpty,
            !didPressKey
        else {
            return
        }

        let modifiers = Modifier.allCases.filter { modifier in
            guard let keyCode = modifier.keyCode else {
                return false
            }
            return capturedModifierKeyCodes.contains(keyCode)
        }
        validateAndSave(Shortcut(modifiers: modifiers, keyCode: nil))
    }

    private func genericModifiers(from flags: NSEvent.ModifierFlags) -> [Modifier] {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var modifiers: [Modifier] = []
        if flags.contains(.control) { modifiers.append(.control) }
        if flags.contains(.option) { modifiers.append(.option) }
        if flags.contains(.shift) { modifiers.append(.shift) }
        if flags.contains(.command) { modifiers.append(.command) }
        if flags.contains(.function) { modifiers.append(.fn) }
        return modifiers
    }

    private func validateAndSave(_ shortcut: Shortcut) {
        if let message = shortcut.validationMessage {
            state = .invalid(message)
            heldModifierKeyCodes.removeAll()
            capturedModifierKeyCodes.removeAll()
            didPressKey = false
            return
        }
        save(shortcut)
    }

    private func save(_ shortcut: Shortcut) {
        stopMonitoring()
        heldModifierKeyCodes.removeAll()
        capturedModifierKeyCodes.removeAll()
        didPressKey = false
        store.updateConfig { $0.hotkey = shortcut }
        guard store.config.hotkey == shortcut else {
            state = .idle
            return
        }

        state = .saved
        savedTask?.cancel()
        savedTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            state = .idle
        }
    }

    private func cancelRecording() {
        stopMonitoring()
        heldModifierKeyCodes.removeAll()
        capturedModifierKeyCodes.removeAll()
        didPressKey = false
        if isRecording {
            state = .idle
        }
    }

    private func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if ownsKeyboard {
            ownsKeyboard = false
            onRecordingChanged(false)
        }
    }
}
