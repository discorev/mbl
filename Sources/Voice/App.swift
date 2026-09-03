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
    private var selfTestTask: Task<Void, Never>?
    private var cleanerTestTask: Task<Void, Never>?
    private var modelStatus = ModelStatus.loading
    private var isListening = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment
        let selfTestPath = environment["VOICE_SELFTEST"]
            .flatMap { $0.isEmpty ? nil : $0 }
        let cleanerTestText = environment["VOICE_CLEANTEST"]
            .flatMap { $0.isEmpty ? nil : $0 }
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

        let config = loadConfig()
        localCleaner.logAvailability()
        let cleaner = CodexCleaner(config: config)
        self.cleaner = cleaner
        configureDictation(config: config, cleaner: cleaner)
        configureStatusItem()
        configureHotkey()
        requestMicrophonePermission()
        requestAccessibilityPermission()
        if config.backend == .codex {
            beginCleanerStartup(cleaner)
        }
        beginModelLoading()
    }

    func applicationWillTerminate(_ notification: Notification) {
        modelLoadTask?.cancel()
        cleanerStartTask?.cancel()
        selfTestTask?.cancel()
        cleanerTestTask?.cancel()
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

    private func configureHotkey() {
        let hotkey = Hotkey(
            onHold: { [weak self] in self?.dictation?.hold() },
            onRelease: { [weak self] in self?.dictation?.release() },
            onCancel: { [weak self] in self?.dictation?.cancel() }
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
                    "cleanup unavailable: \(error.localizedDescription) "
                        + "Raw transcripts will be typed."
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
