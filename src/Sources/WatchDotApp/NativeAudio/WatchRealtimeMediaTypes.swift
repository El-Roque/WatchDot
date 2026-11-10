import Foundation

enum WatchRealtimeMediaEvent: Sendable {
    case connected
    case audio(Data, timestamp: UInt64)
    case eventsOpen
    case event(Data)
    case eventsClosed
    case ended(WatchRealtimeMediaFailure)
}

enum WatchRealtimeEventSendError: Error, Sendable {
    case notOpen
    case backpressure
    case invalidText
}

struct WatchRealtimeMediaFailure: LocalizedError, Sendable {
    enum Kind: String, Sendable { case network, audio, sessionEnded, protocolError }
    enum Reason: String, Sendable {
        case unspecified, iceDisconnected, peerClosed, binaryEvent, noMediaRoute, lostMediaRoute
        case socketWaiting, socketFailed, socketSend, socketReceive, pathChanged, bindingFailure
        case socketRecoveryTimeout
        case audioInterrupted, audioReset, audioSystem
        case engineOperation, engineSendAudio, engineReceive, engineTimeout, engineNegotiation, candidateBudget
        case phoneUnavailable
    }
    let kind: Kind
    let message: String
    let reason: Reason
    let systemCode: Int?
    init(kind: Kind, message: String, reason: Reason = .unspecified, systemCode: Int? = nil) {
        self.kind = kind; self.message = message; self.reason = reason; self.systemCode = systemCode
    }
    var errorDescription: String? {
        self.message
    }
}

enum WatchRealtimeMediaError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self {
        case let .unavailable(message): message
        }
    }
}

