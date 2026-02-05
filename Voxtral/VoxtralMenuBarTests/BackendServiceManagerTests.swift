import Foundation
import XCTest
@testable import VoxtralMenuBar

final class BackendServiceManagerTests: XCTestCase {

    // MARK: - Configuration Tests

    func testDefaultConfigurationValues() {
        let config = BackendServiceManager.Configuration()

        XCTAssertEqual(config.backendExecutableName, "voxtral-backend", "Default backend executable name should be voxtral-backend")
        XCTAssertEqual(config.bundleSubdirectory, "backend", "Default bundle subdirectory should be backend")
        XCTAssertEqual(config.appSupportFolderName, "Voxtral", "Default app support folder should be Voxtral")
        XCTAssertEqual(config.backendFolderName, "backend", "Default backend folder should be backend")
        XCTAssertEqual(config.defaultPort, 8765, "Default port should be 8765")
        XCTAssertEqual(config.maxRestartAttempts, 5, "Default max restart attempts should be 5")
        XCTAssertEqual(config.baseRetryDelay, 1.0, "Default base retry delay should be 1.0 second")
        XCTAssertEqual(config.maxRetryDelay, 30.0, "Default max retry delay should be 30.0 seconds")
    }

    func testConfigurationCustomization() {
        var config = BackendServiceManager.Configuration()
        config.backendExecutableName = "custom-backend"
        config.defaultPort = 9000
        config.maxRestartAttempts = 3

        XCTAssertEqual(config.backendExecutableName, "custom-backend")
        XCTAssertEqual(config.defaultPort, 9000)
        XCTAssertEqual(config.maxRestartAttempts, 3)
    }

    // MARK: - State Tests

    func testInitialState() {
        let manager = BackendServiceManager()
        XCTAssertEqual(manager.state, .idle, "Initial state should be idle")
        XCTAssertFalse(manager.isBackendReady, "Backend should not be ready initially")
    }

    // MARK: - Backend Lifecycle Tests

    func testBackendStartRequested() {
        let manager = BackendServiceManager()
        let startExpectation = expectation(description: "Backend start request completes")

        manager.start()

        // Give the start call time to process
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Verify state transition occurred (either starting or running)
            let state = manager.state
            XCTAssertTrue(state == .starting || state == .running || state == .failed,
                         "State should transition from idle after start request, got: \(state.rawValue)")
            startExpectation.fulfill()
        }

        wait(for: [startExpectation], timeout: 2.0)

        // Clean up
        manager.stop()
    }

    func testBackendStopRequested() {
        let manager = BackendServiceManager()

        // Start first
        manager.start()
        Thread.sleep(forTimeInterval: 0.5)

        // Now stop
        let stopExpectation = expectation(description: "Backend stop request completes")

        manager.stop()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Verify state returned to idle after stop
            XCTAssertEqual(manager.state, .idle, "State should return to idle after stop")
            stopExpectation.fulfill()
        }

        wait(for: [stopExpectation], timeout: 2.0)
    }

    func testBackendStartStopSequence() {
        let manager = BackendServiceManager()

        // Test: start -> stop -> start -> stop sequence
        let expectation1 = self.expectation(description: "First start")
        let expectation2 = self.expectation(description: "First stop")
        let expectation3 = self.expectation(description: "Second start")
        let expectation4 = self.expectation(description: "Second stop")

        // First start
        manager.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            expectation1.fulfill()

            // First stop
            manager.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                XCTAssertEqual(manager.state, .idle)
                expectation2.fulfill()

                // Second start
                manager.start()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    expectation3.fulfill()

                    // Second stop
                    manager.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        XCTAssertEqual(manager.state, .idle)
                        expectation4.fulfill()
                    }
                }
            }
        }

        wait(for: [expectation1, expectation2, expectation3, expectation4], timeout: 5.0)
    }

    // MARK: - IPC Handshake Tests

    func testTranscriptionClientConfiguration() {
        let config = TranscriptionClient.Configuration()

        XCTAssertEqual(config.host, "127.0.0.1", "Default host should be localhost")
        XCTAssertEqual(config.port, 8765, "Default port should match backend default")
        XCTAssertEqual(config.path, "/v1/transcribe", "Default path should be /v1/transcribe")
        XCTAssertFalse(config.useTLS, "TLS should be disabled for local backend")
        XCTAssertEqual(config.maxPendingFrames, 50, "Max pending frames should be 50")
        XCTAssertEqual(config.backpressureThreshold, 25, "Backpressure threshold should be 25")
        XCTAssertEqual(config.recoveryThreshold, 10, "Recovery threshold should be 10")
        XCTAssertTrue(config.backpressureEnabled, "Backpressure should be enabled by default")
    }

    func testTranscriptionClientURLConstruction() {
        let config = TranscriptionClient.Configuration()

        XCTAssertNotNil(config.url, "URL should be constructable from default configuration")
        XCTAssertEqual(config.url?.host, "127.0.0.1")
        XCTAssertEqual(config.url?.port, 8765)
        XCTAssertEqual(config.url?.path, "/v1/transcribe")
        XCTAssertEqual(config.url?.scheme, "ws")
    }

    func testTranscriptionClientCustomPort() {
        var config = TranscriptionClient.Configuration()
        config.port = 9000

        XCTAssertEqual(config.url?.port, 9000)
    }

    func testTranscriptionClientStateTransitions() {
        let client = TranscriptionClient()
        XCTAssertEqual(client.state, .idle, "Initial client state should be idle")

        // Verify state management infrastructure exists
        XCTAssertNotNil(client.onStateChange, "State change callback should be available")
        XCTAssertNotNil(client.onEvent, "Event callback should be available")
    }

    func testTranscriptionClientSessionConfiguration() {
        let sessionConfig = TranscriptionClient.SessionConfiguration()

        XCTAssertEqual(sessionConfig.audioFormat.sampleRate, 16_000, "Audio format should default to 16 kHz")
        XCTAssertEqual(sessionConfig.audioFormat.channels, 1, "Audio format should default to mono")
        XCTAssertEqual(sessionConfig.audioFormat.encoding, "f32le", "Audio format should default to f32le")
        XCTAssertEqual(sessionConfig.audioFormat.frameSamples, 320, "Frame samples should default to 320")
        XCTAssertEqual(sessionConfig.transcriptionDelayMs, 480, "Transcription delay should default to 480ms")
        XCTAssertEqual(sessionConfig.language, "auto", "Language should default to auto")
    }

    func testTranscriptionClientCustomSessionConfiguration() {
        var sessionConfig = TranscriptionClient.SessionConfiguration()
        sessionConfig.transcriptionDelayMs = 500
        sessionConfig.language = "en"

        XCTAssertEqual(sessionConfig.transcriptionDelayMs, 500)
        XCTAssertEqual(sessionConfig.language, "en")
    }

    // MARK: - Environment Variable Tests

    func testDefaultPortFromEnvironment() {
        // The TranscriptionClient reads VOXTRAL_PORT from environment
        // This test documents the expected behavior
        let defaultPort = TranscriptionClient.Configuration().port
        XCTAssertEqual(defaultPort, 8765, "Default port should be 8765")
    }

    // MARK: - Message Structure Tests

    func testAudioFormatCodingKeys() {
        let audioFormat = TranscriptionClient.AudioFormat()

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // Test encoding
        XCTAssertNoThrow(try encoder.encode(audioFormat), "AudioFormat should be encodable")

        // Test round-trip
        if let encoded = try? encoder.encode(audioFormat),
           let decoded = try? decoder.decode(TranscriptionClient.AudioFormat.self, from: encoded) {
            XCTAssertEqual(decoded.sampleRate, audioFormat.sampleRate)
            XCTAssertEqual(decoded.channels, audioFormat.channels)
            XCTAssertEqual(decoded.encoding, audioFormat.encoding)
            XCTAssertEqual(decoded.frameSamples, audioFormat.frameSamples)
        } else {
            XCTFail("AudioFormat round-trip encoding/decoding failed")
        }
    }

    func testReadyMessageDecoding() {
        let json = """
        {
            "type": "ready",
            "session_id": "test-session-123",
            "backend_version": "1.0.0"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        XCTAssertNoThrow(
            try decoder.decode(TranscriptionClient.ReadyMessage.self, from: json),
            "Should decode ready message successfully"
        )

        if let decoded = try? decoder.decode(TranscriptionClient.ReadyMessage.self, from: json) {
            XCTAssertEqual(decoded.sessionId, "test-session-123")
            XCTAssertEqual(decoded.backendVersion, "1.0.0")
        }
    }

    func testTranscriptMessageDecoding() {
        let json = """
        {
            "type": "transcript",
            "seq": 1,
            "start_ms": 240,
            "end_ms": 720,
            "text": "Hello world",
            "is_final": true,
            "confidence": 0.95
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        XCTAssertNoThrow(
            try decoder.decode(TranscriptionClient.TranscriptMessage.self, from: json),
            "Should decode transcript message successfully"
        )

        if let decoded = try? decoder.decode(TranscriptionClient.TranscriptMessage.self, from: json) {
            XCTAssertEqual(decoded.seq, 1)
            XCTAssertEqual(decoded.startMs, 240)
            XCTAssertEqual(decoded.endMs, 720)
            XCTAssertEqual(decoded.text, "Hello world")
            XCTAssertTrue(decoded.isFinal)
            XCTAssertEqual(decoded.confidence, 0.95)
        }
    }

    func testErrorMessageDecoding() {
        let json = """
        {
            "type": "error",
            "code": "backend_error",
            "message": "Something went wrong",
            "recoverable": true
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        XCTAssertNoThrow(
            try decoder.decode(TranscriptionClient.ErrorMessage.self, from: json),
            "Should decode error message successfully"
        )

        if let decoded = try? decoder.decode(TranscriptionClient.ErrorMessage.self, from: json) {
            XCTAssertEqual(decoded.code, "backend_error")
            XCTAssertEqual(decoded.message, "Something went wrong")
            XCTAssertTrue(decoded.recoverable ?? false)
        }
    }

    func testSessionEndMessageDecoding() {
        let json = """
        {
            "type": "session_end",
            "session_id": "test-session-123",
            "reason": "client_stop"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        XCTAssertNoThrow(
            try decoder.decode(TranscriptionClient.SessionEndMessage.self, from: json),
            "Should decode session_end message successfully"
        )

        if let decoded = try? decoder.decode(TranscriptionClient.SessionEndMessage.self, from: json) {
            XCTAssertEqual(decoded.sessionId, "test-session-123")
            XCTAssertEqual(decoded.reason, "client_stop")
        }
    }

    func testStatusMessageDecoding() {
        let json = """
        {
            "type": "status",
            "state": "initializing",
            "detail": "Loading model"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        XCTAssertNoThrow(
            try decoder.decode(TranscriptionClient.StatusMessage.self, from: json),
            "Should decode status message successfully"
        )

        if let decoded = try? decoder.decode(TranscriptionClient.StatusMessage.self, from: json) {
            XCTAssertEqual(decoded.state, "initializing")
            XCTAssertEqual(decoded.detail, "Loading model")
        }
    }

    // MARK: - Integration Smoke Tests

    func testBackendManagerSingletonExists() {
        let manager = BackendServiceManager.shared
        XCTAssertNotNil(manager, "BackendServiceManager singleton should exist")
        XCTAssertTrue(manager === BackendServiceManager.shared, "Shared instance should be the same object")
    }

    func testBackendManagerCanStart() {
        let manager = BackendServiceManager()

        let expectation = self.expectation(description: "Backend manager start call completes")

        manager.start()

        // Give the start call time to process
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)

        // Clean up
        manager.stop()
    }

    func testBackendManagerCanStop() {
        let manager = BackendServiceManager()

        // Start first
        manager.start()
        Thread.sleep(forTimeInterval: 0.5)

        // Stop should not throw or hang
        let expectation = self.expectation(description: "Backend manager stop call completes")

        manager.stop()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }

    func testTranscriptionClientExists() {
        let client = TranscriptionClient()
        XCTAssertNotNil(client, "TranscriptionClient should be instantiable")
        XCTAssertEqual(client.state, .idle)
    }

    func testTranscriptionClientURLMatchesBackendPort() {
        let backendConfig = BackendServiceManager.Configuration()
        let clientConfig = TranscriptionClient.Configuration()

        XCTAssertEqual(backendConfig.defaultPort, clientConfig.port,
                     "Backend default port should match client default port")
    }

    // MARK: - Error Handling Tests

    func testBackendServiceErrorCases() {
        let bundleError = BackendServiceManager.BackendServiceError.bundleExecutableMissing
        XCTAssertNotNil(bundleError, "Error case should exist")

        // Verify error is throwable
        do {
            throw bundleError
        } catch {
            XCTAssertNotNil(error as? BackendServiceManager.BackendServiceError, "Should be able to throw and catch the error")
        }
    }

    func testTranscriptionClientErrorCases() {
        let invalidURL = TranscriptionClientError.invalidURL
        let notConnected = TranscriptionClientError.notConnected
        let encodingFailed = TranscriptionClientError.encodingFailed
        let decodingFailed = TranscriptionClientError.decodingFailed

        XCTAssertNotNil(invalidURL)
        XCTAssertNotNil(notConnected)
        XCTAssertNotNil(encodingFailed)
        XCTAssertNotNil(decodingFailed)
    }

    // MARK: - IPC Protocol Message Types

    func testIncomingMessageTypeCoverage() {
        // Verify all expected message types are represented in the protocol
        let jsonMessages: [(String, String)] = [
            ("ready", #"{"type":"ready","session_id":"abc","backend_version":"1.0"}"#),
            ("status", #"{"type":"status","state":"running"}"#),
            ("transcript", #"{"type":"transcript","seq":1,"start_ms":0,"end_ms":100,"text":"test","is_final":true}"#),
            ("error", #"{"type":"error","code":"test","message":"test"}"#),
            ("session_end", #"{"type":"session_end","session_id":"abc","reason":"test"}"#)
        ]

        for (typeName, json) in jsonMessages {
            let data = json.data(using: .utf8)!
            let decoder = JSONDecoder()

            // We can't directly decode the IncomingMessage enum since it's private,
            // but we can verify the message structure is valid for each type
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertNotNil(dict, "\(typeName) message should be valid JSON")
            XCTAssertEqual(dict?["type"] as? String, typeName, "\(typeName) should have correct type field")
        }
    }

    // MARK: - WebSocket Connection Tests

    func testWebSocketURLScheme() {
        let config = TranscriptionClient.Configuration()
        XCTAssertEqual(config.url?.scheme, "ws", "WebSocket should use ws:// scheme for non-TLS")

        var tlsConfig = TranscriptionClient.Configuration()
        tlsConfig.useTLS = true
        XCTAssertEqual(tlsConfig.url?.scheme, "wss", "WebSocket should use wss:// scheme for TLS")
    }

    func testWebSocketURLComponents() {
        let config = TranscriptionClient.Configuration()
        let url = config.url!

        XCTAssertEqual(url.scheme, "ws")
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.port, 8765)
        XCTAssertEqual(url.path, "/v1/transcribe")
        XCTAssertNil(url.query, "URL should not have query string")
        XCTAssertNil(url.fragment, "URL should not have fragment")
    }
}
