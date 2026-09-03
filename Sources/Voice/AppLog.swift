import Foundation

@MainActor
enum AppLog {
    private static let fileURL = URL(fileURLWithPath: "/tmp/voice.log")

    static func startSession(truncate: Bool = true) {
        if truncate {
            try? Data().write(to: fileURL)
        }
        write(truncate ? "Voice started" : "Voice self-test started")
    }

    static func write(_ message: String) {
        let data = Data("\(message)\n".utf8)
        try? FileHandle.standardError.write(contentsOf: data)

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            return
        }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
    }
}
