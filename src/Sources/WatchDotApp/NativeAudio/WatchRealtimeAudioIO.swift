import AVFAudio
import Darwin
import Foundation
import Synchronization

/// Graph mutations, conversion, codecs and playback have one queue owner. The tap only
/// copies its borrowed buffer; its bounded handoff and cancellation are mutex protected.
final class WatchRealtimeAudioIO: @unchecked Sendable {
    private struct AudioGate {
        var stopped = false
        var muted = true
        var pending = 0
        var pendingPlayback = 0
        var droppedPlayback = 0
        var outputEpoch: UInt64 = 0
        var ringbackAllowed = true
    }

    private struct CapturedAudio: Sendable {
        let format: AudioStreamBasicDescription
        let frames: AVAudioFrameCount
        let buffers: [Data]
        let startSeconds: Double?
    }

    private static let lease = Mutex<UUID?>(nil)
    private let id = UUID()
    private let queue = DispatchQueue(label: "ai.openclaw.watch.realtime.audio", qos: .userInitiated)
    private let gate = Mutex(AudioGate())
    private var onPacket: (@Sendable (Data, UInt64) -> Void)?
    private let trace: VoicePerformanceTrace?
    private let onLevel: @Sendable (Float) -> Void
    private let onInterruption: @Sendable (VoiceInterruptionEvent) -> Void
    private var onFailure: (@Sendable (WatchRealtimeMediaFailure) -> Void)?
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var ringback = VoiceRingbackState()
    private var ringbackBuffer: AVAudioPCMBuffer?
    private var codec: WatchOpusCodec?
    private var resampler: AVAudioConverter?
    private var frame: AVAudioPCMBuffer?
    private var frameOffset = 0
    private var timestamp: UInt64 = 0
    private var playbackReservoir = VoicePlaybackReservoir()
    private var playbackStart: DispatchWorkItem?
    private var playbackWarmup = VoicePlaybackWarmup()
    private var playbackEmptyAt: ContinuousClock.Instant?
    private var playbackStartDeadline: ContinuousClock.Instant?
    private var playbackResets = 0
    private var playbackMaxQueuedFrames: UInt32 = 0
    private var playbackEmptyTransitions = 0
    private var playbackTimeline = VoiceOpusTimeline()
    private var fecRecoveryPackets = 0
    private var receivedOpusBytes: UInt64 = 0
    private var receivedOpusFrames: UInt64 = 0
    private var playbackGeneration: UInt64 = 0
    private var playbackSamplesSinceDiagnostic = 0
    private var playbackPeak: Float = 0
    private var playbackMaxRMS = 0.0
    private var playbackOutputPeak: Float = 0
    private var playbackGainMax: Float = 1
    private var playbackLeveler = VoicePlaybackLeveler()
    private var boostBuiltInSpeaker = false
    private var hasPlaybackDiagnostic = false
    private var observations: [NSObjectProtocol] = []
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var stopContinuations: [CheckedContinuation<Void, Never>] = []
    private var ownsLease = false
    private var activationPending = false
    private var ownsActivation = false
    private var running = false
    private var hasTap = false
    // Keep correlation off the shared capture/codec/playback owner.
    private let useLocalInterruption = true
    private var speakerReference = VoicePlaybackReference()
    private lazy var interruptionAnalyzer = VoiceBargeInAnalyzer { [weak self] change in
        guard let self else { return }
        self.queue.async { [weak self] in
            guard let self, self.running, !self.gate.withLock({ $0.stopped }) else { return }
            if change == .began { self.beginInterruption() }
            else {
                self.interruptionGate.userEnded()
                self.trace?.mark(.bargeInUserFinished)
                if !self.gate.withLock({ $0.muted }) { self.trace?.questionEndedByDetector() }
                self.onInterruption(.userFinished)
            }
        }
    }
    private var interruptionGate = VoiceOutputInterruptionGate()
    private var interruptions = 0
    private var suppressedAudioFrames: UInt64 = 0
    private var inputFrameStartSeconds: Double?
    private var microphonePacketRecorded = false
    private var startupStage = "codec"
    // Explicit AVAudioEngine VoiceProcessing failed on the physical watchOS 26.6
    // device (-308 followed by MediaServicesFailed). Use ordinary duplex I/O with
    // AVAudioSession.voiceChat; retain the independent PCM mute gate. Receive-only
    // level correction compensates the lower playback level without changing routing.
    private let useVoiceProcessing = false
    private var inputSampleRate = 0.0
    private var inputChannels: UInt32 = 0

    init(trace: VoicePerformanceTrace? = nil, onLevel: @escaping @Sendable (Float) -> Void,
         onInterruption: @escaping @Sendable (VoiceInterruptionEvent) -> Void = { _ in }) {
        self.trace = trace
        self.onLevel = onLevel
        self.onInterruption = onInterruption
    }

    deinit {
        self.observations.forEach { NotificationCenter.default.removeObserver($0) }
        if self.hasTap { self.engine.inputNode.removeTap(onBus: 0) }
        self.player.stop()
        self.engine.stop()
        if self.ownsActivation { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        if self.ownsLease {
            Self.lease.withLock { if $0 == self.id { $0 = nil } }
        }
    }

    func start(
        systemAudioActive: Bool = false,
        onPacket: @escaping @Sendable (Data, UInt64) -> Void,
        onFailure: @escaping @Sendable (WatchRealtimeMediaFailure) -> Void) async throws
    {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                self.queue.async { self.begin(continuation, onPacket: onPacket, onFailure: onFailure, systemAudioActive: systemAudioActive) }
            }
        } onCancel: { self.cancel() }
    }

    func setMuted(_ muted: Bool) {
        self.gate.withLock { $0.muted = muted }
        self.queue.async {
            if self.running, self.engine.inputNode.isVoiceProcessingEnabled {
                self.engine.inputNode.isVoiceProcessingInputMuted = muted
            }
        }
    }

    func setRingback(_ enabled: Bool) {
        if !enabled { self.gate.withLock { $0.ringbackAllowed = false } }
        self.queue.async {
            guard self.running, !self.gate.withLock({ $0.stopped }) else { return }
            if !enabled { self.stopRingback(); return }
            guard self.gate.withLock({ $0.ringbackAllowed }) else { return }
            guard self.ringback.begin() else { return }
            do {
                guard let format = self.codec?.pcmFormat,
                      let url = Bundle.main.url(forResource: "DotRingback", withExtension: "wav") else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
                guard file.length > 0, file.length <= AVAudioFramePosition(file.processingFormat.sampleRate * 10),
                      file.processingFormat.channelCount == 1,
                      let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try file.read(into: input)
                let toneFrames = AVAudioFrameCount((Double(file.length) * format.sampleRate / file.processingFormat.sampleRate).rounded())
                guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: toneFrames + 512),
                      let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                converter.primeMethod = .none
                _ = try converter.convert(input, to: converted)
                guard converted.frameLength > 0, let source = converted.floatChannelData?[0] else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                // Same receive-only level correction, with independent gain state.
                var leveler = VoicePlaybackLeveler()
                _ = leveler.process(UnsafeMutableBufferPointer(start: source, count: Int(converted.frameLength)),
                    sampleRate: format.sampleRate, enabled: self.boostBuiltInSpeaker)
                // Louder ringback on the Watch speaker only. This buffer is
                // independent of Dot's voice and leaves the system volume alone.
                if self.boostBuiltInSpeaker {
                    var peak: Float = 0
                    for index in 0..<Int(converted.frameLength) { peak = max(peak, abs(source[index])) }
                    let toneGain: Float = peak > 0 ? min(2, 0.95 / peak) : 1
                    for index in 0..<Int(converted.frameLength) { source[index] *= toneGain }
                }
                let silence = AVAudioFrameCount(format.sampleRate * Double(VoiceRingbackState.repeatSilenceSeconds))
                guard let cycle = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: toneFrames + silence),
                      let destination = cycle.floatChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }
                cycle.frameLength = toneFrames + silence
                destination.initialize(repeating: 0, count: Int(cycle.frameLength))
                destination.update(from: source, count: Int(min(toneFrames, converted.frameLength)))
                // Cancellation/connection can arrive while the file is decoded.
                // Fence the last admission just as for normal voice playback.
                guard self.gate.withLock({ !$0.stopped && $0.ringbackAllowed }) else {
                    self.ringback.finish(); return
                }
                self.ringbackBuffer = cycle
                self.player.scheduleBuffer(cycle, at: nil, options: .loops)
                guard !self.gate.withLock({ $0.stopped || !$0.ringbackAllowed }) else { self.stopRingback(); return }
                self.player.play()
                self.trace?.mark(.ringbackStarted)
            } catch {
                self.ringback.finish(); self.ringbackBuffer = nil
                self.trace?.mark(.ringbackUnavailable)
            }
        }
    }

    private func stopRingback(reason: VoiceRingbackState.StopReason = .terminal) {
        guard self.ringback.finish(reason: reason) else { return }
        self.player.stop()
        self.ringbackBuffer = nil
        self.trace?.mark(.ringbackStopped)
    }

    func play(_ packet: Data, timestamp: UInt64) {
        // Bound work before enqueueing, not only PCM after decoding: route changes
        // or a slow converter must not accumulate an unbounded packet backlog.
        guard let epoch = self.gate.withLock({ state -> UInt64? in
            guard !state.stopped else { return nil }
            state.ringbackAllowed = false
            guard state.pendingPlayback < VoicePlaybackReservoir.pendingPacketLimit else {
                state.droppedPlayback += 1
                return nil
            }
            state.pendingPlayback += 1
            return state.outputEpoch
        }) else { return }
        let enqueued = ContinuousClock.now
        self.queue.async { [self] in
            self.trace?.mark(.playbackQueueWait, duration: enqueued.duration(to: .now))
            defer { self.gate.withLock { $0.pendingPlayback -= 1 } }
            guard self.running, !self.gate.withLock({ $0.stopped }), let codec = self.codec else { return }
            // Stop before decoding/scheduling the first remote media buffer.
            // The latched state rejects any delayed request to restart the tone.
            self.stopRingback()
            do {
                let decoding = ContinuousClock.now
                let timing = self.playbackTimeline.prepare(timestamp)
                guard !timing.late else { return }
                let recovered = timing.missingFrames > 0 ? try codec.recover(frames: timing.missingFrames, from: packet) : nil
                if recovered?.usedFEC == true { self.fecRecoveryPackets += 1 }
                let pcm = try codec.decode(packet)
                self.receivedOpusBytes += UInt64(packet.count)
                self.receivedOpusFrames += UInt64(pcm.frameLength)
                self.trace?.mark(.decodeWork, duration: decoding.duration(to: .now))
                self.playbackTimeline.commit(timing, frames: pcm.frameLength)
                guard self.gate.withLock({ $0.outputEpoch == epoch && !$0.stopped }) else { return }
                if let recovered { self.scheduleDecodedAudio(recovered.pcm) }
                self.scheduleDecodedAudio(pcm)
            } catch { self.fail(self.systemFailure(error)) }
        }
    }

    private func scheduleDecodedAudio(_ pcm: AVAudioPCMBuffer) {
        let scheduling = ContinuousClock.now
        defer { self.trace?.mark(.scheduleWork, duration: scheduling.duration(to: .now)) }
        guard pcm.frameLength > 0 else { return }
        if let emptyAt = self.playbackEmptyAt {
            self.playbackWarmup.resume(afterIdleMS: VoicePerformanceTrace.milliseconds(emptyAt.duration(to: .now)))
            self.playbackEmptyAt = nil
        }
        if let samples = pcm.floatChannelData?[0] {
            let levels = self.playbackLeveler.process(
                UnsafeMutableBufferPointer(start: samples, count: Int(pcm.frameLength)),
                sampleRate: pcm.format.sampleRate, enabled: self.boostBuiltInSpeaker)
            let admission: VoiceOutputInterruptionGate.Admission = self.useLocalInterruption
                ? self.interruptionGate.admit(rms: levels.inputRMS, frames: pcm.frameLength,
                    nowSeconds: ProcessInfo.processInfo.systemUptime) : .play
            if admission == .discard { self.suppressedAudioFrames += UInt64(pcm.frameLength); return }
            if admission == .resumed {
                self.trace?.mark(.bargeInResumed)
                self.onInterruption(.resumed)
            }
            self.recordPlaybackLevel(levels, count: Int(pcm.frameLength))
            let queuedMS = Double(self.playbackReservoir.queuedFrames) / pcm.format.sampleRate * 1000
            let warmupMS = self.playbackReservoir.isPlaying ? 0 : self.playbackStartDeadline.map {
                max(0, VoicePerformanceTrace.milliseconds(ContinuousClock.now.duration(to: $0)))
            } ?? Double(self.playbackWarmup.milliseconds)
            self.trace?.observeResponseSpeech(rms: levels.inputRMS, estimatedPlaybackDelayMS: queuedMS + warmupMS)
        }
        // The render tap also takes gate. Never hold it across player operations:
        // stopping the player can wait for a render cycle that is waiting for gate.
        // Playback state stays on this serial owner; cancellation is checked again
        // after scheduling, and the deferred start has its own cancellation fence.
        guard !self.gate.withLock({ $0.stopped }) else { return }
        if self.playbackReservoir.append(pcm.frameLength) {
            self.trace?.mark(.playbackReset)
            self.playbackResets += 1
            self.clearPlayback(preservingReservoir: true)
        }
        guard !self.gate.withLock({ $0.stopped }) else { return }
        if self.useLocalInterruption, let samples = pcm.floatChannelData?[0] {
            let reference = VoiceBargeInDetector.downsample(
                UnsafeBufferPointer(start: samples, count: Int(pcm.frameLength)), sampleRate: pcm.format.sampleRate)
            for chunk in self.speakerReference.enqueue(reference, frames: pcm.frameLength) {
                self.interruptionAnalyzer.output(chunk.samples, startSeconds: chunk.startSeconds)
            }
        }
        let generation = self.playbackGeneration
        let frames = pcm.frameLength
        self.playbackMaxQueuedFrames = max(self.playbackMaxQueuedFrames, self.playbackReservoir.queuedFrames)
        self.player.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.playbackGeneration == generation else { return }
                self.playbackReservoir.played(frames)
                if !self.playbackReservoir.isPlaying {
                    self.trace?.mark(.playbackEmpty)
                    self.playbackEmptyTransitions += 1
                    self.playbackEmptyAt = .now
                    self.player.pause()
                    self.speakerReference.reset()
                }
            }
        }
        guard !self.gate.withLock({ $0.stopped }) else { self.clearPlayback(); return }
        self.startPlaybackWhenReady()
    }

    func cancel() {
        self.gate.withLock { $0.stopped = true }
        self.queue.async { self.finishStopIfPossible() }
    }

    func observeInterruptionEvent(_ data: Data) {
        guard self.useLocalInterruption, data.count <= 65_536, let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = value["type"] as? String,
              ["input_audio_buffer.speech_started", "input_audio_buffer.speech_stopped", "response.created"].contains(type) else { return }
        self.queue.async {
            guard self.running, !self.gate.withLock({ $0.stopped }) else { return }
            switch type {
            case "input_audio_buffer.speech_started": self.beginInterruption()
            case "input_audio_buffer.speech_stopped": self.interruptionGate.userEnded()
            case "response.created": self.interruptionGate.confirmNewResponse()
            default: break
            }
        }
    }

    private func beginInterruption() {
        guard self.useLocalInterruption, !self.gate.withLock({ $0.stopped || $0.muted }), self.interruptionGate.begin() else { return }
        self.gate.withLock { $0.outputEpoch &+= 1 }
        self.interruptions += 1
        self.trace?.mark(.bargeInStarted)
        // Silence first; stopping the node may take longer than a render cycle.
        self.player.volume = 0
        self.clearPlayback()
        self.player.volume = 1
        self.onInterruption(.began)
    }

    func stop() async {
        self.gate.withLock { $0.stopped = true }
        await withCheckedContinuation { continuation in
            self.queue.async {
                self.stopContinuations.append(continuation)
                self.finishStopIfPossible()
            }
        }
    }

    private func begin(
        _ continuation: CheckedContinuation<Void, Error>,
        onPacket: @escaping @Sendable (Data, UInt64) -> Void,
        onFailure: @escaping @Sendable (WatchRealtimeMediaFailure) -> Void,
        systemAudioActive: Bool)
    {
        guard !self.gate.withLock({ $0.stopped }) else {
            continuation.resume(throwing: CancellationError())
            return
        }
        guard !self.ownsLease, Self.lease.withLock({ owner in
            guard owner == nil else { return false }
            owner = self.id
            return true
        }) else {
            continuation
                .resume(throwing: WatchRealtimeMediaError
                    .unavailable(String(localized: "Another voice session is still stopping.")))
            return
        }
        self.ownsLease = true
        self.onPacket = onPacket
        self.onFailure = onFailure
        self.startContinuation = continuation
        do {
            if systemAudioActive {
                // CallKit already owns category and activation. Do not activate
                // again or deactivate its session from this graph's cleanup.
                self.startupStage = "codec"
                self.codec = try WatchOpusCodec()
                self.engine.attach(self.player)
                self.finishStart()
                return
            }
            self.startupStage = "category"
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, policy: .default, options: [])
            self.startupStage = "activation"
            self.activationPending = true
            session.activate(options: []) { [self] activated, error in
                self.queue.async {
                    self.activationPending = false
                    self.ownsActivation = activated
                    guard !self.gate.withLock({ $0.stopped }) else { self.finishStopIfPossible(); return }
                    if let error { self.fail(self.systemFailure(error)); return }
                    guard activated else { self.fail("Audio [activation, app 0]."); return }
                    do {
                        self.startupStage = "codec"
                        self.codec = try WatchOpusCodec()
                        self.engine.attach(self.player)
                        self.finishStart()
                    } catch { self.fail(self.systemFailure(error)) }
                }
            }
        } catch { self.fail(self.systemFailure(error)) }
    }

    private func finishStart() {
        do {
            try self.configureGraph()
            self.observeAudioChanges()
            let continuation = self.startContinuation
            self.startContinuation = nil
            continuation?.resume()
        } catch { self.fail(self.systemFailure(error)) }
    }

    private func configureGraph() throws {
        self.stopGraph()
        guard let codec = self.codec
        else { throw WatchRealtimeMediaError.unavailable(String(localized: "Voice audio is not ready.")) }
        let input = self.engine.inputNode
        self.startupStage = "input"
        let format = input.outputFormat(forBus: 0)
        self.inputSampleRate = format.sampleRate
        self.inputChannels = format.channelCount
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw WatchRealtimeMediaError.unavailable("Microphone format unavailable.")
        }
        self.startupStage = "conversion"
        guard let resampler = AVAudioConverter(from: format, to: codec.pcmFormat),
              let frame = AVAudioPCMBuffer(pcmFormat: codec.pcmFormat, frameCapacity: WatchOpusCodec.frameCount)
        else {
            throw WatchRealtimeMediaError.unavailable(String(localized: "The current audio route has no microphone."))
        }
        resampler.primeMethod = .none
        self.resampler = resampler
        self.frame = frame
        self.frameOffset = 0
        self.engine.disconnectNodeOutput(self.player)
        self.engine.connect(self.player, to: self.engine.mainMixerNode, format: codec.pcmFormat)
        self.player.volume = 1
        self.engine.mainMixerNode.outputVolume = 1
        self.updatePlaybackRoute()
        if input.isVoiceProcessingEnabled {
            input.isVoiceProcessingInputMuted = self.gate.withLock { $0.muted }
        }
        // AVAudioNode supports 100–400 ms tap buffers, independent of the 20 ms wire frames.
        input
            .installTap(
                onBus: 0,
                bufferSize: AVAudioFrameCount(format.sampleRate / 10),
                format: format)
            { [weak self] buffer, time in
                self?.capture(buffer, time: time)
            }
        self.hasTap = true
        self.startupStage = self.useVoiceProcessing ? "engine" : "basic-engine"
        self.engine.prepare()
        try self.engine.start()
        self.running = true
        self.startupStage = "active"
    }

    private func stopGraph() {
        self.stopRingback(reason: .graphReset)
        self.running = false
        if self.hasTap { self.engine.inputNode.removeTap(onBus: 0)
            self.hasTap = false
        }
        self.clearPlayback()
        self.engine.stop()
    }

    /// Numeric levels only. Never persist decoded samples, audio or device names.
    private func recordPlaybackLevel(_ levels: VoicePlaybackLeveler.Levels, count: Int) {
        self.playbackPeak = max(self.playbackPeak, levels.inputPeak)
        self.playbackMaxRMS = max(self.playbackMaxRMS, levels.inputRMS)
        self.playbackOutputPeak = max(self.playbackOutputPeak, levels.outputPeak)
        self.playbackGainMax = max(self.playbackGainMax, levels.appliedGain)
        self.playbackSamplesSinceDiagnostic += count
        guard (!self.hasPlaybackDiagnostic && self.playbackPeak > 0.001)
                || self.playbackSamplesSinceDiagnostic >= 96_000 else { return }
        self.hasPlaybackDiagnostic = true
        self.playbackSamplesSinceDiagnostic = 0
        self.writePlaybackDiagnostic()
    }

    private func writePlaybackDiagnostic() {
        let session = AVAudioSession.sharedInstance()
        let outputKinds = session.currentRoute.outputs.map { output -> String in
            switch output.portType {
            case .builtInSpeaker: "speaker"
            case .builtInReceiver: "receiver"
            case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE: "bluetooth"
            case .headphones: "headphones"
            default: "other"
            }
        }
        let analysis = self.interruptionAnalyzer.snapshot
        let diagnostic: [String: Any] = ["revision": "voice-fluency-1", "recordedAt": Date().timeIntervalSince1970,
            "receivedOpusBytes": self.receivedOpusBytes, "receivedOpusFrames": self.receivedOpusFrames,
            "receivedOpusAverageBPS": self.receivedOpusFrames == 0 ? 0 : Double(self.receivedOpusBytes) * 8 * 48_000 / Double(self.receivedOpusFrames),
            "localInterruptionEnabled": self.useLocalInterruption,
            "sessionMode": session.mode.rawValue, "systemVolume": session.outputVolume,
            "playerVolume": self.player.volume, "mixerVolume": self.engine.mainMixerNode.outputVolume,
            "decodedPeakMax": self.playbackPeak, "decodedRMSMax": self.playbackMaxRMS,
            "outputPeakMax": self.playbackOutputPeak, "gainMax": self.playbackGainMax,
            "boostEnabled": self.boostBuiltInSpeaker,
            "outputKinds": outputKinds, "voiceProcessing": self.useVoiceProcessing,
            "playbackResets": self.playbackResets, "maxQueuedFrames": self.playbackMaxQueuedFrames,
            "prerollMS": VoicePlaybackReservoir.prerollMilliseconds,
            "currentPrerollMS": self.playbackWarmup.milliseconds,
            "recoveryStarts": self.playbackWarmup.recoveryStarts,
            "emptyTransitions": self.playbackEmptyTransitions,
            "shortTimestampGaps": self.playbackTimeline.shortGaps,
            "concealedFrames": self.playbackTimeline.missingFrames,
            "fecRecoveryPackets": self.fecRecoveryPackets,
            "longTimestampGaps": self.playbackTimeline.longGaps,
            "lateAudioPackets": self.playbackTimeline.latePackets,
            "droppedPlaybackPackets": self.gate.withLock { $0.droppedPlayback },
            "interruptions": self.interruptions, "suppressedAudioFrames": self.suppressedAudioFrames,
            "scheduledReferenceChunks": analysis.referenceChunks,
            "echoFullSearches": analysis.fullSearches, "echoNarrowSearches": analysis.narrowSearches, "echoRejectedFrames": analysis.echoRejectedFrames,
            "lastEchoCorrelation": analysis.lastCorrelation, "lastInputRMS": analysis.lastInputRMS,
            "analysisDroppedInputs": analysis.droppedInputs, "analysisDroppedOutputs": analysis.droppedOutputs,
            "analysisStaleInputs": analysis.staleInputs, "analysisMaximumWorkMS": analysis.maximumWorkMS,
            "analysisMaximumQueueMS": analysis.maximumQueueMS]
        if let data = try? JSONSerialization.data(withJSONObject: diagnostic) {
            VoiceDiagnosticStore.shared.submit(data, to: URL.cachesDirectory.appendingPathComponent("watchdot-playback-diagnostic.json"))
        }
    }

    private func updatePlaybackRoute() {
        let builtIn = AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver
        }
        if builtIn != self.boostBuiltInSpeaker { self.playbackLeveler = VoicePlaybackLeveler() }
        self.boostBuiltInSpeaker = builtIn
    }

    private func capture(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard self.gate.withLock({ state in
            guard !state.stopped, state.pending < 3 else { return false }
            state.pending += 1
            return true
        }) else { return }
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let copy = CapturedAudio(
            format: buffer.format.streamDescription.pointee,
            frames: buffer.frameLength,
            buffers: source.map { chunk in
                chunk.mData.map { Data(bytes: $0, count: Int(chunk.mDataByteSize)) } ?? Data()
            }, startSeconds: time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : nil)
        let enqueued = ContinuousClock.now
        self.queue.async {
            self.trace?.mark(.captureQueueWait, duration: enqueued.duration(to: .now))
            defer { self.gate.withLock { $0.pending -= 1 } }
            guard self.running, !self.gate.withLock({ $0.stopped }) else { return }
            do {
                let encoding = ContinuousClock.now
                try self.encode(copy)
                self.trace?.mark(.encodeWork, duration: encoding.duration(to: .now))
            } catch {
                self.fail(self.systemFailure(error))
            }
        }
    }

    private func encode(_ captured: CapturedAudio) throws {
        var description = captured.format
        guard let format = AVAudioFormat(streamDescription: &description),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: captured.frames)
        else { return }
        buffer.frameLength = captured.frames
        let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard destination.count == captured.buffers.count else { return }
        for index in destination.indices {
            guard let bytes = destination[index].mData,
                  captured.buffers[index].count <= Int(destination[index].mDataByteSize) else { return }
            captured.buffers[index].copyBytes(
                to: bytes.assumingMemoryBound(to: UInt8.self),
                count: captured.buffers[index].count)
        }
        guard let resampler = self.resampler, let codec = self.codec, let frame = self.frame,
              buffer.format == resampler.inputFormat else { return }
        let capacity =
            AVAudioFrameCount(ceil(Double(buffer.frameLength) * WatchOpusCodec.sampleRate / buffer.format.sampleRate)) +
            960
        guard let output = AVAudioPCMBuffer(pcmFormat: codec.pcmFormat, frameCapacity: capacity) else { return }
        _ = try resampler.convert(buffer, to: output)
        for index in 0..<Int(output.frameLength) {
            if self.frameOffset == 0 {
                self.inputFrameStartSeconds = captured.startSeconds.map { $0 + Double(index) / WatchOpusCodec.sampleRate }
            }
            frame.floatChannelData![0][self.frameOffset] = output.floatChannelData![0][index]
            self.frameOffset += 1
            guard self.frameOffset == Int(WatchOpusCodec.frameCount) else { continue }
            frame.frameLength = WatchOpusCodec.frameCount
            if self.useLocalInterruption, let start = self.inputFrameStartSeconds {
                let samples = VoiceBargeInDetector.downsample(
                    UnsafeBufferPointer(start: frame.floatChannelData![0], count: self.frameOffset), sampleRate: WatchOpusCodec.sampleRate)
                self.interruptionAnalyzer.input(samples, startSeconds: start,
                    enabled: !self.gate.withLock({ $0.muted || $0.stopped }),
                    outputActive: self.playbackReservoir.queuedFrames > 0 || self.playbackReservoir.isPlaying)
            }
            let microphoneMuted = self.ringback.isPlaying || self.gate.withLock({ $0.muted })
            if microphoneMuted {
                frame.floatChannelData![0].initialize(repeating: 0, count: self.frameOffset)
            }
            if let packet = try codec.encode(frame) {
                if !microphoneMuted, !self.microphonePacketRecorded {
                    self.microphonePacketRecorded = true
                    self.trace?.mark(.firstMicrophonePacket, once: true)
                }
                self.onPacket?(packet, self.timestamp)
            }
            if self.timestamp % 4800 == 0 {
                var energy: Float = 0
                for sample in 0..<self.frameOffset {
                    let value = frame.floatChannelData![0][sample]
                    energy += value * value
                }
                self.onLevel(min(1, sqrt(energy / Float(self.frameOffset)) * 4))
            }
            self.timestamp += UInt64(WatchOpusCodec.frameCount)
            self.frameOffset = 0
        }
    }

    private func startPlaybackWhenReady() {
        guard !self.playbackReservoir.isPlaying else { return }
        if self.playbackStart == nil {
            let generation = self.playbackGeneration
            let start = DispatchWorkItem { [weak self] in
                guard let self, self.playbackGeneration == generation,
                      self.running, !self.gate.withLock({ $0.stopped }),
                      self.playbackReservoir.queuedFrames > 0 else { return }
                self.playbackStart = nil
                self.playbackStartDeadline = nil
                self.trace?.mark(.playbackStarted)
                if self.useLocalInterruption {
                    let anchor = AVAudioTime.seconds(forHostTime: mach_absolute_time())
                    for chunk in self.speakerReference.start(at: anchor) {
                        self.interruptionAnalyzer.output(chunk.samples, startSeconds: chunk.startSeconds)
                    }
                }
                self.playbackReservoir.start(); self.player.play()
            }
            self.playbackStart = start
            self.playbackStartDeadline = ContinuousClock.now.advanced(by: .milliseconds(self.playbackWarmup.milliseconds))
            // Delay from first arrival, even for a large burst: starting as soon
            // as a burst fills a frame threshold would leave no jitter reserve.
            self.queue.asyncAfter(deadline: .now() + .milliseconds(self.playbackWarmup.milliseconds), execute: start)
        }
    }

    private func clearPlayback(preservingReservoir: Bool = false) {
        self.playbackGeneration &+= 1
        self.playbackStart?.cancel(); self.playbackStart = nil
        self.playbackStartDeadline = nil; self.playbackEmptyAt = nil
        let stopping = ContinuousClock.now
        self.player.stop()
        self.trace?.mark(.playbackStopWork, duration: stopping.duration(to: .now))
        self.speakerReference.reset()
        if !preservingReservoir {
            self.playbackReservoir = VoicePlaybackReservoir()
            self.playbackWarmup = VoicePlaybackWarmup()
        }
    }

    private func observeAudioChanges() {
        let center = NotificationCenter.default
        self.observations.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: self.engine,
            queue: nil)
        { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.running, !self.gate.withLock({ $0.stopped }) else { return }
                do {
                    try self.configureGraph()
                } catch {
                    self.fail(self.systemFailure(error))
                }
            }
        })
        #if os(watchOS)
        self.observations.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.updatePlaybackRoute() }
        })
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification] {
            self.observations.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] event in
                if name == AVAudioSession.interruptionNotification {
                    // An ended interruption restores availability; it must not terminate a
                    // newly started call that registered while the old interruption ended.
                    let type = event.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber
                    guard type?.uintValue == AVAudioSession.InterruptionType.began.rawValue else { return }
                }
                guard let self else { return }
                self.queue
                    .async { self.fail(String(localized: "Voice was interrupted. Start voice again to continue."),
                        reason: name == AVAudioSession.interruptionNotification ? .audioInterrupted : .audioReset) }
            })
        }
        #endif
    }

    private func fail(_ message: String, reason: WatchRealtimeMediaFailure.Reason = .audioSystem) {
        guard !self.gate.withLock({ state in let stopped = state.stopped
            state.stopped = true
            return stopped }) else { return }
        let continuation = self.startContinuation
        self.startContinuation = nil
        continuation?.resume(throwing: WatchRealtimeMediaError.unavailable(message))
        let onFailure = self.onFailure
        self.finishStopIfPossible()
        onFailure?(WatchRealtimeMediaFailure(kind: .audio, message: message, reason: reason))
    }

    private func systemFailure(_ error: Error) -> String {
        let system = error as NSError
        let domain = [NSOSStatusErrorDomain: "OSStatus", NSCocoaErrorDomain: "Cocoa",
                      "com.apple.coreaudio.avfaudio": "AVAudio"][system.domain] ?? "app"
        let diagnostic: [String: Any] = ["stage": self.startupStage, "domain": domain, "code": system.code,
            "voiceProcessing": self.useVoiceProcessing, "inputSampleRate": self.inputSampleRate,
            "inputChannels": self.inputChannels]
        if let data = try? JSONSerialization.data(withJSONObject: diagnostic) {
            VoiceDiagnosticStore.shared.submit(data, to: URL.cachesDirectory.appendingPathComponent("watchdot-audio-diagnostic.json"))
        }
        return "Audio [\(self.startupStage), \(domain) \(system.code)]."
    }

    private func finishStopIfPossible() {
        self.interruptionAnalyzer.stop()
        if self.running { self.writePlaybackDiagnostic() }
        self.stopRingback()
        self.stopGraph()
        self.observations.forEach { NotificationCenter.default.removeObserver($0) }
        self.observations.removeAll()
        let start = self.startContinuation
        self.startContinuation = nil
        start?.resume(throwing: CancellationError())
        // Drain activation before releasing the lease: a late callback must not
        // deactivate the next call's audio session after cancellation.
        guard !self.activationPending else { return }
        if self.ownsActivation {
            self.ownsActivation = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        if self.ownsLease {
            Self.lease.withLock { if $0 == self.id { $0 = nil } }
            self.ownsLease = false
        }
        self.codec = nil
        self.resampler = nil
        self.frame = nil
        self.onPacket = nil
        self.onFailure = nil
        let stops = self.stopContinuations
        self.stopContinuations.removeAll()
        stops.forEach { $0.resume() }
    }
}

