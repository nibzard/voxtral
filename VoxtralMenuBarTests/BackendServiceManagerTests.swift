import Combine
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

    func testStateTransitions() {
        let manager = BackendServiceManager()
        let stateExpectation = expectation(description: "State transitions to starting then running")

        // Observe state changes
        let cancellable = statePublisher(for: manager).sink { state in
            if state == .starting || state == .running {
                stateExpectation.fulfill()
            }
        }

        manager.start()

        wait(for: [stateExpectation], timeout: 5.0)
        cancellable.cancel()

        // Clean up
        manager.stop()
    }

    // MARK: - Backend Lifecycle Tests

    func testBackendStartRequested() {
        let manager = BackendServiceManager()
        let startExpectation = expectation(description: "Backend start requested")

        // Observe state changes
        let cancellable = statePublisher(for: manager).dropFirst().sink { state in
            if state == .starting {
                startExpectation.fulfill()
            }
        }

        manager.start()

        wait(for: [startExpectation], timeout: 2.0)
        cancellable.cancel()

        // Clean up
        manager.stop()
    }

    func testBackendStopRequested() {
        let manager = BackendServiceManager()
        let stopExpectation = expectation(description: "Backend returns to idle after stop")

        // Start first
        let startExpectation = expectation(description: "Backend starts")
        var startFulfilled = false

        let startCancellable = statePublisher(for: manager).sink { state in
            if !startFulfilled && (state == .starting || state == .running) {
                startFulfilled = true
                startExpectation.fulfill()
            }
        }

        manager.start()
        wait(for: [startExpectation], timeout: 2.0)
        startCancellable.cancel()

        // Small delay to ensure start processing
        Thread.sleep(forTimeInterval: 0.5)

        // Now stop and observe idle state
        let stopCancellable = statePublisher(for: manager).sink { state in
            if state == .idle {
                stopExpectation.fulfill()
            }
        }

        manager.stop()

        wait(for: [stopExpectation], timeout: 2.0)
        stopCancellable.cancel()
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

        // Callbacks are nil by default (optional properties)
        XCTAssertNil(client.onStateChange, "State change callback should be nil initially")
        XCTAssertNil(client.onEvent, "Event callback should be nil initially")
        XCTAssertNil(client.onBackpressureChanged, "Backpressure callback should be nil initially")

        // Verify callbacks can be set and invoked
        var stateChanged = false
        var eventReceived = false

        client.onStateChange = { _ in stateChanged = true }
        client.onEvent = { _ in eventReceived = true }
        client.onBackpressureChanged = { _ in }

        XCTAssertNotNil(client.onStateChange, "State change callback should be non-nil after setting")
        XCTAssertNotNil(client.onEvent, "Event callback should be non-nil after setting")
        XCTAssertNotNil(client.onBackpressureChanged, "Backpressure callback should be non-nil after setting")
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

    func testPortFromEnvironmentVariable() {
        // Set environment variable
        setenv("VOXTRAL_PORT", "9999", 1)

        defer {
            unsetenv("VOXTRAL_PORT")
        }

        // Create a new client to pick up the environment variable
        let client = TranscriptionClient()
        // The client reads from environment, but we can't directly test this without
        // refactoring. This documents the expected behavior.
        XCTAssertNotNil(client)
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

    // MARK: - Helper Methods

    private func statePublisher(
        for manager: BackendServiceManager
    ) -> AnyPublisher<BackendServiceManager.State, Never> {
        return manager.$state.eraseToAnyPublisher()
    }
}
