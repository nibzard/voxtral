import AppKit
import AVFoundation
import SwiftUI
import Combine

enum RecordingStatus: String {
    case idle = "Idle"
    case initializing = "Initializing"
    case recording = "Recording"
    case transcribing = "Transcribing"
    case backpressure = "Buffering"
    case error = "Error"
}

enum AppError: LocalizedError {
    case microphoneDenied
    case backendLaunchFailed
    case backendNotReady
    case modelNotReady
    case modelDownloadFailed(any Error)
    case outputFolderUnavailable
    case outputFolderAccessDenied
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is required for transcription."
        case .backendLaunchFailed:
            return "The transcription backend failed to start. Please try again."
        case .backendNotReady:
            return "The transcription service is initializing. Please wait."
        case .modelNotReady:
            return "The speech model is still downloading. Please wait."
        case .modelDownloadFailed(let error):
            return error.localizedDescription
        case .outputFolderUnavailable:
            return "Output folder is not available. Please select a different folder."
        case .outputFolderAccessDenied:
            return "Access to the output folder was denied. Please select a new folder."
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .microphoneDenied:
            return "Open System Settings > Privacy & Security > Microphone to enable access."
        case .backendLaunchFailed:
            return "Click Retry to restart the backend service."
        case .backendNotReady:
            return "Wait a moment and try recording again."
        case .modelNotReady:
            return "Wait for the model download to complete."
        case .modelDownloadFailed(let error):
            if let modelError = error as? ModelAssetManager.ModelImportError {
                switch modelError.kind {
                case .insufficientDiskSpace:
                    return "Free up disk space (models can be several GB) and retry the download."
                case .checksumMismatch:
                    return "The downloaded file was corrupted. Retry the download."
                default:
                    break
                }
            }
            return "Check your network connection and retry the download."
        case .outputFolderUnavailable, .outputFolderAccessDenied:
            return "Click Change to select a new output folder."
        case .transcriptionFailed:
            return "Try stopping and starting a new recording."
        }
    }

    var isRecoverable: Bool {
        switch self {
        case .microphoneDenied, .backendLaunchFailed, .outputFolderUnavailable, .outputFolderAccessDenied:
            return true
        case .backendNotReady, .modelNotReady, .modelDownloadFailed, .transcriptionFailed:
            return false
        }
    }
}

final class MenuBarViewModel: ObservableObject {
    @Published var status: RecordingStatus = .idle
    @Published var outputFolderURL: URL?
    @Published var currentError: AppError?
    @Published var hasGeminiAPIKey: Bool = false
    @Published var isRewriteEnabled: Bool = false
    @Published var isRewriting: Bool = false
    @Published var geminiAPIKeyInput: String = ""
    @Published var currentLatencyMs: Double = 0
    @Published var isInBackpressure: Bool = false
    @Published var modelStatusText: String = "Checking model..."
    @Published var modelDownloadProgress: Double? = nil
    @Published var isModelReady: Bool = false
    @Published var selectedModel: ModelAssetManager.ModelChoice
    @ObservedObject private var backendServiceManager: BackendServiceManager
    private let modelAssetManager: ModelAssetManager

    private let outputFolderBookmarkKey = "OutputFolderBookmark"
    private let geminiAPIKeyKeychainKey = "gemini_api_key"
    private let rewriteEnabledKey = "rewrite_enabled"
    private var securityScopedURL: URL?

    private var audioCapturePipeline: AudioCapturePipeline?
    private var transcriptionClient: TranscriptionClient?
    private var outputWriter: OutputWriter?
    private var keychainManager: KeychainManager?

    private var backendStateCancellable: AnyCancellable?
    private var pendingStartAfterPermission = false
    private var transcriptLines: [(timestampMs: Int, text: String)] = []
    private var latencyUpdateTimer: Timer?
    private var recordingStartTime: TimeInterval?
    private var audioBackpressureActive = false
    private var clientBackpressureActive = false
    private var modelStateToken: Any?
    private var isStopping = false

    private var huggingFaceHomeURL: URL {
        let fileManager = FileManager.default
        let appSupportURL = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.homeDirectoryForCurrentUser

        let appFolderURL = appSupportURL.appendingPathComponent("Voxtral", isDirectory: true)
        let hfURL = appFolderURL.appendingPathComponent("hf", isDirectory: true)
        try? fileManager.createDirectory(at: hfURL, withIntermediateDirectories: true)
        return hfURL
    }

    init(
        backendServiceManager: BackendServiceManager = .shared,
        modelAssetManager: ModelAssetManager = .shared
    ) {
        self.backendServiceManager = backendServiceManager
        self.modelAssetManager = modelAssetManager
        self.selectedModel = modelAssetManager.selectedModel
        self.keychainManager = KeychainManager()
        restoreOutputFolder()
        restoreGeminiSettings()
        promptForOutputFolderIfNeeded()
        requestMicrophonePermissionIfNeeded()
        observeBackendState()
        observeModelState()
    }

    var statusText: String {
        status.rawValue
    }

    var recordButtonTitle: String {
        switch status {
        case .recording, .transcribing, .initializing, .backpressure:
            return "Stop Recording"
        case .idle, .error:
            return "Record"
        }
    }

    var recordButtonTint: Color {
        switch status {
        case .recording, .transcribing:
            return .red
        case .initializing, .backpressure:
            return .orange
        case .idle, .error:
            return .accentColor
        }
    }

    var outputFolderPath: String {
        outputFolderURL?.path ?? "Not set"
    }

    var isOutputFolderSet: Bool {
        outputFolderURL != nil
    }

    var isRecordButtonDisabled: Bool {
        if status == .recording || status == .transcribing || status == .initializing || status == .backpressure {
            return false
        }
        if isRewriting {
            return true
        }
        return !isModelReady
    }

    var shouldShowModelStatus: Bool {
        !isModelReady || modelDownloadProgress != nil
    }

    var selectedModelDisplayName: String {
        selectedModel.displayName
    }

    var selectedModelDownloadSizeText: String {
        let bytes = modelAssetManager.expectedDownloadBytes(for: selectedModel)
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    var modelDownloadPath: String {
        switch selectedModel.backendKind {
        case .voxtral:
            return modelAssetManager.defaultModelDirectoryURL.path
        case .whisper:
            return huggingFaceHomeURL.path
        }
    }

    var modelStorageRootPath: String {
        switch selectedModel.backendKind {
        case .voxtral:
            return modelAssetManager.modelDirectoryURL.path
        case .whisper:
            return huggingFaceHomeURL.path
        }
    }

    func toggleRecording() {
        switch status {
        case .recording, .transcribing, .initializing, .backpressure:
            stopRecording()
        case .idle, .error:
            startRecording()
        }
    }

    private func startRecording() {
        guard !isStopping else { return }
        guard !isRewriting else { return }
        clearError()
        transcriptLines.removeAll()
        recordingStartTime = Date().timeIntervalSince1970
        currentLatencyMs = 0
        isInBackpressure = false
        audioBackpressureActive = false
        clientBackpressureActive = false

        switch microphoneAccessState() {
        case .authorized:
            pendingStartAfterPermission = false
            AppLogger.shared.logMicrophonePermissionGranted()
        case .notDetermined:
            pendingStartAfterPermission = true
            requestMicrophonePermissionIfNeeded()
            status = .initializing
            return
        case .denied:
            pendingStartAfterPermission = false
            AppLogger.shared.logMicrophonePermissionDenied()
            setError(.microphoneDenied)
            return
        }

        guard let outputFolderURL else {
            setError(.outputFolderUnavailable)
            selectOutputFolder()
            return
        }

        if let error = ensureOutputFolderAccess(for: outputFolderURL) {
            handleOutputFolderIssue(error)
            setError(error)
            promptForOutputFolderIfNeeded()
            return
        }
        AppLogger.shared.logOutputFolderAccessGranted(folder: outputFolderURL.path)

        let modelState = modelAssetManager.state
        applyModelState(modelState)
        guard case .ready = modelState else {
            if case .failed = modelState {
                return
            }
            setError(.modelNotReady)
            return
        }

        guard backendServiceManager.isBackendReady else {
            setError(.backendNotReady)
            return
        }

        status = .initializing

        do {
            let configuredModelName = selectedModel.defaultModelNameForBackend
            let resolvedModelName = configuredModelName.split(separator: "/").last.map(String.init) ?? configuredModelName
            let configuration = OutputWriter.Configuration(modelName: resolvedModelName)
            outputWriter = try OutputWriter(outputDirectory: outputFolderURL, configuration: configuration)
        } catch {
            handleOutputWriterError(error)
            return
        }

        if let outputFileURL = outputWriter?.fileURL {
            AppLogger.shared.logRecordingStart(outputFile: outputFileURL.path)
        }

        audioCapturePipeline = AudioCapturePipeline()
        transcriptionClient = TranscriptionClient()

        setupTranscriptionClientEvents()
        setupBackpressureCallbacks()
        startLatencyUpdates()

        let delayMs: Int = (selectedModel.backendKind == .whisper) ? 1500 : 480
        transcriptionClient?.startSession(configuration: .init(transcriptionDelayMs: delayMs))

        do {
            try audioCapturePipeline?.start(onFrames: { [weak self] frames in
                self?.transcriptionClient?.sendFrames(frames)
            })
            // Status will be updated to .recording when backend sends ready event
        } catch {
            cleanupRecording()
            setError(.transcriptionFailed("Failed to start audio capture"))
        }
    }

    private func stopRecording() {
        guard !isStopping else { return }
        isStopping = true
        pendingStartAfterPermission = false

        let writer = outputWriter
        let outputFileURL = writer?.fileURL
        let startTime = recordingStartTime
        var didFinalizeStop = false

        let finalizeStop: () -> Void = { [weak self] in
            guard let self else { return }
            guard !didFinalizeStop else { return }
            didFinalizeStop = true
            writer?.finish()

            if let startTime {
                let duration = Date().timeIntervalSince1970 - startTime
                AppLogger.shared.logRecordingStop(duration: duration)
            }

            let transcriptSnapshot = self.transcriptLines
            let shouldRewrite = self.hasGeminiAPIKey && self.isRewriteEnabled && !transcriptSnapshot.isEmpty
            if shouldRewrite, let fileURL = outputFileURL {
                Task { @MainActor in
                    await self.performRewrite(for: fileURL, transcriptLines: transcriptSnapshot)
                }
            }

            self.cleanupRecording()
            self.recordingStartTime = nil
            self.currentLatencyMs = 0
            self.isInBackpressure = false
            self.audioBackpressureActive = false
            self.clientBackpressureActive = false
            if self.currentError == nil {
                self.status = .idle
                self.clearError()
            }
            self.isStopping = false
        }

        audioCapturePipeline?.stop()

        if let client = transcriptionClient {
            client.stopSession {
                DispatchQueue.main.async {
                    finalizeStop()
                }
            }
        } else {
            finalizeStop()
        }
    }

    private func cleanupRecording() {
        audioCapturePipeline = nil
        transcriptionClient = nil
        outputWriter = nil
        latencyUpdateTimer?.invalidate()
        latencyUpdateTimer = nil
    }

    private func setupTranscriptionClientEvents() {
        transcriptionClient?.onEvent = { [weak self] event in
            guard let self else { return }
            DispatchQueue.main.async {
                switch event {
                case .ready:
                    self.status = .recording
                    self.applyBackpressureState()
                case .status(let statusMsg):
                    switch statusMsg.state {
                    case "initializing":
                        self.status = .initializing
                    case "warming":
                        self.status = .initializing
                    case "running":
                        self.status = .recording
                        self.applyBackpressureState()
                    default:
                        break
                    }
                case .transcript(let transcript):
                    self.outputWriter?.appendTranscript(transcript)
                    if transcript.isFinal {
                        self.transcriptLines.append((timestampMs: transcript.startMs, text: transcript.text))
                    }
                case .backendError(let errorMessage):
                    if self.status == .recording || self.status == .initializing || self.status == .backpressure {
                        self.stopRecording()
                        self.setError(.transcriptionFailed(errorMessage.message))
                    }
                case .sessionEnd(let sessionEnd):
                    if self.status == .recording || self.status == .initializing || self.status == .backpressure {
                        self.stopRecording()
                        if sessionEnd.reason != "client_stop" {
                            self.setError(.transcriptionFailed("Session ended: \(sessionEnd.reason)"))
                        }
                    }
                case .disconnected:
                    if self.status == .recording || self.status == .initializing || self.status == .backpressure {
                        self.stopRecording()
                        self.setError(.backendNotReady)
                    }
                case .failure(let error):
                    if self.status == .recording || self.status == .initializing || self.status == .backpressure {
                        self.stopRecording()
                        self.setError(.transcriptionFailed(error.localizedDescription))
                    }
                }
            }
        }
    }

    private func setupBackpressureCallbacks() {
        audioCapturePipeline?.setBackpressureCallback { [weak self] isInBackpressure in
            guard let self else { return }
            DispatchQueue.main.async {
                self.audioBackpressureActive = isInBackpressure
                self.applyBackpressureState()
            }
        }

        transcriptionClient?.onBackpressureChanged = { [weak self] isInBackpressure in
            guard let self else { return }
            DispatchQueue.main.async {
                self.clientBackpressureActive = isInBackpressure
                self.applyBackpressureState()
            }
        }
    }

    private func applyBackpressureState() {
        let combinedBackpressure = audioBackpressureActive || clientBackpressureActive
        isInBackpressure = combinedBackpressure
        if combinedBackpressure, status == .recording {
            status = .backpressure
        } else if !combinedBackpressure, status == .backpressure {
            status = .recording
        }
    }

    private func startLatencyUpdates() {
        latencyUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateLatencyMetrics()
        }
    }

    private func updateLatencyMetrics() {
        guard let pipeline = audioCapturePipeline else { return }
        let metrics = pipeline.currentMetrics

        let frameDurationMs: Double = 20.0
        let pipelineDepth = metrics.currentQueueDepth
        let clientDepth = transcriptionClient?.currentQueueDepth ?? 0
        let queueDepth = max(pipelineDepth, clientDepth)
        let queueLatencyMs = Double(queueDepth) * frameDurationMs

        currentLatencyMs = queueLatencyMs
    }

    func selectOutputFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.directoryURL = outputFolderURL ?? FileManager.default.homeDirectoryForCurrentUser

        if panel.runModal() == .OK {
            if let url = panel.url {
                applyOutputFolderSelection(url)
            }
        }
    }

    func openOutputFolder() {
        guard let url = outputFolderURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openModelFolder() {
        if selectedModel.backendKind == .whisper {
            NSWorkspace.shared.open(huggingFaceHomeURL)
            return
        }

        let fileManager = FileManager.default
        let modelURL = modelAssetManager.defaultModelDirectoryURL

        if fileManager.fileExists(atPath: modelURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([modelURL])
        } else {
            NSWorkspace.shared.open(modelAssetManager.modelDirectoryURL)
        }
    }

    func quitApp() {
        NSApp.terminate(nil)
    }

    func openSystemSettingsForMicrophone() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func retryBackend() {
        clearError()
        backendServiceManager.start()
    }

    func retryModelDownload() {
        clearErrorIfModelError()
        modelAssetManager.downloadModel()
    }

    func resetModel() {
        clearErrorIfModelError()
        if selectedModel.backendKind == .whisper {
            resetWhisperCache()
        } else {
            modelAssetManager.resetModel(deleteInstalledModel: true)
        }
    }

    func applySelectedModel(_ model: ModelAssetManager.ModelChoice) {
        clearErrorIfModelError()
        selectedModel = model
        modelAssetManager.setSelectedModel(model, autoDownload: true)
    }

    func saveGeminiAPIKey() {
        let trimmed = geminiAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        do {
            try keychainManager?.store(key: geminiAPIKeyKeychainKey, value: trimmed)
            hasGeminiAPIKey = true
        } catch {
            hasGeminiAPIKey = false
        }
        geminiAPIKeyInput = ""
    }

    func deleteGeminiAPIKey() {
        do {
            try keychainManager?.delete(key: geminiAPIKeyKeychainKey)
        } catch {}
        hasGeminiAPIKey = false
        isRewriteEnabled = false
        UserDefaults.standard.set(false, forKey: rewriteEnabledKey)
    }

    func toggleRewrite() {
        isRewriteEnabled.toggle()
        UserDefaults.standard.set(isRewriteEnabled, forKey: rewriteEnabledKey)
    }
}

private extension MenuBarViewModel {
    func performRewrite(for fileURL: URL, transcriptLines: [(timestampMs: Int, text: String)]) async {
        isRewriting = true
        defer { isRewriting = false }

        let rawTranscript = transcriptLines.map { "[\(OutputWriter.formatTimestamp($0.timestampMs))] \($0.text)" }.joined(separator: "\n")
        guard !rawTranscript.isEmpty else {
            return
        }

        do {
            guard let apiKey = try keychainManager?.retrieve(key: geminiAPIKeyKeychainKey) else {
                return
            }

            let configuration = GeminiRewriteService.Configuration(apiKey: apiKey)
            let service = GeminiRewriteService(configuration: configuration)

            let request = GeminiRewriteService.RewriteRequest(transcript: rawTranscript, configuration: configuration)
            let response = try await service.rewrite(request)

            try replaceTranscriptInFile(at: fileURL, with: response.rewrittenText)
        } catch {
            // Silently fail - the spec says to keep the original transcript on error
        }
    }

    func replaceTranscriptInFile(at url: URL, with rewrittenText: String) throws {
        let content = try String(contentsOf: url, encoding: .utf8)
        // The header format is: "# Title\n\nMetadata lines\n\n"
        // We need to find the end of the full header, which ends with two consecutive newlines
        // after the metadata block (not the first blank line after the title)
        guard let titleEndIndex = content.range(of: "\n\n", options: []) else {
            return
        }

        // Find the metadata section - starts after title's \n\n, ends at the next \n\n
        let afterTitle = content[titleEndIndex.upperBound...]
        guard let metadataEndIndex = afterTitle.range(of: "\n\n", options: []) else {
            return
        }

        // Calculate the absolute position of the header end in the full content
        let headerEndAbsoluteOffset = content.distance(from: content.startIndex, to: titleEndIndex.upperBound) +
                                      content.distance(from: afterTitle.startIndex, to: metadataEndIndex.upperBound)
        let headerEndIndex = content.index(content.startIndex, offsetBy: headerEndAbsoluteOffset)

        let header = String(content[..<headerEndIndex])
        let newContent = header + rewrittenText + "\n"
        try newContent.write(to: url, atomically: true, encoding: .utf8)
    }
}

private extension MenuBarViewModel {
    func observeModelState() {
        modelStateToken = modelAssetManager.observeState { [weak self] state in
            DispatchQueue.main.async {
                self?.applyModelState(state)
            }
        }
    }

    func applyModelState(_ state: ModelAssetManager.State) {
        switch state {
        case .unknown, .checking:
            isModelReady = false
            modelDownloadProgress = nil
            modelStatusText = "Checking model..."
        case .missing:
            isModelReady = false
            modelDownloadProgress = nil
            modelStatusText = "\(selectedModelDisplayName) missing. Click Retry Download."
        case .downloading(let progress):
            isModelReady = false
            modelDownloadProgress = progress
            modelStatusText = "Downloading \(selectedModelDisplayName) \(Int(progress * 100))%"
            clearErrorIfModelError()
        case .verifying:
            isModelReady = false
            modelDownloadProgress = nil
            modelStatusText = "Verifying \(selectedModelDisplayName)..."
        case .ready:
            isModelReady = true
            modelDownloadProgress = nil
            if selectedModel.backendKind == .whisper {
                modelStatusText = "\(selectedModelDisplayName) (downloads on first use)"
            } else {
                modelStatusText = "\(selectedModelDisplayName) ready"
            }
            clearErrorIfModelError()
        case .failed(let error):
            isModelReady = false
            modelDownloadProgress = nil
            modelStatusText = "\(selectedModelDisplayName) download failed"
            setError(.modelDownloadFailed(error))
        }
    }

    func clearErrorIfModelError() {
        if let error = currentError {
            switch error {
            case .modelDownloadFailed, .modelNotReady:
                clearError()
            default:
                break
            }
        }
    }

    func resetWhisperCache() {
        let fileManager = FileManager.default
        let rootURL = huggingFaceHomeURL
        if fileManager.fileExists(atPath: rootURL.path) {
            try? fileManager.removeItem(at: rootURL)
        }
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        // Restart the backend so the next session re-loads from a clean cache.
        backendServiceManager.stop()
        backendServiceManager.start()
    }

    enum MicrophoneAccessState {
        case authorized
        case notDetermined
        case denied
    }

    func observeBackendState() {
        backendStateCancellable = backendServiceManager.$state.sink { [weak self] state in
            guard let self else { return }
            if state == .failed && self.currentError == nil {
                self.setError(.backendLaunchFailed)
            }
        }
    }

    func promptForOutputFolderIfNeeded() {
        guard outputFolderURL == nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.selectOutputFolder()
        }
    }

    func restoreOutputFolder() {
        guard let data = UserDefaults.standard.data(forKey: outputFolderBookmarkKey) else { return }
        var isStale = false

        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            outputFolderURL = url
            if isStale {
                storeBookmark(for: url)
            }
            if let error = ensureOutputFolderAccess(for: url) {
                handleOutputFolderIssue(error)
                setError(error)
            }
        } catch {
            UserDefaults.standard.removeObject(forKey: outputFolderBookmarkKey)
        }
    }

    func applyOutputFolderSelection(_ url: URL) {
        outputFolderURL = url
        storeBookmark(for: url)
        if let error = ensureOutputFolderAccess(for: url) {
            handleOutputFolderIssue(error)
            setError(error)
            return
        }
        clearError()
    }

    func restoreGeminiSettings() {
        do {
            let _ = try keychainManager?.retrieve(key: geminiAPIKeyKeychainKey)
            hasGeminiAPIKey = true
        } catch {
            hasGeminiAPIKey = false
        }
        isRewriteEnabled = UserDefaults.standard.bool(forKey: rewriteEnabledKey)
    }

    func storeBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: outputFolderBookmarkKey)
        } catch {
            UserDefaults.standard.removeObject(forKey: outputFolderBookmarkKey)
        }
    }

    @discardableResult
    func startAccessingSecurityScopedResource(_ url: URL) -> Bool {
        if let existingURL = securityScopedURL, existingURL == url {
            return true
        }
        if let existingURL = securityScopedURL {
            existingURL.stopAccessingSecurityScopedResource()
        }
        if url.startAccessingSecurityScopedResource() {
            securityScopedURL = url
            return true
        }
        securityScopedURL = nil
        return false
    }

    func microphoneAccessState() -> MicrophoneAccessState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .authorized
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    func requestMicrophonePermissionIfNeeded() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                if granted {
                    if self.pendingStartAfterPermission {
                        self.pendingStartAfterPermission = false
                        self.startRecording()
                    }
                } else {
                    self.pendingStartAfterPermission = false
                    self.setError(.microphoneDenied)
                }
            }
        }
    }

    func ensureOutputFolderAccess(for url: URL) -> AppError? {
        guard url.isFileURL else {
            return .outputFolderUnavailable
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .outputFolderUnavailable
        }

        guard startAccessingSecurityScopedResource(url) else {
            AppLogger.shared.logOutputFolderAccessDenied(folder: url.path)
            return .outputFolderAccessDenied
        }

        guard FileManager.default.isWritableFile(atPath: url.path) else {
            AppLogger.shared.logOutputFolderAccessDenied(folder: url.path)
            return .outputFolderAccessDenied
        }

        return nil
    }

    func handleOutputWriterError(_ error: Error) {
        let appError: AppError
        if let writerError = error as? OutputWriter.OutputWriterError {
            switch writerError {
            case .invalidOutputDirectory:
                appError = .outputFolderUnavailable
            case .fileCreationFailed:
                appError = .outputFolderAccessDenied
            }
        } else {
            appError = .transcriptionFailed("Failed to create output file.")
        }

        switch appError {
        case .outputFolderUnavailable, .outputFolderAccessDenied:
            handleOutputFolderIssue(appError)
            promptForOutputFolderIfNeeded()
        default:
            break
        }
        setError(appError)
    }

    func handleOutputFolderIssue(_ error: AppError) {
        switch error {
        case .outputFolderUnavailable, .outputFolderAccessDenied:
            clearOutputFolderSelection()
        default:
            break
        }
    }

    func clearOutputFolderSelection() {
        outputFolderURL = nil
        if let existingURL = securityScopedURL {
            existingURL.stopAccessingSecurityScopedResource()
        }
        securityScopedURL = nil
        UserDefaults.standard.removeObject(forKey: outputFolderBookmarkKey)
    }

    func setError(_ error: AppError) {
        currentError = error
        status = .error
    }

    func clearError() {
        currentError = nil
        if status == .error {
            status = .idle
        }
    }
}
