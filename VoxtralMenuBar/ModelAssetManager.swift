import Foundation
import CryptoKit

final class ModelAssetManager: NSObject {
    static let shared = ModelAssetManager()

    enum BackendKind: String, Codable {
        case voxtral = "voxtral"
        case whisper = "whisper"
    }

    enum ModelChoice: String, CaseIterable, Identifiable, Codable {
        case fasterWhisperTiny = "Systran/faster-whisper-tiny"
        case fasterWhisperBase = "Systran/faster-whisper-base"
        case fasterWhisperSmall = "Systran/faster-whisper-small"
        case voxtralMini4BRealtime2602 = "mistralai/Voxtral-Mini-4B-Realtime-2602"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .fasterWhisperTiny:
                return "Whisper Tiny (faster-whisper)"
            case .fasterWhisperBase:
                return "Whisper Base (faster-whisper)"
            case .fasterWhisperSmall:
                return "Whisper Small (faster-whisper)"
            case .voxtralMini4BRealtime2602:
                return "Voxtral Mini 4B Realtime"
            }
        }

        var backendKind: BackendKind {
            switch self {
            case .fasterWhisperTiny, .fasterWhisperBase, .fasterWhisperSmall:
                return .whisper
            case .voxtralMini4BRealtime2602:
                return .voxtral
            }
        }

        var requiresManagedDownload: Bool {
            switch self {
            case .voxtralMini4BRealtime2602:
                return true
            case .fasterWhisperTiny, .fasterWhisperBase, .fasterWhisperSmall:
                return false
            }
        }

        var estimatedDownloadBytes: Int64 {
            // These are approximate. faster-whisper pulls a repo snapshot into the HF cache.
            switch self {
            case .fasterWhisperTiny:
                return 80 * 1024 * 1024
            case .fasterWhisperBase:
                return 180 * 1024 * 1024
            case .fasterWhisperSmall:
                return 520 * 1024 * 1024
            case .voxtralMini4BRealtime2602:
                return 0
            }
        }

        var defaultModelNameForBackend: String {
            rawValue
        }
    }

    enum State {
        case unknown
        case checking
        case missing
        case downloading(progress: Double)
        case verifying
        case ready
        case failed(Error)
    }

    struct ModelFile: Codable {
        let fileName: String
        let downloadURL: URL
        let sha256: String
        let fileSize: Int64
    }

    struct ModelArchive: Codable {
        let downloadURL: URL
        let sha256: String
        let fileSize: Int64
    }

    struct ModelInfo: Codable {
        let name: String
        let version: String
        let files: [ModelFile]
        let archive: ModelArchive?

        var modelIdentifier: String {
            "\(name)-\(version)"
        }
    }

    private static let selectedModelDefaultsKey = "voxtral.selected_model"

    struct ModelImportError: Error, LocalizedError {
        enum Kind {
            case invalidDirectory
            case invalidArchive
            case extractionFailed(underlying: Error)
            case missingModelFiles
            case checksumMismatch(expected: String, actual: String)
            case copyFailed(underlying: Error)
            case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
            case downloadFailed(underlying: Error)
        }

        let kind: Kind

        var errorDescription: String? {
            switch kind {
            case .invalidDirectory:
                return "The selected directory is not a valid model directory."
            case .invalidArchive:
                return "The selected file is not a supported model archive."
            case .extractionFailed(let underlying):
                return "Failed to extract the model archive: \(underlying.localizedDescription)"
            case .missingModelFiles:
                return "Required model files are missing from the selected directory."
            case .checksumMismatch(let expected, let actual):
                return "Model verification failed. Checksum mismatch: expected \(expected), got \(actual)"
            case .copyFailed(let underlying):
                return "Failed to copy model files: \(underlying.localizedDescription)"
            case .insufficientDiskSpace(let requiredBytes, let availableBytes):
                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                let required = formatter.string(fromByteCount: requiredBytes)
                let available = formatter.string(fromByteCount: availableBytes)
                return "Not enough disk space to download the model. Need \(required) free, but only \(available) is available."
            case .downloadFailed(let underlying):
                let message = Self.userFacingDownloadErrorMessage(for: underlying)
                return "Failed to download model: \(message)"
            }
        }

        init(_ kind: Kind) {
            self.kind = kind
        }

        private static func userFacingDownloadErrorMessage(for error: Error) -> String {
            // Most failures here are URLSession/CFNetwork errors which otherwise surface as an unreadable
            // userInfo dump in `localizedDescription` (e.g. CFNetworkDownload_* keys). Prefer a short,
            // actionable message.
            if let urlError = error as? URLError {
                switch urlError.code {
                case .notConnectedToInternet:
                    return "No internet connection."
                case .timedOut:
                    return "The download timed out."
                case .networkConnectionLost:
                    return "Network connection was lost."
                case .cannotFindHost:
                    return "Cannot find the download host."
                case .cannotConnectToHost:
                    return "Cannot connect to the download host."
                case .secureConnectionFailed:
                    return "Secure connection failed."
                case .cannotWriteToFile, .cannotCreateFile:
                    return "Cannot write the downloaded file. Check disk space and permissions."
                case .cancelled:
                    return "Download was cancelled."
                default:
                    return urlError.localizedDescription
                }
            }

            let nsError = error as NSError
            if nsError.domain == NSPOSIXErrorDomain && nsError.code == 28 {
                return "No space left on device."
            }

            return error.localizedDescription
        }
    }

    private let configuration: Configuration
    private let queue = DispatchQueue(label: "voxtral.model.assets")
    private var session: URLSession!
    private var downloadTask: URLSessionDownloadTask?
    private var downloadQueue: [ModelFile] = []
    private var downloadStagingURL: URL?
    private var totalExpectedBytes: Int64 = 0
    private var completedBytes: Int64 = 0
    private var currentDownload: ModelFile?
    private var currentArchive: ModelArchive?
    private var lastReportedProgress: Double = 0
    private var stateChangeHandlers: [UUID: (State) -> Void] = [:]
    private var selectedModelChoice: ModelChoice
    private var currentState: State = .unknown {
        didSet {
            notifyStateChange(currentState)
        }
    }

    private(set) var state: State {
        get { queue.sync { currentState } }
        set { queue.async { [weak self] in self?.currentState = newValue } }
    }

    var modelDirectoryURL: URL {
        let fileManager = FileManager.default
        let appSupportURL = try! fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appFolderURL = appSupportURL.appendingPathComponent(configuration.appSupportFolderName, isDirectory: true)
        return appFolderURL.appendingPathComponent(configuration.modelsFolderName, isDirectory: true)
    }

    var defaultModelDirectoryURL: URL {
        modelDirectoryURL.appendingPathComponent(selectedModelInfo.modelIdentifier, isDirectory: true)
    }

    var isReady: Bool {
        queue.sync {
            if case .ready = currentState {
                return true
            }
            return false
        }
    }

    struct Configuration {
        var appSupportFolderName: String = "Voxtral"
        var modelsFolderName: String = "models"
        // Large model downloads can take a long time (several GB).
        var downloadTimeout: TimeInterval = 6 * 60 * 60
    }

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.selectedModelChoice = Self.loadInitialSelectedModelChoice(configuration: configuration)
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = configuration.downloadTimeout
        config.timeoutIntervalForResource = configuration.downloadTimeout
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    var selectedModel: ModelChoice {
        queue.sync { selectedModelChoice }
    }

    func setSelectedModel(_ choice: ModelChoice, autoDownload: Bool = true) {
        queue.async { [weak self] in
            guard let self else { return }
            guard choice != self.selectedModelChoice else { return }

            UserDefaults.standard.set(choice.rawValue, forKey: Self.selectedModelDefaultsKey)
            self.selectedModelChoice = choice

            // Cancel any in-flight download and re-check for the new model.
            if let task = self.downloadTask {
                self.downloadTask = nil
                task.cancel()
            }
            self.cleanupStagingLocked()
            self.resetDownloadState()
            self.currentState = .unknown
            self.checkModelAvailability(autoDownload: autoDownload)
        }
    }

    func selectedModelBackendKind() -> BackendKind {
        queue.sync { selectedModelChoice.backendKind }
    }

    func selectedModelNameForBackend() -> String {
        queue.sync { selectedModelChoice.defaultModelNameForBackend }
    }

    func expectedDownloadBytes(for choice: ModelChoice) -> Int64 {
        if !choice.requiresManagedDownload {
            return choice.estimatedDownloadBytes
        }
        let info = modelInfo(for: choice)
        return info.archive?.fileSize ?? info.files.reduce(0) { $0 + $1.fileSize }
    }

    func checkModelAvailability(autoDownload: Bool = true) {
        queue.async { [weak self] in
            guard let self else { return }
            AppLogger.shared.logModelCheckStarted()
            self.currentState = .checking

            // faster-whisper models are downloaded on-demand by the backend into the Hugging Face cache.
            // Treat these as "ready" from the app's perspective.
            if !self.selectedModelChoice.requiresManagedDownload {
                self.currentState = .ready
                AppLogger.shared.logModelFound()
                return
            }

            let fileManager = FileManager.default
            let info = self.selectedModelInfo
            let modelURL = self.modelDirectoryURL.appendingPathComponent(info.modelIdentifier)

            if fileManager.fileExists(atPath: modelURL.path) {
                do {
                    try self.verifyModel(at: modelURL, modelInfo: info)
                    self.currentState = .ready
                    AppLogger.shared.logModelFound()
                } catch {
                    AppLogger.shared.logModelVerificationFailed()
                    self.currentState = .failed(error)
                }
            } else {
                AppLogger.shared.logModelNotFound()
                self.currentState = .missing
                if autoDownload {
                    self.startDownloadLocked()
                }
            }
        }
    }

    func downloadModel() {
        queue.async { [weak self] in
            guard let self else { return }
            switch self.currentState {
            case .missing, .failed:
                self.startDownloadLocked()
            default:
                return
            }
        }
    }

    func resetModel(deleteInstalledModel: Bool = true) {
        queue.async { [weak self] in
            guard let self else { return }

            if !self.selectedModelChoice.requiresManagedDownload {
                self.currentState = .ready
                return
            }

            if let task = self.downloadTask {
                self.downloadTask = nil
                task.cancel()
            }

            self.cleanupStagingLocked()
            self.resetDownloadState()

            if deleteInstalledModel {
                let fileManager = FileManager.default
                let url = self.defaultModelDirectoryURL
                if fileManager.fileExists(atPath: url.path) {
                    try? fileManager.removeItem(at: url)
                }
            }

            self.currentState = .missing
        }
    }

    func importModel(from sourceURL: URL) {
        queue.async { [weak self] in
            guard let self else { return }

            self.currentState = .verifying

            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                self.currentState = .failed(ModelImportError(.invalidDirectory))
                return
            }

            do {
                let destinationURL = self.modelDirectoryURL.appendingPathComponent(self.selectedModelInfo.modelIdentifier)

                if sourceURL.hasDirectoryPath {
                    try self.installModel(from: sourceURL, to: destinationURL)
                } else {
                    let extractedURL = try self.extractArchiveIfNeeded(from: sourceURL)
                    try self.installModel(from: extractedURL, to: destinationURL)
                }

                self.currentState = .ready
            } catch {
                self.currentState = .failed(error)
            }
        }
    }

    func observeState(_ handler: @escaping (State) -> Void) -> Any {
        queue.sync {
            let id = UUID()
            stateChangeHandlers[id] = handler
            handler(currentState)
            return id
        }
    }

    func removeObserver(_ token: Any) {
        queue.sync {
            guard let id = token as? UUID else { return }
            stateChangeHandlers.removeValue(forKey: id)
        }
    }

    func modelPathForBackend() -> String? {
        var result: String?
        queue.sync {
            guard case .ready = currentState else { return }
            let info = selectedModelInfo
            let modelURL = modelDirectoryURL.appendingPathComponent(info.modelIdentifier)
            switch selectedModelChoice {
            case .voxtralMini4BRealtime2602:
                result = modelURL.path
            case .fasterWhisperTiny, .fasterWhisperBase, .fasterWhisperSmall:
                // faster-whisper models are managed via the Hugging Face cache; we only pass VOXTRAL_MODEL_NAME.
                result = nil
            }
        }
        return result
    }

    private var selectedModelInfo: ModelInfo {
        modelInfo(for: selectedModelChoice)
    }

    private func modelInfo(for choice: ModelChoice) -> ModelInfo {
        Self.modelInfos[choice] ?? Self.voxtralModelInfo
    }

    private func startDownloadLocked() {
        guard downloadTask == nil else { return }
        resetDownloadState()

        do {
            // Ensure the destination parent folder exists so users can open it in Finder
            // (and so our final move doesn't fail due to a missing directory).
            try FileManager.default.createDirectory(at: modelDirectoryURL, withIntermediateDirectories: true)
        } catch {
            self.currentState = .failed(error)
            return
        }

        // Preflight disk space before starting the download. URLSession tends to surface failures here as
        // cryptic CFNetworkDownload_* errors once the file is nearly complete.
        let info = selectedModelInfo
        let expectedBytes: Int64 = info.archive?.fileSize
            ?? info.files.reduce(0) { $0 + $1.fileSize }
        let safetyBytes = max(Int64(200 * 1024 * 1024), Int64(Double(expectedBytes) * 0.02))
        let requiredBytes = expectedBytes + safetyBytes
        if let availableBytes = availableDiskSpaceBytes(), availableBytes < requiredBytes {
            self.currentState = .failed(ModelImportError(.insufficientDiskSpace(
                requiredBytes: requiredBytes,
                availableBytes: availableBytes
            )))
            return
        }

        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxtral-model-\(UUID().uuidString)")
            .appendingPathComponent(info.modelIdentifier)

        do {
            try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        } catch {
            self.currentState = .failed(error)
            return
        }

        downloadStagingURL = stagingRoot
        completedBytes = 0
        lastReportedProgress = 0

        if let archive = info.archive {
            currentArchive = archive
            totalExpectedBytes = archive.fileSize
            currentState = .downloading(progress: 0.0)
            let task = session.downloadTask(with: archive.downloadURL)
            downloadTask = task
            task.resume()
            return
        }

        downloadQueue = info.files
        totalExpectedBytes = downloadQueue.reduce(0) { $0 + $1.fileSize }
        currentState = .downloading(progress: 0.0)
        startNextDownloadLocked()
    }

    private func startNextDownloadLocked() {
        guard !downloadQueue.isEmpty else {
            finalizeDownloadLocked()
            return
        }

        let next = downloadQueue.removeFirst()
        currentDownload = next
        let task = session.downloadTask(with: next.downloadURL)
        downloadTask = task
        task.resume()
    }

    private func finalizeDownloadLocked() {
        guard let stagingRoot = downloadStagingURL else {
            currentState = .failed(ModelImportError(.downloadFailed(
                underlying: NSError(domain: "ModelAssetManager", code: -1, userInfo: nil)
            )))
            return
        }

        currentState = .verifying

        defer {
            cleanupStagingLocked()
            resetDownloadState()
        }

        do {
            try installDownloadedModel(from: stagingRoot, to: defaultModelDirectoryURL)
            try verifyModel(at: defaultModelDirectoryURL, modelInfo: selectedModelInfo)
            currentState = .ready
            AppLogger.shared.logModelDownloadCompleted()
        } catch {
            currentState = .failed(error)
        }
    }
}

extension ModelAssetManager: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host.lowercased()
        guard Self.isPinnedHost(host) else {
            AppLogger.shared.logError("Model download blocked: no pin for host \(host)")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        guard Self.evaluateServerTrust(serverTrust, host: host) else {
            AppLogger.shared.logError("Model download blocked: TLS trust failed for host \(host)")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        guard Self.isServerTrustPinned(serverTrust, host: host) else {
            AppLogger.shared.logError("Model download blocked: certificate pin mismatch for host \(host)")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            guard downloadTask == self.downloadTask else { return }

            let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : self.currentExpectedBytes()
            let overall = self.completedBytes + totalBytesWritten
            let progress = self.totalExpectedBytes > 0 ? Double(overall) / Double(self.totalExpectedBytes) : 0

            if abs(progress - self.lastReportedProgress) > 0.001 {
                self.lastReportedProgress = progress
                self.currentState = .downloading(progress: min(max(progress, 0), 1))
                AppLogger.shared.logModelDownloadProgress(downloaded: overall, total: max(self.totalExpectedBytes, expected))
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Important: URLSession deletes the file at `location` after this delegate method returns.
        // We must move it synchronously before returning.
        queue.sync { [weak self] in
            guard let self else { return }
            guard downloadTask == self.downloadTask else { return }

            if let archive = self.currentArchive {
                self.handleArchiveDownloadFinished(at: location, archive: archive)
                return
            }

            guard let file = self.currentDownload else {
                self.currentState = .failed(ModelImportError(.downloadFailed(
                    underlying: NSError(domain: "ModelAssetManager", code: -2, userInfo: nil)
                )))
                return
            }

            do {
                try self.handleFileDownloadFinished(at: location, file: file)
            } catch {
                self.currentState = .failed(error)
                self.cleanupStagingLocked()
                self.resetDownloadState()
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            guard task == self.downloadTask else { return }

            if let error = error {
                AppLogger.shared.logModelDownloadError(error)
                self.currentState = .failed(ModelImportError(.downloadFailed(underlying: error)))
                self.cleanupStagingLocked()
                self.resetDownloadState()
            }
        }
    }
}

private extension ModelAssetManager {
    func cleanupStagingLocked() {
        guard let stagingRoot = downloadStagingURL else { return }

        // stagingRoot ends with ".../voxtral-model-UUID/<modelIdentifier>"
        // Remove the UUID folder to clean up everything for this download attempt.
        let stagingContainer = stagingRoot.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: stagingContainer)
    }

    func availableDiskSpaceBytes() -> Int64? {
        // Be conservative: the download is staged in `temporaryDirectory` and then moved into
        // Application Support. If these end up on different volumes, we should respect the minimum.
        let candidates: [URL] = [
            FileManager.default.temporaryDirectory,
            modelDirectoryURL
        ]

        let capacities = candidates.compactMap { volumeAvailableCapacityBytes(for: $0) }
        return capacities.min()
    }

    func volumeAvailableCapacityBytes(for url: URL) -> Int64? {
        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let capacity = values.volumeAvailableCapacityForImportantUsage {
                return Int64(capacity)
            }
        } catch {
            // Fall back below.
        }

        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            if let capacity = values.volumeAvailableCapacity {
                return Int64(capacity)
            }
        } catch {
            return nil
        }

        return nil
    }

    func currentExpectedBytes() -> Int64 {
        if let archive = currentArchive {
            return archive.fileSize
        }
        return currentDownload?.fileSize ?? 0
    }

    func verifyModel(at url: URL) throws {
        try verifyModel(at: url, modelInfo: selectedModelInfo)
    }

    func verifyModel(at url: URL, modelInfo: ModelInfo) throws {
        for file in modelInfo.files {
            let fileURL = url.appendingPathComponent(file.fileName)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw ModelImportError(.missingModelFiles)
            }
            guard let checksum = computeChecksum(for: fileURL) else {
                throw ModelImportError(.checksumMismatch(expected: file.sha256, actual: "unknown"))
            }
            if normalizeChecksum(checksum) != normalizeChecksum(file.sha256) {
                throw ModelImportError(.checksumMismatch(expected: file.sha256, actual: checksum))
            }
        }
    }

    func computeChecksum(for url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hash = SHA256()
        while true {
            let data = try? handle.read(upToCount: 4 * 1024 * 1024)
            guard let data, !data.isEmpty else { break }
            hash.update(data: data)
        }

        return hash.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    func normalizeChecksum(_ checksum: String) -> String {
        let lowered = checksum.lowercased()
        if lowered.hasPrefix("sha256:") {
            return String(lowered.dropFirst(7))
        }
        return lowered
    }

    func handleFileDownloadFinished(at location: URL, file: ModelFile) throws {
        guard let stagingRoot = downloadStagingURL else {
            throw ModelImportError(.downloadFailed(
                underlying: NSError(domain: "ModelAssetManager", code: -3, userInfo: nil)
            ))
        }

        let destinationURL = stagingRoot.appendingPathComponent(file.fileName)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.moveItem(at: location, to: destinationURL)

        guard let checksum = computeChecksum(for: destinationURL) else {
            throw ModelImportError(.checksumMismatch(expected: file.sha256, actual: "unknown"))
        }

        guard normalizeChecksum(checksum) == normalizeChecksum(file.sha256) else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw ModelImportError(.checksumMismatch(expected: file.sha256, actual: checksum))
        }

        completedBytes += file.fileSize
        currentDownload = nil
        downloadTask = nil
        startNextDownloadLocked()
    }

    func handleArchiveDownloadFinished(at location: URL, archive: ModelArchive) {
        currentState = .verifying

        do {
            guard let checksum = computeChecksum(for: location) else {
                throw ModelImportError(.checksumMismatch(expected: archive.sha256, actual: "unknown"))
            }
            guard normalizeChecksum(checksum) == normalizeChecksum(archive.sha256) else {
                throw ModelImportError(.checksumMismatch(expected: archive.sha256, actual: checksum))
            }

            let archiveURL = try persistDownloadedArchive(from: location, archive: archive)
            let extractedURL = try extractArchiveIfNeeded(from: archiveURL)
            let destinationURL = modelDirectoryURL.appendingPathComponent(selectedModelInfo.modelIdentifier)
            try installModel(from: extractedURL, to: destinationURL)
            currentState = .ready
            AppLogger.shared.logModelDownloadCompleted()
        } catch {
            currentState = .failed(error)
        }

        resetDownloadState()
    }

    func persistDownloadedArchive(from location: URL, archive: ModelArchive) throws -> URL {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxtral-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let fileName = archive.downloadURL.lastPathComponent.isEmpty ? "model-archive" : archive.downloadURL.lastPathComponent
        let destination = tempRoot.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: location, to: destination)
        return destination
    }

    func installDownloadedModel(from sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: modelDirectoryURL, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    func installModel(from sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: modelDirectoryURL, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)

        do {
            try verifyModel(at: destinationURL)
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    func extractArchiveIfNeeded(from sourceURL: URL) throws -> URL {
        guard !sourceURL.hasDirectoryPath else { return sourceURL }

        let lowercased = sourceURL.lastPathComponent.lowercased()
        guard lowercased.hasSuffix(".zip") || lowercased.hasSuffix(".tar.gz") || lowercased.hasSuffix(".tgz") || lowercased.hasSuffix(".tar") else {
            throw ModelImportError(.invalidArchive)
        }

        let destinationRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxtral-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        do {
            try extractArchive(at: sourceURL, to: destinationRoot)
        } catch {
            throw ModelImportError(.extractionFailed(underlying: error))
        }

        let resolvedRoot = try resolveExtractedRoot(from: destinationRoot)
        try verifyModel(at: resolvedRoot, modelInfo: selectedModelInfo)

        return resolvedRoot
    }

    func resolveExtractedRoot(from directory: URL) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        if contents.count == 1 {
            let url = contents[0]
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                return url
            }
        }

        return directory
    }

    func extractArchive(at archiveURL: URL, to destinationURL: URL) throws {
        let process = Process()
        let path = archiveURL.path.lowercased()

        if path.hasSuffix(".zip") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-q", "-o", archiveURL.path, "-d", destinationURL.path]
        } else if path.hasSuffix(".tar.gz") || path.hasSuffix(".tgz") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xzf", archiveURL.path, "-C", destinationURL.path]
        } else if path.hasSuffix(".tar") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xf", archiveURL.path, "-C", destinationURL.path]
        } else {
            throw ModelImportError(.invalidArchive)
        }

        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "ModelAssetManager", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
    }

    func resetDownloadState() {
        downloadTask = nil
        currentDownload = nil
        currentArchive = nil
        downloadQueue = []
        downloadStagingURL = nil
        totalExpectedBytes = 0
        completedBytes = 0
        lastReportedProgress = 0
    }

    func notifyStateChange(_ newState: State) {
        for handler in stateChangeHandlers.values {
            DispatchQueue.main.async {
                handler(newState)
            }
        }
    }
}

private extension ModelAssetManager {
    static let pinnedCertificateHashesByHost: [String: Set<String>] = [
        // Amazon RSA 2048 M02 intermediate (huggingface.co)
        "huggingface.co": ["sPMwoxoMUJh+HDp7sCwt2mgpkdMWW1F71E+6SmAgvZQ="],
        // Amazon RSA 2048 M04 intermediate (cas-bridge.xethub.hf.co)
        "cas-bridge.xethub.hf.co": ["E4vfbiOslx605iayed1qJvBXUQ8d45QpOl7qKGDeAZs="]
    ]

    static func isPinnedHost(_ host: String) -> Bool {
        pinnedCertificateHashesByHost[host] != nil
    }

    static func evaluateServerTrust(_ serverTrust: SecTrust, host: String) -> Bool {
        let policy = SecPolicyCreateSSL(true, host as CFString)
        SecTrustSetPolicies(serverTrust, policy)
        var error: CFError?
        return SecTrustEvaluateWithError(serverTrust, &error)
    }

    static func isServerTrustPinned(_ serverTrust: SecTrust, host: String) -> Bool {
        guard let pins = pinnedCertificateHashesByHost[host], !pins.isEmpty else { return false }
        let chainHashes = certificateChainHashes(for: serverTrust)
        return !pins.isDisjoint(with: chainHashes)
    }

    static func certificateChainHashes(for trust: SecTrust) -> Set<String> {
        var hashes: Set<String> = []
        let count = SecTrustGetCertificateCount(trust)
        guard count > 0 else { return hashes }

        for index in 0..<count {
            guard let certificate = SecTrustGetCertificateAtIndex(trust, index) else { continue }
            let data = SecCertificateCopyData(certificate) as Data
            let digest = SHA256.hash(data: data)
            let hash = Data(digest).base64EncodedString()
            hashes.insert(hash)
        }

        return hashes
    }

    static let fasterWhisperTinyInfo = ModelInfo(
        name: "faster-whisper-tiny",
        version: "1",
        files: [],
        archive: nil
    )

    static let fasterWhisperBaseInfo = ModelInfo(
        name: "faster-whisper-base",
        version: "1",
        files: [],
        archive: nil
    )

    static let fasterWhisperSmallInfo = ModelInfo(
        name: "faster-whisper-small",
        version: "1",
        files: [],
        archive: nil
    )

    static let voxtralModelInfo = ModelInfo(
        name: "Voxtral-Mini-4B-Realtime-2602",
        version: "2602",
        files: [
            ModelFile(
                fileName: "consolidated.safetensors",
                downloadURL: URL(string: "https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602/resolve/main/consolidated.safetensors")!,
                sha256: "263f178fe752c90a2ae58f037a95ed092db8b14768b0978b8c48f66979c8345d",
                fileSize: 8_859_462_744
            ),
            ModelFile(
                fileName: "params.json",
                downloadURL: URL(string: "https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602/resolve/main/params.json")!,
                sha256: "2ace010ebf7f0b62c60747d91c6d140e3c7238632d3e9c63d60a2bd2065ea301",
                fileSize: 1_343
            ),
            ModelFile(
                fileName: "tekken.json",
                downloadURL: URL(string: "https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602/resolve/main/tekken.json")!,
                sha256: "8434af1d39eba99f0ef46cf1450bf1a63fa941a26933a1ef5dbbf4adf0d00e44",
                fileSize: 14_910_348
            )
        ],
        archive: nil
    )

    static let modelInfos: [ModelChoice: ModelInfo] = [
        .fasterWhisperTiny: fasterWhisperTinyInfo,
        .fasterWhisperBase: fasterWhisperBaseInfo,
        .fasterWhisperSmall: fasterWhisperSmallInfo,
        .voxtralMini4BRealtime2602: voxtralModelInfo,
    ]

    static func loadInitialSelectedModelChoice(configuration: Configuration) -> ModelChoice {
        if let raw = UserDefaults.standard.string(forKey: selectedModelDefaultsKey),
           let choice = ModelChoice(rawValue: raw) {
            return choice
        }
        // Default to the smaller/friendlier option for Apple Silicon.
        return .fasterWhisperBase
    }
}
