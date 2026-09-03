import Foundation

actor CodexCleaner: Cleaner {
    private struct StartedServer: Sendable {
        let rpc: AppServerRPC
        let notifications: AsyncStream<AppServerNotification>
        let threadID: String
        let instructionModificationDates: Prompts.ModificationDates
    }

    private struct StartedThread: Sendable {
        let id: String
        let instructionModificationDates: Prompts.ModificationDates
    }

    private struct TurnWaiter {
        let token: UUID
        let continuation: CheckedContinuation<String, Error>
    }

    private let config: Config
    private let configDirectory: URL
    private let cleanGate = AsyncGate()

    private var rpc: AppServerRPC?
    private var threadID: String?
    private var instructionModificationDates: Prompts.ModificationDates?
    private var turnCount = 0
    private var startup: (token: UUID, task: Task<StartedServer, Error>)?
    private var notificationTask: Task<Void, Never>?
    private var sessionToken: UUID?

    private var turnWaiters: [String: TurnWaiter] = [:]
    private var completedTurns: [String: Result<String, CodexCleanerError>] = [:]
    private var completedAgentMessages: [String: String] = [:]
    private var ignoredTurns: Set<String> = []

    init(config: Config, configDirectory: URL = Config.directoryURL) {
        self.config = config
        self.configDirectory = configDirectory
    }

    func start() async throws {
        try await ensureReady()
    }

    func clean(_ raw: String) async throws -> String {
        await cleanGate.acquire()
        do {
            try Task.checkCancellation()
            let result = try await cleanSerially(raw)
            await cleanGate.release()
            return result
        } catch {
            await cleanGate.release()
            throw error
        }
    }

    func shutdown() async {
        startup?.task.cancel()
        startup = nil
        notificationTask?.cancel()
        notificationTask = nil
        let activeRPC = clearSession()
        await activeRPC?.stop()
        failTurnWaiters(with: CodexCleanerError.stopped)
    }

    private func cleanSerially(_ raw: String) async throws -> String {
        try await ensureReady()
        try await rotateThreadIfNeeded()

        guard let rpc, let threadID else {
            throw CodexCleanerError.notReady
        }

        let response = try await rpc.request(
            method: "turn/start",
            params: .object([
                "threadId": .string(threadID),
                "input": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(raw),
                    ]),
                ]),
                "effort": .string("none"),
            ])
        )
        guard
            let turnID = response.objectValue?["turn"]?.objectValue?["id"]?.stringValue
        else {
            throw CodexCleanerError.invalidResponse(
                "turn/start returned no result.turn.id"
            )
        }
        turnCount += 1

        do {
            return try await awaitTurnCompletion(
                turnID: turnID,
                timeoutSeconds: config.cleanupTimeoutSeconds
            )
        } catch let error as CodexCleanerError {
            guard case .timeout = error else { throw error }
            ignoredTurns.insert(turnID)
            completedTurns.removeValue(forKey: turnID)
            completedAgentMessages.removeValue(forKey: turnID)
            await interrupt(turnID: turnID, threadID: threadID, rpc: rpc)
            throw error
        } catch is CancellationError {
            ignoredTurns.insert(turnID)
            completedTurns.removeValue(forKey: turnID)
            completedAgentMessages.removeValue(forKey: turnID)
            await interrupt(turnID: turnID, threadID: threadID, rpc: rpc)
            throw CancellationError()
        }
    }

    private func ensureReady() async throws {
        if let rpc, threadID != nil, await rpc.isRunning() {
            return
        }

        notificationTask?.cancel()
        notificationTask = nil
        _ = clearSession()

        let token: UUID
        let task: Task<StartedServer, Error>
        if let startup {
            token = startup.token
            task = startup.task
        } else {
            token = UUID()
            let config = self.config
            let directory = configDirectory
            task = Task {
                try await Self.launchServer(
                    config: config,
                    configDirectory: directory
                )
            }
            startup = (token, task)
        }

        let started: StartedServer
        do {
            started = try await task.value
        } catch {
            if startup?.token == token {
                startup = nil
            }
            throw error
        }

        if startup?.token == token {
            startup = nil
            install(started)
        }
        if let rpc, threadID != nil, await rpc.isRunning() {
            return
        }
        throw CodexCleanerError.notReady
    }

    private static func launchServer(
        config: Config,
        configDirectory: URL
    ) async throws -> StartedServer {
        let startedAt = ContinuousClock.now
        guard let binary = CodexBinary.resolve() else {
            throw CodexCleanerError.binaryNotFound
        }
        await AppLog.write(
            "codex binary found: \(binary.url.path) (\(binary.source))"
        )

        let rpc = AppServerRPC()
        do {
            try await rpc.start(
                executableURL: binary.url,
                currentDirectoryURL: configDirectory,
                environment: binary.environment
            )
            let notifications = await rpc.notifications()
            _ = try await rpc.request(
                method: "initialize",
                params: .object([
                    "clientInfo": .object([
                        "name": .string("voice"),
                        "version": .string("0.1"),
                    ]),
                    "capabilities": .object([
                        "experimentalApi": .bool(true),
                    ]),
                ])
            )
            try await rpc.notify(method: "initialized", params: .object([:]))
            let thread = try await startThread(
                rpc: rpc,
                config: config,
                configDirectory: configDirectory
            )
            await AppLog.write(
                "cleanup server started: duration="
                    + formatSeconds(startedAt.duration(to: .now))
                    + "s"
            )
            return StartedServer(
                rpc: rpc,
                notifications: notifications,
                threadID: thread.id,
                instructionModificationDates: thread.instructionModificationDates
            )
        } catch {
            await rpc.stop()
            throw error
        }
    }

    private static func startThread(
        rpc: AppServerRPC,
        config: Config,
        configDirectory: URL
    ) async throws -> StartedThread {
        let promptURL = Prompts.codexURL(
            for: config.codexModel,
            directoryURL: configDirectory
        )
        let instructions = try Prompts.instructions(
            at: promptURL,
            directoryURL: configDirectory
        )
        if instructions.vocabularyCount > 0 {
            await AppLog.write("vocab: \(instructions.vocabularyCount) terms")
        }

        let response = try await rpc.request(
            method: "thread/start",
            params: .object([
                "model": .string(config.codexModel),
                "cwd": .string(configDirectory.path),
                "approvalPolicy": .string("never"),
                "sandbox": .string("read-only"),
                "ephemeral": .bool(true),
                "dynamicTools": .array([]),
                "developerInstructions": .string(instructions.text),
            ])
        )
        guard
            let threadID = response.objectValue?["thread"]?.objectValue?["id"]?.stringValue
        else {
            throw CodexCleanerError.invalidResponse(
                "thread/start returned no result.thread.id"
            )
        }
        return StartedThread(
            id: threadID,
            instructionModificationDates: instructions.modificationDates
        )
    }

    private func install(_ started: StartedServer) {
        let token = UUID()
        rpc = started.rpc
        threadID = started.threadID
        instructionModificationDates = started.instructionModificationDates
        turnCount = 0
        sessionToken = token
        notificationTask?.cancel()
        notificationTask = Task { [weak self] in
            for await notification in started.notifications {
                guard !Task.isCancelled else { return }
                await self?.handle(notification)
            }
            guard !Task.isCancelled else { return }
            await self?.notificationStreamEnded(sessionToken: token)
        }
    }

    private func notificationStreamEnded(sessionToken: UUID) {
        guard self.sessionToken == sessionToken else { return }
        notificationTask = nil
        _ = clearSession()
        failTurnWaiters(with: .serverDisconnected)
    }

    private func rotateThreadIfNeeded() async throws {
        guard let rpc else { throw CodexCleanerError.notReady }

        let promptURL = Prompts.codexURL(
            for: config.codexModel,
            directoryURL: configDirectory
        )
        let currentModificationDates = Prompts.modificationDates(
            promptURL: promptURL,
            directoryURL: configDirectory
        )
        let reachedTurnLimit = turnCount >= max(config.codexThreadMaxTurns, 1)
        let instructionsChanged = currentModificationDates != instructionModificationDates
        guard reachedTurnLimit || instructionsChanged else { return }

        let reason = reachedTurnLimit ? "turn limit" : "prompt or vocabulary changed"
        await AppLog.write("cleanup thread rotating: \(reason)")
        let thread = try await Self.startThread(
            rpc: rpc,
            config: config,
            configDirectory: configDirectory
        )
        threadID = thread.id
        instructionModificationDates = thread.instructionModificationDates
        turnCount = 0
    }

    private func awaitTurnCompletion(
        turnID: String,
        timeoutSeconds: Int
    ) async throws -> String {
        let token = UUID()
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await self.waitForTurn(turnID: turnID, token: token)
            }
            group.addTask {
                if timeoutSeconds > 0 {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                }
                throw CodexCleanerError.timeout(seconds: timeoutSeconds)
            }

            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CodexCleanerError.invalidResponse(
                    "turn completion wait ended unexpectedly"
                )
            }
            return result
        }
    }

    private func waitForTurn(turnID: String, token: UUID) async throws -> String {
        if let result = completedTurns.removeValue(forKey: turnID) {
            return try result.get()
        }
        guard sessionToken != nil else {
            throw CodexCleanerError.serverDisconnected
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                turnWaiters[turnID] = TurnWaiter(
                    token: token,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task {
                await self.cancelTurnWaiter(turnID: turnID, token: token)
            }
        }
    }

    private func cancelTurnWaiter(turnID: String, token: UUID) {
        guard turnWaiters[turnID]?.token == token else { return }
        let waiter = turnWaiters.removeValue(forKey: turnID)
        waiter?.continuation.resume(throwing: CancellationError())
    }

    private func interrupt(
        turnID: String,
        threadID: String,
        rpc: AppServerRPC
    ) async {
        do {
            _ = try await rpc.request(
                method: "turn/interrupt",
                params: .object([
                    "threadId": .string(threadID),
                    "turnId": .string(turnID),
                ])
            )
        } catch {
            await AppLog.write(
                "cleanup turn interrupt failed: \(error.localizedDescription)"
            )
        }
    }

    private func handle(_ notification: AppServerNotification) async {
        switch notification.method {
        case "item/completed":
            handleItemCompleted(notification.params)
        case "turn/completed":
            handleTurnCompleted(notification.params)
        case "error":
            await AppLog.write(
                "codex app-server error notification: "
                    + notification.params.compactDescription
            )
        case "item/agentMessage/delta":
            break
        default:
            break
        }
    }

    private func handleItemCompleted(_ params: JSONValue) {
        guard
            let object = params.objectValue,
            let turnID = object["turnId"]?.stringValue,
            !ignoredTurns.contains(turnID),
            let item = object["item"]?.objectValue,
            item["type"]?.stringValue == "agentMessage",
            let text = item["text"]?.stringValue
        else {
            return
        }
        completedAgentMessages[turnID] = text
    }

    private func handleTurnCompleted(_ params: JSONValue) {
        guard
            let turn = params.objectValue?["turn"]?.objectValue,
            let turnID = turn["id"]?.stringValue
        else {
            return
        }
        if ignoredTurns.remove(turnID) != nil {
            completedAgentMessages.removeValue(forKey: turnID)
            return
        }

        let result: Result<String, CodexCleanerError>
        if turn["status"]?.stringValue != "completed" {
            result = .failure(.turnFailed(
                turn["error"]?.compactDescription ?? "unknown error"
            ))
        } else if let text = lastAgentMessage(in: turn)
                    ?? completedAgentMessages[turnID] {
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            result = cleaned.isEmpty
                ? .failure(.missingAgentMessage)
                : .success(cleaned)
        } else {
            result = .failure(.missingAgentMessage)
        }
        completedAgentMessages.removeValue(forKey: turnID)

        if let waiter = turnWaiters.removeValue(forKey: turnID) {
            waiter.continuation.resume(with: result.mapError { $0 as Error })
        } else {
            completedTurns[turnID] = result
        }
    }

    private func lastAgentMessage(in turn: [String: JSONValue]) -> String? {
        turn["items"]?.arrayValue?
            .compactMap { item -> String? in
                guard
                    let object = item.objectValue,
                    object["type"]?.stringValue == "agentMessage"
                else {
                    return nil
                }
                return object["text"]?.stringValue
            }
            .last
    }

    private func clearSession() -> AppServerRPC? {
        let activeRPC = rpc
        rpc = nil
        threadID = nil
        instructionModificationDates = nil
        sessionToken = nil
        turnCount = 0
        return activeRPC
    }

    private func failTurnWaiters(with error: CodexCleanerError) {
        let waiters = turnWaiters.values
        turnWaiters.removeAll()
        completedTurns.removeAll()
        completedAgentMessages.removeAll()
        ignoredTurns.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(throwing: error)
        }
    }

    private static func formatSeconds(_ duration: Duration) -> String {
        let parts = duration.components
        let seconds = Double(parts.seconds)
            + Double(parts.attoseconds) / 1_000_000_000_000_000_000
        return String(format: "%.3f", seconds)
    }
}

private actor AsyncGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

enum CodexCleanerError: LocalizedError, Sendable {
    case binaryNotFound
    case notReady
    case invalidResponse(String)
    case turnFailed(String)
    case missingAgentMessage
    case timeout(seconds: Int)
    case serverDisconnected
    case stopped

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            "Codex binary not found. Checked the configured pnpm path, PATH, and common install locations."
        case .notReady:
            "Codex cleaner is not ready."
        case let .invalidResponse(detail):
            "Invalid Codex app-server response: \(detail)"
        case let .turnFailed(detail):
            "Codex cleanup turn failed: \(detail)"
        case .missingAgentMessage:
            "Codex cleanup turn completed without an agent message."
        case let .timeout(seconds):
            "Codex cleanup timed out after \(seconds) seconds."
        case .serverDisconnected:
            "Codex app-server disconnected during cleanup."
        case .stopped:
            "Codex cleaner stopped."
        }
    }
}
