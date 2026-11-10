import Foundation

/// Metadata access is evidence for a route, never evidence that a voice call works.
public enum DotVoiceRouteCapability: String, Codable, Sendable, Equatable {
    case cloudAeonMetadataVerified
    case cloudThreadMetadataKindUnverified

    public var message: String {
        switch self {
        case .cloudAeonMetadataVerified:
            "Your Dot's cloud chat is reachable. Voice calling has not been verified yet."
        case .cloudThreadMetadataKindUnverified:
            "The cloud chat is reachable, but its Dot type was not confirmed. Voice calling is not verified."
        }
    }
}

/// Contains only fixed categories and booleans; no account, thread, room or token values.
public struct DotVoiceRouteProbeResult: Codable, Sendable, Equatable {
    public let capability: DotVoiceRouteCapability
    public let messagingRoomLinked: Bool
    public var voiceCallValidated: Bool { false }
}

/// In-memory binding for a future native call. Never encode, display or log this value.
/// Construction stays in this file after both reads and the current-account fence succeed.
struct VerifiedDotVoiceRoute: Sendable, Equatable {
    let dotID: String
    let threadID: String
    let rootThreadID: String?
    let accountID: String
    let subject: String
    let hostID = "durable"

    fileprivate init(dotID: String, threadID: String, rootThreadID: String? = nil, accountID: String, subject: String) {
        self.dotID = dotID; self.threadID = threadID; self.accountID = accountID; self.subject = subject
        self.rootThreadID = rootThreadID
    }
}

enum DotVoiceRouteProbeError: Error, Sendable, Equatable {
    case session, identity, accountChanged, noPrimary, unavailable, binding, identifier, threadKind
    case primaryHTTP(Int), cloudHTTP(Int), challenge, schema, network, tls

    var message: String {
        switch self {
        case .session: "This session cannot run the check or has expired. Sign in again."
        case .identity: "Could not verify this session's account. Check stopped."
        case .accountChanged: "Your account changed during the check. Check stopped."
        case .noPrimary: "The account did not provide a primary Dot with an available chat."
        case .unavailable: "Your primary Dot is unavailable."
        case .binding: "The selected Dot does not match its profile. Check stopped."
        case .identifier: "The service returned an unusable identifier. Check stopped."
        case .threadKind: "The service returned a different chat type. No voice route was confirmed for your Dot."
        case .primaryHTTP(let status): "Primary Dot: HTTP \(status). The cloud route was not confirmed."
        case .cloudHTTP(let status): "Cloud chat: HTTP \(status). The cloud route was not confirmed."
        case .challenge: "The service requires verification. Check stopped."
        case .schema: "The service returned an unrecognized response. Check stopped."
        case .network: "Could not connect. You can try again."
        case .tls: "Could not verify the secure connection."
        }
    }
}

/// Two GETs using only the OAuth session created by this app. No WebSocket, voice or writes.
/// Production must use SecureSignInHTTP, which rejects redirects before credentials are forwarded.
struct DotVoiceRouteProbe: Sendable {
    let http: any SignInHTTP

    func run(account: SignedInAccount, now: Date,
             isCurrentAccount: @Sendable () async -> Bool) async throws -> DotVoiceRouteProbeResult {
        try await locate(account: account, now: now, isCurrentAccount: isCurrentAccount).diagnostics
    }

    func locate(account: SignedInAccount, now: Date,
                isCurrentAccount: @Sendable () async -> Bool) async throws
        -> (diagnostics: DotVoiceRouteProbeResult, route: VerifiedDotVoiceRoute?) {
        try await checkCurrent(isCurrentAccount)
        guard account.clientID == OpenAIOAuthClient.codex, account.expiresAt > now,
              let token = account.accessToken, !token.isEmpty else { throw DotVoiceRouteProbeError.session }
        let accountID = try routingAccount(token: token, account: account, now: now)
        let primary: Primary = try await get(
            URL(string: "https://chatgpt.com/backend-api/tbo/primary")!,
            token: token, accountID: accountID, cloud: false, isCurrentAccount: isCurrentAccount)

        let selection = primary.selection
        if let selection, !selection.available { throw DotVoiceRouteProbeError.unavailable }
        if primary.profile?.status == "deleting" { throw DotVoiceRouteProbeError.unavailable }
        if let selected = selection?.aeon_id, let profileID = primary.profile?.id, selected != profileID {
            throw DotVoiceRouteProbeError.binding
        }
        // Follow the shipped client's jWt: a present unavailable selection never falls back.
        let threadID = selection == nil ? primary.profile?.active_root_thread_id : selection?.thread_id
        guard let threadID,
              let dotID = selection?.aeon_id ?? primary.profile?.id else { throw DotVoiceRouteProbeError.noPrimary }
        guard validOpaqueID(threadID), threadID != ".", threadID != "..", validOpaqueID(dotID),
              let segment = threadID.addingPercentEncoding(withAllowedCharacters: Self.unreserved) else {
            throw DotVoiceRouteProbeError.identifier
        }
        if let kind = primary.profile?.aeon_kind, kind != "orbit" {
            // Missing aeon_kind occurs in older profiles; an explicit other kind is not inferred.
            throw DotVoiceRouteProbeError.threadKind
        }
        let roomID = selection?.messaging_room_id ?? primary.profile?.messaging_room_id
        if let roomID, !validOpaqueID(roomID) { throw DotVoiceRouteProbeError.identifier }
        let rootThreadID = primary.profile?.active_root_thread_id
        if let rootThreadID, !validOpaqueID(rootThreadID) { throw DotVoiceRouteProbeError.identifier }
        guard let url = URL(string: "https://codex-cloud-backend.chatgpt.com/v1/threads/\(segment)"),
              url.scheme == "https", url.host == "codex-cloud-backend.chatgpt.com",
              url.query == nil, url.fragment == nil else { throw DotVoiceRouteProbeError.identifier }
        let metadata: ThreadMetadata = try await get(url, token: token, accountID: accountID,
            cloud: true, isCurrentAccount: isCurrentAccount)
        guard metadata.thread.id == threadID else { throw DotVoiceRouteProbeError.binding }
        // The shipped helper accepts threadStartKind or threadSource. `source` is another enum.
        // Conflicting explicit kinds fail closed rather than manufacturing a verified route.
        let kinds = [metadata.thread.threadSource, metadata.thread.threadStartKind].compactMap { $0 }
        if kinds.contains(where: { $0 != "aeon" }) { throw DotVoiceRouteProbeError.threadKind }
        let aeonVerified = kinds.contains("aeon")
        try await checkCurrent(isCurrentAccount)
        return (DotVoiceRouteProbeResult(
            capability: aeonVerified ? .cloudAeonMetadataVerified : .cloudThreadMetadataKindUnverified,
            messagingRoomLinked: roomID != nil),
            aeonVerified ? VerifiedDotVoiceRoute(dotID: dotID, threadID: threadID, rootThreadID: rootThreadID, accountID: accountID, subject: account.subject) : nil)
    }

    private func get<T: Decodable>(_ url: URL, token: String, accountID: String, cloud: Bool,
                                  isCurrentAccount: @Sendable () async -> Bool) async throws -> T {
        try await checkCurrent(isCurrentAccount)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("watch-dot", forHTTPHeaderField: "originator")
        request.setValue("WatchDot/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if cloud { request.setValue("aeon", forHTTPHeaderField: "X-OpenAI-Product-Sku") }
        let response: SignInHTTPResponse
        do { response = try await http.sendWithMetadata(request) }
        catch {
            try Task.checkCancellation()
            if error is CancellationError { throw CancellationError() }
            if case SignInError.tls = error { throw DotVoiceRouteProbeError.tls }
            throw DotVoiceRouteProbeError.network
        }
        try await checkCurrent(isCurrentAccount)
        guard !response.clientChallenge else { throw DotVoiceRouteProbeError.challenge }
        // Every 3xx is a failure; the HTTP client must never follow authorization redirects.
        guard response.status == 200 else {
            throw cloud ? DotVoiceRouteProbeError.cloudHTTP(response.status) : .primaryHTTP(response.status)
        }
        guard response.data.count <= 256_000, response.contentType != .html else {
            throw DotVoiceRouteProbeError.schema
        }
        do { return try JSONDecoder().decode(T.self, from: response.data) }
        catch { throw DotVoiceRouteProbeError.schema }
    }

    private func checkCurrent(_ current: @Sendable () async -> Bool) async throws {
        try Task.checkCancellation()
        guard await current() else { throw DotVoiceRouteProbeError.accountChanged }
        try Task.checkCancellation()
    }

    func routingAccount(token: String, account: SignedInAccount, now: Date) throws -> String {
        let access = try payload(token), identity = try payload(account.idToken)
        guard let exp = access["exp"] as? Double, exp.isFinite, exp > now.timeIntervalSince1970 else {
            throw DotVoiceRouteProbeError.session
        }
        guard identity["sub"] as? String == account.subject,
              let auth = access["https://api.openai.com/auth"] as? [String: Any],
              let accountID = auth["chatgpt_account_id"] as? String ?? auth["account_id"] as? String,
              let userID = auth["user_id"] as? String ?? auth["chatgpt_user_id"] as? String,
              safeRoutingID(accountID), safeRoutingID(userID) else { throw DotVoiceRouteProbeError.identity }
        if let verified = identity["https://api.openai.com/auth"] as? [String: Any] {
            if let bound = verified["chatgpt_account_id"] as? String ?? verified["account_id"] as? String,
               bound != accountID { throw DotVoiceRouteProbeError.identity }
            if let bound = verified["user_id"] as? String ?? verified["chatgpt_user_id"] as? String,
               bound != userID { throw DotVoiceRouteProbeError.identity }
        }
        // Routing claims from our own already verified OAuth record, not signature verification.
        // Server acceptance and the caller's current-account fence remain required.
        return accountID
    }

    private func payload(_ token: String) throws -> [String: Any] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard token.utf8.count <= 64_000, parts.count == 3,
              parts.allSatisfy({ $0.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil }),
              let data = Data(base64URL: String(parts[1])),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DotVoiceRouteProbeError.identity
        }
        return value
    }
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    private func safeRoutingID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{1,200}$", options: .regularExpression) != nil
    }
    private func validOpaqueID(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 4096 &&
        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private struct Primary: Decodable {
        let selection: Selection?
        let profile: Profile?
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard values.contains(.selection) else { throw DotVoiceRouteProbeError.schema }
            selection = try values.decodeIfPresent(Selection.self, forKey: .selection)
            profile = try values.decodeIfPresent(Profile.self, forKey: .profile)
        }
        enum CodingKeys: String, CodingKey { case selection, profile }
    }
    private struct Selection: Decodable {
        let available: Bool
        let thread_id: String?
        let aeon_id: String?
        let messaging_room_id: String?
    }
    private struct Profile: Decodable {
        let id: String
        let status: String?
        let active_root_thread_id: String?
        let messaging_room_id: String?
        let aeon_kind: String?
    }
    private struct ThreadMetadata: Decodable {
        let thread: Thread
        struct Thread: Decodable { let id: String; let threadSource: String?; let threadStartKind: String? }
    }
}
