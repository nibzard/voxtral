import Foundation
import os.log

final class AppLogger {
    static let shared = AppLogger()

    private let subsystem = "com.voxtral.menu"
    private let log: OSLog

    private init() {
        log = OSLog(subsystem: subsystem, category: "default")
    }

    // Lifecycle events
    func logApplicationLaunch() {
        logInfo("Application launched")
    }

    func logApplicationTerminate() {
        logInfo("Application terminating")
    }

    func logBackendStart() {
        logInfo("Starting backend service")
    }

    func logBackendStarted() {
        logInfo("Backend service started")
    }

    func logBackendStop() {
        logInfo("Stopping backend service")
    }

    func logBackendStopped() {
        logInfo("Backend service stopped")
    }

    func logBackendTerminated(exitCode: Int?) {
        if let code = exitCode {
            logError("Backend process terminated with exit code: \(code)")
        } else {
            logError("Backend process terminated")
        }
    }

    func logBackendRestart(attempt: Int, maxAttempts: Int) {
        logInfo("Backend restart attempt \(attempt)/\(maxAttempts)")
    }

    func logBackendFailed() {
        logError("Backend service failed after maximum restart attempts")
    }

    // Recording events
    func logRecordingStart(outputFile: String) {
        logInfo("Recording started, output: \(outputFile.lastPathComponent)")
    }

    func logRecordingStop(duration: TimeInterval) {
        logInfo("Recording stopped, duration: \(String(format: "%.1f", duration))s")
    }

    func logTranscriptionSessionStart(sessionId: String) {
        logInfo("Transcription session started: \(sessionId)")
    }

    func logTranscriptionSessionEnd(sessionId: String, reason: String) {
        logInfo("Transcription session ended: \(sessionId), reason: \(reason)")
    }

    // Audio events
    func logAudioEngineStart() {
        logInfo("Audio capture started")
    }

    func logAudioEngineStop() {
        logInfo("Audio capture stopped")
    }

    func logAudioEngineError(_ error: Error) {
        logError("Audio engine error: \(error.localizedDescription)")
    }

    func logBackpressureEntered(source: String) {
        logInfo("Backpressure entered: \(source)")
    }

    func logBackpressureRecovered(source: String) {
        logInfo("Backpressure recovered: \(source)")
    }

    func logFramesDropped(count: Int, total: UInt64) {
        logWarning("Dropped \(count) frames (total dropped: \(total))")
    }

    // WebSocket events
    func logWebSocketConnecting(url: String) {
        logInfo("WebSocket connecting: \(url)")
    }

    func logWebSocketConnected() {
        logInfo("WebSocket connected")
    }

    func logWebSocketDisconnected(code: Int, reason: String?) {
        logInfo("WebSocket disconnected: code=\(code), reason=\(reason ?? "none")")
    }

    func logWebSocketError(_ error: Error) {
        logError("WebSocket error: \(error.localizedDescription)")
    }

    // File I/O events
    func logFileCreated(path: String) {
        logInfo("Output file created: \(path.lastPathComponent)")
    }

    func logFileWriteError(path: String, error: Error) {
        logError("File write error: \(path.lastPathComponent) - \(error.localizedDescription)")
    }

    func logFileClosed(path: String) {
        logInfo("Output file closed: \(path.lastPathComponent)")
    }

    // Model events
    func logModelCheckStarted() {
        logInfo("Model availability check started")
    }

    func logModelFound() {
        logInfo("Model found and verified")
    }

    func logModelNotFound() {
        logInfo("Model not found, download required")
    }

    func logModelDownloadProgress(downloaded: Int64, total: Int64) {
        let percent = Int((Double(downloaded) / Double(total)) * 100)
        logInfo("Model download progress: \(percent)%")
    }

    func logModelDownloadCompleted() {
        logInfo("Model download completed")
    }

    func logModelDownloadError(_ error: Error) {
        logError("Model download failed: \(error.localizedDescription)")
    }

    func logModelVerificationFailed() {
        logError("Model verification failed")
    }

    // Rewrite events
    func logRewriteStarted() {
        logInfo("Gemini rewrite started")
    }

    func logRewriteCompleted() {
        logInfo("Gemini rewrite completed")
    }

    func logRewriteError(_ error: Error) {
        logError("Gemini rewrite failed: \(error.localizedDescription)")
    }

    // Permission events
    func logMicrophonePermissionGranted() {
        logInfo("Microphone permission granted")
    }

    func logMicrophonePermissionDenied() {
        logWarning("Microphone permission denied")
    }

    func logOutputFolderAccessGranted(folder: String) {
        logInfo("Output folder access granted: \(folder.lastPathComponent)")
    }

    func logOutputFolderAccessDenied(folder: String) {
        logWarning("Output folder access denied: \(folder.lastPathComponent)")
    }

    // Error logging
    func logError(_ message: String) {
        os_log("%{public}@", log: log, type: .error, message)
    }

    func logWarning(_ message: String) {
        os_log("%{public}@", log: log, type: .fault, message)
    }

    func logInfo(_ message: String) {
        os_log("%{public}@", log: log, type: .info, message)
    }

    func logDebug(_ message: String) {
        os_log("%{public}@", log: log, type: .debug, message)
    }
}
