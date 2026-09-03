import FoundationModels
import Foundation

@main struct Probe {
    static func main() async throws {
        let instructions = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let tests = [
            "so the planreview upload er should like retry on a five oh three no wait on any five hundred um three times then give up",
            "um this is a test of immediate talking after um pressing key down to check that the the changes have worked",
            "we should recognize the color of the organization logo",
            "can you um make the button blue sorry green and move it to the the top right",
            "this is a test of recognition and changing the dictation to british english through luna I'm trying to see if this works um and feel if it's working reasonably fast",
        ]
        for raw in tests {
            let session = LanguageModelSession(instructions: instructions)
            let t0 = Date()
            let r = try await session.respond(to: raw, options: GenerationOptions(temperature: 0))
            print(String(format: "%.2fs  ", Date().timeIntervalSince(t0)) + r.content.replacingOccurrences(of: "\n", with: "⏎"))
        }
    }
}
