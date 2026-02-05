import Foundation
import Darwin

final class OutputWriter {
    struct Configuration {
        var modelName: String
        var appName: String
        var appVersion: String
        var deviceDescription: String

        init(
            modelName: String = OutputWriter.defaultModelName,
            appName: String = OutputWriter.defaultAppName,
            appVersion: String = OutputWriter.defaultAppVersion,
            deviceDescription: String = OutputWriter.defaultDeviceDescription
        ) {
            self.modelName = modelName
            self.appName = appName
            self.appVersion = appVersion
            self.deviceDescription = deviceDescription
        }
    }

    enum OutputWriterError: Error {
        case invalidOutputDirectory
        case fileCreationFailed
    }

    private let queue = DispatchQueue(label: "voxtral.output.writer")
    private let queueKey = DispatchSpecificKey<Void>()
    private let fileHandle: FileHandle
    private let sessionDate: Date
    private var isClosed = false

    let fileURL: URL

    init(outputDirectory: URL, configuration: Configuration = Configuration(), date: Date = Date()) throws {
        guard outputDirectory.isFileURL else {
            throw OutputWriterError.invalidOutputDirectory
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: outputDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw OutputWriterError.invalidOutputDirectory
        }

        queue.setSpecific(key: queueKey, value: ())

        sessionDate = date
        fileURL = OutputWriter.uniqueFileURL(in: outputDirectory, for: date)

        let header = OutputWriter.header(for: date, configuration: configuration)
        guard let headerData = header.data(using: .utf8) else {
            throw OutputWriterError.fileCreationFailed
        }

        guard FileManager.default.createFile(atPath: fileURL.path, contents: headerData, attributes: nil) else {
            throw OutputWriterError.fileCreationFailed
        }

        fileHandle = try FileHandle(forWritingTo: fileURL)
        fileHandle.seekToEndOfFile()

        AppLogger.shared.logFileCreated(path: fileURL.path)
    }

    func appendTranscript(_ message: TranscriptionClient.TranscriptMessage, includePartial: Bool = false) {
        guard includePartial || message.isFinal else { return }
        appendLine(timestampMs: message.startMs, text: message.text)
    }

    func appendLine(timestampMs: Int, text: String) {
        let sanitized = OutputWriter.sanitize(text)
        guard !sanitized.isEmpty else { return }
        let line = "[\(OutputWriter.formatTimestamp(timestampMs))] \(sanitized)\n"
        write(line)
    }

    func appendRawLine(_ line: String) {
        let value = line.hasSuffix("\n") ? line : "\(line)\n"
        write(value)
    }

    func finish() {
        let closeBlock = {
            guard !self.isClosed else { return }
            if let data = "\n".data(using: .utf8) {
                self.fileHandle.write(data)
            }
            self.fileHandle.closeFile()
            self.isClosed = true
            AppLogger.shared.logFileClosed(path: self.fileURL.path)
        }

        if DispatchQueue.getSpecific(key: queueKey) != nil {
            closeBlock()
        } else {
            queue.sync(execute: closeBlock)
        }
    }

    deinit {
        finish()
    }
}

internal extension OutputWriter {
    static let defaultModelName = "Voxtral-Mini-4B-Realtime-2602"

    static var defaultAppName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Voxtral Menu Bar Transcriber"
    }

    static var defaultAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static var defaultDeviceDescription: String {
        let modelIdentifier = readSysctlString("hw.model") ?? "Mac"
        let chipDescription: String
        #if arch(arm64)
        chipDescription = "Apple Silicon"
        #else
        chipDescription = readSysctlString("machdep.cpu.brand_string") ?? "Intel"
        #endif
        return "\(modelIdentifier) (\(chipDescription))"
    }

    static func fileName(for date: Date) -> String {
        let baseName = fileNameFormatter.string(from: date)
        return fileName(for: baseName, suffixIndex: 0)
    }

    static func uniqueFileURL(in directory: URL, for date: Date) -> URL {
        let baseName = fileNameFormatter.string(from: date)
        let key = uniqueKey(directory: directory, baseName: baseName)
        var selectedIndex = 0

        uniqueFileNameQueue.sync {
            var index = (lastUsedIndexByKey[key] ?? -1) + 1
            while FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(fileName(for: baseName, suffixIndex: index)).path
            ) {
                index += 1
            }
            lastUsedIndexByKey[key] = index
            selectedIndex = index
        }

        return directory.appendingPathComponent(fileName(for: baseName, suffixIndex: selectedIndex))
    }

    static func header(for date: Date, configuration: Configuration) -> String {
        let title = "# Transcript - \(titleFormatter.string(from: date))"
        let metadata = [
            "- Device: \(configuration.deviceDescription)",
            "- Model: \(configuration.modelName)",
            "- App: \(configuration.appName) \(configuration.appVersion)"
        ].joined(separator: "\n")

        return "\(title)\n\n\(metadata)\n\n"
    }

    static func formatTimestamp(_ milliseconds: Int) -> String {
        let safeMs = max(0, milliseconds)
        let totalSeconds = safeMs / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let ms = safeMs % 1000
        return String(format: "%02d:%02d.%03d", minutes, seconds, ms)
    }

    static func sanitize(_ text: String) -> String {
        let components = text.split(whereSeparator: { $0.isNewline })
        let collapsed = components.joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func readSysctlString(_ name: String) -> String? {
        var size: size_t = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static let fileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter
    }()

    static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    func write(_ string: String) {
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            guard let data = string.data(using: .utf8) else { return }
            self.fileHandle.write(data)
        }
    }

    private static let uniqueFileNameQueue = DispatchQueue(label: "voxtral.output.writer.filename")
    private static var lastUsedIndexByKey: [String: Int] = [:]

    private static func uniqueKey(directory: URL, baseName: String) -> String {
        "\(directory.path)::\(baseName)"
    }

    private static func fileName(for baseName: String, suffixIndex: Int) -> String {
        if suffixIndex == 0 {
            return "\(baseName)_transcript.md"
        }
        return "\(baseName)_\(suffixIndex)_transcript.md"
    }
}
