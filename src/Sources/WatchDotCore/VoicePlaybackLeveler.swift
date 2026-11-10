import Foundation

/// The RTC engine supplies the Opus RTP clock at 48 kHz. Preserve small holes
/// for decoder PLC, discard late/duplicate frames, and never fill long pauses.
struct VoiceOpusTimeline {
    struct Timing {
        let timestamp: UInt64
        let missingFrames: UInt32
        let late: Bool
    }
    private var expected: UInt64?
    private(set) var shortGaps = 0
    private(set) var missingFrames: UInt64 = 0
    private(set) var longGaps = 0
    private(set) var latePackets = 0

    mutating func prepare(_ raw: UInt64) -> Timing {
        let timestamp = normalized(raw)
        guard let expected else { return Timing(timestamp: timestamp, missingFrames: 0, late: false) }
        if timestamp < expected {
            latePackets += 1
            return Timing(timestamp: timestamp, missingFrames: 0, late: true)
        }
        let gap = timestamp - expected
        if gap > 0, gap <= 5_760, gap % 120 == 0 {
            shortGaps += 1; missingFrames += gap
            return Timing(timestamp: timestamp, missingFrames: UInt32(gap), late: false)
        }
        if gap > 0 { longGaps += 1 }
        return Timing(timestamp: timestamp, missingFrames: 0, late: false)
    }
    mutating func commit(_ timing: Timing, frames: UInt32) {
        guard !timing.late else { return }
        let (next, overflow) = timing.timestamp.addingReportingOverflow(UInt64(frames))
        expected = overflow ? nil : next
    }
    private func normalized(_ raw: UInt64) -> UInt64 {
        guard raw <= UInt32.max, let expected else { return raw }
        let cycle: UInt64 = 1 << 32
        var candidate = (expected & ~(cycle - 1)) | raw
        if candidate < expected, expected - candidate > cycle / 2, candidate <= UInt64.max - cycle {
            candidate += cycle
        } else if candidate > expected, candidate - expected > cycle / 2, candidate >= cycle {
            candidate -= cycle
        }
        return candidate
    }
}

/// Frame accounting for bursty Bluetooth delivery at 48 kHz. A short preroll
/// absorbs radio jitter; the hard limit prevents seconds of stale speech.
struct VoicePlaybackReservoir {
    private(set) var queuedFrames: UInt32 = 0
    private(set) var isPlaying = false
    static let pendingPacketLimit = 32
    static let prerollMilliseconds = 200
    static let recoveryPrerollMilliseconds = 400
    private let maximumFrames: UInt32 = 48_000 // 1 second, including preroll and radio burst
    /// Returns true only when the player must discard an excessive backlog.
    mutating func append(_ frames: UInt32) -> Bool {
        let reset = frames > maximumFrames || queuedFrames > maximumFrames - min(frames, maximumFrames)
        if reset { queuedFrames = 0; isPlaying = false }
        queuedFrames += frames
        return reset
    }
    mutating func start() { if queuedFrames > 0 { isPlaying = true } }
    mutating func played(_ frames: UInt32) {
        queuedFrames -= min(frames, queuedFrames)
        if queuedFrames == 0 { isPlaying = false }
    }
}

/// Start each answer promptly; retain the larger reserve only after a short
/// starvation within an ongoing stream. A conversational pause resets it.
struct VoicePlaybackWarmup {
    private(set) var milliseconds = VoicePlaybackReservoir.prerollMilliseconds
    private(set) var recoveryStarts = 0
    mutating func resume(afterIdleMS idle: Double) {
        if idle.isFinite, idle >= 0, idle < 500 {
            milliseconds = VoicePlaybackReservoir.recoveryPrerollMilliseconds
            recoveryStarts += 1
        } else { milliseconds = VoicePlaybackReservoir.prerollMilliseconds }
    }
}

/// In-place receive-only speech gain. The frame peak provides lookahead for a
/// ceiling without clipping samples; gain ramps use audio duration, not packets.
public struct VoicePlaybackLeveler: Sendable {
    public struct Levels: Sendable {
        public let inputPeak: Float
        public let inputRMS: Double
        public let outputPeak: Float
        public let appliedGain: Float
    }

    private var gain: Float = 1
    public init() {}

    public mutating func process(_ samples: UnsafeMutableBufferPointer<Float>,
                                 sampleRate: Double, enabled: Bool = true) -> Levels {
        guard !samples.isEmpty else {
            return Levels(inputPeak: 0, inputRMS: 0, outputPeak: 0, appliedGain: 1)
        }
        var peak: Float = 0
        var squares = 0.0
        for index in samples.indices {
            if !samples[index].isFinite { samples[index] = 0 }
            let value = samples[index]
            peak = max(peak, abs(value))
            squares += Double(value) * Double(value)
        }
        let rms = sqrt(squares / Double(samples.count))
        let peakLimit: Float = peak > 0 ? min(16, 0.95 / peak) : 16
        let canBoost = enabled && sampleRate.isFinite && sampleRate > 0 && rms >= 0.001
        let start: Float
        let end: Float
        if canBoost {
            let desired = min(16, max(1, 0.18 / rms))
            let duration = Double(samples.count) / sampleRate
            let timeConstant = desired < Double(gain) ? 0.015 : 0.12
            let blend = 1 - exp(-duration / timeConstant)
            start = min(gain, peakLimit)
            end = min(Float(Double(gain) + (desired - Double(gain)) * blend), peakLimit)
            gain = end
        } else {
            // Preserve silence/noise level and leave headphones unamplified.
            start = min(1, peakLimit)
            end = start
            if !enabled { gain = 1 }
        }
        var outputPeak: Float = 0
        for index in samples.indices {
            let progress = Float(index + 1) / Float(samples.count)
            samples[index] *= start + (end - start) * progress
            outputPeak = max(outputPeak, abs(samples[index]))
        }
        return Levels(inputPeak: peak, inputRMS: rms, outputPeak: outputPeak, appliedGain: end)
    }
}
