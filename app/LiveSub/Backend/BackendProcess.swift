import Foundation
import Security
import Darwin

struct BackendPaths {
    let source: URL
    let python: URL
    let runtime: URL
    let models: URL

    static func locate() throws -> BackendPaths {
        let manager = FileManager.default
        guard let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw BackendClientError.environmentMissing("~/Library/Application Support/LiveSub")
        }
        let root = support.appendingPathComponent("LiveSub", isDirectory: true)
        let runtime = root.appendingPathComponent(
            "runtime/Confucius4-R2T2-26d55a54ce5670cff9947a167d8ed95d569fd4d9", isDirectory: true
        )
        let models = root.appendingPathComponent("models", isDirectory: true)

        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let resources = Bundle.main.resourceURL else {
                throw BackendClientError.environmentMissing("LiveSub.app/Contents/Resources")
            }
            return try checked(
                source: resources.appendingPathComponent("backend", isDirectory: true),
                python: root.appendingPathComponent("backend/.venv/bin/python3"),
                runtime: runtime,
                models: models
            )
        }

        let starts = [
            URL(fileURLWithPath: manager.currentDirectoryPath, isDirectory: true),
            Bundle.main.executableURL?.deletingLastPathComponent(),
        ].compactMap { $0 }
        for start in starts {
            var directory = start.standardizedFileURL
            while directory.path != "/" {
                let backend = directory.appendingPathComponent("backend", isDirectory: true)
                if manager.fileExists(atPath: backend.appendingPathComponent("pyproject.toml").path) {
                    return try checked(
                        source: backend,
                        python: backend.appendingPathComponent(".venv/bin/python3"),
                        runtime: runtime,
                        models: models
                    )
                }
                directory.deleteLastPathComponent()
            }
        }
        throw BackendClientError.environmentMissing("backend/pyproject.toml")
    }

    private static func checked(source: URL, python: URL, runtime: URL, models: URL) throws -> BackendPaths {
        let manager = FileManager.default
        let required = [
            source.appendingPathComponent("livesub/server.py"),
            source.appendingPathComponent("pyproject.toml"),
            python,
            runtime.appendingPathComponent("r2t2_llama", isDirectory: true),
            models.appendingPathComponent("r2t2", isDirectory: true),
            models.appendingPathComponent("Qwen3-4B-Instruct-2507-4bit", isDirectory: true),
        ]
        for url in required where !manager.fileExists(atPath: url.path) {
            throw BackendClientError.environmentMissing(url.path)
        }
        guard manager.isExecutableFile(atPath: python.path) else {
            throw BackendClientError.environmentMissing(python.path)
        }
        return BackendPaths(source: source, python: python, runtime: runtime, models: models)
    }
}

@MainActor
final class BackendProcess {
    var onUnexpectedExit: ((Int32) -> Void)?

    private var process: Process?
    private var launchID: UUID?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = Data()
    private var readyContinuation: CheckedContinuation<BackendReady, Error>?
    private var readyTimeout: Task<Void, Never>?
    private var isStopping = false

    var isRunning: Bool { process?.isRunning == true }
    var currentLaunchID: UUID? { launchID }

    func launch() async throws -> (ready: BackendReady, token: String) {
        guard process == nil else { throw BackendClientError.alreadyStarting }
        let paths = try BackendPaths.locate()
        let token = try Self.randomToken()
        let process = Process()
        process.executableURL = paths.python
        process.arguments = ["-m", "livesub.server"]
        process.currentDirectoryURL = paths.source
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = "\(paths.source.path):\(paths.runtime.path)"
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["LIVESUB_AUTH_TOKEN"] = token
        environment["LIVESUB_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        environment["LIVESUB_MODEL_ROOT"] = paths.models.path
        process.environment = environment
        return try await launch(process: process, token: token)
    }

    // Accept a configured process so lifecycle checks can use a tiny local child
    // without loading models or relying on an installed Python environment.
    func launch(process: Process, token: String) async throws -> (ready: BackendReady, token: String) {
        guard self.process == nil else { throw BackendClientError.alreadyStarting }
        let id = UUID()
        launchID = id
        isStopping = false
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in self?.receiveStdout(data, launchID: id) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            // Drain diagnostics so the child cannot stall; never expose transcript or token text.
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in self?.processExited(finished.terminationStatus, launchID: id) }
        }
        self.process = process
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        do {
            let ready = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BackendReady, Error>) in
                readyContinuation = continuation
                readyTimeout = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    guard !Task.isCancelled else { return }
                    self?.failReady(BackendClientError.launchTimeout, launchID: id)
                }
                do {
                    try process.run()
                } catch {
                    failReady(error, launchID: id)
                }
            }
            return (ready, token)
        } catch {
            if launchID == id { await shutdown() }
            throw error
        }
    }

    func shutdown(ifCurrentLaunchID id: UUID?) async {
        guard let id, launchID == id else { return }
        await shutdown()
    }

    func shutdown() async {
        guard let id = launchID else { return }
        if isStopping {
            while launchID == id && process != nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            return
        }
        isStopping = true
        failReady(BackendClientError.disconnected, launchID: id)
        guard let process else {
            cleanup(launchID: id)
            return
        }
        if process.isRunning {
            process.terminate()
            for _ in 0..<40 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        cleanup(launchID: id)
    }

    private func receiveStdout(_ data: Data, launchID id: UUID) {
        guard launchID == id, readyContinuation != nil else { return }
        if data.isEmpty {
            failReady(BackendClientError.invalidReadyMessage, launchID: id)
            return
        }
        stdoutBuffer.append(data)
        guard stdoutBuffer.count <= 4096 else {
            failReady(BackendClientError.invalidReadyMessage, launchID: id)
            return
        }
        guard let newline = stdoutBuffer.firstIndex(of: 0x0A) else { return }
        let line = stdoutBuffer.prefix(upTo: newline)
        guard let ready = try? JSONDecoder().decode(BackendReady.self, from: line), ready.isValid else {
            failReady(BackendClientError.invalidReadyMessage, launchID: id)
            return
        }
        readyTimeout?.cancel()
        readyTimeout = nil
        let continuation = readyContinuation
        readyContinuation = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        stdoutBuffer.removeAll(keepingCapacity: false)
        continuation?.resume(returning: ready)
    }

    private func failReady(_ error: Error, launchID id: UUID) {
        guard launchID == id else { return }
        readyTimeout?.cancel()
        readyTimeout = nil
        let continuation = readyContinuation
        readyContinuation = nil
        continuation?.resume(throwing: error)
    }

    private func processExited(_ status: Int32, launchID id: UUID) {
        guard launchID == id else { return }
        let expected = isStopping
        failReady(BackendClientError.processExited(status), launchID: id)
        cleanup(launchID: id)
        if !expected { onUnexpectedExit?(status) }
    }

    private func cleanup(launchID id: UUID) {
        guard launchID == id else { return }
        launchID = nil
        readyTimeout?.cancel()
        readyTimeout = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
        process = nil
        stdoutBuffer.removeAll(keepingCapacity: false)
    }

    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw BackendClientError.environmentMissing("secure random generator")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
