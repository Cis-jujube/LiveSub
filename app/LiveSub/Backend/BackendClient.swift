import Combine
import Foundation
import LiveSubAudio

/// Owns exactly one authenticated loopback service and one WebSocket connection.
@MainActor
public final class BackendClient: ObservableObject {
    @Published public private(set) var state: BackendConnectionState = .idle
    @Published public private(set) var status = "Local backend is stopped"

    /// Called first for every validated event. Both callbacks run on the main actor.
    public var onRawEvent: ((Data) -> Void)?
    public var onEvent: ((BackendEvent) -> Void)?

    private let process = BackendProcess()
    private var urlSession: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var connectionID: UUID?
    private var receiveTask: Task<Void, Never>?
    private var sendTail: Task<Void, Error>?
    private var queuedMessages = 0
    private var closing = false
    private var sessionID: String?
    private var generation: UInt64 = 0
    private var backendPhase = "idle"
    private var nextSequence: UInt64 = 0
    private var nextSample: UInt64 = 0
    private var audioSendInProgress = false

    public init() {
        process.onUnexpectedExit = { [weak self] exitStatus in
            self?.connectionFailed(BackendClientError.processExited(exitStatus))
        }
    }

    public func start(
        sessionID: String,
        generation: UInt64,
        sourceLanguage: String,
        targetLanguage: String
    ) async throws {
        guard !sessionID.isEmpty else { throw BackendClientError.sessionMismatch }
        try Self.validateDirection(sourceLanguage, targetLanguage)
        if closing || state == .launching { throw BackendClientError.alreadyStarting }
        if state == .connected && backendPhase != "idle" {
            if backendPhase == "error" {
                await shutdown()
            } else {
                throw BackendClientError.sessionMismatch
            }
        }
        if state == .failed { await shutdown() }
        if state != .connected {
            try await connect()
        }
        self.sessionID = sessionID
        self.generation = generation
        nextSequence = 0
        nextSample = 0
        backendPhase = "loading"
        try await send(BackendCommand(
            kind: "start", sessionID: sessionID, generation: generation,
            sourceLanguage: sourceLanguage, targetLanguage: targetLanguage
        ))
    }

    public func sendAudio(_ frame: AudioFrame) async throws {
        guard state == .connected, backendPhase == "listening", let sendingSocket = socket else {
            throw BackendClientError.notListening
        }
        guard frame.sessionID == sessionID, frame.generation == generation else {
            throw BackendClientError.sessionMismatch
        }
        guard frame.sequence == nextSequence, frame.startSample == nextSample else {
            throw BackendClientError.audioOutOfOrder
        }
        guard frame.sampleRate == 16_000, frame.channels == 1,
              !frame.pcm16.isEmpty, frame.pcm16.count <= 5120,
              frame.pcm16.count.isMultiple(of: 2) else {
            throw BackendClientError.invalidAudioFrame
        }
        guard !audioSendInProgress else { throw BackendClientError.sendBacklogFull }
        audioSendInProgress = true
        defer {
            if socket === sendingSocket { audioSendInProgress = false }
        }
        try await send(.audio(frame))
        guard socket === sendingSocket, frame.sessionID == sessionID, frame.generation == generation else {
            throw BackendClientError.sessionMismatch
        }
        nextSequence += 1
        nextSample += UInt64(frame.sampleCount)
    }

    public func pause() async throws {
        guard let sessionID, state == .connected else { throw BackendClientError.disconnected }
        guard backendPhase == "listening" || backendPhase == "paused" else {
            throw BackendClientError.notListening
        }
        if backendPhase == "paused" { return }
        try await send(BackendCommand(kind: "pause", sessionID: sessionID, generation: generation))
        try await waitForPhase("paused", action: "pausing")
    }

    public func resume(
        generation: UInt64,
        sourceLanguage: String,
        targetLanguage: String
    ) async throws {
        guard let sessionID, state == .connected else { throw BackendClientError.disconnected }
        guard backendPhase == "paused", generation > self.generation else {
            throw BackendClientError.sessionMismatch
        }
        try Self.validateDirection(sourceLanguage, targetLanguage)
        self.generation = generation
        nextSequence = 0
        nextSample = 0
        audioSendInProgress = false
        backendPhase = "loading"
        try await send(BackendCommand(
            kind: "resume", sessionID: sessionID, generation: generation,
            sourceLanguage: sourceLanguage, targetLanguage: targetLanguage
        ))
    }

    public func stop() async throws {
        guard let sessionID, state == .connected else { throw BackendClientError.disconnected }
        if backendPhase == "idle" { return }
        try await send(BackendCommand(kind: "stop", sessionID: sessionID, generation: generation))
        try await waitForPhase("idle", action: "stopping")
    }

    public func shutdown() async {
        if closing { return }
        closing = true
        if state == .connected, sessionID != nil,
           backendPhase != "idle", backendPhase != "error" {
            try? await stop()
        }
        connectionID = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        sendTail?.cancel()
        sendTail = nil
        queuedMessages = 0
        await process.shutdown()
        sessionID = nil
        generation = 0
        backendPhase = "idle"
        nextSequence = 0
        nextSample = 0
        state = .idle
        audioSendInProgress = false
        status = "Local backend is stopped"
        closing = false
    }

    private func connect() async throws {
        let id = UUID()
        connectionID = id
        state = .launching
        status = "Starting local backend"
        do {
            let launch = try await process.launch()
            guard connectionID == id else { throw CancellationError() }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            let session = URLSession(configuration: configuration)
            var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(launch.ready.port)/ws")!)
            request.setValue("Bearer \(launch.token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15
            let socket = session.webSocketTask(with: request)
            self.urlSession = session
            self.socket = socket
            socket.resume()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                socket.sendPing { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            guard connectionID == id, self.socket === socket else { throw CancellationError() }
            state = .connected
            status = "Local backend connected"
            receiveTask = Task { @MainActor [weak self] in
                await self?.receiveEvents(from: socket)
            }
        } catch {
            if connectionID == id { await disconnectAfterFailure(error) }
            throw error
        }
    }

    private func send(_ command: BackendCommand) async throws {
        guard state == .connected, let socket else { throw BackendClientError.disconnected }
        guard queuedMessages < 32 else { throw BackendClientError.sendBacklogFull }
        let encoded = try JSONEncoder().encode(command)
        guard let json = String(data: encoded, encoding: .utf8) else {
            throw BackendClientError.invalidAudioFrame
        }
        queuedMessages += 1
        let previous = sendTail
        let pending = Task { @MainActor in
            if let previous { try await previous.value }
            try await socket.send(.string(json))
        }
        sendTail = pending
        defer {
            if self.socket === socket {
                queuedMessages -= 1
                if queuedMessages == 0 { sendTail = nil }
            }
        }
        do {
            try await pending.value
        } catch {
            if self.socket === socket { connectionFailed(error) }
            throw error
        }
    }

    private func receiveEvents(from socket: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                guard self.socket === socket, !Task.isCancelled else { return }
                guard case .string(let text) = message else {
                    throw BackendClientError.invalidBackendEvent
                }
                let data = Data(text.utf8)
                guard data.count <= 65_536 else { throw BackendClientError.invalidBackendEvent }
                let event = try JSONDecoder().decode(BackendEvent.self, from: data)
                guard ["state", "subtitle", "error"].contains(event.kind) else {
                    throw BackendClientError.invalidBackendEvent
                }
                if event.kind == "state", let phase = event.state,
                   event.sessionID == sessionID, event.generation == generation {
                    backendPhase = phase
                    status = event.detail ?? phase
                } else if event.kind == "error" {
                    status = event.detail ?? event.code ?? "Backend error"
                }
                onRawEvent?(data)
                onEvent?(event)
            }
        } catch {
            if self.socket === socket, !closing, !Task.isCancelled { connectionFailed(error) }
        }
    }

    private func waitForPhase(_ expected: String, action: String) async throws {
        for _ in 0..<500 {
            if backendPhase == expected { return }
            if backendPhase == "error" || state != .connected {
                throw BackendClientError.disconnected
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw BackendClientError.operationTimedOut(action)
    }

    private func connectionFailed(_ error: Error) {
        guard !closing, state != .failed else { return }
        state = .failed
        status = error.localizedDescription
        socket?.cancel(with: .goingAway, reason: nil)
        let payload: [String: String] = [
            "kind": "error", "code": "backend_failure", "detail": error.localizedDescription,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let event = try? JSONDecoder().decode(BackendEvent.self, from: data) {
            onRawEvent?(data)
            onEvent?(event)
        }
        // Capture ownership before yielding: a retry may replace the child before
        // this task runs. Cleanup from an old failure must not stop the new child.
        let failedLaunchID = process.currentLaunchID
        Task { @MainActor [weak self] in
            await self?.process.shutdown(ifCurrentLaunchID: failedLaunchID)
        }
    }

    private func disconnectAfterFailure(_ error: Error) async {
        connectionFailed(error)
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        await process.shutdown()
    }

    private static func validateDirection(_ source: String, _ target: String) throws {
        guard (source == "en" && target == "zh") || (source == "zh" && target == "en") else {
            throw BackendClientError.invalidDirection
        }
    }
}
