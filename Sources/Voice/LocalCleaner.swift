import Foundation
import FoundationModels

struct LocalCleaner: Cleaner {
    let configDirectory: URL

    init(configDirectory: URL = Config.directoryURL) {
        self.configDirectory = configDirectory
    }

    var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    var availabilityDescription: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            "available"
        case .unavailable(let reason):
            "unavailable reason=\(reason)"
        }
    }

    @MainActor
    func logAvailability() {
        switch SystemLanguageModel.default.availability {
        case .available:
            AppLog.write("local cleanup model: available")
        case .unavailable(let reason):
            AppLog.write("local cleanup model: unavailable reason=\(reason)")
        }
    }

    func clean(_ raw: String) async throws -> String {
        guard case .available = SystemLanguageModel.default.availability else {
            throw LocalCleanerError.unavailable(
                SystemLanguageModel.default.availability
            )
        }

        let location = try Prompts.localLocation(directoryURL: configDirectory)
        if location.selectedKey != location.requestedKey {
            await AppLog.write(
                "local prompt fallback: requested=\(location.requestedKey) "
                    + "using=prompts/\(location.selectedKey).md"
            )
        }
        let instructions = try String(contentsOf: location.url, encoding: .utf8)
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: raw,
            options: GenerationOptions(temperature: 0)
        )
        let cleaned = postProcess(response.content)
        if cleaned != response.content {
            await AppLog.write("local cleanup post-processing changed output")
        }
        return cleaned
    }

    private func postProcess(_ output: String) -> String {
        var result = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 1,
           lines[0].trimmingCharacters(in: .whitespaces).hasSuffix(":") {
            result = lines.dropFirst().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if result.count >= 2 {
            let first = result.first
            let last = result.last
            if (first == "\"" && last == "\"")
                || (first == "“" && last == "”") {
                result.removeFirst()
                result.removeLast()
                result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return result
    }
}

enum LocalCleanerError: LocalizedError {
    case unavailable(SystemLanguageModel.Availability)

    var errorDescription: String? {
        switch self {
        case .unavailable(let availability):
            "Local language model unavailable: \(availability)"
        }
    }
}
