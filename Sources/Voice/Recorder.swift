import AVFoundation
import FluidAudio
import os

@MainActor
final class Recorder {
    private let engine = AVAudioEngine()
    private let accumulator = AudioAccumulator()
    private var isRecording = false

    func start() throws {
        guard !isRecording else {
            return
        }

        accumulator.reset()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.inputUnavailable
        }

        let converter = AudioConverter()
        input.installTap(
            onBus: 0,
            bufferSize: 2_048,
            format: inputFormat
        ) { [accumulator] buffer, _ in
            do {
                let samples = try converter.resampleBuffer(buffer)
                accumulator.append(samples)
            } catch {
                accumulator.record(error)
            }
        }

        engine.prepare()
        do {
            try engine.start()
            isRecording = true
        } catch {
            input.removeTap(onBus: 0)
            accumulator.reset()
            throw error
        }
    }

    func snapshot() -> [Float] {
        accumulator.snapshot()
    }

    func stop() -> [Float] {
        guard isRecording else {
            return []
        }

        finishCapture()
        let capture = accumulator.consume()
        if let conversionError = capture.conversionError {
            AppLog.write("audio conversion failed: \(conversionError)")
        }
        return capture.samples
    }

    func cancel() {
        if isRecording {
            finishCapture()
        }
        accumulator.reset()
    }

    private func finishCapture() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        isRecording = false
    }
}

enum RecorderError: LocalizedError {
    case inputUnavailable

    var errorDescription: String? {
        switch self {
        case .inputUnavailable:
            "No microphone input is available."
        }
    }
}

private struct AudioCapture: Sendable {
    let samples: [Float]
    let conversionError: String?
}

private final class AudioAccumulator: Sendable {
    private struct State: Sendable {
        var samples: [Float] = []
        var conversionError: String?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func append(_ samples: [Float]) {
        state.withLock { state in
            state.samples.append(contentsOf: samples)
        }
    }

    func record(_ error: Error) {
        state.withLock { state in
            if state.conversionError == nil {
                state.conversionError = error.localizedDescription
            }
        }
    }

    func snapshot() -> [Float] {
        state.withLock { $0.samples }
    }

    func consume() -> AudioCapture {
        state.withLock { state in
            let capture = AudioCapture(
                samples: state.samples,
                conversionError: state.conversionError
            )
            state = State()
            return capture
        }
    }

    func reset() {
        state.withLock { $0 = State() }
    }
}
