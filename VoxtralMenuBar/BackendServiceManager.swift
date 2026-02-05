import Foundation

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
        var defaultPort: Int = 8765
        var maxRestartAttempts: Int = 5
        var baseRetryDelay: TimeInterval = 1.0
        var maxRetryDelay: TimeInterval = 30.0
    }

    enum BackendServiceError: Error {
        case bundleExecutableMissing
    }

    private let configuration: Configuration
    private let queue = DispatchQueue(label: "voxtral.backend.service")
    private var process: Process?
    private var restartWorkItem: DispatchWorkItem?
    private var restartAttempts = 0
    private var shouldKeepRunning = false
    private var modelPath: String?

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
            self.startIfNeeded()
        }
    }

    func setModelPath(_ path: String?) {
        queue.async { [weak self] in
            self?.modelPath = path
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
            restartAttempts = 0
            setState(.running)
            AppLogger.shared.logBackendStarted()
        } catch {
            do {
                let executableURL = try prepareBackendExecutable(forceCopy: true)
                try runProcess(at: executableURL)
                restartAttempts = 0
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
    }

    private func handleTermination(of terminatedProcess: Process) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.process === terminatedProcess else { return }
            AppLogger.shared.logBackendTerminated(exitCode: Int(terminatedProcess.terminationStatus))
            self.process = nil

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
        if process.isRunning {
            process.terminate()
        }
        self.process = nil
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

        let needsCopy = forceCopy
            || !fileManager.isExecutableFile(atPath: destinationURL.path)
            || !hasPythonRuntime

        if needsCopy {
            try installBackendExecutable(at: destinationURL)
        }

        return destinationURL
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

        // Model configuration - opinionated defaults for Voxtral-Mini-4B-Realtime-2602
        if environment["VOXTRAL_MODEL_PATH"] == nil, let modelPath {
            environment["VOXTRAL_MODEL_PATH"] = modelPath
        }
        if environment["VOXTRAL_MODEL_NAME"] == nil {
            environment["VOXTRAL_MODEL_NAME"] = modelPath ?? "mistralai/Voxtral-Mini-4B-Realtime-2602"
        }
        if environment["VOXTRAL_DTYPE"] == nil {
            environment["VOXTRAL_DTYPE"] = "bf16"
        }
        if environment["VOXTRAL_TEMPERATURE"] == nil {
            environment["VOXTRAL_TEMPERATURE"] = "0.0"
        }
        if environment["VOXTRAL_TRANSCRIPTION_DELAY_MS"] == nil {
            environment["VOXTRAL_TRANSCRIPTION_DELAY_MS"] = "480"
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
