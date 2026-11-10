import Combine
import SwiftUI
import WatchKit

@MainActor
private final class DeviceLoginModel: ObservableObject {
    @Published private(set) var code: String?
    @Published private(set) var status = "Connect your ChatGPT account."
    @Published private(set) var busy = false
    private var operation = UUID()
    private var task: Task<Void, Never>?

    func begin(_ connection: ConnectionSession) {
        guard !busy else { return }
        operation = UUID()
        let expected = operation
        busy = true
        status = "Preparing sign-in…"
        task = Task { [weak self, weak connection] in
            guard let self, let connection else { return }
            defer { if operation == expected { busy = false; code = nil; task = nil } }
            do {
                let service = DeviceAuthorizationService(http: SecureSignInHTTP())
                let challenge = try await service.begin(now: .now)
                try Task.checkCancellation()
                guard operation == expected else { return }
                code = challenge.userCode
                status = "Approve this code in your browser."
                while Date.now < challenge.expiresAt {
                    try await Task.sleep(for: .seconds(challenge.interval))
                    if let account = try await service.poll(challenge, now: .now) {
                        try Task.checkCancellation()
                        guard operation == expected else { return }
                        try connection.acceptDeviceAccount(account)
                        status = "Account connected."
                        return
                    }
                }
                throw SignInError.expired
            } catch is CancellationError {
                if operation == expected { status = "Sign-in cancelled." }
            } catch {
                if operation == expected { status = (error as? SignInError)?.message ?? "Could not complete sign-in." }
            }
        }
    }
    func cancel() {
        operation = UUID()
        task?.cancel(); task = nil
        code = nil; busy = false
        status = "Sign-in cancelled."
    }
}

@main
@MainActor
struct WatchDotApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var connection: ConnectionSession
    @StateObject private var login = DeviceLoginModel()
    @StateObject private var call = WatchNativeCallController()
    @State private var accountVisible = false
    @State private var detailsVisible = false

    init() {
        #if DEBUG
        if Self.previewMode != nil {
            _connection = StateObject(wrappedValue: ConnectionSession(store: EmptyPreviewSignInStore()))
            return
        }
        #endif
        // Register early; CallKit must finish providerDidBegin before admission.
        _ = WatchSystemCall.shared
        _connection = StateObject(wrappedValue: ConnectionSession(store: KeychainSignInStore()))
    }

    private static var previewMode: String? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--ui-preview"), index + 1 < arguments.count {
            let mode = arguments[index + 1]
            if ["ready", "calling", "muted", "connecting", "ending", "sign-in", "code", "account"].contains(mode) { return mode }
        }
        #endif
        return nil
    }

    private var ready: Bool {
        if case .located = connection.dotProbeState { return connection.phase == .signedIn }
        return false
    }

    private var canRetry: Bool {
        if case .failed = connection.dotProbeState { return true }
        return false
    }

    var body: some Scene {
        WindowGroup {
            surface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
                .sheet(isPresented: $accountVisible) {
                    AccountSurface(label: connection.accountLabel ?? "ChatGPT account",
                        onSignOut: {
                            login.cancel()
                            connection.signOutLocally()
                            accountVisible = false
                        }, onDone: { accountVisible = false })
                }
                .alert("Call unavailable", isPresented: $detailsVisible) {
                    Button("Close", role: .cancel) {}
                } message: {
                    Text(call.phase == .failed ? call.status : connection.chatBlockReason)
                }
                .onAppear {
                    if Self.previewMode == nil { connection.enterForeground() }
                }
                .onChange(of: scenePhase) { _, phase in
                    guard Self.previewMode == nil else { return }
                    if phase == .active { connection.enterForeground() }
                    else if phase == .background { connection.enterBackground() }
                }
        }
    }

    @ViewBuilder
    private var surface: some View {
        #if DEBUG
        if let mode = Self.previewMode { previewSurface(mode) }
        else { liveSurface }
        #else
        liveSurface
        #endif
    }

    @ViewBuilder
    private var liveSurface: some View {
        if call.isRunning || connection.phase == .signedIn {
            WatchCallSurface(phase: call.phase, connectedAt: call.connectedAt, muted: call.muted,
                status: call.status, ready: ready, canRetry: canRetry,
                blockedReason: ready ? nil : connection.chatBlockReason,
                onCall: { call.start(using: connection) }, onMute: call.toggleMute,
                onEnd: call.finish, onAccount: { accountVisible = true },
                onRetry: connection.probeDotAccess, onDetails: { detailsVisible = true })
        } else {
            DeviceSignInSurface(code: login.code, status: login.status, busy: login.busy,
                canRenew: connection.canRenewSession,
                onConnect: { login.begin(connection) }, onCancel: login.cancel,
                onRenew: { connection.connect() })
        }
    }

    #if DEBUG
    @ViewBuilder
    private func previewSurface(_ mode: String) -> some View {
        if mode == "account" {
            AccountSurface(label: "you@example.com", onSignOut: {}, onDone: {})
        } else if mode == "sign-in" || mode == "code" {
            DeviceSignInSurface(code: mode == "code" ? "ABCD-EFGH" : nil,
                status: mode == "code" ? "Approve this code in your browser." : "Connect your ChatGPT account.",
                busy: mode == "code", canRenew: false,
                onConnect: {}, onCancel: {}, onRenew: {})
        } else {
            let phase: WatchNativeCallController.Phase = switch mode {
            case "calling", "muted": .talking
            case "connecting": .connecting
            case "ending": .ending
            default: .idle
            }
            WatchCallSurface(phase: phase,
                connectedAt: phase == .talking ? .now.addingTimeInterval(-83) : nil,
                muted: mode == "muted", status: "Calling Dot…", ready: true, canRetry: false,
                blockedReason: nil, onCall: {}, onMute: {}, onEnd: {},
                onAccount: {}, onRetry: {}, onDetails: {})
        }
    }
    #endif
}

/// The call surface follows the previously accepted circular controls. It has
/// no audio/network ownership and never creates a call from appearance or a timer.
private struct WatchCallSurface: View {
    let phase: WatchNativeCallController.Phase
    let connectedAt: Date?
    let muted: Bool
    let status: String
    let ready: Bool
    let canRetry: Bool
    let blockedReason: String?
    let onCall: () -> Void
    let onMute: () -> Void
    let onEnd: () -> Void
    let onAccount: () -> Void
    let onRetry: () -> Void
    let onDetails: () -> Void

    var body: some View {
        GeometryReader { geometry in
            Group {
                if phase == .idle || phase == .failed { idleSurface }
                else if phase == .ending {
                    VStack(spacing: 12) {
                        Text("Dot").font(.title3.weight(.medium))
                        ProgressView().frame(width: 24, height: 24)
                        Text("Ending call…").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .combine)
                }
                else { activeSurface(compact: geometry.size.height < 185) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }

    private var idleSurface: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Button(action: onCall) {
                VStack(spacing: 10) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 30, weight: .regular))
                        .frame(width: 76, height: 76)
                        .background(ready ? Color.green : Color.white.opacity(0.15), in: Circle())
                    Text(phase == .failed ? "Call again" : "Call Dot")
                        .font(.headline.weight(.medium))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(!ready)
            .accessibilityHint(ready ? "Start a voice conversation with your Dot." : "Waiting for your account and Dot.")
            if phase == .failed {
                Text("Couldn't start the call.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("Details", action: onDetails).font(.caption2).buttonStyle(.plain)
            } else if let blockedReason {
                Text(blockedReason).font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if canRetry {
                    Button("Try again", action: onRetry).font(.footnote).buttonStyle(.plain)
                } else { ProgressView().controlSize(.small) }
            }
            Spacer(minLength: 0)
            Button("Account", action: onAccount)
                .font(.caption2).foregroundStyle(.secondary).buttonStyle(.plain)
                .padding(.vertical, 4)
        }
        .contextMenu { Button("Account", action: onAccount) }
    }

    private func activeSurface(compact: Bool) -> some View {
        VStack(spacing: compact ? 4 : 6) {
            Text("Dot").font(compact ? .headline.weight(.medium) : .title3.weight(.medium))
            if phase == .talking, let connectedAt {
                Text(connectedAt, style: .timer)
                    .font(.system(size: compact ? 26 : 28, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .accessibilityLabel("Call duration")
                LocalWatchVolume().frame(height: compact ? 28 : 38)
                    .accessibilityLabel("Watch volume")
            } else {
                Text(status).font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 6)
            }
            Spacer(minLength: 0)
            HStack(spacing: compact ? 20 : 22) {
                if phase == .talking {
                    Button(action: onMute) {
                        Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 19))
                            .frame(width: compact ? 44 : 48, height: compact ? 44 : 48)
                            .foregroundStyle(muted ? .black : .white)
                            .background(muted ? Color.white : Color.white.opacity(0.18), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(muted ? "Unmute microphone" : "Mute microphone")
                    .accessibilityValue(muted ? "Muted" : "On")
                }
                Button(role: .destructive, action: onEnd) {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 25))
                        .frame(width: compact ? 54 : 60, height: compact ? 54 : 60)
                        .foregroundStyle(.white)
                        .background(.red, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(phase == .talking ? "End call" : "Cancel call")
            }
        }
        .padding(.vertical, compact ? 2 : 4)
    }
}

private struct DeviceSignInSurface: View {
    let code: String?
    let status: String
    let busy: Bool
    let canRenew: Bool
    let onConnect: () -> Void
    let onCancel: () -> Void
    let onRenew: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 185
            ScrollView {
                VStack(spacing: compact ? 8 : 12) {
                    Text("WatchDot").font(compact ? .headline.weight(.medium) : .title3.weight(.medium))
                    if let code {
                        Text(code)
                            .font(.system(size: compact ? 20 : 22, weight: .medium, design: .monospaced))
                            .tracking(1)
                            .lineLimit(1).minimumScaleFactor(0.75)
                            .accessibilityLabel("Authorization code: \(code)")
                        Text("auth.openai.com/codex/device")
                            .font(.system(size: compact ? 11 : 12)).foregroundStyle(.green)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: compact ? 26 : 38, weight: .light))
                            .foregroundStyle(.green)
                            .accessibilityHidden(true)
                    }
                    Text(status).font(compact ? .caption2 : .footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if busy {
                        Button("Cancel", action: onCancel)
                            .font(.footnote).buttonStyle(.plain)
                    } else {
                        Button(action: onConnect) {
                            Text("Connect account").font(.footnote.weight(.medium))
                                .lineLimit(1).minimumScaleFactor(0.85)
                                .frame(maxWidth: .infinity)
                        }.tint(.green)
                        if canRenew {
                            Button("Refresh session", action: onRenew)
                                .font(.footnote).buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, compact ? 2 : 8)
            }
        }
    }
}

private struct AccountSurface: View {
    let label: String
    let onSignOut: () -> Void
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("Account").font(.title3.weight(.medium))
                Text(label).font(.footnote).multilineTextAlignment(.center)
                Button("Sign out", role: .destructive, action: onSignOut)
                Button("Done", action: onDone).font(.footnote).buttonStyle(.plain)
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

private struct LocalWatchVolume: WKInterfaceObjectRepresentable {
    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl { WKInterfaceVolumeControl(origin: .local) }
    func updateWKInterfaceObject(_ control: WKInterfaceVolumeControl, context: Context) {}
}

#if DEBUG
/// Layout-only simulator previews never load the user's session or call services.
private struct EmptyPreviewSignInStore: SignInStore {
    func load() throws -> SignInRecord? { nil }
    func save(_ record: SignInRecord) throws {}
}
#endif
