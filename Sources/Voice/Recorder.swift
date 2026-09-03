import AVFoundation
import os

@MainActor
final class Recorder {
    private let engine = AVAudioEngine()
    private let accumulator = AudioAccumulator()
    private var converter: AudioInputConverter?
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

        let converter = try AudioInputConverter(inputFormat: inputFormat)
        self.converter = converter
        input.installTap(
            onBus: 0,
            bufferSize: 2_048,
            format: inputFormat
        ) { [accumulator, converter] buffer, _ in
            do {
                accumulator.append(try converter.convert(buffer))
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
            self.converter = nil
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
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.reset()
        isRecording = false

        if let converter {
            do {
                accumulator.append(try converter.finish())
            } catch {
                accumulator.record(error)
            }
        }
        converter = nil
    }
}

enum RecorderError: LocalizedError {
    case inputUnavailable
    case converterUnavailable
    case outputBufferUnavailable
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .inputUnavailable:
            "No microphone input is available."
        case .converterUnavailable:
            "The microphone audio format could not be converted."
        case .outputBufferUnavailable:
            "An audio conversion buffer could not be created."
        case .conversionFailed(let message):
            "Audio conversion failed: \(message)"
        }
    }
}

private final class AudioInputConverter: Sendable {
    private static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private let converter: AVAudioConverter
    private let inputSampleRate: Double

    init(inputFormat: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(
            from: inputFormat,
            to: Self.outputFormat
        ) else {
            throw RecorderError.converterUnavailable
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        self.converter = converter
        inputSampleRate = inputFormat.sampleRate
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> [Float] {
        let ratio = Self.outputFormat.sampleRate / inputSampleRate
        let estimatedFrames = ceil(Double(input.frameLength) * ratio)
        let capacity = AVAudioFrameCount(max(4_096, estimatedFrames + 64))
        let supplied = OSAllocatedUnfairLock(initialState: false)
        let audioBuffer = SendableAudioBuffer(input)

        return try convert(capacity: capacity) { _, status in
            let wasSupplied = supplied.withLock { supplied in
                defer { supplied = true }
                return supplied
            }
            if wasSupplied {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return audioBuffer.value
        }
    }

    func finish() throws -> [Float] {
        var samples: [Float] = []
        while true {
            let (status, output) = try convertWithStatus(capacity: 4_096) {
                _, status in
                status.pointee = .endOfStream
                return nil
            }
            samples.append(contentsOf: output)
            if status == .endOfStream || output.isEmpty {
                return samples
            }
        }
    }

    private func convert(
        capacity: AVAudioFrameCount,
        inputBlock: @escaping AVAudioConverterInputBlock
    ) throws -> [Float] {
        let (_, samples) = try convertWithStatus(
            capacity: capacity,
            inputBlock: inputBlock
        )
        return samples
    }

    private func convertWithStatus(
        capacity: AVAudioFrameCount,
        inputBlock: @escaping AVAudioConverterInputBlock
    ) throws -> (AVAudioConverterOutputStatus, [Float]) {
        guard let output = AVAudioPCMBuffer(
            pcmFormat: Self.outputFormat,
            frameCapacity: capacity
        ) else {
            throw RecorderError.outputBufferUnavailable
        }

        var error: NSError?
        let status = converter.convert(
            to: output,
            error: &error,
            withInputFrom: inputBlock
        )
        if status == .error {
            throw RecorderError.conversionFailed(
                error?.localizedDescription ?? "unknown error"
            )
        }

        guard let channel = output.floatChannelData?[0] else {
            throw RecorderError.outputBufferUnavailable
        }
        let samples = Array(
            UnsafeBufferPointer(
                start: channel,
                count: Int(output.frameLength)
            )
        )
        return (status, samples)
    }
}

/// AVAudioConverterInputBlock is @Sendable but synchronously borrows this Objective-C buffer.
/// The wrapper never outlives AudioInputConverter.convert(_:).
private struct SendableAudioBuffer: @unchecked Sendable {
    let value: AVAudioPCMBuffer

    init(_ value: AVAudioPCMBuffer) {
        self.value = value
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
        state.withLock { $0.samples.append(contentsOf: samples) }
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
