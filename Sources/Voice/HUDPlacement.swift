import AppKit

@MainActor
final class HUDPlacement: NSObject {
    private static let defaultsPrefix = "Voice.HUDPosition."

    private weak var window: NSWindow?
    private let defaults: UserDefaults
    private var bottomInset: CGFloat
    private var isMovingProgrammatically = false
    private var saveTask: Task<Void, Never>?

    init(
        window: NSWindow,
        bottomInset: CGFloat,
        defaults: UserDefaults = .standard
    ) {
        self.window = window
        self.bottomInset = bottomInset
        self.defaults = defaults
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidMove(_:)),
            name: NSWindow.didMoveNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        saveTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func update(bottomInset: CGFloat) {
        self.bottomInset = bottomInset
    }

    func prepareForShow() {
        let fingerprint = displayFingerprint()
        if let origin = savedOrigin(for: fingerprint), isVisible(origin: origin) {
            move(to: origin)
        } else {
            moveHome()
        }
    }

    func resetCurrentPosition() {
        let fingerprint = displayFingerprint()
        defaults.removeObject(forKey: defaultsKey(for: fingerprint))
        moveHome()
    }

    @objc
    private func windowDidMove(_ notification: Notification) {
        guard !isMovingProgrammatically else {
            return
        }

        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }
            self?.saveCurrentOrigin()
        }
    }

    @objc
    private func screenParametersDidChange(_ notification: Notification) {
        moveHome()
    }

    private func saveCurrentOrigin() {
        guard let window else {
            return
        }

        let fingerprint = displayFingerprint()
        defaults.set(
            ["x": Double(window.frame.origin.x), "y": Double(window.frame.origin.y)],
            forKey: defaultsKey(for: fingerprint)
        )
    }

    private func savedOrigin(for fingerprint: String) -> NSPoint? {
        guard
            let saved = defaults.dictionary(forKey: defaultsKey(for: fingerprint)),
            let x = saved["x"] as? Double,
            let y = saved["y"] as? Double
        else {
            return nil
        }
        return NSPoint(x: x, y: y)
    }

    private func isVisible(origin: NSPoint) -> Bool {
        guard let window else {
            return false
        }

        let frame = NSRect(origin: origin, size: window.frame.size)
        return NSScreen.screens.contains { $0.visibleFrame.contains(frame) }
    }

    private func moveHome() {
        guard let window, let screen = homeScreen() else {
            return
        }

        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.midX - window.frame.width / 2,
            y: visibleFrame.minY + bottomInset
        )
        move(to: origin)
    }

    private func move(to origin: NSPoint) {
        guard let window else {
            return
        }

        saveTask?.cancel()
        isMovingProgrammatically = true
        window.setFrameOrigin(origin)
        isMovingProgrammatically = false
    }

    private func homeScreen() -> NSScreen? {
        if let main = NSScreen.main {
            return main
        }

        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.screens.first
    }

    private func defaultsKey(for fingerprint: String) -> String {
        Self.defaultsPrefix + fingerprint
    }

    private func displayFingerprint() -> String {
        let mainScreen = NSScreen.main
        let descriptors = NSScreen.screens.map { screen in
            let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
            let identifier: String
            if let number = screen.deviceDescription[screenNumberKey] as? NSNumber {
                identifier = "id=\(number.uint32Value)"
            } else {
                identifier = "name=\(screen.localizedName)"
            }

            let frame = screen.frame
            let main = screen === mainScreen ? "main" : "secondary"
            return String(
                format: "%@;frame=%.3f,%.3f,%.3f,%.3f;%@",
                identifier,
                frame.origin.x,
                frame.origin.y,
                frame.width,
                frame.height,
                main
            )
        }
        return descriptors.sorted().joined(separator: "|")
    }
}
