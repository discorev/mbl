import Foundation

struct TextReplacement: Codable, Equatable, Sendable, Identifiable {
    var phrase: String
    var replacement: String
    var id: String { phrase }
}

enum Replacements {
    static func load(directoryURL: URL = Config.directoryURL) throws -> [TextReplacement] {
        try Vocabulary.load(directoryURL: directoryURL).replacements
    }

    static func validate(_ rules: [TextReplacement]) throws {
        var seen = Set<String>()
        for rule in rules {
            guard !rule.phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !rule.phrase.contains(where: \.isNewline),
                  seen.insert(rule.phrase.lowercased()).inserted else {
                throw CompanionStoreError.invalid("Replacement phrases must be nonempty, unique (ignoring case), and on one line.")
            }
        }
    }

    static func apply(_ rules: [TextReplacement], to text: String) -> String {
        // Match the original text once: inserted text is never interpreted as another rule.
        let ordered = rules.enumerated().sorted {
            $0.element.phrase.count == $1.element.phrase.count
                ? $0.offset < $1.offset : $0.element.phrase.count > $1.element.phrase.count
        }.map(\.element).filter { !$0.phrase.isEmpty }
        guard !ordered.isEmpty else { return text }
        let alternatives = ordered.map {
            "(" + NSRegularExpression.escapedPattern(for: $0.phrase) + ")"
        }.joined(separator: "|")
        guard let regex = try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{M}\\p{N}_])(?:" + alternatives + ")(?![\\p{L}\\p{M}\\p{N}_])",
            options: [.caseInsensitive]
        ) else { return text }
        let result = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let index = ordered.indices.first(where: { match.range(at: $0 + 1).location != NSNotFound }) else { continue }
            result.replaceCharacters(in: match.range, with: ordered[index].replacement)
        }
        return result as String
    }

    static func apply(_ rules: [TextReplacement], to result: CleanupResult) -> CleanupResult {
        let output = apply(rules, to: result.output)
        return CleanupResult(output: output,
            cleaned: output != result.output ? output : result.cleaned,
            backend: result.backend, fallback: result.fallback,
            duration: result.duration, error: result.error)
    }
}
