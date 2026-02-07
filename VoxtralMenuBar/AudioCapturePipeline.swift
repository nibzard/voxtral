import AVFoundation
import Foundation

struct AudioFrame {
    let sequence: UInt64
    let data: Data
    let sampleRate: Double
    let channels: Int
    let sampleCount: Int
    let timestamp: TimeInterval
}

struct LatencyMetrics {
    var framesSent: UInt64 = 0
    var framesDropped: UInt64 = 0
    var currentQueueDepth: Int = 0
    var peakQueueDepth: Int = 0
    var averageQueueDepth: Double = 0
    var lastUpdateTime: TimeInterval = 0

    mutating func recordSent() {
        framesSent += 1
        updateTime()
    }

    mutating func recordDropped() {
        framesDropped += 1
        updateTime()
    }

    mutating func updateQueueDepth(_ depth: Int) {
        currentQueueDepth = depth
        peakQueueDepth = max(peakQueueDepth, depth)
        updateTime()
    }

    private mutating func updateTime() {
        lastUpdateTime = Date().timeIntervalSince1970
    }

    var dropRate: Double {
        guard framesSent > 0 else { return 0 }
        return Double(framesDropped) / Double(framesSent)
    }
}

final class AudioCapturePipeline {
    enum DropPolicy {
        case dropNewest
        case dropOldest
    }

    struct Configuration {
        var sampleRate: Double = 16_000
        var channels: AVAudioChannelCount = 1
        var frameDuration: TimeInterval = 0.02
        var tapBufferSize: AVAudioFrameCount = 1024
        var maxBufferedFrames: Int = BackpressureDefaults.maxFrames
        var dropPolicy: DropPolicy = .dropOldest
        var backpressureThreshold: Int = BackpressureDefaults.backpressureThreshold
        var recoveryThreshold: Int = BackpressureDefaults.recoveryThreshold

        var frameSize: Int {
            max(1, Int((sampleRate * frameDuration).rounded()))
        }

        var bufferedSampleCapacity: Int {
            let frames = max(1, maxBufferedFrames)
            return max(frameSize, frameSize * frames)
        }

        var maxLatencyMs: Double {
            Double(maxBufferedFrames) * frameDuration * 1000
        }
    }

    enum AudioCaptureError: Error {
        case converterUnavailable
        case engineStartFailed(Error)
    }

    private let configuration: Configuration
    private let engine: AVAudioEngine
    private let deliveryQueue: DispatchQueue
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var ringBuffer: FloatRingBuffer
    private var isRunning = false
    private var nextSequence: UInt64 = 0
    private var onFrames: (([AudioFrame]) -> Void)?
    private var onBackpressureStateChanged: ((Bool) -> Void)?
    private var metrics: LatencyMetrics
    private var isInBackpressure: Bool = false

    init(
        configuration: Configuration = Configuration(),
        deliveryQueue: DispatchQueue = DispatchQueue(label: "voxtral.audio.capture.delivery")
    ) {
        self.configuration = configuration
        self.deliveryQueue = deliveryQueue
        self.engine = AVAudioEngine()
        self.ringBuffer = FloatRingBuffer(capacity: configuration.bufferedSampleCapacity)
        self.metrics = LatencyMetrics()
    }

    func start(onFrames: @escaping ([AudioFrame]) -> Void) throws {
        guard !isRunning else { return }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            standardFormatWithSampleRate: configuration.sampleRate,
            channels: configuration.channels
        ) else {
            throw AudioCaptureError.converterUnavailable
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioCaptureError.converterUnavailable
        }

        self.targetFormat = targetFormat
        self.converter = converter
        self.onFrames = onFrames
        self.ringBuffer.reset()
        self.nextSequence = 0
        self.metrics = LatencyMetrics()
        self.isInBackpressure = false

        inputNode.installTap(onBus: 0, bufferSize: configuration.tapBufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.handleInputBuffer(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
            isRunning = true
            AppLogger.shared.logAudioEngineStart()
        } catch {
            inputNode.removeTap(onBus: 0)
            AppLogger.shared.logAudioEngineError(error)
            throw AudioCaptureError.engineStartFailed(error)
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        converter = nil
        targetFormat = nil
        onFrames = nil
        onBackpressureStateChanged = nil
        ringBuffer.reset()
        isInBackpressure = false
        isRunning = false
        AppLogger.shared.logAudioEngineStop()
    }

    private func handleInputBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRunning else { return }
        guard let converted = convert(buffer) else { return }
        guard let channelData = converted.floatChannelData else { return }

        let sampleCount = Int(converted.frameLength)
        guard sampleCount > 0 else { return }

        let samples = UnsafeBufferPointer(start: channelData[0], count: sampleCount)
        let dropped = ringBuffer.write(samples, dropPolicy: configuration.dropPolicy)

        let frameSize = configuration.frameSize
        guard ringBuffer.count >= frameSize else { return }

        var framesToDeliver: [AudioFrame] = []
        var droppedCount = dropped
        var sentCount = 0
        while ringBuffer.count >= frameSize {
            var frameSamples: [Float] = []
            if ringBuffer.read(frameSize, into: &frameSamples) {
                let data = frameSamples.withUnsafeBufferPointer { Data(buffer: $0) }
                let timestamp = Date().timeIntervalSince1970
                let frame = AudioFrame(
                    sequence: nextSequence,
                    data: data,
                    sampleRate: configuration.sampleRate,
                    channels: Int(configuration.channels),
                    sampleCount: frameSamples.count,
                    timestamp: timestamp
                )
                nextSequence += 1
                sentCount += 1
                framesToDeliver.append(frame)
            } else {
                break
            }
        }

        guard !framesToDeliver.isEmpty else { return }

        // Capture current queue depth on tap thread before async dispatch
        let currentFrameCount = ringBuffer.count / configuration.frameSize

        let callback = onFrames
        deliveryQueue.async { [weak self] in
            guard let self = self else { return }
            // Update metrics on deliveryQueue to synchronize with currentMetrics reads
            if droppedCount > 0 {
                self.metrics.recordDropped()
            }
            for _ in 0..<sentCount {
                self.metrics.recordSent()
            }
            // Use captured queue depth
            self.metrics.updateQueueDepth(currentFrameCount)
            self.updateBackpressureState(currentFrameCount: currentFrameCount)
            callback?(framesToDeliver)
        }
    }

    private func updateBackpressureState(currentFrameCount: Int) {
        let maxBufferedFrames = max(1, configuration.maxBufferedFrames)
        let backpressureThreshold = min(max(1, configuration.backpressureThreshold), maxBufferedFrames)
        let recoveryThreshold = min(max(0, configuration.recoveryThreshold), backpressureThreshold)

        if !isInBackpressure {
            if currentFrameCount >= backpressureThreshold {
                isInBackpressure = true
                AppLogger.shared.logBackpressureEntered(source: "audio_pipeline")
                onBackpressureStateChanged?(true)
            }
        } else if currentFrameCount <= recoveryThreshold {
            isInBackpressure = false
            AppLogger.shared.logBackpressureRecovered(source: "audio_pipeline")
            onBackpressureStateChanged?(false)
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter = converter, let targetFormat = targetFormat else { return nil }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputCapacity = max(1, AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            return nil
        }

        var error: NSError?
        var inputBuffer: AVAudioPCMBuffer? = buffer
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if let input = inputBuffer {
                outStatus.pointee = .haveData
                inputBuffer = nil
                return input
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        if status == .error || error != nil {
            return nil
        }

        return outputBuffer
    }

    var currentMetrics: LatencyMetrics {
        deliveryQueue.sync {
            metrics
        }
    }

    func setBackpressureCallback(_ callback: @escaping (Bool) -> Void) {
        deliveryQueue.async {
            self.onBackpressureStateChanged = callback
        }
    }
}

private final class FloatRingBuffer {
    private var storage: [Float]
    private let capacity: Int
    private var readIndex: Int = 0
    private var writeIndex: Int = 0
    private(set) var count: Int = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.storage = Array(repeating: 0, count: self.capacity)
    }

    func reset() {
        readIndex = 0
        writeIndex = 0
        count = 0
    }

    @discardableResult
    func write(_ samples: UnsafeBufferPointer<Float>, dropPolicy: AudioCapturePipeline.DropPolicy) -> Int {
        guard samples.count > 0 else { return 0 }
        guard let baseAddress = samples.baseAddress else { return 0 }

        let totalCount = samples.count
        var dropped = 0

        if totalCount >= capacity {
            switch dropPolicy {
            case .dropOldest:
                dropped += count
                reset()
                let start = totalCount - capacity
                writeSamples(from: baseAddress.advanced(by: start), count: capacity)
                dropped += start
                return dropped
            case .dropNewest:
                let writable = max(0, capacity - count)
                if writable > 0 {
                    writeSamples(from: baseAddress, count: writable)
                }
                dropped += totalCount - writable
                return dropped
            }
        }

        let freeSpace = capacity - count
        if totalCount > freeSpace {
            switch dropPolicy {
            case .dropNewest:
                let writable = freeSpace
                if writable > 0 {
                    writeSamples(from: baseAddress, count: writable)
                }
                dropped += totalCount - writable
                return dropped
            case .dropOldest:
                let needed = totalCount - freeSpace
                if needed >= count {
                    dropped += count
                    reset()
                } else {
                    readIndex = (readIndex + needed) % capacity
                    count -= needed
                    dropped += needed
                }
                writeSamples(from: baseAddress, count: totalCount)
                return dropped
            }
        }

        writeSamples(from: baseAddress, count: totalCount)
        return dropped
    }

    func read(_ count: Int, into output: inout [Float]) -> Bool {
        guard count <= self.count else { return false }

        output.removeAll(keepingCapacity: true)
        output.reserveCapacity(count)

        let firstCount = min(count, capacity - readIndex)
        output.append(contentsOf: storage[readIndex ..< readIndex + firstCount])

        let remaining = count - firstCount
        if remaining > 0 {
            output.append(contentsOf: storage[0 ..< remaining])
        }

        readIndex = (readIndex + count) % capacity
        self.count -= count
        return true
    }

    private func writeSamples(from pointer: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }

        let firstCount = min(count, capacity - writeIndex)
        storage.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress?.advanced(by: writeIndex).assign(from: pointer, count: firstCount)
            let remaining = count - firstCount
            if remaining > 0 {
                buffer.baseAddress?.assign(from: pointer.advanced(by: firstCount), count: remaining)
            }
        }

        writeIndex = (writeIndex + count) % capacity
        self.count += count
    }
}
