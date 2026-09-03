import Foundation

enum TranscriptBackend: String, Codable, Sendable {
    case codex
    case local
    case raw
}

struct CleanupResult: Sendable {
    let output: String
    let cleaned: String?
    let backend: TranscriptBackend
    let fallback: Bool
    let duration: TimeInterval?
    let error: String?
}

enum CleanupPipeline {
    static func run(
        raw: String,
        config: Config,
        codex: CodexCleaner,
        local: LocalCleaner
    ) async -> CleanupResult {
        let wordCount = raw.split(whereSeparator: \.isWhitespace).count
        guard wordCount >= config.minWordsForCleanup else {
            return rawResult(raw)
        }

        switch config.backend {
        case .local:
            return await runLocal(raw: raw, local: local)
        case .codex:
            return await runCodex(
                raw: raw,
                fallback: config.fallback,
                codex: codex,
                local: local
            )
        }
    }

    private static func runLocal(
        raw: String,
        local: LocalCleaner
    ) async -> CleanupResult {
        guard local.isAvailable else {
            let error = "Local language model \(local.availabilityDescription)"
            await AppLog.write("\(error); typing raw transcript")
            return rawResult(raw, error: error)
        }

        let started = Date()
        do {
            let cleaned = try await local.clean(raw)
            let duration = Date().timeIntervalSince(started)
            await AppLog.write(
                "cleanup: local duration=\(formatSeconds(duration))s"
            )
            await AppLog.write("cleaned: \(cleaned)")
            return CleanupResult(
                output: cleaned,
                cleaned: cleaned,
                backend: .local,
                fallback: false,
                duration: duration,
                error: nil
            )
        } catch {
            let duration = Date().timeIntervalSince(started)
            await AppLog.write(
                "local cleanup failed after \(formatSeconds(duration))s: "
                    + error.localizedDescription
                    + "; typing raw transcript"
            )
            return rawResult(
                raw,
                duration: duration,
                error: error.localizedDescription
            )
        }
    }

    private static func runCodex(
        raw: String,
        fallback: CleanupFallback,
        codex: CodexCleaner,
        local: LocalCleaner
    ) async -> CleanupResult {
        let started = Date()
        do {
            let cleaned = try await codex.clean(raw)
            let duration = Date().timeIntervalSince(started)
            await AppLog.write("cleanup: duration=\(formatSeconds(duration))s")
            await AppLog.write("cleaned: \(cleaned)")
            return CleanupResult(
                output: cleaned,
                cleaned: cleaned,
                backend: .codex,
                fallback: false,
                duration: duration,
                error: nil
            )
        } catch {
            let codexError = error.localizedDescription
            if fallback == .none {
                let duration = Date().timeIntervalSince(started)
                await AppLog.write(
                    "cleanup failed after \(formatSeconds(duration))s: "
                        + codexError
                        + "; typing raw transcript"
                )
                return rawResult(
                    raw,
                    duration: duration,
                    error: codexError
                )
            }
            guard local.isAvailable else {
                let duration = Date().timeIntervalSince(started)
                let localError = "Local language model \(local.availabilityDescription)"
                await AppLog.write(
                    "cleanup fallback unavailable after \(formatSeconds(duration))s: "
                        + localError
                        + "; typing raw transcript"
                )
                return rawResult(
                    raw,
                    duration: duration,
                    error: "Codex: \(codexError); local: \(localError)"
                )
            }

            let fallbackStarted = Date()
            do {
                let cleaned = try await local.clean(raw)
                let fallbackDuration = Date().timeIntervalSince(fallbackStarted)
                await AppLog.write(
                    "cleanup fallback: local duration="
                        + "\(formatSeconds(fallbackDuration))s"
                )
                await AppLog.write("cleaned: \(cleaned)")
                return CleanupResult(
                    output: cleaned,
                    cleaned: cleaned,
                    backend: .local,
                    fallback: true,
                    duration: Date().timeIntervalSince(started),
                    error: codexError
                )
            } catch {
                let localError = error.localizedDescription
                let duration = Date().timeIntervalSince(started)
                await AppLog.write(
                    "cleanup fallback failed after \(formatSeconds(duration))s: "
                        + localError
                        + "; typing raw transcript"
                )
                return rawResult(
                    raw,
                    fallback: true,
                    duration: duration,
                    error: "Codex: \(codexError); local: \(localError)"
                )
            }
        }
    }

    private static func rawResult(
        _ raw: String,
        fallback: Bool = false,
        duration: TimeInterval? = nil,
        error: String? = nil
    ) -> CleanupResult {
        CleanupResult(
            output: raw,
            cleaned: nil,
            backend: .raw,
            fallback: fallback,
            duration: duration,
            error: error
        )
    }

    private static func formatSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.3f", seconds)
    }
}
