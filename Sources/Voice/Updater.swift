import Foundation
import Sparkle

@MainActor
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case available(version: String)
        case downloading
        case ready
        case upToDate
        case failed
    }

    private let driver: MenuUserDriver
    private let updater: SPUUpdater

    private(set) var state: State = .idle
    var onStateChange: ((State) -> Void)?
    var autoDownload = false {
        didSet { driver.autoDownload = autoDownload }
    }

    static func makeIfAvailable() -> Updater? {
        guard let feedURL = Bundle.main.object(
            forInfoDictionaryKey: "SUFeedURL"
        ) as? String,
            !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        let driver = MenuUserDriver()
        let sparkleUpdater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: driver,
            delegate: nil
        )
        let updater = Updater(driver: driver, updater: sparkleUpdater)

        do {
            try sparkleUpdater.start()
            // Releases are frequent at 0.x, so look for a new version at every
            // launch instead of waiting for the scheduled interval to elapse.
            sparkleUpdater.checkForUpdatesInBackground()
            return updater
        } catch {
            AppLog.write(
                "updater unavailable: \(error.localizedDescription)"
            )
            return nil
        }
    }

    private init(driver: MenuUserDriver, updater: SPUUpdater) {
        self.driver = driver
        self.updater = updater
        driver.onStateChange = { [weak self] state in
            guard let self else { return }
            self.state = state
            self.onStateChange?(state)
        }
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }

    func download() {
        driver.download()
    }

    func installAndRestart() {
        driver.installAndRestart()
    }
}

@MainActor
private final class MenuUserDriver: NSObject, SPUUserDriver {
    var onStateChange: ((Updater.State) -> Void)?
    var autoDownload = false

    private var state: Updater.State = .idle
    private var pendingChoice: CheckedContinuation<SPUUserUpdateChoice, Never>?
    private var resetTask: Task<Void, Never>?

    func show(
        _ request: SPUUpdatePermissionRequest
    ) async -> SUUpdatePermissionResponse {
        SUUpdatePermissionResponse(
            automaticUpdateChecks: true,
            sendSystemProfile: false
        )
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        setState(.checking)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) async -> SPUUserUpdateChoice {
        guard !appcastItem.isInformationOnlyUpdate else {
            return .dismiss
        }

        switch state.stage {
        case .notDownloaded:
            if autoDownload {
                setState(.downloading)
                return .install
            }
            setState(.available(version: appcastItem.displayVersionString))
        case .downloaded, .installing:
            setState(.ready)
        @unknown default:
            return .dismiss
        }

        return await withCheckedContinuation { continuation in
            replacePendingChoice(with: continuation)
        }
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        setState(.downloading)
    }

    func showDownloadDidReceiveExpectedContentLength(
        _ expectedContentLength: UInt64
    ) {
        setState(.downloading)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        setState(.downloading)
    }

    func showDownloadDidStartExtractingUpdate() {
        setState(.downloading)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        setState(.downloading)
    }

    func showReadyToInstallAndRelaunch() async -> SPUUserUpdateChoice {
        setState(.ready)
        return await withCheckedContinuation { continuation in
            replacePendingChoice(with: continuation)
        }
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {}

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool) async {}

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error) async {
        showTransientState(.upToDate)
    }

    func showUpdaterError(_ error: Error) async {
        AppLog.write("updater error: \(error.localizedDescription)")
        resolvePendingChoice(with: .dismiss)
        showTransientState(.failed)
    }

    func dismissUpdateInstallation() {
        resolvePendingChoice(with: .dismiss)
        setState(.idle)
    }

    func download() {
        resolvePendingChoice(with: .install)
    }

    func installAndRestart() {
        resolvePendingChoice(with: .install)
    }

    private func setState(_ newState: Updater.State) {
        guard state != newState else { return }
        resetTask?.cancel()
        resetTask = nil
        state = newState
        onStateChange?(newState)
    }

    private func showTransientState(_ transientState: Updater.State) {
        resetTask?.cancel()
        resetTask = nil
        setState(transientState)
        resetTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            guard let self, self.state == transientState else { return }
            self.setState(.idle)
        }
    }

    private func replacePendingChoice(
        with continuation: CheckedContinuation<SPUUserUpdateChoice, Never>
    ) {
        pendingChoice?.resume(returning: .dismiss)
        pendingChoice = continuation
    }

    private func resolvePendingChoice(with choice: SPUUserUpdateChoice) {
        let continuation = pendingChoice
        pendingChoice = nil
        continuation?.resume(returning: choice)
    }
}
