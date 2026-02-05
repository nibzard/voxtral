import Foundation

final class TranscriptionClient: NSObject {
    enum State: String {
        case idle
        case connecting
        case running
        case closing
    }

    enum Event {
        case ready(ReadyMessage)
        case status(StatusMessage)
        case transcript(TranscriptMessage)
        case backendError(ErrorMessage)
        case sessionEnd(SessionEndMessage)
        case disconnected(URLSessionWebSocketTask.CloseCode, String?)
        case failure(Error)
    }

    struct Configuration {
        var host: String = "127.0.0.1"
        var port: Int = TranscriptionClient.defaultPort
        var path: String = "/v1/transcribe"
        var useTLS: Bool = false
        var maxPendingFrames: Int = 50
        var backpressureThreshold: Int = 25
        var recoveryThreshold: Int = 10
        var backpressureEnabled: Bool = true

        var url: URL? {
            var components = URLComponents()
            components.scheme = useTLS ? "wss" : "ws"
            components.host = host
            components.port = port
            components.path = path
            return components.url
        }
    }

    struct AudioFormat: Codable {
        var sampleRate: Int
        var channels: Int
        var encoding: String
        var frameSamples: Int

        init(sampleRate: Int = 16_000, channels: Int = 1, encoding: String = "f32le", frameSamples: Int = 320) {
            self.sampleRate = sampleRate
            self.channels = channels
            self.encoding = encoding
            self.frameSamples = frameSamples
        }

        enum CodingKeys: String, CodingKey {
            case sampleRate = "sample_rate"
            case channels
            case encoding
            case frameSamples = "frame_samples"
        }
    }

    struct SessionConfiguration {
        var audioFormat: AudioFormat
        var transcriptionDelayMs: Int = 480
        var language: String = "auto"

        init(audioFormat: AudioFormat = AudioFormat(), transcriptionDelayMs: Int = 480, language: String = "auto") {
            self.audioFormat = audioFormat
            self.transcriptionDelayMs = transcriptionDelayMs
            self.language = language
        }
    }

    struct ReadyMessage: Decodable {
        let sessionId: String
        let backendVersion: String?

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case backendVersion = "backend_version"
        }
    }

    struct StatusMessage: Decodable {
        let state: String
        let detail: String?
    }

    struct TranscriptMessage: Decodable {
        let seq: Int
        let startMs: Int
        let endMs: Int
        let text: String
        let isFinal: Bool
        let confidence: Double?

        enum CodingKeys: String, CodingKey {
            case seq
            case startMs = "start_ms"
            case endMs = "end_ms"
            case text
            case isFinal = "is_final"
            case confidence
        }
    }

    struct ErrorMessage: Decodable {
        let code: String
        let message: String
        let recoverable: Bool?
    }

    struct SessionEndMessage: Decodable {
        let sessionId: String
        let reason: String

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case reason
        }
    }

    private struct StartMessage: Encodable {
        let type: String = "start"
        let sessionId: String
        let audioFormat: AudioFormat
        let transcriptionDelayMs: Int
        let language: String

        enum CodingKeys: String, CodingKey {
            case type
            case sessionId = "session_id"
            case audioFormat = "audio_format"
            case transcriptionDelayMs = "transcription_delay_ms"
            case language
        }
    }

    private struct StopMessage: Encodable {
        let type: String = "stop"
        let sessionId: String

        enum CodingKeys: String, CodingKey {
            case type
            case sessionId = "session_id"
        }
    }

    private enum IncomingMessage: Decodable {
        case ready(ReadyMessage)
        case status(StatusMessage)
        case transcript(TranscriptMessage)
        case error(ErrorMessage)
        case sessionEnd(SessionEndMessage)

        private enum CodingKeys: String, CodingKey {
            case type
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "ready":
                self = .ready(try ReadyMessage(from: decoder))
            case "status":
                self = .status(try StatusMessage(from: decoder))
            case "transcript":
                self = .transcript(try TranscriptMessage(from: decoder))
            case "error":
                self = .error(try ErrorMessage(from: decoder))
            case "session_end":
                self = .sessionEnd(try SessionEndMessage(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown message type: \(type)")
            }
        }
    }

    private let configuration: Configuration
    private let queue = DispatchQueue(label: "voxtral.transcription.client")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var session: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var sessionId: String?
    private var sessionConfiguration: SessionConfiguration?
    private var pendingSendCount: Int = 0
    private var isInBackpressure: Bool = false

    private(set) var state: State = .idle

    var onEvent: ((Event) -> Void)?
    var onStateChange: ((State) -> Void)?
    var onBackpressureChanged: ((Bool) -> Void)?

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        super.init()
    }

    func startSession(configuration sessionConfiguration: SessionConfiguration = SessionConfiguration()) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.state == .idle else { return }
            guard let url = self.configuration.url else {
                self.emitEvent(.failure(TranscriptionClientError.invalidURL))
                return
            }

            self.sessionConfiguration = sessionConfiguration
            self.sessionId = UUID().uuidString
            self.encoder.outputFormatting = []
            self.pendingSendCount = 0
            self.isInBackpressure = false

            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            let task = session.webSocketTask(with: url)

            self.session = session
            self.webSocketTask = task
            self.setState(.connecting)

            task.resume()
            self.receiveNextMessage()
            self.sendStartMessage()
        }
    }

    func sendFrames(_ frames: [AudioFrame]) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !frames.isEmpty else { return }
            for frame in frames {
                self.sendFrameInternal(frame.data)
            }
        }
    }

    func sendFrame(_ frame: AudioFrame) {
        queue.async { [weak self] in
            self?.sendFrameInternal(frame.data)
        }
    }

    var currentQueueDepth: Int {
        queue.sync {
            pendingSendCount
        }
    }

    var isInBackpressureState: Bool {
        queue.sync {
            isInBackpressure
        }
    }

    func stopSession(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else {
                completion?()
                return
            }
            guard self.state != .idle else {
                completion?()
                return
            }
            guard self.state != .closing else {
                completion?()
                return
            }
            self.setState(.closing)
            self.sendStopMessage { [weak self] in
                guard let self else {
                    completion?()
                    return
                }
                // Wait for session_end message or timeout before closing
                // The session_end handler will call closeConnection
                // Start a timeout to close connection if session_end doesn't arrive
                DispatchQueue.main.async { [weak self] in
                    self?.waitForSessionEndOrTimeout(completion: completion)
                }
            }
        }
    }

    private func waitForSessionEndOrTimeout(completion: (() -> Void)?) {
        // Use a simple timeout mechanism - if we're still in closing state after 2 seconds,
        // close the connection forcibly. The session_end handler will call closeConnection
        // first and update state to .idle, which this check will catch.
        let deadline = DispatchTime.now() + .seconds(2)
        DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
            guard let self else {
                completion?()
                return
            }
            // Only close if we haven't received session_end yet (still in closing state)
            if self.state == .closing {
                AppLogger.shared.logWarning("Session end timeout, closing connection")
                self.queue.async { [weak self] in
                    self?.closeConnection(code: .goingAway, reason: "session_end_timeout")
                    completion?()
                }
            } else if self.state == .idle {
                // Already received session_end and closed
                completion?()
            }
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            self?.closeConnection(code: .goingAway, reason: "client_disconnect")
        }
    }

    private func sendStartMessage() {
        guard let sessionId, let sessionConfiguration else { return }
        AppLogger.shared.logTranscriptionSessionStart(sessionId: sessionId)
        let message = StartMessage(
            sessionId: sessionId,
            audioFormat: sessionConfiguration.audioFormat,
            transcriptionDelayMs: sessionConfiguration.transcriptionDelayMs,
            language: sessionConfiguration.language
        )
        sendJSON(message)
    }

    private func sendStopMessage(completion: @escaping () -> Void) {
        guard let sessionId else {
            completion()
            return
        }
        AppLogger.shared.logTranscriptionSessionEnd(sessionId: sessionId, reason: "client_stop")
        let message = StopMessage(sessionId: sessionId)
        sendJSON(message) { _ in
            completion()
        }
    }

    private func sendJSON<T: Encodable>(_ message: T, completion: ((Error?) -> Void)? = nil) {
        guard let task = webSocketTask else {
            completion?(TranscriptionClientError.notConnected)
            return
        }

        do {
            let data = try encoder.encode(message)
            guard let text = String(data: data, encoding: .utf8) else {
                completion?(TranscriptionClientError.encodingFailed)
                return
            }

            task.send(.string(text)) { [weak self] error in
                if let error {
                    self?.emitEvent(.failure(error))
                }
                completion?(error)
            }
        } catch {
            completion?(error)
            emitEvent(.failure(error))
        }
    }

    private func sendFrameInternal(_ data: Data) {
        guard let task = webSocketTask else { return }
        guard state == .connecting || state == .running else { return }

        guard configuration.backpressureEnabled else {
            task.send(.data(data)) { [weak self] error in
                if let error {
                    self?.emitEvent(.failure(error))
                }
            }
            return
        }

        let maxPending = max(max(configuration.maxPendingFrames, configuration.backpressureThreshold), 1)
        let shouldDrop = pendingSendCount >= maxPending

        if shouldDrop {
            updateBackpressureState()
            return
        }

        pendingSendCount += 1
        updateBackpressureState()

        task.send(.data(data)) { [weak self] error in
            guard let self else { return }
            self.pendingSendCount -= 1
            self.updateBackpressureState()
            if let error {
                self.emitEvent(.failure(error))
            }
        }
    }

    private func updateBackpressureState() {
        let backpressureThreshold = max(1, configuration.backpressureThreshold)
        let recoveryThreshold = min(max(0, configuration.recoveryThreshold), backpressureThreshold)

        if !isInBackpressure {
            if pendingSendCount >= backpressureThreshold {
                setBackpressureState(true)
            }
        } else if pendingSendCount <= recoveryThreshold {
            setBackpressureState(false)
        }
    }

    private func setBackpressureState(_ newValue: Bool) {
        guard newValue != isInBackpressure else { return }
        isInBackpressure = newValue
        if newValue {
            AppLogger.shared.logBackpressureEntered(source: "websocket_client")
        } else {
            AppLogger.shared.logBackpressureRecovered(source: "websocket_client")
        }
        DispatchQueue.main.async { [weak self] in
            self?.onBackpressureChanged?(newValue)
        }
    }

    private func receiveNextMessage() {
        guard let task = webSocketTask else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.emitEvent(.failure(error))
                self.queue.async {
                    self.closeConnection(code: .abnormalClosure, reason: error.localizedDescription)
                }
            case .success(let message):
                self.handle(message)
                self.receiveNextMessage()
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8) else {
                emitEvent(.failure(TranscriptionClientError.decodingFailed))
                return
            }
            decodeAndEmit(data)
        case .data(let data):
            decodeAndEmit(data)
        @unknown default:
            emitEvent(.failure(TranscriptionClientError.decodingFailed))
        }
    }

    private func decodeAndEmit(_ data: Data) {
        do {
            let message = try decoder.decode(IncomingMessage.self, from: data)
            switch message {
            case .ready(let ready):
                if ready.sessionId == sessionId {
                    setState(.running)
                    AppLogger.shared.logWebSocketConnected()
                    emitEvent(.ready(ready))
                }
            case .status(let status):
                emitEvent(.status(status))
            case .transcript(let transcript):
                emitEvent(.transcript(transcript))
            case .error(let errorMessage):
                emitEvent(.backendError(errorMessage))
            case .sessionEnd(let sessionEnd):
                emitEvent(.sessionEnd(sessionEnd))
                AppLogger.shared.logTranscriptionSessionEnd(sessionId: sessionEnd.sessionId, reason: sessionEnd.reason)
                queue.async { [weak self] in
                    self?.closeConnection(code: .normalClosure, reason: sessionEnd.reason)
                }
            }
        } catch {
            emitEvent(.failure(error))
        }
    }

    private func closeConnection(code: URLSessionWebSocketTask.CloseCode, reason: String?) {
        AppLogger.shared.logWebSocketDisconnected(code: code.rawValue, reason: reason)
        if let task = webSocketTask, task.state == .running || task.state == .suspended {
            let reasonData = reason?.data(using: .utf8)
            task.cancel(with: code, reason: reasonData)
        }
        session?.invalidateAndCancel()
        session = nil
        webSocketTask = nil
        sessionId = nil
        sessionConfiguration = nil
        pendingSendCount = 0
        setBackpressureState(false)
        setState(.idle)
    }

    private func setState(_ newState: State) {
        guard state != newState else { return }
        state = newState
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(newState)
        }
    }

    private func emitEvent(_ event: Event) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }

    private static var defaultPort: Int {
        if let value = ProcessInfo.processInfo.environment["VOXTRAL_PORT"], let port = Int(value) {
            return port
        }
        return 8765
    }
}

extension TranscriptionClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) }
        emitEvent(.disconnected(closeCode, reasonText))
        queue.async { [weak self] in
            self?.closeConnection(code: closeCode, reason: reasonText)
        }
    }
}

enum TranscriptionClientError: Error {
    case invalidURL
    case notConnected
    case encodingFailed
    case decodingFailed
}
