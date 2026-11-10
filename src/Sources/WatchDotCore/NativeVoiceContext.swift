import Foundation

/// Own-account binding only. Intentionally not Codable or printable for diagnostics.
struct NativeVoiceContext: Sendable {
    let account: SignedInAccount
    let route: VerifiedDotVoiceRoute
    let isCurrentAccount: @Sendable () async -> Bool
}

/// Media from this call's authenticated RTC peer can establish duplex readiness
/// before the attach HTTP response returns. Account and call ownership still gate admission.
struct NativeVoiceReadiness: Sendable {
    var mediaConnected = false
    var eventsOpen = false
    var attachmentRequested = false
    var attachmentAccepted = false
    var remoteAudioReceived = false

    var mediaReady: Bool {
        mediaConnected && eventsOpen && attachmentRequested && (attachmentAccepted || remoteAudioReceived)
    }

    func permitsAudio(currentAccount: Bool, activeCall: Bool) -> Bool {
        currentAccount && activeCall && mediaReady
    }
}
