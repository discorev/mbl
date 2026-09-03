import Darwin
import Dispatch
import Foundation

@MainActor
final class ConfigWatcher {
    private let directoryURL: URL
    private let onChange: () -> Void

    private var source: DispatchSourceFileSystemObject?
    private var debounceTask: Task<Void, Never>?

    init(
        directoryURL: URL = Config.directoryURL,
        onChange: @escaping () -> Void
    ) {
        self.directoryURL = directoryURL
        self.onChange = onChange
    }

    func start() {
        guard source == nil else {
            return
        }

        let fileDescriptor = open(directoryURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            AppLog.write(
                "config watcher failed to start: \(String(cString: strerror(errno)))"
            )
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleChange()
        }
        source.setCancelHandler {
            close(fileDescriptor)
        }
        self.source = source
        source.resume()
        AppLog.write("config watcher started: \(directoryURL.path)")
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        source?.cancel()
        source = nil
    }

    private func scheduleChange() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            self?.onChange()
        }
    }
}
