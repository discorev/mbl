import AppKit

@main
@MainActor
struct VoiceApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()

        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hotkey: Hotkey?
    private var config: Config?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.startSession()

        do {
            config = try Config.load()
            AppLog.write("config loaded")
        } catch {
            AppLog.write("Unable to load config: \(error.localizedDescription)")
        }

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "mic",
            accessibilityDescription: "Voice"
        )
        statusItem.menu = makeMenu()
        self.statusItem = statusItem

        let hotkey = Hotkey(
            onHold: { [weak self] in
                self?.setListening(true)
                AppLog.write("hold")
            },
            onRelease: { [weak self] in
                self?.setListening(false)
                AppLog.write("release")
            },
            onCancel: { [weak self] in
                self?.setListening(false)
                AppLog.write("cancel")
            }
        )
        hotkey.start()
        self.hotkey = hotkey
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey?.stop()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let quitItem = NSMenuItem(
            title: "Quit Voice",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    private func setListening(_ listening: Bool) {
        let symbolName = listening ? "mic.fill" : "mic"
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: listening ? "Voice listening" : "Voice"
        )
        if listening {
            image?.isTemplate = false
            statusItem?.button?.image = image?.withSymbolConfiguration(
                .init(paletteColors: [.systemRed])
            )
        } else {
            statusItem?.button?.image = image
        }
    }

    @objc
    private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

@MainActor
enum AppLog {
    private static let fileURL = URL(fileURLWithPath: "/tmp/voice.log")

    static func startSession() {
        try? Data().write(to: fileURL)
        write("Voice started")
    }

    static func write(_ message: String) {
        let data = Data("\(message)\n".utf8)
        try? FileHandle.standardError.write(contentsOf: data)

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            return
        }

        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
    }
}
