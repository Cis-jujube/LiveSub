import Foundation
import LiveSubBackend

/// First-launch download of the local Python runtime and the two models into
/// `LiveSubRuntime.supportRoot`, so a user who installed the app from the DMG
/// never needs Terminal. Every step is idempotent; rerunning resumes.
@MainActor
public final class RuntimeSetup: ObservableObject {
    public enum Phase: Equatable {
        case ready
        case needed
        case running
        case failed(String)
    }

    struct Step: Identifiable {
        let id: Int
        let title: String
        let detail: String
        let expectedBytes: Int64
        /// Directories whose on-disk size tracks this step's download.
        let measured: [String]
    }

    @Published public private(set) var phase: Phase
    @Published private(set) var stepIndex = 0
    @Published private(set) var downloadedBytes: Int64 = 0
    @Published private(set) var bytesPerSecond: Double = 0
    @Published private(set) var usingMirror = false

    let steps: [Step] = [
        Step(id: 0, title: "准备运行环境", detail: "Python 3.12 与推理库", expectedBytes: 1_650_000_000,
             measured: ["runtime/python", "runtime/uv-cache"]),
        Step(id: 1, title: "下载语音识别模型", detail: "Qwen3-ASR-1.7B", expectedBytes: 4_703_000_000,
             measured: ["models/Qwen3-ASR-1.7B"]),
        Step(id: 2, title: "下载翻译模型", detail: "Qwen3-4B-Instruct · MLX 4-bit", expectedBytes: 2_279_000_000,
             measured: ["models/Qwen3-4B-Instruct-2507-4bit"]),
    ]
    var totalBytes: Int64 { steps.reduce(0) { $0 + $1.expectedBytes } }

    private static let pythonMirror = "https://registry.npmmirror.com/-/binary/python-build-standalone"
    private static let huggingFaceMirror = "https://hf-mirror.com"

    private var process: Process?
    private var runTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var cancelled = false

    public init() {
        phase = LiveSubRuntime.isReady ? .ready : .needed
    }

    public var isReady: Bool { phase == .ready }

    func start() {
        guard phase != .running, phase != .ready else { return }
        let root = LiveSubRuntime.supportRoot
        guard let resources = Bundle.main.resourceURL,
              FileManager.default.isExecutableFile(atPath: resources.appendingPathComponent("bin/uv").path) else {
            phase = .failed("这个版本没有包含安装组件。请从 GitHub Releases 下载 LiveSub，或在源码目录运行 script/setup_models.sh。")
            return
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            phase = .failed("无法创建数据目录：\(error.localizedDescription)")
            return
        }
        let needed = remainingBytes(root: root) + 1_000_000_000
        if let free = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < needed {
            phase = .failed("磁盘空间不足：还需要约 \(Self.gigabytes(needed))，当前可用 \(Self.gigabytes(free))。")
            return
        }
        cancelled = false
        usingMirror = false
        phase = .running
        startMeter(root: root)
        runTask = Task { [weak self] in
            await self?.run(root: root, resources: resources)
        }
    }

    func cancel() {
        guard phase == .running else { return }
        cancelled = true
        process?.terminate()
    }

    /// Stops a running download when the app quits; downloads resume next launch.
    public func stopForQuit() {
        cancelled = true
        process?.terminate()
    }

    private func run(root: URL, resources: URL) async {
        let uv = resources.appendingPathComponent("bin/uv")
        let backend = resources.appendingPathComponent("backend", isDirectory: true)
        let python = root.appendingPathComponent("backend/.venv/bin/python3")
        let models = root.appendingPathComponent("models", isDirectory: true)
        let uvEnvironment = [
            "UV_PROJECT_ENVIRONMENT": root.appendingPathComponent("backend/.venv").path,
            "UV_PYTHON_INSTALL_DIR": root.appendingPathComponent("runtime/python").path,
            "UV_CACHE_DIR": root.appendingPathComponent("runtime/uv-cache").path,
            "UV_PYTHON_PREFERENCE": "only-managed",
            "UV_NO_CONFIG": "1",
        ]
        let pythonEnvironment = [
            "PYTHONPATH": backend.path,
            "PYTHONDONTWRITEBYTECODE": "1",
            "HF_HUB_DISABLE_TELEMETRY": "1",
        ]

        let plan: [(Int, URL, [String], [String: String], [String: String])] = [
            (0, uv, ["sync", "--project", backend.path, "--locked", "--no-dev", "--python", "3.12"],
             uvEnvironment, ["UV_PYTHON_INSTALL_MIRROR": Self.pythonMirror]),
            (1, python, ["-m", "livesub.asr.download_qwen", "--model-dir", models.appendingPathComponent("Qwen3-ASR-1.7B").path],
             pythonEnvironment, ["HF_ENDPOINT": Self.huggingFaceMirror]),
            (2, python, ["-m", "livesub.translation.download_model", "--model-dir", models.appendingPathComponent("Qwen3-4B-Instruct-2507-4bit").path],
             pythonEnvironment, ["HF_ENDPOINT": Self.huggingFaceMirror]),
        ]
        for (index, executable, arguments, environment, mirror) in plan {
            stepIndex = index
            var result = await execute(executable, arguments, environment: environment.merging(usingMirror ? mirror : [:]) { $1 }, root: root)
            if result != 0, !cancelled, !usingMirror {
                // The default hosts are often unreachable or slow from mainland China; retry once through mirrors.
                usingMirror = true
                result = await execute(executable, arguments, environment: environment.merging(mirror) { $1 }, root: root)
            }
            if cancelled { return finish(.needed) }
            if result != 0 { return finish(.failed(failureMessage(step: index, root: root))) }
        }

        stepIndex = steps.count - 1
        let check = await execute(python, ["-c", "from livesub.asr.qwen import QwenASREngine; from livesub.translation.mlx_engine import MLXTranslator; from livesub.server import main"],
                                  environment: pythonEnvironment, root: root)
        if check != 0 { return finish(.failed(failureMessage(step: steps.count - 1, root: root))) }
        try? FileManager.default.removeItem(at: root.appendingPathComponent("runtime/uv-cache"))
        finish(LiveSubRuntime.isReady ? .ready : .failed("下载已完成，但运行环境校验未通过。请重试。"))
    }

    private func finish(_ next: Phase) {
        meterTask?.cancel()
        meterTask = nil
        process = nil
        if next == .ready { downloadedBytes = totalBytes }
        bytesPerSecond = 0
        phase = next
    }

    private func execute(_ executable: URL, _ arguments: [String], environment: [String: String], root: URL) async -> Int32 {
        let log = root.appendingPathComponent("runtime/setup.log")
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: log)
        handle?.seekToEndOfFile()
        handle?.write(Data("\n$ \(executable.lastPathComponent) \(arguments.joined(separator: " "))\n".utf8))

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment { merged[key] = value }
        process.environment = merged
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        self.process = process
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                try? handle?.close()
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                handle?.write(Data("launch failed: \(error.localizedDescription)\n".utf8))
                try? handle?.close()
                continuation.resume(returning: -1)
            }
        }
    }

    private func failureMessage(step: Int, root: URL) -> String {
        let log = root.appendingPathComponent("runtime/setup.log")
        let tail = (try? String(contentsOf: log, encoding: .utf8))?
            .split(separator: "\n").suffix(40)
            .last { $0.contains("Error") || $0.contains("error") || $0.contains("failed") }
            .map { String($0.prefix(220)) }
        let base = "「\(steps[min(step, steps.count - 1)].title)」没有完成。请检查网络后点「重试」，已下载的部分会保留。"
        return tail.map { base + "\n\($0)" } ?? base
    }

    private func remainingBytes(root: URL) -> Int64 {
        steps.reduce(0) { sum, step in
            let have = step.measured.reduce(Int64(0)) { $0 + Self.allocatedSize(root.appendingPathComponent($1)) }
            return sum + max(0, step.expectedBytes - have)
        }
    }

    private func startMeter(root: URL) {
        meterTask?.cancel()
        let steps = self.steps
        meterTask = Task { [weak self] in
            var last: (Date, Int64)?
            while !Task.isCancelled {
                let current = await Task.detached(priority: .utility) {
                    steps.reduce(Int64(0)) { sum, step in
                        let have = step.measured.reduce(Int64(0)) { $0 + Self.allocatedSize(root.appendingPathComponent($1)) }
                        return sum + min(have, step.expectedBytes)
                    }
                }.value
                guard let self, !Task.isCancelled else { return }
                let now = Date()
                if let (time, bytes) = last, now.timeIntervalSince(time) > 0 {
                    let instant = Double(max(0, current - bytes)) / now.timeIntervalSince(time)
                    self.bytesPerSecond = self.bytesPerSecond == 0 ? instant : self.bytesPerSecond * 0.7 + instant * 0.3
                }
                last = (now, current)
                self.downloadedBytes = max(self.downloadedBytes, current)
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    nonisolated static func allocatedSize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: []) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }

    /// Fixed states for `script/render_design.swift`; never called by the app.
    func showPreview(_ phase: Phase, step: Int = 0, downloaded: Int64 = 0, speed: Double = 0, mirror: Bool = false) {
        self.phase = phase
        stepIndex = step
        downloadedBytes = downloaded
        bytesPerSecond = speed
        usingMirror = mirror
    }
}

extension RuntimeSetup {
    /// `LiveSub.app/Contents/MacOS/LiveSub --prepare-runtime` runs the same setup without a window,
    /// for scripted installs and end-to-end tests. Exits 0 when ready.
    static func runHeadlessAndExit() -> Never {
        let setup = RuntimeSetup()
        if setup.isReady {
            print("LiveSub runtime is ready at \(LiveSubRuntime.supportRoot.path)")
            exit(0)
        }
        print("Preparing LiveSub runtime at \(LiveSubRuntime.supportRoot.path)")
        setup.start()
        var last = ""
        while true {
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            switch setup.phase {
            case .ready:
                print("LiveSub runtime is ready")
                exit(0)
            case .failed(let message):
                FileHandle.standardError.write(Data((message + "\n").utf8))
                exit(1)
            case .needed:
                exit(2)
            case .running:
                let line = "[\(setup.stepIndex + 1)/\(setup.steps.count)] \(setup.steps[setup.stepIndex].title) · "
                    + "\(gigabytes(setup.downloadedBytes)) / \(gigabytes(setup.totalBytes))"
                    + (setup.usingMirror ? " · mirror" : "")
                if line != last {
                    print(line)
                    fflush(stdout)
                    last = line
                }
            }
        }
    }
}
