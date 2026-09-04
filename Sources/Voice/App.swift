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
    private var updater: Updater?
    private var companionStore: CompanionStore?
    private var companionWindow: CompanionWindowController?
    private var isCompanionPreview = false
    private var updateMenuItem: NSMenuItem?
    private var updateState = Updater.State.idle
    private var selfTestTask: Task<Void, Never>?
    private var cleanerTestTask: Task<Void, Never>?
    private var auroraTestTask: Task<Void, Never>?
    private var modelStatus = ModelStatus.loading
    private var isListening = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment
        if environment["VOICE_COMPANION_PREVIEW"] == "1" {
            isCompanionPreview = true
            switch environment["VOICE_COMPANION_PREVIEW_UPDATE"] {
            case "available": updateState = .available(version: "Preview")
            case "downloaded": updateState = .ready
            default: updateState = .idle
            }
            openCompanionWindow()
            return
        }
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
        configureUpdater(config: config)
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

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        openCompanionWindow()
        return true
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

        updater?.autoDownload = config.autoDownloadUpdates
        self.currentConfig = config
        companionStore?.refresh()
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

    private func configureUpdater(config: Config) {
        guard let updater = Updater.makeIfAvailable() else {
            return
        }

        self.updater = updater
        updater.autoDownload = config.autoDownloadUpdates
        updateState = updater.state
        updater.onStateChange = { [weak self] state in
            guard let self else { return }
            self.updateState = state
            self.companionWindow?.updateState = state
            self.updateUpdateMenuItem(for: state)
            self.updateStatusIcon()
        }
        statusItem?.menu = makeMenu()
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
            symbolName = "waveform"
            description = "mbl listening"
        } else if modelStatus == .ready {
            symbolName = "waveform"
            description = "mbl"
        } else {
            symbolName = "waveform.slash"
            description = modelStatus == .loading
                ? "mbl loading speech model"
                : "mbl speech model unavailable"
        }

        guard let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: description
        ) else {
            statusItem?.button?.image = nil
            return
        }

        if isListening {
            image.isTemplate = false
            statusItem?.button?.image = image.withSymbolConfiguration(
                .init(paletteColors: [.systemRed])
            )
        } else if hasUpdateBadge {
            let size = NSSize(width: 18, height: 18)
            let badgeDiameter: CGFloat = 9
            let badgeRect = NSRect(
                x: size.width - badgeDiameter,
                y: 0,
                width: badgeDiameter,
                height: badgeDiameter
            )
            let ringRect = badgeRect.insetBy(dx: -1, dy: -1)
            let composite = NSImage(
                size: size,
                flipped: false
            ) { rect in
                image.draw(in: rect)

                guard let context = NSGraphicsContext.current else {
                    return true
                }
                context.saveGraphicsState()
                context.compositingOperation = .copy
                NSColor.clear.setFill()
                NSBezierPath(ovalIn: ringRect).fill()
                context.compositingOperation = .sourceOver
                NSColor.black.setFill()
                NSBezierPath(ovalIn: badgeRect).fill()
                context.compositingOperation = .destinationOut
                NSColor.black.setStroke()
                let arrow = NSBezierPath()
                arrow.lineWidth = 1.5
                arrow.lineCapStyle = .round
                arrow.lineJoinStyle = .round
                let midX = badgeRect.midX
                let top = badgeRect.maxY - 2
                let bottom = badgeRect.minY + 2
                arrow.move(to: NSPoint(x: midX, y: top))
                arrow.line(to: NSPoint(x: midX, y: bottom))
                arrow.move(to: NSPoint(x: midX - 2, y: bottom + 2))
                arrow.line(to: NSPoint(x: midX, y: bottom))
                arrow.line(to: NSPoint(x: midX + 2, y: bottom + 2))
                arrow.stroke()
                context.restoreGraphicsState()
                return true
            }
            composite.isTemplate = true
            composite.accessibilityDescription = description + ", update available"
            statusItem?.button?.image = composite
        } else {
            statusItem?.button?.image = image
        }
    }

    private var hasUpdateBadge: Bool {
        switch updateState {
        case .available, .ready:
            true
        default:
            false
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        updateMenuItem = nil

        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let versionItem = NSMenuItem(
            title: version.map { "mbl \($0)" } ?? "mbl",
            action: nil,
            keyEquivalent: ""
        )
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(.separator())

        let openItem = NSMenuItem(
            title: "Open mbl",
            action: #selector(openCompanionWindow),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())

        if updater != nil {
            let updateItem = NSMenuItem(
                title: "",
                action: nil,
                keyEquivalent: ""
            )
            updateItem.target = self
            updateMenuItem = updateItem
            updateUpdateMenuItem(for: updateState)
            menu.addItem(updateItem)
            menu.addItem(.separator())
        }

        let resetItem = NSMenuItem(
            title: "Reset HUD position",
            action: #selector(resetHUDPosition),
            keyEquivalent: ""
        )
        resetItem.target = self
        menu.addItem(resetItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit mbl",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    private func updateUpdateMenuItem(for state: Updater.State) {
        guard let updateMenuItem else { return }

        switch state {
        case .idle:
            updateMenuItem.title = "Check for updates"
            updateMenuItem.action = #selector(checkForUpdates)
            updateMenuItem.isEnabled = true
        case .checking:
            updateMenuItem.title = "Checking for updates…"
            updateMenuItem.action = nil
            updateMenuItem.isEnabled = false
        case let .available(version):
            updateMenuItem.title = "Download \(version)"
            updateMenuItem.action = #selector(downloadUpdate)
            updateMenuItem.isEnabled = true
        case .downloading:
            updateMenuItem.title = "Preparing update…"
            updateMenuItem.action = nil
            updateMenuItem.isEnabled = false
        case .ready:
            updateMenuItem.title = "Install and restart"
            updateMenuItem.action = #selector(installAndRestart)
            updateMenuItem.isEnabled = true
        case .upToDate:
            updateMenuItem.title = "Up to date"
            updateMenuItem.action = nil
            updateMenuItem.isEnabled = false
        case .failed:
            updateMenuItem.title = "Update check failed"
            updateMenuItem.action = nil
            updateMenuItem.isEnabled = false
        }
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
    private func checkForUpdates() {
        updater?.checkForUpdates()
    }

    @objc
    private func downloadUpdate() {
        updater?.download()
    }

    @objc
    private func installAndRestart() {
        updater?.installAndRestart()
    }

    @objc
    private func resetHUDPosition() {
        dictation?.resetHUDPosition()
    }

    @objc
    private func openCompanionWindow() {
        if companionWindow == nil {
            configureMainMenu()
            let store = CompanionStore()
            companionStore = store
            companionWindow = CompanionWindowController(
                store: store,
                onResetHUD: { [weak self] in self?.resetHUDPosition() },
                onUpdateAction: { [weak self] in self?.performCompanionUpdateAction() }
            )
        }
        companionWindow?.updateState = updateState
        companionWindow?.updaterAvailable = updater != nil || isCompanionPreview
        companionWindow?.show()
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "mbl")
        let quitItem = NSMenuItem(
            title: "Quit mbl", action: #selector(quit), keyEquivalent: "q"
        )
        quitItem.target = self
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(
            withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"
        )
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApplication.shared.mainMenu = mainMenu
        NSApplication.shared.windowsMenu = windowMenu
    }

    private func performCompanionUpdateAction() {
        if isCompanionPreview {
            if case .available = updateState {
                updateState = .ready
                companionWindow?.updateState = updateState
            }
            return
        }
        switch updateState {
        case .available:
            downloadUpdate()
        case .ready:
            installAndRestart()
        default:
            break
        }
    }

    @objc
    private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
