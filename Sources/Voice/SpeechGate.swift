import Foundation

/// Cheap energy check so previews are not run on silence, where the speech
/// model tends to hallucinate short fillers like "mm-hmm".
enum SpeechGate {
    /// RMS threshold on 16 kHz float samples; room noise sits well below this.
    private static let rmsThreshold: Float = 0.01
    static let rmsWindowSize = 1_600  // 100 ms

    static func containsSpeech(_ samples: [Float]) -> Bool {
        var index = 0
        while index + rmsWindowSize <= samples.count {
            let window = samples[index..<index + rmsWindowSize]
            if rms(window) >= rmsThreshold {
                return true
            }
            index += rmsWindowSize
        }
        return false
    }

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else {
            return 0
        }

        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return (sum / Float(samples.count)).squareRoot()
    }
}
