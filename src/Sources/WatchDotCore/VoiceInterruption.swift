import Foundation

enum VoiceInterruptionEvent: Sendable { case began, userFinished, resumed }

/// Conservative double-talk detector. It compares microphone audio to the
/// scheduled speaker reference with a bounded acoustic-delay search.
/// All PCM is transient, downsampled to 2 kHz with at most 4,000 reference samples.
struct VoiceBargeInDetector {
    enum Change: Equatable, Sendable { case began, ended }
    private struct Point { let time: Double; let value: Float }
    private var reference: [Point] = []
    private var microphone: [Float] = []
    private var lastInputEnd: Double?
    private var echoGain: Double?
    private var echoLagSamples: Int?
    private(set) var fullSearches = 0
    private(set) var narrowSearches = 0
    private var noiseRMS = 0.001
    private var candidateMS = 0.0
    private var quietMS = 0.0
    private(set) var speaking = false
    private(set) var referenceChunks = 0
    private(set) var echoRejectedFrames = 0
    private(set) var lastCorrelation = 0.0
    private(set) var lastInputRMS = 0.0

    static func downsample(_ input: UnsafeBufferPointer<Float>, sampleRate: Double) -> [Float] {
        guard sampleRate.isFinite, sampleRate >= 2_000, sampleRate <= 384_000, input.count <= Int(sampleRate) else { return [] }
        let count = Int(Double(input.count) * 2_000 / sampleRate)
        return (0..<count).map { index in
            let start = Int(Double(index) * sampleRate / 2_000)
            let end = min(input.count, Int(Double(index + 1) * sampleRate / 2_000))
            guard end > start else { return 0 }
            var sum: Float = 0
            for i in start..<end { sum += input[i].isFinite ? input[i] : 0 }
            return sum / Float(end - start)
        }
    }
    mutating func observeOutput(_ samples: [Float], startSeconds: Double) {
        guard startSeconds.isFinite, !samples.isEmpty, samples.count <= 1_000 else { return }
        referenceChunks += 1
        for (index, value) in samples.enumerated() {
            let time = startSeconds + Double(index) / 2_000
            if time > (reference.last?.time ?? -.infinity) {
                reference.append(Point(time: time, value: value.isFinite ? value : 0))
            }
        }
        let cutoff = startSeconds - 1.5
        let remove = reference.prefix { $0.time < cutoff }.count
        if remove > 0 { reference.removeFirst(remove) }
        if reference.count > 4_000 { reference.removeFirst(reference.count - 4_000) }
    }
    mutating func observeInput(_ samples: [Float], startSeconds: Double, enabled: Bool, outputActive: Bool) -> Change? {
        guard startSeconds.isFinite, !samples.isEmpty, samples.count <= 1_000 else { return nil }
        let durationMS = Double(samples.count) / 2
        if let lastInputEnd, abs(startSeconds - lastInputEnd) > 0.04 {
            microphone.removeAll(); candidateMS = 0
        }
        lastInputEnd = startSeconds + Double(samples.count) / 2_000
        microphone.append(contentsOf: samples.map { $0.isFinite ? $0 : 0 })
        if microphone.count > 80 { microphone.removeFirst(microphone.count - 80) }
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
        lastInputRMS = rms
        if !enabled {
            candidateMS = 0; quietMS = 0
            if speaking { speaking = false; return .ended }
            return nil
        }
        let floor = max(0.006, noiseRMS * 3)
        if speaking {
            quietMS = rms < floor ? quietMS + durationMS : 0
            if quietMS >= 300 { speaking = false; quietMS = 0; return .ended }
            return nil
        }
        guard outputActive, microphone.count == 80 else {
            candidateMS = 0
            if rms < 0.006 { noiseRMS = noiseRMS * 0.95 + rms * 0.05 }
            return nil
        }
        let inputMean = microphone.reduce(0.0) { $0 + Double($1) } / 80
        let centered = microphone.map { Double($0) - inputMean }
        let energy = centered.reduce(0) { $0 + $1 * $1 }
        let inputStart = (lastInputEnd ?? startSeconds) - 0.04
        guard rms >= max(0.0015, noiseRMS * 1.5) else { candidateMS = 0; return nil }
        let reference = self.reference
        func search(_ lags: ClosedRange<Int>) -> (correlation: Double, rms: Double, covered: Bool, lag: Int) {
            var best = (correlation: 0.0, rms: 0.0, covered: false, lag: 0)
            for lagSamples in lags {
                let target = inputStart - Double(lagSamples) / 2_000
                var low = 0, high = reference.count
                while low < high { let mid = (low + high) / 2; if reference[mid].time < target { low = mid + 1 } else { high = mid } }
                if low > 0, low == reference.count || abs(reference[low - 1].time - target) < abs(reference[low].time - target) { low -= 1 }
                guard low + 80 <= reference.count, abs(reference[low].time - target) < 0.001,
                      abs(reference[low + 79].time - reference[low].time - 79.0 / 2_000) < 0.002 else { continue }
                best.covered = true
                var mean = 0.0
                for i in 0..<80 { mean += Double(reference[low + i].value) / 80 }
                var outputEnergy = 0.0, dot = 0.0
                for i in 0..<80 {
                    let value = Double(reference[low + i].value) - mean
                    outputEnergy += value * value; dot += value * centered[i]
                }
                guard energy > 1e-12, outputEnergy > 1e-12 else { continue }
                let correlation = min(1, abs(dot) / sqrt(energy * outputEnergy))
                if correlation > best.correlation { best.correlation = correlation; best.rms = sqrt(outputEnergy / 80); best.lag = lagSamples }
            }
            return best
        }
        var match: (correlation: Double, rms: Double, covered: Bool, lag: Int)
        if let lag = echoLagSamples {
            narrowSearches += 1
            match = search(max(0, lag - 8)...min(600, lag + 8))
        } else { match = (0, 0, false, 0) }
        // A poor local match must be checked across the full delay range before
        // calling it independent speech. Stable echo uses only 17 delay slots.
        if match.correlation < 0.8 { fullSearches += 1; match = search(0...600) }
        let bestCorrelation = match.correlation, matchedRMS = match.rms, covered = match.covered
        lastCorrelation = bestCorrelation
        guard covered, matchedRMS >= 0.003 else { candidateMS = 0; return nil }
        if bestCorrelation >= 0.8 {
            echoLagSamples = match.lag
            let gain = rms / matchedRMS
            echoGain = echoGain.map { $0 * 0.9 + gain * 0.1 } ?? gain
            echoRejectedFrames += 1; candidateMS = 0
            return nil
        }
        let candidate: Bool
        if let echoGain {
            let echoRMS = matchedRMS * echoGain
            let residual = rms * sqrt(max(0, 1 - bestCorrelation * bestCorrelation))
            candidate = rms > max(floor, echoRMS * 1.25) && residual > max(floor, echoRMS * 0.6)
        } else {
            // No calibration: require a strong independent signal, not merely
            // noise or a low-correlation echo with an unknown speaker gain.
            candidate = rms > max(0.02, floor * 2) && bestCorrelation < 0.35
        }
        candidateMS = candidate ? candidateMS + durationMS : 0
        if candidateMS >= 80 { speaking = true; quietMS = 0; candidateMS = 0; return .began }
        return nil
    }
}

/// Discard the interrupted tail until the user finishes AND the remote audio
/// crosses a quiet boundary. Keep decoding while suppressed so Opus stays valid.
struct VoiceOutputInterruptionGate {
    enum Admission: Equatable { case play, discard, resumed }
    private(set) var suppressed = false
    private(set) var userSpeaking = false
    private var remoteBoundary = false
    private var quietFrames: UInt64 = 0
    private var lastArrival: Double?
    mutating func begin() -> Bool {
        userSpeaking = true
        guard !suppressed else { return false }
        suppressed = true; remoteBoundary = false; quietFrames = 0
        return true
    }
    mutating func userEnded() { userSpeaking = false; remoteBoundary = false; quietFrames = 0 }
    mutating func confirmNewResponse() { if suppressed { userSpeaking = false; remoteBoundary = true } }
    mutating func admit(rms: Double, frames: UInt32, nowSeconds: Double) -> Admission {
        if let lastArrival, nowSeconds - lastArrival >= 0.35 { remoteBoundary = true }
        lastArrival = nowSeconds
        guard suppressed else { return .play }
        if rms.isFinite, rms < 0.003 {
            quietFrames += UInt64(frames)
            if quietFrames >= 12_000 { remoteBoundary = true }
            return .discard
        }
        quietFrames = 0
        if userSpeaking { remoteBoundary = false; return .discard }
        guard !userSpeaking, remoteBoundary else { return .discard }
        suppressed = false; remoteBoundary = false
        return .resumed
    }
}


/// Predict the reference from buffers already admitted to the player. The
/// anchor is set when play() starts, so preroll is not mistaken for speaker echo.
/// Pending PCM reference is bounded to one second at 2 kHz.
struct VoicePlaybackReference {
    struct Chunk { let samples: [Float]; let startSeconds: Double }
    private var anchor: Double?
    private var cursor: UInt64 = 0
    private var pending: [(offset: UInt64, samples: [Float])] = []
    private var pendingSamples = 0
    mutating func enqueue(_ samples: [Float], frames: UInt32) -> [Chunk] {
        guard !samples.isEmpty, samples.count <= 2_000, frames > 0, frames <= 48_000 else { return [] }
        let offset = cursor
        cursor &+= UInt64(frames)
        if let anchor { return [Chunk(samples: samples, startSeconds: anchor + Double(offset) / 48_000)] }
        guard pendingSamples + samples.count <= 2_000 else { return [] }
        pending.append((offset, samples)); pendingSamples += samples.count
        return []
    }
    mutating func start(at seconds: Double) -> [Chunk] {
        guard seconds.isFinite else { reset(); return [] }
        anchor = seconds
        let result = pending.map { Chunk(samples: $0.samples, startSeconds: seconds + Double($0.offset) / 48_000) }
        pending.removeAll(keepingCapacity: true); pendingSamples = 0
        return result
    }
    mutating func reset() { anchor = nil; cursor = 0; pending.removeAll(keepingCapacity: true); pendingSamples = 0 }
}

/// Correlation has a separate owner: capture/Opus/playback never wait for it.
/// Admission is bounded before dispatch; obsolete mic windows are discarded.
final class VoiceBargeInAnalyzer: @unchecked Sendable {
    struct Snapshot: Sendable {
        var pendingInputs = 0, pendingOutputs = 0
        var droppedInputs = 0, droppedOutputs = 0, staleInputs = 0
        var referenceChunks = 0, fullSearches = 0, narrowSearches = 0, echoRejectedFrames = 0
        var lastCorrelation = 0.0, lastInputRMS = 0.0, maximumWorkMS = 0.0, maximumQueueMS = 0.0
    }
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var stats = Snapshot()
    private var stopped = false
    private var detector = VoiceBargeInDetector()
    private let maximumInputAge: Duration
    private let onChange: @Sendable (VoiceBargeInDetector.Change) -> Void
    init(queue: DispatchQueue = DispatchQueue(label: "ar.rochi.watchdot.barge-in", qos: .userInitiated),
         maximumInputAge: Duration = .milliseconds(150),
         onChange: @escaping @Sendable (VoiceBargeInDetector.Change) -> Void) {
        self.queue = queue; self.maximumInputAge = maximumInputAge; self.onChange = onChange
    }
    var snapshot: Snapshot { lock.withLock { stats } }
    func output(_ samples: [Float], startSeconds: Double) {
        guard !samples.isEmpty, samples.count <= 1000, startSeconds.isFinite else { return }
        guard lock.withLock({
            guard !stopped else { return false }
            guard stats.pendingOutputs < 16 else { stats.droppedOutputs += 1; return false }
            stats.pendingOutputs += 1; return true
        }) else { return }
        queue.async { [self] in
            defer { lock.withLock { stats.pendingOutputs -= 1 } }
            guard !lock.withLock({ stopped }) else { return }
            detector.observeOutput(samples, startSeconds: startSeconds)
            publish()
        }
    }
    func input(_ samples: [Float], startSeconds: Double, enabled: Bool, outputActive: Bool) {
        guard !samples.isEmpty, samples.count <= 1000, startSeconds.isFinite else { return }
        let enqueued = ContinuousClock.now
        guard lock.withLock({
            guard !stopped else { return false }
            guard stats.pendingInputs < 2 else { stats.droppedInputs += 1; return false }
            stats.pendingInputs += 1; return true
        }) else { return }
        queue.async { [self] in
            defer { lock.withLock { stats.pendingInputs -= 1 } }
            guard !lock.withLock({ stopped }) else { return }
            let delay = enqueued.duration(to: .now)
            lock.withLock { stats.maximumQueueMS = max(stats.maximumQueueMS, VoicePerformanceTrace.milliseconds(delay)) }
            guard delay <= maximumInputAge else { lock.withLock { stats.staleInputs += 1 }; return }
            let began = ContinuousClock.now
            let change = detector.observeInput(samples, startSeconds: startSeconds, enabled: enabled, outputActive: outputActive)
            lock.withLock { stats.maximumWorkMS = max(stats.maximumWorkMS, VoicePerformanceTrace.milliseconds(began.duration(to: .now))) }
            publish()
            if let change, !lock.withLock({ stopped }) { onChange(change) }
        }
    }
    private func publish() {
        lock.withLock {
            stats.referenceChunks = detector.referenceChunks
            stats.fullSearches = detector.fullSearches; stats.narrowSearches = detector.narrowSearches
            stats.echoRejectedFrames = detector.echoRejectedFrames
            stats.lastCorrelation = detector.lastCorrelation; stats.lastInputRMS = detector.lastInputRMS
        }
    }
    func stop() {
        guard lock.withLock({ if stopped { return false }; stopped = true; return true }) else { return }
        queue.async { [self] in detector = VoiceBargeInDetector() }
    }
    func flush() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}
