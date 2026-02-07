import Foundation
import Darwin

final class BackendServiceManager: ObservableObject {
    static let shared = BackendServiceManager()

    enum State: String {
        case idle
        case starting
        case running
        case failed
    }

    struct Configuration {
        var backendExecutableName: String = "voxtral-backend"
        var bundleSubdirectory: String = "backend"
        var appSupportFolderName: String = "Voxtral"
        var backendFolderName: String = "backend"
        var bundleIDFileName: String = "backend-bundle-id.txt"
        var defaultPort: Int = 8765
        var maxRestartAttempts: Int = 5
        var baseRetryDelay: TimeInterval = 1.0
        var maxRetryDelay: TimeInterval = 30.0
        var terminationTimeout: TimeInterval = 2.0
        // If the backend survives at least this long, treat it as a "good" run and reset
        // restart attempts so later crashes get a fresh retry budget.
        var stableUptimeToResetRestartAttempts: TimeInterval = 10.0
    }

    enum BackendServiceError: Error {
        case bundleExecutableMissing
    }

    private let configuration: Configuration
    private let queue = DispatchQueue(label: "voxtral.backend.service")
    private var process: Process?
    private var restartWorkItem: DispatchWorkItem?
    private var terminationWorkItem: DispatchWorkItem?
    private var restartAttempts = 0
    private var shouldKeepRunning = false
    private var modelPath: String?
    private var modelName: String?
    private var modelBackend: String?
    private var processStartUptime: TimeInterval?

    @Published private(set) var state: State = .idle

    var isBackendReady: Bool {
        state == .running && process?.isRunning == true
    }

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            AppLogger.shared.logBackendStart()
            self.shouldKeepRunning = true
            self.restartAttempts = 0
            self.restartWorkItem?.cancel()
            self.restartWorkItem = nil
            self.startIfNeeded()
        }
    }

    func configureModel(modelPath: String?, modelName: String?, backend: String?) {
        queue.async { [weak self] in
            self?.modelPath = modelPath
            self?.modelName = modelName
            self?.modelBackend = backend
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            AppLogger.shared.logBackendStop()
            self.shouldKeepRunning = false
            self.restartWorkItem?.cancel()
            self.restartWorkItem = nil
            self.terminateProcess()
            self.setState(.idle)
        }
    }

    private func startIfNeeded() {
        guard shouldKeepRunning else { return }
        guard process?.isRunning != true else { return }
        launchProcess()
    }

    private func launchProcess() {
        setState(.starting)

        do {
            let executableURL = try prepareBackendExecutable(forceCopy: false)
            try runProcess(at: executableURL)
            setState(.running)
            AppLogger.shared.logBackendStarted()
        } catch {
            do {
                let executableURL = try prepareBackendExecutable(forceCopy: true)
                try runProcess(at: executableURL)
                setState(.running)
                AppLogger.shared.logBackendStarted()
            } catch {
                scheduleRestart()
            }
        }
    }

    private func runProcess(at executableURL: URL) throws {
        let process = Process()
        process.executableURL = executableURL
        process.environment = buildEnvironment()
        process.terminationHandler = { [weak self] terminatedProcess in
            self?.handleTermination(of: terminatedProcess)
        }
        try process.run()
        self.process = process
        self.processStartUptime = ProcessInfo.processInfo.systemUptime
    }

    private func handleTermination(of terminatedProcess: Process) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.process === terminatedProcess else { return }
            AppLogger.shared.logBackendTerminated(exitCode: Int(terminatedProcess.terminationStatus))

            if let startedAt = self.processStartUptime {
                let lifetime = max(0, ProcessInfo.processInfo.systemUptime - startedAt)
                if lifetime >= self.configuration.stableUptimeToResetRestartAttempts {
                    self.restartAttempts = 0
                }
            }

            self.process = nil
            self.processStartUptime = nil

            if self.shouldKeepRunning {
                self.scheduleRestart()
            } else {
                self.setState(.idle)
                AppLogger.shared.logBackendStopped()
            }
        }
    }

    private func terminateProcess() {
        guard let process else { return }
        terminationWorkItem?.cancel()
        terminationWorkItem = nil
        if process.isRunning {
            process.terminate()
            let processID = process.processIdentifier
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                defer { self.terminationWorkItem = nil }
                guard process.isRunning else { return }
                AppLogger.shared.logWarning("Backend did not exit after SIGTERM; sending SIGKILL")
                kill(processID, SIGKILL)
            }
            terminationWorkItem = workItem
            queue.asyncAfter(deadline: .now() + configuration.terminationTimeout, execute: workItem)
        }
        self.process = nil
        self.processStartUptime = nil
    }

    private func scheduleRestart() {
        guard shouldKeepRunning else { return }
        restartAttempts += 1

        guard restartAttempts <= configuration.maxRestartAttempts else {
            setState(.failed)
            shouldKeepRunning = false
            AppLogger.shared.logBackendFailed()
            return
        }

        AppLogger.shared.logBackendRestart(attempt: restartAttempts, maxAttempts: configuration.maxRestartAttempts)

        let delay = min(
            configuration.baseRetryDelay * pow(2.0, Double(restartAttempts - 1)),
            configuration.maxRetryDelay
        )

        let workItem = DispatchWorkItem { [weak self] in
            self?.startIfNeeded()
        }

        restartWorkItem?.cancel()
        restartWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func setState(_ newState: State) {
        DispatchQueue.main.async { [weak self] in
            self?.state = newState
        }
    }

    private func prepareBackendExecutable(forceCopy: Bool) throws -> URL {
        let fileManager = FileManager.default
        let backendDirectory = try backendDirectoryURL()
        let destinationURL = backendDirectory.appendingPathComponent(configuration.backendExecutableName)
        let pythonRuntimeURL = backendDirectory.appendingPathComponent("python-runtime", isDirectory: true)
        var isDirectory: ObjCBool = false
        let hasPythonRuntime = fileManager.fileExists(atPath: pythonRuntimeURL.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        let pythonShimURL = pythonRuntimeURL.appendingPathComponent("bin/python3")

        let bundleBackendDirectory = bundledBackendDirectoryURL()
        let bundleID = bundleBackendDirectory.flatMap { backendBundleID(in: $0) }
        let installedID = backendBundleID(in: backendDirectory)
        let isBundleIDMismatch = shouldReplaceInstalledBackend(
            installedDirectory: backendDirectory,
            bundledDirectory: bundleBackendDirectory,
            installedID: installedID,
            bundleID: bundleID
        )

        let needsCopy = forceCopy
            || !fileManager.isExecutableFile(atPath: destinationURL.path)
            || !hasPythonRuntime
            || shouldReplacePythonShim(at: pythonShimURL)
            || isBundleIDMismatch

        if needsCopy {
            try installBackendExecutable(at: destinationURL)
        }

        return destinationURL
    }

    private enum BackendInstallKind: Int {
        case unknown = 0
        case shim = 1
        case full = 2
    }

    private func backendInstallKind(in directory: URL) -> BackendInstallKind {
        let runtimeURL = directory.appendingPathComponent("python-runtime", isDirectory: true)

        // "Full" bundle marker: python-build-standalone layout includes lib/pythonX.Y/site-packages.
        // We check for a required dependency folder to avoid accidental false positives.
        let fullMarker = runtimeURL
            .appendingPathComponent("lib/python3.12/site-packages/websockets", isDirectory: true)
        if FileManager.default.fileExists(atPath: fullMarker.path) {
            return .full
        }

        // Shim marker: at least a python entrypoint exists.
        let shimMarker = runtimeURL.appendingPathComponent("bin/python3")
        if FileManager.default.fileExists(atPath: shimMarker.path) {
            return .shim
        }

        return .unknown
    }

    private func shouldReplaceInstalledBackend(
        installedDirectory: URL,
        bundledDirectory: URL?,
        installedID: String?,
        bundleID: String?
    ) -> Bool {
        guard let bundledDirectory else { return false }
        guard let bundleID else { return false }

        // Bundle IDs match: keep installed backend.
        if bundleID == installedID {
            return false
        }

        // Avoid "downgrading" a fully bundled backend to the debug shim.
        //
        // This matters in local development: once you build a fully bundled backend (VOXTRAL_BUNDLE_BACKEND=1),
        // launching a normal Debug build (which uses the lightweight shim) should keep the working backend
        // instead of overwriting it with a shim that lacks dependencies.
        let installedKind = backendInstallKind(in: installedDirectory)
        let bundledKind = backendInstallKind(in: bundledDirectory)
        if installedKind == .full && bundledKind == .shim {
            return false
        }

        // Otherwise, refresh to match the bundle (upgrade shim->full, update full->full, etc).
        return true
    }

    private func backendBundleID(in directory: URL) -> String? {
        let url = directory.appendingPathComponent(configuration.bundleIDFileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func shouldReplacePythonShim(at url: URL) -> Bool {
        // Older Debug builds wrote a python shim that used `/usr/bin/env python3.12`, which frequently
        // fails for GUI-launched apps/tests because PATH does not include Homebrew.
        //
        // If we detect that legacy shim, refresh the backend folder from the current app bundle.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        let prefix = (try? handle.read(upToCount: 256)) ?? Data()
        guard !prefix.isEmpty else { return false }
        guard let text = String(data: prefix, encoding: .utf8) else { return false }
        return text.contains("/usr/bin/env") && (text.contains("python3.12") || text.contains("python3"))
    }

    private func backendDirectoryURL() throws -> URL {
        let fileManager = FileManager.default
        let appSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appFolderURL = appSupportURL.appendingPathComponent(
            configuration.appSupportFolderName,
            isDirectory: true
        )
        let backendFolderURL = appFolderURL.appendingPathComponent(
            configuration.backendFolderName,
            isDirectory: true
        )

        try fileManager.createDirectory(at: backendFolderURL, withIntermediateDirectories: true)
        return backendFolderURL
    }

    private func huggingFaceHomeURL() -> URL? {
        let fileManager = FileManager.default
        guard let appSupportURL = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }

        let appFolderURL = appSupportURL.appendingPathComponent(
            configuration.appSupportFolderName,
            isDirectory: true
        )

        let hfURL = appFolderURL.appendingPathComponent("hf", isDirectory: true)
        try? fileManager.createDirectory(at: hfURL, withIntermediateDirectories: true)
        return hfURL
    }

    private func installBackendExecutable(at destinationURL: URL) throws {
        let fileManager = FileManager.default
        guard let sourceDirectoryURL = bundledBackendDirectoryURL() else {
            throw BackendServiceError.bundleExecutableMissing
        }

        let destinationDirectoryURL = destinationURL.deletingLastPathComponent()

        if fileManager.fileExists(atPath: destinationDirectoryURL.path) {
            try? fileManager.removeItem(at: destinationDirectoryURL)
        }

        try fileManager.copyItem(at: sourceDirectoryURL, to: destinationDirectoryURL)
        let executableDestinationURL = destinationDirectoryURL.appendingPathComponent(configuration.backendExecutableName)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableDestinationURL.path)
    }

    private func bundledBackendDirectoryURL() -> URL? {
        let fileManager = FileManager.default
        let bundle = Bundle.main
        let candidates: [URL] = [
            bundle.url(forResource: configuration.bundleSubdirectory, withExtension: nil),
            bundle.resourceURL?.appendingPathComponent(configuration.bundleSubdirectory),
            bundle.bundleURL.appendingPathComponent(configuration.bundleSubdirectory),
            bundle.bundleURL.appendingPathComponent("Contents/Resources").appendingPathComponent(configuration.bundleSubdirectory),
            bundle.bundleURL.appendingPathComponent("Contents/MacOS").appendingPathComponent(configuration.bundleSubdirectory)
        ].compactMap { $0 }

        for candidate in candidates {
            let executableURL = candidate.appendingPathComponent(configuration.backendExecutableName)
            if fileManager.isExecutableFile(atPath: executableURL.path) {
                return candidate
            }
        }

        return nil
    }

    private func buildEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment

        // Server port
        if environment["VOXTRAL_PORT"] == nil {
            environment["VOXTRAL_PORT"] = "\(configuration.defaultPort)"
        }

        // Hugging Face cache root (used by faster-whisper and any other HF downloads).
        if environment["HF_HOME"] == nil, let hfURL = huggingFaceHomeURL() {
            environment["HF_HOME"] = hfURL.path
            environment["TOKENIZERS_PARALLELISM"] = "false"
            environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        }

        // Backend selection
        if environment["VOXTRAL_BACKEND"] == nil, let modelBackend {
            environment["VOXTRAL_BACKEND"] = modelBackend
        }

        // Model configuration - opinionated defaults for Voxtral-Mini-4B-Realtime-2602
        if environment["VOXTRAL_MODEL_PATH"] == nil, let modelPath {
            environment["VOXTRAL_MODEL_PATH"] = modelPath
        }
        if environment["VOXTRAL_MODEL_NAME"] == nil {
            if let modelName {
                environment["VOXTRAL_MODEL_NAME"] = modelName
            } else {
                environment["VOXTRAL_MODEL_NAME"] = modelPath ?? "mistralai/Voxtral-Mini-4B-Realtime-2602"
            }
        }
        if environment["VOXTRAL_DTYPE"] == nil {
            // vLLM uses strings like "bfloat16"/"float16" (not "bf16"/"f16").
            environment["VOXTRAL_DTYPE"] = "bfloat16"
        }
        if environment["VOXTRAL_TEMPERATURE"] == nil {
            environment["VOXTRAL_TEMPERATURE"] = "0.0"
        }
        if environment["VOXTRAL_TRANSCRIPTION_DELAY_MS"] == nil {
            environment["VOXTRAL_TRANSCRIPTION_DELAY_MS"] = "480"
        }
        if environment["VOXTRAL_MAX_AUDIO_QUEUE_SIZE"] == nil {
            environment["VOXTRAL_MAX_AUDIO_QUEUE_SIZE"] = "\(BackpressureDefaults.maxFrames)"
        }
        if environment["VOXTRAL_MAX_MODEL_LEN"] == nil {
            // 131072 tokens ~3 hours at default settings
            environment["VOXTRAL_MAX_MODEL_LEN"] = "131072"
        }
        if environment["VOXTRAL_USE_MLX"] == nil {
            environment["VOXTRAL_USE_MLX"] = "true"
        }
        if environment["VOXTRAL_MEMORY_FRACTION"] == nil {
            environment["VOXTRAL_MEMORY_FRACTION"] = "0.9"
        }

        return environment
    }
}
