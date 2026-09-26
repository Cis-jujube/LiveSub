import Foundation
import LiveSubAudio
@testable import LiveSubBackend

@main
struct BackendProtocolChecks {
    @MainActor static func main() async throws {
        try checkWireFormat()
        try await checkStaleProcessCallbacks()
        if CommandLine.arguments.contains("--transport") {
            try await checkLocalTransport()
        }
    }

    @MainActor private static func checkStaleProcessCallbacks() async throws {
        let owner = BackendProcess()
        var unexpectedExits = 0
        owner.onUnexpectedExit = { _ in unexpectedExits += 1 }

        func child(port: Int) -> (Process, Pipe) {
            let process = Process()
            let input = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "read marker; printf '%s\\n' '{\"kind\":\"ready\",\"version\":1,\"port\":\(port)}'; exec /bin/cat >/dev/null"]
            process.standardInput = input
            return (process, input)
        }

        func waitUntilRunning(_ process: Process) async throws {
            for _ in 0..<200 {
                if process.isRunning { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw CheckFailure.childDidNotStart
        }

        let (first, firstInput) = child(port: 32101)
        let firstLaunch = Task { try await owner.launch(process: first, token: "first-fixture") }
        try await waitUntilRunning(first)
        let staleOutput = (first.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler
        let staleExit = first.terminationHandler
        precondition(staleOutput != nil && staleExit != nil)
        try firstInput.fileHandleForWriting.write(contentsOf: Data("ready\n".utf8))
        let firstReady = try await firstLaunch.value
        precondition(firstReady.ready.port == 32101)
        let failedLaunchID = owner.currentLaunchID
        precondition(failedLaunchID != nil)
        await owner.shutdown()
        precondition(!owner.isRunning)

        let (second, secondInput) = child(port: 32102)
        let secondLaunch = Task { try await owner.launch(process: second, token: "second-fixture") }
        try await waitUntilRunning(second)
        // Deliver the old callbacks after a new process owns the continuation.
        // A stale ready line must not satisfy the new handshake, and a stale
        // termination must not clean up the new process or emit an exit event.
        let delayedOutput = Pipe()
        try delayedOutput.fileHandleForWriting.write(contentsOf: Data(
            "{\"kind\":\"ready\",\"version\":1,\"port\":32101}\n".utf8
        ))
        staleOutput?(delayedOutput.fileHandleForReading)
        staleExit?(first)
        // Model a BackendClient failure cleanup task that resumes only after
        // another connection has already launched its replacement process.
        await owner.shutdown(ifCurrentLaunchID: failedLaunchID)
        try await Task.sleep(for: .milliseconds(50))
        precondition(owner.isRunning, "stale exit must not detach the new process")
        precondition(unexpectedExits == 0, "stale exit must not report failure for the new process")
        try secondInput.fileHandleForWriting.write(contentsOf: Data("ready\n".utf8))
        let secondReady = try await secondLaunch.value
        precondition(secondReady.ready.port == 32102, "stale stdout must not complete the new handshake")
        precondition(secondReady.token == "second-fixture")
        await owner.shutdown(ifCurrentLaunchID: owner.currentLaunchID)
        precondition(!owner.isRunning)
        print("BackendProtocolChecks: stale stdout, termination, and failure cleanup rejected across relaunch")
    }

    private enum CheckFailure: Error { case childDidNotStart }

    private static func checkWireFormat() throws {
        let ready = try JSONDecoder().decode(
            BackendReady.self,
            from: Data(#"{"kind":"ready","version":1,"port":34123}"#.utf8)
        )
        precondition(ready.isValid)
        let wrongVersion = try JSONDecoder().decode(
            BackendReady.self,
            from: Data(#"{"kind":"ready","version":2,"port":34123}"#.utf8)
        )
        precondition(!wrongVersion.isValid)

        let start = BackendCommand(
            kind: "start", sessionID: "session-1", generation: 3,
            sourceLanguage: "en", targetLanguage: "zh"
        )
        let startJSON = try object(JSONEncoder().encode(start))
        precondition(startJSON["kind"] as? String == "start")
        precondition(startJSON["session_id"] as? String == "session-1")
        precondition(startJSON["generation"] as? Int == 3)
        precondition(startJSON["source_language"] as? String == "en")
        precondition(startJSON["target_language"] as? String == "zh")
        precondition(startJSON["sourceLanguage"] == nil)

        let samples = Data([0x01, 0x00, 0xFF, 0x7F])
        let audio = AudioFrame(
            sessionID: "session-1", generation: 3,
            sequence: 4, startSample: 10_240, pcm16: samples
        )
        let audioJSON = try object(JSONEncoder().encode(BackendCommand.audio(audio)))
        precondition(audioJSON["sample_rate"] as? Int == 16_000)
        precondition(audioJSON["channels"] as? Int == 1)
        precondition(audioJSON["sequence"] as? Int == 4)
        precondition(audioJSON["start_sample"] as? Int == 10_240)
        precondition(Data(base64Encoded: audioJSON["pcm16"] as? String ?? "") == samples)

        let event = try JSONDecoder().decode(BackendEvent.self, from: Data("""
        {"kind":"subtitle","segment":{
          "session_id":"session-1","generation":3,"segment_id":"seg-1","sequence":1,
          "start_ms":100,"end_ms":400,"source_language":"en","target_language":"zh",
          "source_text":"hello","source_revision":2,"source_final":true,
          "target_text":"你好","translated_source_text":"hello",
          "translated_source_revision":2,"translation_state":"final"}}
        """.utf8))
        precondition(event.kind == "subtitle")
        precondition(event.segment?.translatedSourceText == "hello")
        precondition(event.segment?.translatedSourceRevision == 2)
        precondition(event.segment?.targetText == "你好")

        let state = try JSONDecoder().decode(BackendEvent.self, from: Data(
            #"{"kind":"state","session_id":"session-1","generation":3,"state":"listening","detail":null}"#.utf8
        ))
        precondition(state.state == "listening")
        precondition(state.sessionID == "session-1")
        print("BackendProtocolChecks: 15 assertions passed")
    }

    @MainActor private static func checkLocalTransport() async throws {
        let process = BackendProcess()
        let launch = try await process.launch()
        do {
            precondition((1...65_535).contains(launch.ready.port))
            precondition(launch.token.count == 64)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            let session = URLSession(configuration: configuration)
            var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(launch.ready.port)/ws")!)
            request.setValue("Bearer \(launch.token)", forHTTPHeaderField: "Authorization")
            let socket = session.webSocketTask(with: request)
            socket.resume()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                socket.sendPing { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            socket.cancel(with: .normalClosure, reason: nil)
            let unauthorized = session.webSocketTask(
                with: URL(string: "ws://127.0.0.1:\(launch.ready.port)/ws")!
            )
            unauthorized.resume()
            let rejected = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                unauthorized.sendPing { error in continuation.resume(returning: error != nil) }
            }
            precondition(rejected, "a connection without the launch token must be rejected")
            unauthorized.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            print("BackendProtocolChecks: authenticated handshake and unauthenticated rejection passed")
        } catch {
            await process.shutdown()
            throw error
        }
        await process.shutdown()
        precondition(!process.isRunning)
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BackendClientError.invalidBackendEvent
        }
        return result
    }
}
