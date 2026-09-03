import Foundation
import FluidAudio

actor Transcriber {
    private var manager: AsrManager?

    func load() async throws {
        guard manager == nil else {
            return
        }

        let models = try await AsrModels.downloadAndLoad(version: .v2)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager

        // TODO: FluidAudio 0.15.6 has no public AsrManager keyterm/custom-vocabulary API.
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else {
            throw TranscriberError.notReady
        }
        guard samples.count >= 4_800 else {
            throw TranscriberError.audioTooShort
        }

        let decoderLayers = await manager.decoderLayerCount
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(
            samples,
            decoderState: &decoderState
        )
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func runSelfTest(at url: URL) async throws -> SelfTestResult {
        let conversionStarted = Date()
        let samples = try AudioConverter().resampleAudioFile(url)
        let conversionSeconds = Date().timeIntervalSince(conversionStarted)

        let transcriptionStarted = Date()
        let text = try await transcribe(samples)
        let transcriptionSeconds = Date().timeIntervalSince(transcriptionStarted)

        return SelfTestResult(
            text: text,
            audioSeconds: Double(samples.count) / 16_000,
            conversionSeconds: conversionSeconds,
            transcriptionSeconds: transcriptionSeconds
        )
    }
}

struct SelfTestResult: Sendable {
    let text: String
    let audioSeconds: Double
    let conversionSeconds: TimeInterval
    let transcriptionSeconds: TimeInterval
}

enum TranscriberError: LocalizedError {
    case notReady
    case audioTooShort

    var errorDescription: String? {
        switch self {
        case .notReady:
            "The speech model is not ready."
        case .audioTooShort:
            "The recording is too short to transcribe."
        }
    }
}
