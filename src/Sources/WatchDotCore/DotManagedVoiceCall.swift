import Foundation

enum DotManagedVoiceError: Error, Sendable, Equatable {
    case accountChanged, busy, invalidOffer, invalidAnswer, missingCallID, rootChanged
    case rejected(String, Int)
    var message: String {
        switch self {
        case .accountChanged: "Your account changed or expired. Reconnect before calling."
        case .busy: "Your Dot already has an active call. End it before calling again."
        case .invalidOffer, .invalidAnswer: "Could not prepare audio for the Dot call."
        case .missingCallID: "Dot returned an unrecognized call."
        case .rootChanged: "Your Dot's primary chat changed. Reconnect before calling."
        case .rejected(let stage, let status): "Dot rejected the call [\(stage), HTTP \(status)]."
        }
    }
}

struct DotManagedVoiceAllocation: Sendable {
    let answer: String
}

/// Fixed metadata only. Never contains IDs, SDP, headers, server text or conversation content.
struct DotManagedVoiceDiagnostic: Codable, Sendable {
    let revision: String
    let recordedAt: TimeInterval
    let stage: String
    let result: String
    let httpStatus: Int?
    let failureStage: String?
    let failureHTTPStatus: Int?
}

/// The primary Dot's own server-managed call protocol (Orbit), not Codex task voice.
/// Pending create/attach requests settle before stop so late responses cannot revive a call.
actor DotManagedVoiceCall {
    private let http: any SignInHTTP
    private let account: SignedInAccount
    private let route: VerifiedDotVoiceRoute
    private let isCurrentAccount: @Sendable () async -> Bool
    private let onDiagnostic: @Sendable (DotManagedVoiceDiagnostic) -> Void
    private let now: @Sendable () -> Date
    private var pendingCreate: Task<SignInHTTPResponse, any Error>?
    private var pendingAttach: Task<SignInHTTPResponse, any Error>?
    private var callID: String?
    private var allocationValidated = false
    private var closed = false
    private var stopping = false
    private var stopped = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var failureStage: String?
    private var failureHTTPStatus: Int?

    init(http: any SignInHTTP, account: SignedInAccount, route: VerifiedDotVoiceRoute,
         isCurrentAccount: @escaping @Sendable () async -> Bool,
         onDiagnostic: @escaping @Sendable (DotManagedVoiceDiagnostic) -> Void = { _ in },
         now: @escaping @Sendable () -> Date = { .now }) {
        self.http = http; self.account = account; self.route = route
        self.isCurrentAccount = isCurrentAccount; self.onDiagnostic = onDiagnostic; self.now = now
    }

    func allocate(offer: String) async throws -> DotManagedVoiceAllocation {
        try await checkCurrent()
        guard !closed, pendingCreate == nil else { throw CancellationError() }
        guard offer.hasPrefix("v=0"), offer.utf8.count <= 200_000 else { throw DotManagedVoiceError.invalidOffer }
        var request = try request(suffix: "")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["sdp": offer])
        let task = Task { [http, request] in try await http.sendWithMetadata(request) }
        pendingCreate = task
        report("create", "pending")
        do {
            let response = try await task.value
            rememberCall(response)
            try await checkCurrent()
            guard !closed else { throw CancellationError() }
            try validate(response, stage: "create")
            guard callID != nil else { throw DotManagedVoiceError.missingCallID }
            if let root = response.rootThreadID, let expected = route.rootThreadID, root != expected {
                throw DotManagedVoiceError.rootChanged
            }
            guard let answer = String(data: response.data, encoding: .utf8),
                  answer.hasPrefix("v=0"), answer.utf8.count <= 200_000 else { throw DotManagedVoiceError.invalidAnswer }
            allocationValidated = true
            return DotManagedVoiceAllocation(answer: answer)
        } catch {
            report("create", "failed")
            throw error
        }
    }

    func attach() async throws {
        try await checkCurrent()
        guard !closed, allocationValidated, let callID, pendingAttach == nil else { throw CancellationError() }
        let request = try request(suffix: "/\(callID)/attach")
        let task = Task { [http] in try await http.sendWithMetadata(request) }
        pendingAttach = task
        report("attach", "pending")
        do {
            let response = try await task.value
            try await checkCurrent()
            guard !closed else { throw CancellationError() }
            try validate(response, stage: "attach")
        } catch {
            report("attach", "failed")
            throw error
        }
    }

    /// Call only after stopping local capture. Never cancel allocation and lose its returned ID.
    func stop() async {
        if stopped { return }
        if stopping {
            await withCheckedContinuation { stopWaiters.append($0) }
            return
        }
        stopping = true; closed = true
        defer {
            pendingCreate = nil; pendingAttach = nil; callID = nil
            stopped = true; stopping = false
            let waiters = stopWaiters; stopWaiters.removeAll(); waiters.forEach { $0.resume() }
        }
        if let response = try? await pendingCreate?.value { rememberCall(response) }
        _ = try? await pendingAttach?.value
        guard let callID else { report("stop", "no_allocation"); return }
        do {
            try await checkCurrent()
            let response = try await http.sendWithMetadata(request(suffix: "/\(callID)/stop"))
            try validate(response, stage: "stop")
        } catch { report("stop", "failed") }
    }

    private func checkCurrent() async throws {
        try Task.checkCancellation()
        guard account.subject == route.subject, account.clientID == OpenAIOAuthClient.codex,
              account.expiresAt > now(), let token = account.accessToken, !token.isEmpty,
              token.utf8.count <= 64_000, await isCurrentAccount() else { throw DotManagedVoiceError.accountChanged }
        try Task.checkCancellation()
    }

    private func request(suffix: String) throws -> URLRequest {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard !route.dotID.isEmpty, route.dotID.utf8.count <= 512,
              let segment = route.dotID.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://chatgpt.com/backend-api/tbo/\(segment)/voice/calls\(suffix)") else {
            throw DotManagedVoiceError.accountChanged
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 25
        request.httpShouldHandleCookies = false
        request.setValue("Bearer " + (account.accessToken ?? ""), forHTTPHeaderField: "Authorization")
        request.setValue(route.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        return request
    }

    private func rememberCall(_ response: SignInHTTPResponse) {
        guard (200..<300).contains(response.status), !response.clientChallenge,
              let location = response.location, let path = URLComponents(string: location)?.path,
              let value = path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init),
              value.range(of: "^rtc_[A-Za-z0-9_-]{1,160}$", options: .regularExpression) != nil else { return }
        if callID == nil { callID = value }
    }

    private func validate(_ response: SignInHTTPResponse, stage: String) throws {
        guard !response.clientChallenge, (200..<300).contains(response.status) else {
            report(stage, "rejected", status: response.status)
            if response.status == 409 { throw DotManagedVoiceError.busy }
            throw DotManagedVoiceError.rejected(stage, response.status)
        }
        report(stage, "accepted", status: response.status)
    }

    private func report(_ stage: String, _ result: String, status: Int? = nil) {
        if ["failed", "rejected"].contains(result), failureStage == nil {
            failureStage = stage; failureHTTPStatus = status
        }
        onDiagnostic(DotManagedVoiceDiagnostic(revision: "orbit-1", recordedAt: now().timeIntervalSince1970,
            stage: stage, result: result, httpStatus: status,
            failureStage: failureStage, failureHTTPStatus: failureHTTPStatus))
    }
}
