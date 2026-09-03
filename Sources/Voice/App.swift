import AppKit
import ApplicationServices
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
    private let localCleaner = LocalCleaner()
    private var cleaner: CodexCleaner?
    private var statusItem: NSStatusItem?
    private var hotkey: Hotkey?
    private var dictation: DictationController?
    private var modelLoadTask: Task<Void, Never>?
    private var cleanerStartTask: Task<Void, Never>?
    private var configWatcher: ConfigWatcher?
    private var currentConfig: Config?
    private var selfTestTask: Task<Void, Never>?
    private var cleanerTestTask: Task<Void, Never>?
    private var auroraTestTask: Task<Void, Never>?
    private var modelStatus = ModelStatus.loading
    private var isListening = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment
        let selfTestPath = environment["VOICE_SELFTEST"]
            .flatMap { $0.isEmpty ? nil : $0 }
        let cleanerTestText = environment["VOICE_CLEANTEST"]
            .flatMap { $0.isEmpty ? nil : $0 }
        let runsAuroraTest = environment["VOICE_AURORATEST"] == "1"
        AppLog.startSession(
            truncate: selfTestPath == nil && cleanerTestText == nil
        )

        if let selfTestPath {
            runSelfTest(path: selfTestPath)
            return
        }
        if let cleanerTestText {
            runCleanerTest(raw: cleanerTestText)
            return
        }
        if runsAuroraTest {
            runAuroraTest()
            return
        }

        let config = loadConfig()
        localCleaner.logAvailability()
        let cleaner = CodexCleaner(config: config)
        self.cleaner = cleaner
        configureDictation(config: config, cleaner: cleaner)
        configureStatusItem()
        configureHotkey(config: config)
        requestMicrophonePermission()
        requestAccessibilityPermission()
        if config.backend == .codex {
            beginCleanerStartup(cleaner)
        }
        beginModelLoading()

        currentConfig = config
        let configWatcher = ConfigWatcher { [weak self] in
            self?.reloadConfig()
        }
        self.configWatcher = configWatcher
        configWatcher.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        modelLoadTask?.cancel()
        cleanerStartTask?.cancel()
        selfTestTask?.cancel()
        cleanerTestTask?.cancel()
        auroraTestTask?.cancel()
        configWatcher?.stop()
        dictation?.shutdown()
        hotkey?.stop()
        if let cleaner {
            Task { await cleaner.shutdown() }
        }
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

    private func reloadConfig() {
        guard let currentConfig else {
            return
        }

        let config: Config
        do {
            config = try Config.load()
        } catch {
            AppLog.write(
                "config reload failed; keeping previous values: "
                    + error.localizedDescription
            )
            return
        }

        guard config != currentConfig else {
            return
        }

        if config.hotkey != currentConfig.hotkey {
            hotkey?.stop()
            configureHotkey(config: config)
        }

        let cleanerConfigChanged = config.backend != currentConfig.backend
            || config.codexModel != currentConfig.codexModel
            || config.codexThreadMaxTurns != currentConfig.codexThreadMaxTurns
            || config.cleanupTimeoutSeconds != currentConfig.cleanupTimeoutSeconds
        if cleanerConfigChanged {
            cleanerStartTask?.cancel()
            cleanerStartTask = nil

            let oldCleaner = cleaner
            let newCleaner = CodexCleaner(config: config)
            cleaner = newCleaner
            dictation?.update(codexCleaner: newCleaner)

            if let oldCleaner {
                Task { await oldCleaner.shutdown() }
            }
            if config.backend == .codex {
                beginCleanerStartup(newCleaner)
            }
        }

        self.currentConfig = config
        AppLog.write("config reloaded")
    }

    private func configureDictation(config: Config, cleaner: CodexCleaner) {
        let controller = DictationController(
            recorder: Recorder(),
            transcriber: transcriber,
            codexCleaner: cleaner,
            localCleaner: localCleaner,
            typist: Typist(),
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

    private func configureHotkey(config: Config) {
        let hotkey = Hotkey(
            key: config.hotkey,
            onHold: { [weak self] in self?.dictation?.hold() },
            onRelease: { [weak self] in self?.dictation?.release() },
            onCancel: { [weak self] in self?.dictation?.cancel() },
            onUserKeyDown: { [weak self] keyCode in self?.dictation?.userDidType(keyCode: keyCode) }
        )
        hotkey.start()
        self.hotkey = hotkey
    }

    private func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        AppLog.write("accessibility trusted: \(trusted)")
    }

    private func requestMicrophonePermission() {
        AppLog.write("microphone permission requested")
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                AppLog.write(
                    "microphone permission outcome: \(granted ? "granted" : "denied")"
                )
                if granted {
                    self.dictation?.prewarmRecorder()
                }
            }
        }
    }

    private func beginCleanerStartup(_ cleaner: CodexCleaner) {
        cleanerStartTask = Task { @MainActor in
            do {
                try await cleaner.start()
            } catch {
                guard !Task.isCancelled else { return }
                AppLog.write(
                    "cleanup startup unavailable: \(error.localizedDescription). "
                        + "Cleanup will retry on demand."
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
            symbolName = "waveform.circle.fill"
            description = "Voice listening"
        } else if modelStatus == .ready {
            symbolName = "waveform"
            description = "Voice"
        } else {
            symbolName = "waveform.slash"
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

        let historyItem = NSMenuItem(
            title: "Open history",
            action: #selector(openHistory),
            keyEquivalent: ""
        )
        historyItem.target = self
        menu.addItem(historyItem)
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

    private func runCleanerTest(raw: String) {
        let config = loadConfig()
        localCleaner.logAvailability()
        let cleaner = CodexCleaner(config: config)
        self.cleaner = cleaner
        cleanerTestTask = Task { @MainActor in
            AppLog.write("cleaner-test input: \(raw)")
            if config.backend == .codex {
                do {
                    try await cleaner.start()
                } catch {
                    AppLog.write(
                        "cleaner-test startup failed: \(error.localizedDescription)"
                    )
                }
            }

            let started = Date()
            let result = await CleanupPipeline.run(
                raw: raw,
                config: config,
                codex: cleaner,
                local: localCleaner
            )
            let duration = Date().timeIntervalSince(started)
            AppLog.write("cleaner-test output: \(result.output)")
            AppLog.write(
                "cleaner-test backend=\(result.backend.rawValue) "
                    + "fallback=\(result.fallback)"
            )
            AppLog.write(
                "cleaner-test duration=\(formatSeconds(duration))s"
            )
            if let error = result.error {
                AppLog.write("cleaner-test error: \(error)")
            }

            do {
                try History.append(
                    HistoryEntry(
                        audioSeconds: 0,
                        raw: raw,
                        result: result,
                        transcribeDuration: 0
                    )
                )
                AppLog.write("cleaner-test history appended")
            } catch {
                AppLog.write(
                    "cleaner-test history append failed: "
                        + error.localizedDescription
                )
            }

            await cleaner.shutdown()
            NSApplication.shared.terminate(nil)
        }
    }

    private func runAuroraTest() {
        let hud = HUD(bottomInset: CGFloat(Config.fallbackValue.hudBottomInset))
        auroraTestTask = Task { @MainActor in
            if let volume = InputDevice.inputVolume() {
                AppLog.write("input volume: \(String(format: "%.2f", volume))")
            } else {
                AppLog.write("input volume: unavailable")
            }
            AppLog.write("aurora-test state: listening")
            hud.show(state: .listening, text: "Aurora test")

            let listeningStarted = Date()
            while Date().timeIntervalSince(listeningStarted) < 2 {
                let elapsed = Date().timeIntervalSince(listeningStarted)
                let envelope = 0.5 + 0.5 * sin(elapsed * .pi * 2)
                hud.setLevel(Float(0.1 + 0.9 * envelope))
                try? await Task.sleep(for: .milliseconds(33))
            }

            hud.setLevel(0)
            AppLog.write("aurora-test state: transcribing")
            hud.update(state: .transcribing, text: "Transcribing")
            try? await Task.sleep(for: .seconds(2))

            AppLog.write("aurora-test state: cleaning")
            hud.update(state: .cleaning, text: "Cleaning")
            try? await Task.sleep(for: .seconds(2))

            AppLog.write("aurora-test state: done")
            hud.update(state: .done, text: "Done")
            try? await Task.sleep(for: .seconds(4))

            hud.hide()
            AppLog.write("aurora-test complete")
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
    private func openHistory() {
        do {
            try History.ensureFileExists()
            NSWorkspace.shared.activateFileViewerSelecting([History.fileURL])
        } catch {
            AppLog.write("Unable to open history: \(error.localizedDescription)")
        }
    }

    @objc
    private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
