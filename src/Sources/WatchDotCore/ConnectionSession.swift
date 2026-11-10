import Foundation
import Combine
import CryptoKit

public enum ConnectionPhase: Equatable {
    case setupRequired, signedOut, connecting, awaitingConsent, verifying, paused, signedIn, expired, cancelled
    case failed(String)
    public var title: String {
        switch self {
        case .setupRequired: "Connect your account on this Watch"
        case .signedOut: "Signed out"
        case .connecting: "Connecting…"
        case .awaitingConsent: "Approve sign-in in your browser"
        case .verifying: "Verifying account…"
        case .paused: "Sign-in paused"
        case .signedIn: "Account connected"
        case .expired: "Session expired"
        case .cancelled: "Sign-in cancelled"
        case .failed: "Could not connect"
        }
    }
    public var isBusy: Bool { [.connecting, .awaitingConsent, .verifying].contains(self) }
}

@MainActor
public final class ConnectionSession: ObservableObject {
    @Published public private(set) var phase: ConnectionPhase = .setupRequired
    @Published public private(set) var accountLabel: String?
    @Published public private(set) var dotProbeState: DotProbeState = .idle
    // Signing in verifies an account only. Dot access remains an independent requirement.
    public var andyConnected: Bool { directConversation?.deliveryState == .answered }
    @Published public private(set) var directConversation: ConversationSession?
    // Demo is opt-in for this app run. Missing/expired authentication never selects it.
    @Published public private(set) var demoEnabled = false
    @Published public private(set) var isRenewingSession = false

    public func selectDemo(_ enabled: Bool) {
        if enabled { directConversation?.suspend() }
        demoEnabled = enabled
    }

    public func selectedConversation(demo: ConversationSession) -> ConversationSession? {
        if demoEnabled { return demo }
        return phase == .signedIn ? directConversation : nil
    }

    public var chatBlockReason: String {
        if phase == .signedIn {
            switch dotProbeState {
            case .checking: return "Connecting to Dot…"
            case .failed(let reason): return reason
            case .cancelled: return "Connection to Dot cancelled. You can try again."
            case .idle, .located: return "Dot's room still needs to be verified."
            }
        }
        if case .failed(let reason) = phase { return reason }
        return phase.title
    }
    private var activeChatKey: String?
    private let chatDirectory: URL?
    private let http: any SignInHTTP
    private let backgroundReceiver: (any BackgroundChatReceiving)?
    private var backgroundTransition: Task<Void, Never>?
    private var isForeground = true
    public var isConfigured: Bool { companion != nil }
    public var canResume: Bool { (record.phoneRequest?.expiresAt ?? .distantPast) > now() }
    public var actionTitle: String {
        if !isConfigured && !canRenewSession { return "Connect your account on this Watch" }
        if canResume { return "Resume sign-in" }
        if canRenewSession { return "Refresh session" }
        if phase == .expired { return "Sign in again" }
        return "Continue with ChatGPT"
    }
    private let companion: (any WatchSignInLink)?
    private var phoneValidationID: UUID?
    private let store: any SignInStore
    private let service: SignInService
    private let dotProbe: DotAccessProbe
    private let now: () -> Date
    private var record = SignInRecord()
    private var storageAvailable = false
    private var probeTask: Task<Void, Never>?
    private var probeOperation: UUID?
    private var probeDiagnostics: [DotProbeDiagnostic] = []
    private var voiceContextGeneration = UUID()
    private var renewalTask: Task<SignedInAccount, Error>?
    private var renewalID: UUID?
    private var renewalRetryAfter: Date?
    private var unsavedRenewal: SignedInAccount?
    public var canRenewSession: Bool { record.account?.clientID == OpenAIOAuthClient.codex && record.account?.refreshToken != nil }

    public init(store: any SignInStore, http: any SignInHTTP = SecureSignInHTTP(),
                now: @escaping () -> Date = Date.init,
                chatDirectory: URL? = nil, backgroundReceiver: (any BackgroundChatReceiving)? = nil,
                companion: (any WatchSignInLink)? = nil) {
        self.store = store
        self.companion = companion
        self.http = http
        self.chatDirectory = chatDirectory
        self.backgroundReceiver = backgroundReceiver
        service = SignInService(http: http)
        dotProbe = DotAccessProbe(http: http)
        self.now = now
        refresh()
    }

    public func refresh() {
        guard phoneValidationID == nil, renewalTask == nil, unsavedRenewal == nil else { return }
        do {
            let loaded = try store.load() ?? SignInRecord()
            if loaded.account?.accessToken != record.account?.accessToken ||
                loaded.account?.subject != record.account?.subject ||
                ((loaded.account?.expiresAt ?? .distantPast) <= now() && loaded.account?.refreshToken == nil) {
                resetDotProbe()
            }
            record = loaded
            storageAvailable = true
            if let account = record.account {
                accountLabel = account.email ?? "ChatGPT account"
                phase = account.expiresAt > now() ? .signedIn : .expired
            } else {
                accountLabel = nil
                phase = (record.phoneRequest?.expiresAt ?? .distantPast) > now() ? .awaitingConsent : (isConfigured ? .signedOut : .setupRequired)
            }
        } catch {
            resetDotProbe()
            storageAvailable = false
            phase = .failed(SignInError.storage.message)
        }
    }

    public func connect() {
        guard phoneValidationID == nil else { return }
        demoEnabled = false
        if let companion, let request = record.phoneRequest, request.expiresAt > now() {
            phase = .awaitingConsent
            companion.requestAuthorization(request)
            return
        }
        if canRenewSession || unsavedRenewal != nil {
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.ensureCurrentAccount(force: true)
                    if self.isForeground {
                        self.directConversation?.resumeAutomatically()
                        if self.dotProbeState == .idle { self.probeDotAccess() }
                    }
                } catch { /* ensureCurrentAccount publishes a safe, actionable status. */ }
            }
            return
        }
        guard storageAvailable else { refresh(); return }
        if let companion {
            do {
                let request = try preparePhoneAuthorization()
                phase = .awaitingConsent
                companion.requestAuthorization(request)
            } catch { phase = .failed((error as? SignInError)?.message ?? SignInError.storage.message) }
            return
        }
        phase = .setupRequired
    }

    public func pause() {
        cancelDotProbe()
    }

    public func cancel() {
        phoneValidationID = nil
        if let request = record.phoneRequest {
            do {
                var updated = record; updated.phoneRequest = nil
                try store.save(updated); record = updated
                companion?.cancelAuthorization(request)
            } catch { phase = .failed(SignInError.storage.message); return }
        }
        cancelDotProbe()
        phase = .cancelled
    }

    public func signOutLocally() {
        renewalID = nil
        renewalTask?.cancel(); renewalTask = nil
        isRenewingSession = false
        unsavedRenewal = nil; renewalRetryAfter = nil
        demoEnabled = false
        cancel()
        resetDotProbe()
        guard storageAvailable else { phase = .failed(SignInError.storage.message); return }
        do {
            var updated = record
            updated.account = nil
            updated.phoneRequest = nil
            updated.acceptedPhoneTransfer = nil
            try store.save(updated)
            record = updated
            accountLabel = nil
            phase = isConfigured ? .signedOut : .setupRequired
        } catch { phase = .failed(SignInError.storage.message) }
    }

    /// Stored before sending, so a phone cannot revive a cancelled request after a restart.
    func preparePhoneAuthorization() throws -> PhoneAuthorizationRequest {
        guard storageAvailable, renewalTask == nil, unsavedRenewal == nil else { throw SignInError.storage }
        if let request = record.phoneRequest, request.expiresAt > now() { return request }
        guard record.account == nil || record.account!.expiresAt <= now() || !canRenewSession else {
            throw SignInError.denied // A different account requires an explicit local sign-out.
        }
        let request = try PhoneAuthorizationRequest(installationID: record.hostID,
            expectedSubject: record.account?.subject, now: now())
        var updated = record
        updated.phoneRequest = request
        updated.acceptedPhoneTransfer = nil
        try store.save(updated)
        record = updated
        demoEnabled = false
        phase = .awaitingConsent
        return request
    }

    public func receiveCompanionMessage(_ message: CompanionMessage) async -> CompanionMessage {
        do {
            switch message {
            case .prepare:
                if record.account != nil, !canResume, canRenewSession, record.account!.expiresAt > now() {
                    return .failure("This Watch is already signed in. Sign out to switch accounts.")
                }
                return .begin(try preparePhoneAuthorization())
            case .query:
                guard storageAvailable else { throw SignInError.storage }
                if let request = record.phoneRequest, request.expiresAt > now() { return .begin(request) }
                if let receipt = record.acceptedPhoneTransfer { return .acknowledgement(receipt) }
                return .idle
            case .credentials(let transfer):
                guard storageAvailable else { throw SignInError.storage }
                // Check receipt before token validity: a delayed retry may carry a token already rotated by Watch.
                if record.acceptedPhoneTransfer == transfer.receipt {
                    return .acknowledgement(transfer.receipt)
                }
                guard record.phoneRequest == transfer.request, transfer.request.installationID == record.hostID,
                      renewalTask == nil, unsavedRenewal == nil else { throw SignInError.invalidResponse }
                let validationID = UUID()
                phoneValidationID = validationID
                phase = .verifying
                try await service.validateTransfer(transfer, now: now())
                guard phoneValidationID == validationID, record.phoneRequest == transfer.request,
                      transfer.request.expiresAt > now() else { throw SignInError.expired }
                var updated = record
                updated.account = transfer.account
                updated.phoneRequest = nil
                updated.acceptedPhoneTransfer = transfer.receipt
                // Tokens and receipt are one atomic Keychain record; never acknowledge a failed save.
                try store.save(updated)
                record = updated
                phoneValidationID = nil
                resetDotProbe()
                accountLabel = transfer.account.email ?? "ChatGPT account"
                phase = .signedIn
                if isForeground { probeDotAccess() }
                return .acknowledgement(transfer.receipt)
            case .cancel(let request):
                if record.phoneRequest == request { cancel() }
                return .idle
            case .status:
                return .idle
            default: throw SignInError.invalidResponse
            }
        } catch {
            let reason = (error as? SignInError)?.message ?? SignInError.storage.message
            if record.phoneRequest != nil { phase = .failed(reason) }
            return .failure(reason)
        }
    }

    /// Commit only a verified device-flow session to this app's own Keychain.
    func acceptDeviceAccount(_ account: SignedInAccount) throws {
        guard companion == nil, storageAvailable, phoneValidationID == nil,
              renewalTask == nil, unsavedRenewal == nil,
              account.clientID == OpenAIOAuthClient.codex, account.expiresAt > now(),
              record.account == nil || record.account?.subject == account.subject else { throw SignInError.denied }
        var updated = record
        updated.account = account
        updated.phoneRequest = nil
        updated.acceptedPhoneTransfer = nil
        try store.save(updated)
        record = updated
        demoEnabled = false
        resetDotProbe()
        accountLabel = account.email ?? "ChatGPT account"
        phase = .signedIn
        if isForeground { probeDotAccess() }
    }

    public func companionRequestFailed() {
        if record.phoneRequest != nil {
            phase = .failed("Open WatchDot on your Watch and choose Connect account.")
        }
    }

    public func probeDotAccess() {
        guard probeTask == nil, phoneValidationID == nil else { return }
        refresh()
        guard storageAvailable, phase == .signedIn, let account = record.account else {
            dotProbeState = .failed(DotProbeError.session.message)
            return
        }
        let id = UUID()
        resetDotProbe()
        probeOperation = id
        dotProbeState = .checking
        probeTask = Task { [weak self, dotProbe, now] in
            do {
                let found = try await dotProbe.run(account: account, now: now(), onDiagnostic: { [weak self] diagnostic in
                    await self?.collect(diagnostic, operation: id)
                })
                guard let self, self.probeOperation == id, !Task.isCancelled else { return }
                // A response received after expiry is not evidence of a current usable session.
                if account.expiresAt > now() {
                    self.dotProbeState = .located(found)
                    self.openChat(found, account: account)
                } else {
                    self.dotProbeState = .failed(DotProbeError.session.message)
                    self.phase = .expired
                }
                self.probeTask = nil
                self.probeOperation = nil
            } catch {
                guard let self, self.probeOperation == id, !Task.isCancelled else { return }
                if case DotProbeError.schema = error, let diagnostic = self.probeDiagnostics.last {
                    self.dotProbeState = .failed(diagnostic.summary)
                } else {
                    self.dotProbeState = .failed((error as? DotProbeError)?.message ?? "Check interrupted. You can try again.")
                }
                self.probeTask = nil
                self.probeOperation = nil
            }
        }
    }

    public func cancelDotProbe() {
        probeTask?.cancel()
        probeTask = nil
        probeOperation = nil
        if dotProbeState == .checking { dotProbeState = .cancelled }
    }

    private func resetDotProbe() {
        voiceContextGeneration = UUID()
        backgroundTransition?.cancel()
        if activeChatKey != nil, let backgroundReceiver { Task { await backgroundReceiver.stop() } }
        directConversation?.suspend()
        directConversation = nil
        activeChatKey = nil
        cancelDotProbe()
        dotProbeState = .idle
        probeDiagnostics = []
    }

    /// A call must bind to the same account and Dot as the visible real conversation.
    /// The returned credentials and identifiers stay in memory and are never diagnostics.
    func nativeVoiceContext() async throws -> NativeVoiceContext {
        guard !demoEnabled, phase == .signedIn, case .located(let visibleDot) = dotProbeState else {
            throw DotNativeVoiceError.accountChanged
        }
        let account = try await ensureCurrentAccount()
        let generation = voiceContextGeneration
        let probe = DotVoiceRouteProbe(http: http)
        let accountID = try probe.routingAccount(token: account.accessToken ?? "", account: account, now: now())
        let current: @Sendable () async -> Bool = { [weak self] in
            await self?.matchesVoiceContext(subject: account.subject, accountID: accountID, generation: generation) ?? false
        }
        let discovered = try await probe.locate(
            account: account, now: now(), isCurrentAccount: current)
        guard await current(), let route = discovered.route, route.dotID == visibleDot.dotID else {
            throw DotVoiceRouteProbeError.binding
        }
        return NativeVoiceContext(account: account, route: route, isCurrentAccount: current)
    }

    private func matchesVoiceContext(subject: String, accountID: String, generation: UUID) -> Bool {
        guard !demoEnabled, phase == .signedIn, let account = record.account,
              account.subject == subject, voiceContextGeneration == generation else { return false }
        return (try? DotVoiceRouteProbe(http: http).routingAccount(
            token: account.accessToken ?? "", account: account, now: now())) == accountID
    }

    public func enterBackground() {
        isForeground = false
        pause()
        directConversation?.suspend()
        backgroundTransition?.cancel()
        guard let backgroundReceiver, !demoEnabled, let account = record.account,
              case .located(let dot) = dotProbeState, let key = activeChatKey, let chatDirectory else { return }
        let directory = chatDirectory.appendingPathComponent(key, isDirectory: true)
        backgroundTransition = Task { await backgroundReceiver.start(destination: dot, account: account, directory: directory) }
    }

    public func enterForeground() {
        isForeground = true
        backgroundTransition?.cancel()
        backgroundTransition = Task { [weak self] in
            guard let self else { return }
            await self.backgroundReceiver?.stop()
            guard !Task.isCancelled, self.isForeground else { return }
            self.directConversation?.reloadAfterBackground()
            self.refresh()
            if self.record.account != nil {
                do { _ = try await self.ensureCurrentAccount() }
                catch { return }
            }
            guard !Task.isCancelled, self.isForeground else { return }
            self.directConversation?.resumeAutomatically()
            if self.phase == .signedIn, self.dotProbeState == .idle { self.probeDotAccess() }
        }
    }

    private func collect(_ diagnostic: DotProbeDiagnostic, operation id: UUID) {
        guard probeOperation == id, probeDiagnostics.count < 2 else { return }
        probeDiagnostics.append(diagnostic)
    }

    private func openChat(_ dot: LocatedDot, account: SignedInAccount) {
        guard let chatDirectory else { return }
        // A new account, Dot or room never inherits another destination's pending sends or cache.
        let binding = [account.subject, dot.accountID, dot.userID, dot.dotID, dot.roomID, dot.dotMemberID]
        guard let data = try? JSONEncoder().encode(binding) else { return }
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if activeChatKey == key, directConversation != nil { return }
        directConversation?.suspend()
        let directory = chatDirectory.appendingPathComponent(key, isDirectory: true)
        let transport = DotChatTransport(destination: dot, http: http, credentials: { [weak self] in
            guard let self else { throw ChatTransportError.direct(.session) }
            return try await self.currentChatAccount(subject: account.subject, key: key)
        }, receipts: DotReceiptStore(directory: directory.appendingPathComponent("receipts")), onDiagnostic: { _ in })
        activeChatKey = key
        demoEnabled = false
        directConversation = ConversationSession(transport: transport,
            store: FileConversationStore(url: directory.appendingPathComponent("conversation.json")),
            responseTimeout: .seconds(600))
        if isForeground { directConversation?.resumeAutomatically() }
    }

    private func currentChatAccount(subject: String, key: String) async throws -> SignedInAccount {
        guard activeChatKey == key, record.account?.subject == subject,
              phase == .signedIn || isRenewingSession else { throw ChatTransportError.direct(.session) }
        let account: SignedInAccount
        do { account = try await ensureCurrentAccount() }
        catch { throw ChatTransportError.direct(.session) }
        guard activeChatKey == key, phase == .signedIn, account.subject == subject,
              account.accessToken == (try store.load()?.account?.accessToken) else {
            throw ChatTransportError.direct(.session)
        }
        return account
    }

    /// One in-flight refresh shared by foreground sync, sends and reply reads. No periodic timer.
    func ensureCurrentAccount(force: Bool = false) async throws -> SignedInAccount {
        if let renewalTask { return try await renewalTask.value }
        if let unsavedRenewal {
            var updated = record; updated.account = unsavedRenewal
            do { try store.save(updated) }
            catch { phase = .failed(SignInError.storage.message); throw SignInError.storage }
            record = updated; self.unsavedRenewal = nil; storageAvailable = true
        }
        guard let account = record.account else { throw SignInError.expired }
        if (record.phoneRequest?.expiresAt ?? .distantPast) > now() {
            guard account.expiresAt > now() else { throw SignInError.expired }
            return account
        }
        let valid = account.expiresAt > now()
        if !force, valid, account.expiresAt.timeIntervalSince(now()) > 60 {
            phase = .signedIn
            return account
        }
        guard canRenewSession else {
            if valid { phase = .signedIn; return account }
            phase = .expired; throw SignInError.expired
        }
        if !force, let retry = renewalRetryAfter, retry > now() {
            if valid { return account }
            throw SignInError.refreshUnavailable
        }
        let id = UUID()
        renewalID = id
        isRenewingSession = true
        if !valid { phase = .verifying }
        let work = Task { [weak self, service] () throws -> SignedInAccount in
            guard let self else { throw CancellationError() }
            defer {
                if self.renewalID == id {
                    self.renewalID = nil; self.renewalTask = nil; self.isRenewingSession = false
                }
            }
            do {
                let renewed = try await service.renew(account, now: self.now())
                guard self.renewalID == id, self.record.account?.subject == account.subject,
                      !Task.isCancelled else { throw CancellationError() }
                guard renewed.expiresAt > self.now() else { throw SignInError.refreshUnavailable }
                // Retain a rotated credential in memory if Keychain is temporarily unavailable;
                // retry saving it before ever trying the old refresh token again.
                self.unsavedRenewal = renewed
                var updated = self.record; updated.account = renewed
                do { try self.store.save(updated) }
                catch { throw SignInError.storage }
                self.record = updated; self.unsavedRenewal = nil; self.storageAvailable = true
                self.renewalRetryAfter = nil
                self.accountLabel = renewed.email ?? "ChatGPT account"
                self.phase = .signedIn
                return renewed
            } catch {
                guard self.renewalID == id, !Task.isCancelled else { throw CancellationError() }
                if let reason = error as? SignInError {
                    switch reason {
                    case .refreshRejected, .identity:
                        let revoked = SignedInAccount(subject: account.subject, clientID: account.clientID,
                            email: account.email, expiresAt: .distantPast, idToken: account.idToken,
                            accessToken: nil, authorizationNonce: account.authorizationNonce)
                        self.unsavedRenewal = revoked
                        var updated = self.record; updated.account = revoked
                        do { try self.store.save(updated); self.unsavedRenewal = nil }
                        catch { self.storageAvailable = false }
                        self.record = updated
                        self.phase = .expired
                    case .storage:
                        self.storageAvailable = false
                        self.phase = .failed(SignInError.storage.message)
                    default:
                        self.renewalRetryAfter = self.now().addingTimeInterval(30)
                        self.phase = account.expiresAt > self.now() ? .signedIn : .failed(SignInError.refreshUnavailable.message)
                    }
                } else {
                    self.renewalRetryAfter = self.now().addingTimeInterval(30)
                    self.phase = account.expiresAt > self.now() ? .signedIn : .failed(SignInError.refreshUnavailable.message)
                }
                if self.unsavedRenewal == nil, account.expiresAt > self.now(),
                   self.record.account?.refreshToken == account.refreshToken, self.phase == .signedIn { return account }
                throw error
            }
        }
        renewalTask = work
        return try await work.value
    }

}
