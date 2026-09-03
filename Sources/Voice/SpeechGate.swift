import Foundation

/// Cheap energy check so previews are not run on silence, where the speech
/// model tends to hallucinate short fillers like "mm-hmm".
enum SpeechGate {
    /// RMS threshold on 16 kHz float samples; room noise sits well below this.
    private static let rmsThreshold: Float = 0.01
    private static let windowSize = 1_600  // 100 ms

    static func containsSpeech(_ samples: [Float]) -> Bool {
        var index = 0
        while index + windowSize <= samples.count {
            var sum: Float = 0
            for sample in samples[index..<index + windowSize] {
                sum += sample * sample
            }
            if (sum / Float(windowSize)).squareRoot() >= rmsThreshold {
                return true
            }
            index += windowSize
        }
        return false
    }
}
