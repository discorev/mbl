import AppKit
import AVFoundation

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
    private enum ModelStatus {
        case loading
        case ready
        case failed
    }

    private let transcriber = Transcriber()
    private var statusItem: NSStatusItem?
    private var hotkey: Hotkey?
    private var dictation: DictationController?
    private var modelLoadTask: Task<Void, Never>?
    private var selfTestTask: Task<Void, Never>?
    private var modelStatus = ModelStatus.loading
    private var isListening = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let selfTestPath = ProcessInfo.processInfo.environment["VOICE_SELFTEST"]
            .flatMap { $0.isEmpty ? nil : $0 }
        AppLog.startSession(truncate: selfTestPath == nil)

        if let selfTestPath {
            runSelfTest(path: selfTestPath)
            return
        }

        let config = loadConfig()
        configureDictation(config: config)
        configureStatusItem()
        configureHotkey()
        requestMicrophonePermission()
        beginModelLoading()
    }

    func applicationWillTerminate(_ notification: Notification) {
        modelLoadTask?.cancel()
        selfTestTask?.cancel()
        dictation?.shutdown()
        hotkey?.stop()
    }

    private func loadConfig() -> Config {
        do {
            let config = try Config.load()
            AppLog.write("config loaded")
            return config
        } catch {
            AppLog.write(
                "Unable to load config; using defaults: \(error.localizedDescription)"
            )
            return .fallbackValue
        }
    }

    private func configureDictation(config: Config) {
        let controller = DictationController(
            recorder: Recorder(),
            transcriber: transcriber,
            paster: Paster(),
            hud: HUD(bottomInset: CGFloat(config.hudBottomInset)),
            config: config,
            onListeningChanged: { [weak self] listening in
                self?.isListening = listening
                self?.updateStatusIcon()
            }
        )
        dictation = controller
    }

    private func configureStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )
        statusItem.menu = makeMenu()
        self.statusItem = statusItem
        updateStatusIcon()
    }

    private func configureHotkey() {
        let hotkey = Hotkey(
            onHold: { [weak self] in self?.dictation?.hold() },
            onRelease: { [weak self] in self?.dictation?.release() },
            onCancel: { [weak self] in self?.dictation?.cancel() }
        )
        hotkey.start()
        self.hotkey = hotkey
    }

    private func requestMicrophonePermission() {
        AppLog.write("microphone permission requested")
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                AppLog.write(
                    "microphone permission outcome: \(granted ? "granted" : "denied")"
                )
            }
        }
    }

    private func beginModelLoading() {
        AppLog.write("models loading: Parakeet v2")
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let started = Date()
            do {
                try await transcriber.load()
                guard !Task.isCancelled else {
                    return
                }
                modelStatus = .ready
                dictation?.setModelsReady(true)
                AppLog.write(
                    "models loaded: Parakeet v2 in "
                        + formatSeconds(Date().timeIntervalSince(started))
                        + "s"
                )
            } catch {
                modelStatus = .failed
                AppLog.write(
                    "models failed to load after "
                        + formatSeconds(Date().timeIntervalSince(started))
                        + "s: \(error.localizedDescription)"
                )
            }
            updateStatusIcon()
        }
        modelLoadTask = task
        dictation?.setModelLoadTask(task)
    }

    private func updateStatusIcon() {
        let symbolName: String
        let description: String

        if isListening {
            symbolName = "mic.fill"
            description = "Voice listening"
        } else if modelStatus == .ready {
            symbolName = "mic"
            description = "Voice"
        } else {
            symbolName = "mic.slash"
            description = modelStatus == .loading
                ? "Voice loading speech model"
                : "Voice speech model unavailable"
        }

        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: description
        )
        if isListening {
            image?.isTemplate = false
            statusItem?.button?.image = image?.withSymbolConfiguration(
                .init(paletteColors: [.systemRed])
            )
        } else {
            statusItem?.button?.image = image
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let resetItem = NSMenuItem(
            title: "Reset HUD position",
            action: #selector(resetHUDPosition),
            keyEquivalent: ""
        )
        resetItem.target = self
        menu.addItem(resetItem)

        let configItem = NSMenuItem(
            title: "Open config folder",
            action: #selector(openConfigFolder),
            keyEquivalent: ""
        )
        configItem.target = self
        menu.addItem(configItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Voice",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    private func runSelfTest(path: String) {
        AppLog.write("self-test requested: \(path)")
        selfTestTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let modelStarted = Date()
            AppLog.write("models loading: Parakeet v2")
            do {
                try await transcriber.load()
                AppLog.write(
                    "models loaded: Parakeet v2 in "
                        + formatSeconds(Date().timeIntervalSince(modelStarted))
                        + "s"
                )

                let result = try await transcriber.runSelfTest(
                    at: URL(fileURLWithPath: path)
                )
                AppLog.write(
                    "self-test audio: \(formatSeconds(result.audioSeconds))s, "
                        + "conversion=\(formatSeconds(result.conversionSeconds))s, "
                        + "transcription=\(formatSeconds(result.transcriptionSeconds))s"
                )
                AppLog.write("self-test transcript: \(result.text)")
            } catch {
                AppLog.write("self-test failed: \(error.localizedDescription)")
            }
            NSApplication.shared.terminate(nil)
        }
    }

    private func formatSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.3f", seconds)
    }

    @objc
    private func resetHUDPosition() {
        dictation?.resetHUDPosition()
    }

    @objc
    private func openConfigFolder() {
        do {
            try FileManager.default.createDirectory(
                at: Config.directoryURL,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.open(Config.directoryURL)
        } catch {
            AppLog.write("Unable to open config folder: \(error.localizedDescription)")
        }
    }

    @objc
    private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
