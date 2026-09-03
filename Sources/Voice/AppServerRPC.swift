import Foundation

/// The JSON values accepted and returned by the Codex app-server boundary.
enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(jsonObject: Any) throws {
        switch jsonObject {
        case is NSNull:
            self = .null
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        case let value as String:
            self = .string(value)
        case let values as [Any]:
            self = .array(try values.map(JSONValue.init(jsonObject:)))
        case let values as [String: Any]:
            self = .object(
                try values.mapValues(JSONValue.init(jsonObject:))
            )
        default:
            throw AppServerRPCError.invalidJSON(
                "Unsupported JSON value: \(type(of: jsonObject))"
            )
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var integerValue: Int? {
        guard case let .number(value) = self, value.rounded() == value else {
            return nil
        }
        return Int(exactly: value)
    }

    var compactDescription: String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: foundationObject,
                options: [.sortedKeys]
            ),
            let text = String(data: data, encoding: .utf8)
        else {
            return String(describing: self)
        }
        return text
    }

    fileprivate var foundationObject: Any {
        switch self {
        case .null:
            NSNull()
        case let .bool(value):
            value
        case let .number(value):
            value
        case let .string(value):
            value
        case let .array(values):
            values.map(\.foundationObject)
        case let .object(values):
            values.mapValues(\.foundationObject)
        }
    }
}

struct AppServerNotification: Sendable {
    let method: String
    let params: JSONValue
}

actor AppServerRPC {
    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<JSONValue, Error>
    }

    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var outputBuffer = Data()
    private var errorBuffer = Data()
    private var generation = 0
    private var nextRequestID = 1
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var notificationContinuations: [
        UUID: AsyncStream<AppServerNotification>.Continuation
    ] = [:]

    deinit {
        if let process, process.isRunning {
            process.terminate()
        }
    }

    func start(executableURL: URL, currentDirectoryURL: URL) throws {
        guard process == nil else {
            throw AppServerRPCError.alreadyRunning
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = ["app-server"]
        process.currentDirectoryURL = currentDirectoryURL
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        generation += 1
        let activeGeneration = generation
        process.terminationHandler = { [weak self] terminatedProcess in
            let status = terminatedProcess.terminationStatus
            Task {
                await self?.processExited(
                    generation: activeGeneration,
                    status: status
                )
            }
        }

        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            throw AppServerRPCError.launchFailed(error.localizedDescription)
        }

        self.process = process
        inputHandle = inputPipe.fileHandleForWriting
        self.outputHandle = outputHandle
        self.errorHandle = errorHandle
        outputBuffer.removeAll(keepingCapacity: true)
        errorBuffer.removeAll(keepingCapacity: true)
        startPipeReader(
            handle: outputHandle,
            generation: activeGeneration,
            isStandardError: false
        )
        startPipeReader(
            handle: errorHandle,
            generation: activeGeneration,
            isStandardError: true
        )
    }

    func isRunning() -> Bool {
        process?.isRunning == true
    }

    func notifications() -> AsyncStream<AppServerNotification> {
        let identifier = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            notificationContinuations[identifier] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task {
                    await self?.removeNotificationContinuation(identifier)
                }
            }
        }
    }

    func request(method: String, params: JSONValue) async throws -> JSONValue {
        guard process?.isRunning == true else {
            throw AppServerRPCError.notRunning
        }

        let requestID = nextRequestID
        nextRequestID += 1
        let message: JSONValue = .object([
            "method": .string(method),
            "id": .number(Double(requestID)),
            "params": params,
        ])

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = PendingRequest(
                method: method,
                continuation: continuation
            )
            do {
                try write(message)
            } catch {
                pendingRequests.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
            }
        }
    }

    func notify(method: String, params: JSONValue) throws {
        try write(.object([
            "method": .string(method),
            "params": params,
        ]))
    }

    func stop() {
        generation += 1
        let activeProcess = process
        process = nil
        inputHandle = nil
        detachReadHandles()

        failPendingRequests(with: AppServerRPCError.stopped)
        finishNotificationStreams()

        if let activeProcess, activeProcess.isRunning {
            activeProcess.terminate()
        }
    }

    private nonisolated func startPipeReader(
        handle: FileHandle,
        generation: Int,
        isStandardError: Bool
    ) {
        let label = isStandardError
            ? "voice.codex-app-server.stderr"
            : "voice.codex-app-server.stdout"
        DispatchQueue(label: label, qos: .utility).async { [weak self] in
            while true {
                let data = handle.availableData
                let delivered = DispatchSemaphore(value: 0)
                Task {
                    if isStandardError {
                        await self?.receiveErrorOutput(
                            data,
                            generation: generation
                        )
                    } else {
                        await self?.receiveOutput(data, generation: generation)
                    }
                    delivered.signal()
                }
                delivered.wait()
                if data.isEmpty { return }
            }
        }
    }

    private func receiveOutput(_ data: Data, generation: Int) async {
        guard generation == self.generation else { return }
        guard !data.isEmpty else {
            if !outputBuffer.isEmpty,
               let line = String(data: outputBuffer, encoding: .utf8) {
                outputBuffer.removeAll()
                await receive(line: line, generation: generation)
            }
            outputEnded(generation: generation, detail: "stdout closed")
            return
        }

        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            var lineData = Data(outputBuffer[..<newline])
            outputBuffer.removeSubrange(...newline)
            if lineData.last == 0x0D {
                lineData.removeLast()
            }
            guard let line = String(data: lineData, encoding: .utf8) else {
                await AppLog.write("codex app-server emitted non-UTF-8 output")
                continue
            }
            await receive(line: line, generation: generation)
        }
    }

    private func receiveErrorOutput(_ data: Data, generation: Int) async {
        guard generation == self.generation else { return }
        guard !data.isEmpty else {
            if !errorBuffer.isEmpty,
               let line = String(data: errorBuffer, encoding: .utf8) {
                await AppLog.write("codex app-server stderr: \(line)")
            }
            errorBuffer.removeAll()
            return
        }

        errorBuffer.append(data)
        while let newline = errorBuffer.firstIndex(of: 0x0A) {
            var lineData = Data(errorBuffer[..<newline])
            errorBuffer.removeSubrange(...newline)
            if lineData.last == 0x0D {
                lineData.removeLast()
            }
            if let line = String(data: lineData, encoding: .utf8) {
                await AppLog.write("codex app-server stderr: \(line)")
            } else {
                await AppLog.write("codex app-server stderr contained non-UTF-8 data")
            }
        }
    }

    private func receive(line: String, generation: Int) async {
        guard generation == self.generation else { return }

        do {
            let data = Data(line.utf8)
            let object = try JSONSerialization.jsonObject(with: data)
            let message = try JSONValue(jsonObject: object)
            try route(message)
        } catch {
            await AppLog.write(
                "codex app-server invalid message: \(error.localizedDescription); "
                    + line
            )
        }
    }

    private func route(_ message: JSONValue) throws {
        guard let object = message.objectValue else {
            throw AppServerRPCError.invalidJSON("Top-level message is not an object")
        }

        if let requestID = object["id"]?.integerValue,
           let pending = pendingRequests.removeValue(forKey: requestID) {
            if let error = object["error"] {
                pending.continuation.resume(
                    throwing: AppServerRPCError.requestFailed(
                        method: pending.method,
                        id: requestID,
                        detail: error.compactDescription
                    )
                )
            } else {
                pending.continuation.resume(returning: object["result"] ?? .null)
            }
            return
        }

        guard let method = object["method"]?.stringValue else {
            return
        }
        let notification = AppServerNotification(
            method: method,
            params: object["params"] ?? .object([:])
        )
        for continuation in notificationContinuations.values {
            continuation.yield(notification)
        }
    }

    private func write(_ message: JSONValue) throws {
        guard
            process?.isRunning == true,
            let inputHandle
        else {
            throw AppServerRPCError.notRunning
        }

        var data = try JSONSerialization.data(
            withJSONObject: message.foundationObject,
            options: []
        )
        data.append(0x0A)
        do {
            try inputHandle.write(contentsOf: data)
        } catch {
            throw AppServerRPCError.writeFailed(error.localizedDescription)
        }
    }

    private func processExited(generation: Int, status: Int32) {
        guard generation == self.generation, process != nil else { return }
        process = nil
        inputHandle = nil
        detachReadHandles()

        let error = AppServerRPCError.processExited(status: status)
        failPendingRequests(with: error)
        finishNotificationStreams()
    }

    private func outputEnded(generation: Int, detail: String) {
        guard generation == self.generation, let activeProcess = process else {
            return
        }

        process = nil
        inputHandle = nil
        detachReadHandles()
        if activeProcess.isRunning {
            activeProcess.terminate()
        }

        failPendingRequests(with: AppServerRPCError.transportClosed(detail))
        finishNotificationStreams()
    }

    private func detachReadHandles() {
        try? outputHandle?.close()
        try? errorHandle?.close()
        outputHandle = nil
        errorHandle = nil
        outputBuffer.removeAll()
        errorBuffer.removeAll()
    }

    private func failPendingRequests(with error: AppServerRPCError) {
        let requests = pendingRequests.values
        pendingRequests.removeAll()
        for request in requests {
            request.continuation.resume(throwing: error)
        }
    }

    private func finishNotificationStreams() {
        let continuations = notificationContinuations.values
        notificationContinuations.removeAll()
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func removeNotificationContinuation(_ identifier: UUID) {
        notificationContinuations.removeValue(forKey: identifier)
    }
}

enum AppServerRPCError: LocalizedError, Sendable {
    case alreadyRunning
    case notRunning
    case launchFailed(String)
    case writeFailed(String)
    case invalidJSON(String)
    case requestFailed(method: String, id: Int, detail: String)
    case processExited(status: Int32)
    case transportClosed(String)
    case stopped

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "The Codex app-server is already running."
        case .notRunning:
            "The Codex app-server is not running."
        case let .launchFailed(detail):
            "Unable to launch Codex app-server: \(detail)"
        case let .writeFailed(detail):
            "Unable to write to Codex app-server: \(detail)"
        case let .invalidJSON(detail):
            "Invalid Codex app-server JSON: \(detail)"
        case let .requestFailed(method, id, detail):
            "Codex app-server request \(method) (id \(id)) failed: \(detail)"
        case let .processExited(status):
            "Codex app-server exited with status \(status)."
        case let .transportClosed(detail):
            "Codex app-server transport closed: \(detail)."
        case .stopped:
            "Codex app-server stopped."
        }
    }
}
