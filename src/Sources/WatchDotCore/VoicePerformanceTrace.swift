import Foundation

/// Coalesced, serial disk writes. Audio, Bluetooth and socket owners never wait
/// for filesystem I/O. Only the newest pending snapshot of each file is kept.
final class VoiceDiagnosticStore: @unchecked Sendable {
    static let shared = VoiceDiagnosticStore()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ar.rochi.watchdot.diagnostics", qos: .utility)
    private var pending: [URL: @Sendable () -> Data?] = [:]
    private var scheduled = false
    private let writer: @Sendable (Data, URL) -> Void
    init(writer: @escaping @Sendable (Data, URL) -> Void = { data, url in try? data.write(to: url, options: .atomic) }) {
        self.writer = writer
    }
    func submit(_ data: Data, to url: URL) { enqueue({ data }, to: url) }
    func submit<T: Encodable & Sendable>(_ value: T, to url: URL) {
        enqueue({ try? JSONEncoder().encode(value) }, to: url)
    }
    private func enqueue(_ job: @escaping @Sendable () -> Data?, to url: URL) {
        let start = lock.withLock {
            guard pending[url] != nil || pending.count < 16 else { return false }
            pending[url] = job
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        if start { queue.async { self.drain() } }
    }
    private func drain() {
        while true {
            let batch = lock.withLock {
                let batch = pending; pending.removeAll()
                if batch.isEmpty { scheduled = false }
                return batch
            }
            if batch.isEmpty { return }
            for (url, job) in batch { if let data = job() { writer(data, url) } }
        }
    }
    func flush() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
}

/// Static event names and numeric timings only: never audio, SDP or transcripts.
final class VoicePerformanceTrace: @unchecked Sendable {
    enum Event: String, Codable, Sendable {
        case callTapped, previousCleanupDone, phoneReady, accountReady, audioReady, offerReady
        case firstMicrophonePacket
        case allocationReady, networkReady, attached, mediaReady, eventsReady, callReady, callEnded
        case firstAudioReceived, audioAfterSpeechStop, playbackStarted, playbackEmpty, playbackReset, playbackStopWork
        case captureQueueWait, encodeWork, playbackQueueWait, decodeWork, scheduleWork
        case serverSpeechStarted, serverSpeechStopped, responseCreated, responseDone, responseCancelled
        case questionEndedByMute, questionEndedByDetector, responseSpeechReceived, responsePlaybackDelayEstimate
        case bargeInStarted, bargeInUserFinished, bargeInResumed
        case ringbackStarted, ringbackStopped, ringbackUnavailable
    }
    struct Entry: Codable, Sendable {
        let event: Event
        let elapsedMS: Double
        let durationMS: Double?
    }
    struct Snapshot: Codable, Sendable {
        let revision = "voice-performance-2"
        let recordedAt: Double
        let firstMS: [String: Double]
        let maximumMS: [String: Double]
        let counts: [String: Int]
        let events: [Entry]
    }
    private let lock = NSLock()
    private let began = ContinuousClock.now
    private var first: [String: Double] = [:]
    private var maximum: [String: Double] = [:]
    private var counts: [String: Int] = [:]
    private var entries: [Entry] = []
    private var lastWrite = ContinuousClock.now
    private var awaitingAudio = false
    private var questionEndedAt: ContinuousClock.Instant?
    private let url: URL?
    init(url: URL? = nil) { self.url = url }
    static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
    func mark(_ event: Event, duration: Duration? = nil, once: Bool = false) {
        let snapshot: Snapshot? = lock.withLock {
            if once, first[event.rawValue] != nil { return nil }
            let elapsed = Self.milliseconds(began.duration(to: .now))
            let ms = duration.map(Self.milliseconds)
            first[event.rawValue] = first[event.rawValue] ?? elapsed
            counts[event.rawValue, default: 0] += 1
            if let ms { maximum[event.rawValue] = max(maximum[event.rawValue] ?? 0, ms) }
            if ms == nil || ms! >= 20 {
                entries.append(Entry(event: event, elapsedMS: elapsed, durationMS: ms))
                if entries.count > 160 { entries.removeFirst() }
            }
            let important = duration == nil
            guard important || lastWrite.duration(to: .now) >= .seconds(2) else { return nil }
            lastWrite = .now
            return makeSnapshot()
        }
        if let snapshot, let url { VoiceDiagnosticStore.shared.submit(snapshot, to: url) }
    }
    func audioArrived() {
        mark(.firstAudioReceived, once: true)
        let response = lock.withLock { let waiting = awaitingAudio; awaitingAudio = false; return waiting }
        if response { mark(.audioAfterSpeechStop) }
    }
    func questionEndedByMute() {
        lock.withLock { questionEndedAt = .now }
        mark(.questionEndedByMute)
    }
    /// Local estimate after the detector's quiet window, not the exact last phoneme.
    func questionEndedByDetector() {
        lock.withLock { questionEndedAt = .now }
        mark(.questionEndedByDetector)
    }
    func cancelQuestionTiming() { lock.withLock { questionEndedAt = nil } }
    func observeResponseSpeech(rms: Double, estimatedPlaybackDelayMS: Double) {
        guard rms.isFinite, rms >= 0.005 else { return }
        let end = lock.withLock { let end = questionEndedAt; questionEndedAt = nil; return end }
        guard let end else { return }
        mark(.responseSpeechReceived, duration: end.duration(to: .now))
        if estimatedPlaybackDelayMS.isFinite, estimatedPlaybackDelayMS >= 0 {
            mark(.responsePlaybackDelayEstimate, duration: .milliseconds(estimatedPlaybackDelayMS))
        }
    }
    func observeServerEvent(_ data: Data) {
        guard data.count <= 65_536,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return }
        let event: Event
        switch type {
        case "input_audio_buffer.speech_started": event = .serverSpeechStarted
        case "input_audio_buffer.speech_stopped":
            event = .serverSpeechStopped
            lock.withLock { awaitingAudio = true }
        case "response.created": event = .responseCreated
        case "response.done": event = .responseDone
        case "response.cancelled": event = .responseCancelled
        default: return
        }
        mark(event)
    }
    func snapshot() -> Snapshot { lock.withLock { makeSnapshot() } }
    private func makeSnapshot() -> Snapshot {
        Snapshot(recordedAt: Date().timeIntervalSince1970, firstMS: first, maximumMS: maximum, counts: counts, events: entries)
    }
}
