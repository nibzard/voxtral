import AVFoundation
import XCTest
@testable import VoxtralMenuBar

final class AudioCapturePipelineTests: XCTestCase {

    // MARK: - Configuration Tests

    func testDefaultConfigurationTargetParameters() {
        let config = AudioCapturePipeline.Configuration()

        XCTAssertEqual(config.sampleRate, 16_000, "Target sample rate should be 16 kHz")
        XCTAssertEqual(config.channels, 1, "Target channel count should be 1 (mono)")
        XCTAssertEqual(config.frameDuration, 0.02, "Frame duration should be 20 ms")
    }

    func testFrameSizeCalculation() {
        let config = AudioCapturePipeline.Configuration()
        let expectedFrameSize = Int((16_000 * 0.02).rounded()) // 320 samples

        XCTAssertEqual(config.frameSize, expectedFrameSize, "Frame size should be 320 samples (16 kHz * 20 ms)")
    }

    func testMaxLatencyCalculation() {
        let config = AudioCapturePipeline.Configuration()
        let expectedLatencyMs = 50 * 0.02 * 1000 // maxBufferedFrames * frameDuration * 1000

        XCTAssertEqual(config.maxLatencyMs, expectedLatencyMs, "Max latency should be 1000 ms (50 frames * 20 ms)")
    }

    // MARK: - Resampling Tests

    func testResamplingFrom48kHzStereoTo16kHzMono() throws {
        // Create a 48 kHz stereo input buffer with a known test pattern
        let inputSampleRate: Double = 48_000
        let inputChannels: UInt32 = 2
        let frameCount: AVAudioFrameCount = 480 // 10 ms at 48 kHz

        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputSampleRate,
            channels: inputChannels,
            interleaved: false
        ) else {
            XCTFail("Failed to create input format")
            return
        }

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: frameCount
        ) else {
            XCTFail("Failed to create input buffer")
            return
        }

        inputBuffer.frameLength = frameCount

        // Fill with a test pattern: 440 Hz tone (A4) in left channel, silence in right
        let frequency: Double = 440.0
        let amplitude: Float = 0.5

        guard let leftChannel = inputBuffer.floatChannelData?[0],
              let rightChannel = inputBuffer.floatChannelData?[1] else {
            XCTFail("Failed to get channel data")
            return
        }

        for i in 0..<Int(frameCount) {
            let t = Double(i) / inputSampleRate
            leftChannel[i] = amplitude * Float(sin(2.0 * .pi * frequency * t))
            rightChannel[i] = 0.0 // Silence in right channel
        }

        // Create target format: 16 kHz mono
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            XCTFail("Failed to create target format")
            return
        }

        // Perform conversion
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            XCTFail("Failed to create audio converter")
            return
        }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount((Double(frameCount) * ratio).rounded(.up))

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else {
            XCTFail("Failed to create output buffer")
            return
        }

        var error: NSError?
        var inputBufferRef: AVAudioPCMBuffer? = inputBuffer
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if let input = inputBufferRef {
                outStatus.pointee = .haveData
                inputBufferRef = nil
                return input
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        XCTAssertNil(error, "Conversion should not produce an error")
        XCTAssertNotEqual(status, .error, "Conversion status should not be error")

        // Verify output format
        XCTAssertEqual(outputBuffer.format.sampleRate, 16_000, "Output should be 16 kHz")
        XCTAssertEqual(outputBuffer.format.channelCount, 1, "Output should be mono")

        // Verify output has data
        XCTAssertGreaterThan(outputBuffer.frameLength, 0, "Output buffer should contain samples")

        // Expected output frame count: (480 / 48000) * 16000 = 160 frames
        let expectedOutputFrames = Int((Double(frameCount) / inputSampleRate * 16_000).rounded())
        let actualOutputFrames = Int(outputBuffer.frameLength)
        let tolerance = 10 // AVAudioConverter may round differently depending on internal resampler behavior.
        XCTAssertLessThanOrEqual(
            abs(actualOutputFrames - expectedOutputFrames),
            tolerance,
            "Output should have roughly correct number of frames"
        )

        // Verify mono channel data
        guard let channelData = outputBuffer.floatChannelData else {
            XCTFail("Failed to get output channel data")
            return
        }

        // Check that samples are not all zeros (should contain mixed stereo input)
        var hasNonZero = false
        for i in 0..<Int(outputBuffer.frameLength) {
            if abs(channelData[0][i]) > 0.001 {
                hasNonZero = true
                break
            }
        }
        XCTAssertTrue(hasNonZero, "Output should contain non-zero samples from mixed stereo input")
    }

    func testResamplingFrom44_1kHzStereoTo16kHzMono() throws {
        // Create a 44.1 kHz stereo input buffer
        let inputSampleRate: Double = 44_100
        let inputChannels: UInt32 = 2
        let frameCount: AVAudioFrameCount = 441 // 10 ms at 44.1 kHz

        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputSampleRate,
            channels: inputChannels,
            interleaved: false
        ) else {
            XCTFail("Failed to create input format")
            return
        }

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: frameCount
        ) else {
            XCTFail("Failed to create input buffer")
            return
        }

        inputBuffer.frameLength = frameCount

        // Fill with a simple pattern: ascending values in left, descending in right
        guard let leftChannel = inputBuffer.floatChannelData?[0],
              let rightChannel = inputBuffer.floatChannelData?[1] else {
            XCTFail("Failed to get channel data")
            return
        }

        for i in 0..<Int(frameCount) {
            leftChannel[i] = Float(i) / Float(frameCount) // 0.0 to 1.0
            rightChannel[i] = 1.0 - (Float(i) / Float(frameCount)) // 1.0 to 0.0
        }

        // Create target format and convert
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            XCTFail("Failed to create target format")
            return
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            XCTFail("Failed to create audio converter")
            return
        }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount((Double(frameCount) * ratio).rounded(.up))

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else {
            XCTFail("Failed to create output buffer")
            return
        }

        var error: NSError?
        var inputBufferRef: AVAudioPCMBuffer? = inputBuffer
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if let input = inputBufferRef {
                outStatus.pointee = .haveData
                inputBufferRef = nil
                return input
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        XCTAssertNil(error, "Conversion should not produce an error")
        XCTAssertNotEqual(status, .error, "Conversion status should not be error")
        XCTAssertEqual(outputBuffer.format.sampleRate, 16_000, "Output should be 16 kHz")
        XCTAssertEqual(outputBuffer.format.channelCount, 1, "Output should be mono")
    }

    // MARK: - Chunking/Frame Tests

    func testAudioFrameStructure() {
        let testSamples: [Float] = Array(repeating: 0.5, count: 320)
        let data = testSamples.withUnsafeBufferPointer { Data(buffer: $0) }

        let frame = AudioFrame(
            sequence: 1,
            data: data,
            sampleRate: 16_000,
            channels: 1,
            sampleCount: 320,
            timestamp: 0.0
        )

        XCTAssertEqual(frame.sequence, 1, "Sequence should match")
        XCTAssertEqual(frame.sampleRate, 16_000, "Sample rate should be 16 kHz")
        XCTAssertEqual(frame.channels, 1, "Channels should be mono")
        XCTAssertEqual(frame.sampleCount, 320, "Sample count should be 320 (20 ms at 16 kHz)")
        XCTAssertEqual(frame.data.count, 320 * MemoryLayout<Float>.size, "Data should contain 320 floats")
    }

    func testFrameDurationCalculation() {
        let frame = AudioFrame(
            sequence: 0,
            data: Data(),
            sampleRate: 16_000,
            channels: 1,
            sampleCount: 320,
            timestamp: 0.0
        )

        let duration = Double(frame.sampleCount) / frame.sampleRate
        XCTAssertEqual(duration, 0.02, "320 samples at 16 kHz should equal 20 ms")
    }

    // MARK: - Integration Tests

    func testIntegrationResamplingAndChunkingFromKnownInput() throws {
        // Simulate a real-world scenario: 48 kHz stereo input -> 16 kHz mono chunks
        let inputSampleRate: Double = 48_000
        let inputChannels: UInt32 = 2
        let inputDurationMs: Double = 100 // 100 ms of audio
        let inputFrameCount = AVAudioFrameCount((inputSampleRate * inputDurationMs / 1000).rounded())

        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputSampleRate,
            channels: inputChannels,
            interleaved: false
        ) else {
            XCTFail("Failed to create input format")
            return
        }

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: inputFrameCount
        ) else {
            XCTFail("Failed to create input buffer")
            return
        }

        inputBuffer.frameLength = inputFrameCount

        // Fill with a 440 Hz tone in both channels
        let frequency: Double = 440.0
        let amplitude: Float = 0.3

        guard let leftChannel = inputBuffer.floatChannelData?[0],
              let rightChannel = inputBuffer.floatChannelData?[1] else {
            XCTFail("Failed to get channel data")
            return
        }

        for i in 0..<Int(inputFrameCount) {
            let t = Double(i) / inputSampleRate
            let sample = amplitude * Float(sin(2.0 * .pi * frequency * t))
            leftChannel[i] = sample
            rightChannel[i] = sample
        }

        // Convert to 16 kHz mono
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            XCTFail("Failed to create target format")
            return
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            XCTFail("Failed to create audio converter")
            return
        }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount((Double(inputFrameCount) * ratio).rounded(.up))

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else {
            XCTFail("Failed to create output buffer")
            return
        }

        var error: NSError?
        var inputBufferRef: AVAudioPCMBuffer? = inputBuffer
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if let input = inputBufferRef {
                outStatus.pointee = .haveData
                inputBufferRef = nil
                return input
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        XCTAssertNil(error, "Conversion should not produce an error")
        XCTAssertNotEqual(status, .error, "Conversion should not fail")

        // Now chunk into 20 ms frames
        let frameSize = 320 // 20 ms at 16 kHz
        let outputSampleCount = Int(outputBuffer.frameLength)
        let expectedFrameCount = outputSampleCount / frameSize

        XCTAssertGreaterThanOrEqual(expectedFrameCount, 4, "100 ms should produce at least 4 frames of 20 ms each")

        guard let channelData = outputBuffer.floatChannelData else {
            XCTFail("Failed to get output channel data")
            return
        }

        // Verify chunking
        var frames: [AudioFrame] = []
        for i in 0..<expectedFrameCount {
            let startIdx = i * frameSize
            var frameSamples: [Float] = []

            for j in 0..<frameSize {
                if startIdx + j < outputSampleCount {
                    frameSamples.append(channelData[0][startIdx + j])
                }
            }

            let data = frameSamples.withUnsafeBufferPointer { Data(buffer: $0) }
            let frame = AudioFrame(
                sequence: UInt64(i),
                data: data,
                sampleRate: 16_000,
                channels: 1,
                sampleCount: frameSamples.count,
                timestamp: Double(i) * 0.02
            )
            frames.append(frame)
        }

        XCTAssertEqual(frames.count, expectedFrameCount, "Should create expected number of frames")

        // Verify each frame
        for (index, frame) in frames.enumerated() {
            XCTAssertEqual(frame.sampleRate, 16_000, "Frame \(index): Sample rate should be 16 kHz")
            XCTAssertEqual(frame.channels, 1, "Frame \(index): Should be mono")
            XCTAssertEqual(frame.sampleCount, 320, "Frame \(index): Should have 320 samples")
            XCTAssertEqual(frame.sequence, UInt64(index), "Frame \(index): Sequence should match index")
            XCTAssertEqual(frame.data.count, 320 * MemoryLayout<Float>.size, "Frame \(index): Data size should match")
        }
    }

    func testLatencyMetricsInitialization() {
        var metrics = LatencyMetrics()

        XCTAssertEqual(metrics.framesSent, 0, "Initial frames sent should be 0")
        XCTAssertEqual(metrics.framesDropped, 0, "Initial frames dropped should be 0")
        XCTAssertEqual(metrics.currentQueueDepth, 0, "Initial queue depth should be 0")
        XCTAssertEqual(metrics.peakQueueDepth, 0, "Initial peak queue depth should be 0")
        XCTAssertEqual(metrics.dropRate, 0.0, "Initial drop rate should be 0.0")
    }

    func testLatencyMetricsRecording() {
        var metrics = LatencyMetrics()

        metrics.recordSent()
        metrics.recordSent()
        metrics.recordSent()

        XCTAssertEqual(metrics.framesSent, 3, "Should record 3 frames sent")

        metrics.recordDropped()
        metrics.recordDropped()

        XCTAssertEqual(metrics.framesDropped, 2, "Should record 2 frames dropped")
        XCTAssertEqual(metrics.dropRate, 2.0 / 3.0, "Drop rate should be 2/3")

        metrics.updateQueueDepth(10)
        XCTAssertEqual(metrics.currentQueueDepth, 10, "Queue depth should be 10")
        XCTAssertEqual(metrics.peakQueueDepth, 10, "Peak queue depth should be 10")

        metrics.updateQueueDepth(5)
        XCTAssertEqual(metrics.currentQueueDepth, 5, "Queue depth should update to 5")
        XCTAssertEqual(metrics.peakQueueDepth, 10, "Peak queue depth should remain at 10")
    }

    func testConfigurationBackpressureThresholds() {
        let config = AudioCapturePipeline.Configuration()

        XCTAssertLessThanOrEqual(config.backpressureThreshold, config.maxBufferedFrames,
                               "Backpressure threshold should not exceed max buffered frames")
        XCTAssertLessThanOrEqual(config.recoveryThreshold, config.backpressureThreshold,
                               "Recovery threshold should not exceed backpressure threshold")
    }
}
