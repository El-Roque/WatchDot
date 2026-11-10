import Combine
import Foundation
import WatchKit

/// One user-initiated native call. No account loading, network or microphone in init.
@MainActor
final class WatchNativeCallController: ObservableObject {
    enum Phase: Equatable { case idle, preparing, connecting, talking, ending, failed }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = "Tap Call to talk to your Dot."
    @Published private(set) var muted = false
    @Published private(set) var level: Float = 0
    @Published private(set) var connectedAt: Date?

    var isRunning: Bool { [.preparing, .connecting, .talking, .ending].contains(phase) }
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var media: WatchRealtimeMediaSession?
    private var managedCall: DotManagedVoiceCall?
    private var mediaConnected = false
    private var eventsOpen = false
    private var dotStarted = false
    private var attachmentRequested = false
    private var remoteAudioReceived = false
    private var audioAdmitted = false
    private var accountIsCurrent: (@Sendable () async -> Bool)?
    private var readinessTask: Task<Void, Never>?
    private var performance: VoicePerformanceTrace?
    private var step = "account"
    private var mediaFailure: WatchRealtimeMediaFailure?
    private var systemCallID: UUID?

    func start(using connection: ConnectionSession, initiallyMuted: Bool = false) {
        guard !isRunning else { return }
        generation = UUID()
        let expected = generation
        let trace = VoicePerformanceTrace(url: URL.cachesDirectory.appendingPathComponent("watchdot-voice-performance.json"))
        self.performance = trace
        trace.mark(.callTapped)
        muted = initiallyMuted
        level = 0
        connectedAt = nil
        mediaConnected = false; eventsOpen = false; dotStarted = false
        attachmentRequested = false; remoteAudioReceived = false; audioAdmitted = false
        readinessTask?.cancel(); readinessTask = nil; accountIsCurrent = nil
        phase = .preparing
        step = "account"
        mediaFailure = nil
        status = "Connecting to your Dot…"
        task = Task { [weak self, weak connection] in
            guard let self, let connection else { return }
            do {
                await cleanup?.value
                trace.mark(.previousCleanupDone)
                try Task.checkCancellation()
                guard generation == expected else { return }
                try Task.checkCancellation()
                guard generation == expected else { return }
                step = "account"
                let context = try await connection.nativeVoiceContext()
                trace.mark(.accountReady)
                try Task.checkCancellation()
                guard generation == expected else { return }
                accountIsCurrent = context.isCurrentAccount
                step = "audio"
                try await WatchRealtimeMediaSession.requestMicrophonePermission()
                try Task.checkCancellation()
                guard generation == expected else { return }
                step = "system-call"
                systemCallID = expected
                try await WatchSystemCall.shared.start(id: expected) { [weak self] event in
                    guard let self, self.generation == expected else { return }
                    switch event {
                    case .muted(let value):
                        self.muted = value
                        self.media?.setMuted(value || !self.audioAdmitted || !self.mediaConnected || !self.eventsOpen)
                    case .ended: self.finish()
                    case .reset, .audioDeactivated, .timedOut: self.fail("The system interrupted call audio.")
                    }
                }
                try Task.checkCancellation()
                guard generation == expected else { throw CancellationError() }
                // CallKit admission is complete; prepare the independent media session.
                let media = WatchRealtimeMediaSession(trace: trace) { [weak self] event in
                    Task { @MainActor in self?.receive(event, generation: expected) }
                }
                self.media = media
                media.setMuted(true)
                status = "Preparing audio…"
                step = "audio"
                try await media.startAudio()
                trace.mark(.audioReady)
                media.setMuted(true)
                try Task.checkCancellation()
                guard generation == expected else { media.cancel(); return }
                phase = .connecting
                status = "Calling Dot…"
                media.setRingback(true)
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(45)) } catch { return }
                    guard let self, generation == expected, phase != .talking else { return }
                    fail("The call timed out. Check your connection and try again.")
                }
                let managed = DotManagedVoiceCall(http: SecureSignInHTTP(), account: context.account,
                    route: context.route, isCurrentAccount: context.isCurrentAccount, onDiagnostic: { diagnostic in
                        if let data = try? JSONEncoder().encode(diagnostic) {
                            VoiceDiagnosticStore.shared.submit(data, to: URL.cachesDirectory.appendingPathComponent("watchdot-dot-call-diagnostic.json"))
                        }
                    })
                self.managedCall = managed
                step = "offer"
                let offer = try await media.makeOffer()
                trace.mark(.offerReady)
                step = "allocate"
                let allocation = try await managed.allocate(offer: offer)
                trace.mark(.allocationReady)
                try Task.checkCancellation()
                guard generation == expected else { media.cancel(); return }
                step = "transport"
                try await media.applyAnswer(allocation.answer)
                trace.mark(.networkReady)
                try Task.checkCancellation()
                guard generation == expected else { media.cancel(); return }
                step = "attach"
                attachmentRequested = true
                becomeReadyIfPossible()
                try await managed.attach()
                trace.mark(.attached)
                guard generation == expected, await context.isCurrentAccount() else { throw CancellationError() }
                dotStarted = true
                if audioAdmitted { step = "call"; recordState("connected") }
                else { becomeReadyIfPossible() }
            } catch is CancellationError {
                if generation == expected { finish() }
            } catch {
                guard generation == expected else { return }
                if let error = error as? DotVoiceRouteProbeError { fail(error.message) }
                else if let error = error as? WatchSystemCallError { fail(error.localizedDescription) }
                else if let error = error as? DotManagedVoiceError { fail(error.message) }
                else if let error = error as? DotNativeVoiceError { fail(error.message) }
                else if let error = error as? WatchRealtimeMediaError, step == "audio" {
                    fail(error.localizedDescription)
                } else {
                    let system = error as NSError
                    fail("Could not start the call [\(step), \(Self.safeDomain(system.domain)) \(system.code)].")
                }
            }
        }
    }

    func toggleMute() {
        guard isRunning else { return }
        muted.toggle()
        if phase == .talking, muted { performance?.questionEndedByMute() }
        else if !muted { performance?.cancelQuestionTiming() }
        media?.setMuted(!audioAdmitted || !mediaConnected || !eventsOpen || muted)
    }


    /// Stop local capture synchronously, even if the service is unreachable.
    func finish() {
        guard phase != .ending else { return }
        guard isRunning || media != nil || managedCall != nil else { return }
        WKInterfaceDevice.current().play(.stop)
        phase = .ending
        releaseResources()
        status = "Ending call…"
        let expected = generation
        Task { [weak self] in
            guard let self else { return }
            await cleanup?.value
            guard generation == expected, phase == .ending else { return }
            phase = .idle
            status = "Call ended."
        }
    }

    private func fail(_ message: String) {
        WKInterfaceDevice.current().play(.failure)
        recordState("failed", message: message)
        releaseResources()
        phase = .failed
        status = message
    }

    private func recordState(_ result: String, message: String = "") {
        let revision = "voice-admission-1"
        var diagnostic = ["revision": revision, "recordedAt": String(Date().timeIntervalSince1970),
            "stage": step, "result": result, "mediaConnected": String(mediaConnected),
            "eventsOpen": String(eventsOpen), "attached": String(dotStarted)]
        diagnostic["attachmentRequested"] = String(attachmentRequested)
        diagnostic["remoteAudioReceived"] = String(remoteAudioReceived)
        diagnostic["audioAdmitted"] = String(audioAdmitted)
        if let failure = mediaFailure {
            diagnostic["mediaFailureKind"] = failure.kind.rawValue
            diagnostic["mediaFailureReason"] = failure.reason.rawValue
            if let code = failure.systemCode { diagnostic["mediaFailureCode"] = String(code) }
        }
        if message.range(of: "^Audio \\[([a-z-]+), (AVAudio|OSStatus|Cocoa|app) -?[0-9]+\\]\\.$", options: .regularExpression) != nil {
            diagnostic["audioError"] = message
        }
        if let data = try? JSONSerialization.data(withJSONObject: diagnostic) {
            VoiceDiagnosticStore.shared.submit(data, to: URL.cachesDirectory.appendingPathComponent("watchdot-voice-diagnostic.json"))
        }
    }

    private static func safeDomain(_ value: String) -> String {
        [NSURLErrorDomain, NSOSStatusErrorDomain, NSCocoaErrorDomain, "com.apple.coreaudio.avfaudio"].contains(value)
            ? value : "app"
    }

    private func releaseResources() {
        performance?.mark(.callEnded, once: true)
        generation = UUID()
        readinessTask?.cancel(); readinessTask = nil; accountIsCurrent = nil
        audioAdmitted = false; attachmentRequested = false; remoteAudioReceived = false
        task?.cancel(); task = nil
        timeout?.cancel(); timeout = nil
        let media = media; self.media = nil
        let managed = managedCall; self.managedCall = nil
        let systemID = systemCallID; systemCallID = nil
        if let systemID { WatchSystemCall.shared.cancel(id: systemID) }
        media?.cancel()
        level = 0
        dotStarted = false; mediaConnected = false; eventsOpen = false
        let previous = cleanup
        cleanup = Task {
            await previous?.value
            await media?.stop()
            await managed?.stop()
            if let systemID { await WatchSystemCall.shared.stop(id: systemID) }
        }
    }

    private var readiness: NativeVoiceReadiness {
        NativeVoiceReadiness(mediaConnected: mediaConnected, eventsOpen: eventsOpen,
            attachmentRequested: attachmentRequested, attachmentAccepted: dotStarted,
            remoteAudioReceived: remoteAudioReceived)
    }

    private var canAdmitMedia: Bool { phase == .preparing || phase == .connecting }

    private func becomeReadyIfPossible() {
        guard canAdmitMedia, readiness.mediaReady, readinessTask == nil,
              let accountIsCurrent else { return }
        let expected = generation
        readinessTask = Task { [weak self] in
            let current = await accountIsCurrent()
            guard let self, !Task.isCancelled, generation == expected else { return }
            readinessTask = nil
            guard current else { fail(DotNativeVoiceError.accountChanged.message); return }
            guard readiness.permitsAudio(currentAccount: current, activeCall: canAdmitMedia) else { return }
            admitMedia()
        }
    }

    private func admitMedia() {
        audioAdmitted = true
        timeout?.cancel(); timeout = nil
        media?.setRingback(false)
        media?.setMuted(muted)
        performance?.mark(.callReady, once: true)
        phase = .talking
        connectedAt = .now
        if let systemCallID { WatchSystemCall.shared.reportConnected(id: systemCallID) }
        WKInterfaceDevice.current().play(.start)
        step = dotStarted ? "call" : "attach"
        status = "Connected to your Dot"
        recordState("connected")
    }

    private func receive(_ event: WatchRealtimeSessionEvent, generation expected: UUID) {
        guard generation == expected, isRunning else { return }
        switch event {
        case .connected: performance?.mark(.mediaReady, once: true); mediaConnected = true; becomeReadyIfPossible()
        case .remoteAudioReady: remoteAudioReceived = true; becomeReadyIfPossible()
        case .eventsOpen: performance?.mark(.eventsReady, once: true); eventsOpen = true; becomeReadyIfPossible()
        case .inputLevel(let value): level = value
        case .interruption(let state):
            guard phase == .talking else { return }
            switch state {
            case .began: status = "Listening…"
            case .userFinished: status = "Waiting for Dot…"
            case .resumed: status = "Connected to your Dot"
            }
        case .event(let data):
            // Interpret only the lifecycle envelope; never retain transcripts/provider events.
            if data.count <= 65_536,
               let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               event["type"] as? String == "session.closed" {
                if event["reason"] as? String == "client_request" { finish() }
                else { fail("Dot ended the call. You can call again.") }
            }
        case .eventsClosed: fail("The call channel closed. You can call again.")
        case .ended(let error):
            mediaFailure = error
            if error.reason == .phoneUnavailable {
                fail(error.message)
            } else if error.kind == .audio, error.message.hasPrefix("Audio [") {
                fail(error.message)
            } else { fail("The call was interrupted [\(step)]. Check your connection and audio output.") }
        }
    }

}
