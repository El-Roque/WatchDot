import AVFAudio
import CallKit
import Foundation
import WatchKit

enum WatchSystemCallError: LocalizedError {
    case unavailable, activationTimedOut, rejected(Int)
    var errorDescription: String? {
        switch self {
        case .unavailable: "The Watch could not prepare the system call."
        case .activationTimedOut: "The Watch did not activate call audio in time."
        case .rejected(let code): "The Watch could not start the call [system, \(code)]."
        }
    }
}

/// One process-wide provider. CallKit owns activation; neither audio nor UDP may
/// start before didActivate. All callbacks run on the provider's main queue.
@MainActor
final class WatchSystemCall: NSObject, @preconcurrency CXProviderDelegate {
    static let shared = WatchSystemCall()
    enum Event { case ended, reset, audioDeactivated, timedOut, muted(Bool) }
    private let provider: CXProvider
    private let controller = CXCallController()
    private var callID: UUID?
    private var ending = false
    private var connected = false
    private var startAccepted = false
    private var audioActive = false
    private var audioWasActivated = false
    private var endPerformed = false
    private var providerReady = false
    private var startRequested = false
    private var mediaFailureSnapshot: [String: Any]?
    private var stages: [String] = []
    private var activation: CheckedContinuation<Void, Error>?
    private var stops: [CheckedContinuation<Void, Never>] = []
    private var deadline: Task<Void, Never>?
    private var onEvent: (@MainActor (Event) -> Void)?

    private override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.supportedHandleTypes = [.generic]
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.includesCallsInRecents = false
        self.provider = CXProvider(configuration: configuration)
        super.init()
        self.provider.setDelegate(self, queue: .main)
    }

    func start(id: UUID, onEvent: @escaping @MainActor (Event) -> Void) async throws {
        try Task.checkCancellation()
        guard callID == nil else { throw WatchSystemCallError.unavailable }
        callID = id
        ending = false
        connected = false
        startAccepted = false
        audioActive = false
        audioWasActivated = false
        endPerformed = false
        startRequested = false
        mediaFailureSnapshot = nil
        stages.removeAll()
        self.onEvent = onEvent
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                activation = continuation
                record(providerReady ? "preparingRequest" : "waitingForProvider")
                requestStartIfReady(id: id)
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    guard let self, self.callID == id, self.activation != nil else { return }
                    self.record("activationTimedOut")
                    let pending = self.activation; self.activation = nil
                    pending?.resume(throwing: WatchSystemCallError.activationTimedOut)
                    self.cancel(id: id)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        }
        try Task.checkCancellation()
    }

    private func requestStartIfReady(id: UUID) {
        guard providerReady, callID == id, activation != nil, !startRequested, !ending else { return }
        startRequested = true
        record("requested")
        let action = CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: "Dot"))
        action.isVideo = false
        controller.request(CXTransaction(action: action)) { [weak self] error in
            let code = (error as NSError?)?.code
            Task { @MainActor in
                guard let self, self.callID == id, let code else { return }
                self.complete(id: id, error: WatchSystemCallError.rejected(code), result: "rejected", code: code)
            }
        }
    }

    func providerDidBegin(_ provider: CXProvider) {
        providerReady = true
        record("providerReady")
        if let callID { requestStartIfReady(id: callID) }
    }

    /// Cancel admission immediately. Local media is stopped by the call owner;
    /// the asynchronous end action only settles the system UI/audio ownership.
    func cancel(id: UUID) {
        guard callID == id, !ending else { return }
        ending = true
        onEvent = nil
        deadline?.cancel()
        let pending = activation; activation = nil
        pending?.resume(throwing: CancellationError())
        record("ending")
        guard startRequested else { complete(id: id, result: "cancelledBeforeRequest"); return }
        controller.request(CXTransaction(action: CXEndCallAction(call: id))) { [weak self] error in
            let code = (error as NSError?)?.code
            Task { @MainActor in
                guard let self, self.callID == id, let code else { return }
                self.provider.reportCall(with: id, endedAt: nil, reason: .failed)
                self.complete(id: id, result: "endRejected", code: code)
            }
        }
        scheduleEndDeadline(id: id)
    }

    private func scheduleEndDeadline(id: UUID) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, self.callID == id, self.ending else { return }
            self.provider.reportCall(with: id, endedAt: nil, reason: .failed)
            self.complete(id: id, result: "endTimedOut")
        }
    }

    func stop(id: UUID) async {
        cancel(id: id)
        guard callID == id else { return }
        await withCheckedContinuation { stops.append($0) }
    }

    func reportConnected(id: UUID) {
        guard callID == id, !ending, !connected else { return }
        connected = true
        provider.reportOutgoingCall(with: id, connectedAt: nil)
        record("connected")
    }

    func setMuted(id: UUID, muted: Bool) {
        guard callID == id, !ending else { return }
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: id, muted: muted))) { _ in }
    }

    func recordMediaFailure(id: UUID) {
        guard callID == id else { return }
        mediaFailureSnapshot = ["audioActive": audioActive, "connected": connected,
            "ending": ending, "activeSystemCalls": controller.callObserver.calls.filter { !$0.hasEnded }.count,
            "applicationActive": WKApplication.shared().applicationState == .active,
            "recordedAt": Date().timeIntervalSince1970]
        record("mediaFailed")
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        guard callID == action.callUUID, !ending else { action.fail(); return }
        do {
            // Restore the profile validated by the real call on this Watch.
            // Its lower playback level is compensated only in receive PCM.
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord,
                mode: .voiceChat, policy: .default, options: [])
            let update = CXCallUpdate()
            update.localizedCallerName = "Dot"
            update.remoteHandle = action.handle
            update.supportsHolding = false
            update.supportsGrouping = false
            update.supportsUngrouping = false
            update.supportsDTMF = false
            provider.reportCall(with: action.callUUID, updated: update)
            provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
            record("accepted")
            startAccepted = true
            action.fulfill()
        } catch {
            action.fail()
            let code = (error as NSError).code
            complete(id: action.callUUID, error: WatchSystemCallError.rejected(code), result: "audioConfigurationFailed", code: code)
        }
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        guard callID != nil, startAccepted else { return }
        audioActive = true
        audioWasActivated = true
        guard !ending else { record("lateAudioActivation"); return }
        deadline?.cancel(); deadline = nil
        record("audioActivated")
        let pending = activation; activation = nil
        pending?.resume()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        guard let id = callID else { return }
        if ending {
            audioActive = false
            if endPerformed { complete(id: id, result: "ended") }
            return
        }
        guard audioActive else { return }
        audioActive = false
        record("audioDeactivated")
        let notify = onEvent
        cancel(id: id)
        notify?(.audioDeactivated)
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard callID == action.callUUID else { action.fulfill(); return }
        let notify = callID == action.callUUID && !ending ? onEvent : nil
        ending = true
        endPerformed = true
        onEvent = nil
        let pending = activation; activation = nil
        pending?.resume(throwing: CancellationError())
        record("endAccepted")
        action.fulfill()
        // Keep ownership through deactivation so a late callback cannot tear down
        // the next call. Calls cancelled before start acceptance need no audio drain.
        if !startAccepted || (audioWasActivated && !audioActive) { complete(id: action.callUUID, result: "ended") }
        else { scheduleEndDeadline(id: action.callUUID) }
        notify?(.ended)
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard callID == action.callUUID, !ending else { action.fail(); return }
        onEvent?(.muted(action.isMuted))
        action.fulfill()
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        guard let action = action as? CXCallAction, callID == action.callUUID else { return }
        let notify = onEvent
        provider.reportCall(with: action.callUUID, endedAt: nil, reason: .failed)
        complete(id: action.callUUID, result: "actionTimedOut")
        notify?(.timedOut)
    }

    func providerDidReset(_ provider: CXProvider) {
        guard let id = callID else { return }
        let notify = onEvent
        complete(id: id, result: "reset")
        notify?(.reset)
    }

    private func complete(id: UUID, error: Error = CancellationError(), result: String, code: Int? = nil) {
        guard callID == id else { return }
        record(result, code: code)
        deadline?.cancel(); deadline = nil
        callID = nil
        ending = false
        connected = false
        startAccepted = false
        audioActive = false
        audioWasActivated = false
        endPerformed = false
        startRequested = false
        onEvent = nil
        let pending = activation; activation = nil
        pending?.resume(throwing: error)
        let waiting = stops; stops.removeAll()
        waiting.forEach { $0.resume() }
    }

    private func record(_ result: String, code: Int? = nil) {
        stages.append(result)
        if stages.count > 16 { stages.removeFirst(stages.count - 16) }
        var diagnostic: [String: Any] = ["revision": "orbit-6", "recordedAt": Date().timeIntervalSince1970,
            "result": result, "connected": connected, "ending": ending,
            "audioActive": audioActive, "startAccepted": startAccepted, "stages": stages,
            "providerReady": providerReady, "startRequested": startRequested,
            "maximumCallGroups": provider.configuration.maximumCallGroups,
            "maximumCallsPerGroup": provider.configuration.maximumCallsPerCallGroup,
            "applicationActive": WKApplication.shared().applicationState == .active,
            "activeSystemCalls": controller.callObserver.calls.filter { !$0.hasEnded }.count]
        if let code { diagnostic["systemCode"] = code }
        if let snapshot = mediaFailureSnapshot { diagnostic["atMediaFailure"] = snapshot }
        if let data = try? JSONSerialization.data(withJSONObject: diagnostic) {
            try? data.write(to: URL.cachesDirectory.appendingPathComponent("watchdot-system-call-diagnostic.json"), options: .atomic)
        }
    }
}
