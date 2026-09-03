import Foundation

@MainActor
final class DictationController {
    private let recorder: Recorder
    private let transcriber: Transcriber
    private let codexCleaner: CodexCleaner
    private let localCleaner: LocalCleaner
    private let typist: Typist
    private let hud: HUD
    private let onListeningChanged: (Bool) -> Void

    private var config: Config
    private var modelLoadTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var finalTask: Task<Void, Never>?
    private var previewTimer: Timer?
    private var levelTimer: Timer?
    private var peakRMS: Float = 0

    private var modelsReady = false
    private var isHolding = false
    private var isRecording = false
    private var utteranceID = 0
    private var finalTaskGeneration = 0
    private var latestPreviewText = ""

    init(
        recorder: Recorder,
        transcriber: Transcriber,
        codexCleaner: CodexCleaner,
        localCleaner: LocalCleaner,
        typist: Typist,
        hud: HUD,
        config: Config,
        onListeningChanged: @escaping (Bool) -> Void
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.codexCleaner = codexCleaner
        self.localCleaner = localCleaner
        self.typist = typist
        self.hud = hud
        self.config = config
        self.onListeningChanged = onListeningChanged
    }

    func setModelLoadTask(_ task: Task<Void, Never>) {
        modelLoadTask = task
    }

    func setModelsReady(_ ready: Bool) {
        modelsReady = ready
    }

    func hold() {
        guard !isHolding else {
            return
        }

        finalTask?.cancel()
        reloadConfig()

        utteranceID += 1
        latestPreviewText = ""
        isHolding = true
        onListeningChanged(true)
        hud.show(state: .listening)
        AppLog.write("hold")

        do {
            try recorder.start()
            isRecording = true
            checkInputVolume()
            startPreviewTimer()
            startLevelTimer()
        } catch {
            isHolding = false
            isRecording = false
            onListeningChanged(false)
            AppLog.write("unable to start recording: \(error.localizedDescription)")
            hud.update(state: .done, text: "Microphone unavailable")
            hud.dismissAfterPaste()
        }
    }

    func release() {
        guard isHolding else {
            return
        }

        isHolding = false
        isRecording = false
        stopPreviewTimer()
        stopLevelTimer()
        onListeningChanged(false)

        let sessionID = utteranceID
        let samples = recorder.stop()
        let audioSeconds = Double(samples.count) / 16_000
        AppLog.write("release: captured \(formatSeconds(audioSeconds))s of audio")
        hud.update(state: .transcribing, text: latestPreviewText)

        let activePreview = previewTask
        activePreview?.cancel()

        guard samples.count >= 4_800 else {
            AppLog.write("recording too short to transcribe")
            hud.update(state: .done, text: "No speech detected")
            hud.dismissAfterPaste()
            return
        }

        let previousFinal = finalTask
        previousFinal?.cancel()
        let loading = modelLoadTask
        finalTaskGeneration += 1
        let generation = finalTaskGeneration

        finalTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                if self.finalTaskGeneration == generation {
                    self.finalTask = nil
                }
            }

            await previousFinal?.value
            await activePreview?.value
            await loading?.value

            guard !Task.isCancelled, self.utteranceID == sessionID else {
                return
            }
            guard self.modelsReady else {
                AppLog.write("final transcription skipped: speech model unavailable")
                self.hud.update(state: .done, text: "Speech model unavailable")
                self.hud.dismissAfterPaste()
                return
            }

            await self.transcribeFinal(samples, audioSeconds: audioSeconds, sessionID: sessionID)
        }
    }

    func cancel() {
        guard isHolding else {
            return
        }

        isHolding = false
        isRecording = false
        stopPreviewTimer()
        stopLevelTimer()
        previewTask?.cancel()
        recorder.cancel()
        latestPreviewText = ""
        onListeningChanged(false)
        hud.hide()
        AppLog.write("cancel")
    }

    func resetHUDPosition() {
        hud.resetPosition()
    }

    func userDidType(keyCode: Int64) {
        typist.userDidType(keyCode: keyCode)
    }

    func prewarmRecorder() {
        recorder.prewarm()
    }

    func shutdown() {
        stopPreviewTimer()
        stopLevelTimer()
        previewTask?.cancel()
        finalTask?.cancel()
        recorder.cancel()
    }

    private func reloadConfig() {
        do {
            config = try Config.load()
            hud.update(bottomInset: CGFloat(config.hudBottomInset))
        } catch {
            AppLog.write(
                "Unable to reload config; keeping previous values: "
                    + error.localizedDescription
            )
        }
    }

    private func transcribeFinal(
        _ samples: [Float],
        audioSeconds: TimeInterval,
        sessionID: Int
    ) async {
        let started = Date()
        do {
            let text = try await transcriber.transcribe(samples)
            let transcribeDuration = Date().timeIntervalSince(started)
            AppLog.write(
                "final transcribe: audio=\(formatSeconds(audioSeconds))s "
                    + "duration=\(formatSeconds(transcribeDuration))s"
            )

            guard !Task.isCancelled, utteranceID == sessionID else {
                return
            }

            let wordCount = text.split(whereSeparator: \.isWhitespace).count
            if wordCount >= config.minWordsForCleanup {
                hud.update(state: .cleaning, text: text)
                AppLog.write("raw: \(text)")
            }

            let result = await CleanupPipeline.run(
                raw: text,
                config: config,
                codex: codexCleaner,
                local: localCleaner
            )
            guard !Task.isCancelled, utteranceID == sessionID else {
                return
            }

            switch result.backend {
            case .codex:
                hud.update(state: .done, text: result.output)
            case .local:
                hud.update(state: .cleanedLocally, text: result.output)
            case .raw:
                hud.update(
                    state: .done,
                    text: result.output,
                    showsWarning: result.error != nil
                )
            }

            let delivery = typist.deliver(result.output)
            appendHistory(
                audioSeconds: audioSeconds,
                raw: text,
                result: result,
                transcribeDuration: transcribeDuration
            )
            handleDelivery(
                delivery,
                transcriptKind: result.backend == .raw ? "raw" : "cleaned"
            )
        } catch {
            guard !Task.isCancelled, utteranceID == sessionID else {
                return
            }
            AppLog.write(
                "final transcription failed after "
                    + formatSeconds(Date().timeIntervalSince(started))
                    + "s: \(error.localizedDescription)"
            )
            hud.update(state: .done, text: "Transcription failed")
            hud.dismissAfterPaste()
        }
    }

    private func appendHistory(
        audioSeconds: TimeInterval,
        raw: String,
        result: CleanupResult,
        transcribeDuration: TimeInterval
    ) {
        do {
            try History.append(
                HistoryEntry(
                    audioSeconds: audioSeconds,
                    raw: raw,
                    result: result,
                    transcribeDuration: transcribeDuration
                )
            )
        } catch {
            AppLog.write("history append failed: \(error.localizedDescription)")
        }
    }

    private func handleDelivery(
        _ delivery: TypeDelivery,
        transcriptKind: String
    ) {
        switch delivery {
        case .nothing:
            AppLog.write("empty transcript; nothing typed")
            hud.update(state: .done, text: "No speech detected")
        case .typed:
            AppLog.write("\(transcriptKind) transcript typed")
        case .accessibilityRequired:
            hud.update(state: .done, text: "Grant Accessibility to type")
        case .eventUnavailable:
            hud.update(state: .done, text: "Could not type transcript")
        }
        hud.dismissAfterPaste()
    }

    private func checkInputVolume() {
        guard let volume = InputDevice.inputVolume() else {
            AppLog.write("input volume: unavailable")
            return
        }

        AppLog.write("input volume: \(String(format: "%.2f", volume))")
        guard volume < config.minInputVolume else {
            return
        }

        let percentage = Int((volume * 100).rounded())
        AppLog.write(
            "warning: input volume \(String(format: "%.2f", volume)) is below "
                + "minimum \(String(format: "%.2f", config.minInputVolume))"
        )
        hud.update(
            state: .listening,
            text: "Mic input is at \(percentage)% — raise it in System Settings › Sound"
        )
    }

    private func startPreviewTimer() {
        stopPreviewTimer()
        let interval = Double(max(config.previewTickMs, 100)) / 1_000
        let timer = Timer(
            timeInterval: interval,
            target: self,
            selector: #selector(previewTick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        previewTimer = timer
    }

    private func stopPreviewTimer() {
        previewTimer?.invalidate()
        previewTimer = nil
    }

    private func startLevelTimer() {
        stopLevelTimer()
        hud.setLevel(0)
        let timer = Timer(
            timeInterval: 1.0 / 30.0,
            target: self,
            selector: #selector(levelTick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
        hud.setLevel(0)
        if peakRMS > 0 {
            AppLog.write("level: peak rms=\(String(format: "%.4f", peakRMS))")
            peakRMS = 0
        }
    }

    @objc
    private func levelTick() {
        guard isHolding, isRecording else {
            return
        }
        let rms = recorder.recentLevel()
        peakRMS = max(peakRMS, rms)
        hud.setLevel(Self.normaliseLevel(rms))
    }

    @objc
    private func previewTick() {
        guard
            isHolding,
            isRecording,
            modelsReady,
            previewTask == nil,
            finalTask == nil
        else {
            return
        }

        let samples = recorder.snapshot()
        guard samples.count >= 4_800, SpeechGate.containsSpeech(samples) else {
            return
        }

        let sessionID = utteranceID
        let audioSeconds = Double(samples.count) / 16_000
        previewTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                self.previewTask = nil
            }

            let started = Date()
            do {
                let text = try await self.transcriber.transcribe(samples)
                AppLog.write(
                    "preview transcribe: audio=\(self.formatSeconds(audioSeconds))s "
                        + "duration=\(self.formatSeconds(Date().timeIntervalSince(started)))s"
                )

                guard
                    !Task.isCancelled,
                    self.isHolding,
                    self.utteranceID == sessionID
                else {
                    return
                }
                self.latestPreviewText = text
                self.hud.update(state: .listening, text: text)
            } catch {
                if !Task.isCancelled {
                    AppLog.write(
                        "preview transcription failed: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    /// Map mic RMS to 0...1 on a log scale so quiet speech still moves the
    /// indicator. Tuned on a MacBook Air mic at 75% input: -52 dBFS -> 0,
    /// -26 dBFS (a firm syllable) -> 1.
    private static func normaliseLevel(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db + 52) / 26))
    }

    private func formatSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.3f", seconds)
    }
}
