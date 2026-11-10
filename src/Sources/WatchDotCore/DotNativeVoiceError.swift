import Foundation

enum DotNativeVoiceError: Error {
    case accountChanged, invalidVoice, invalidOffer, invalidAnswer, missingCallID
    case rejected(Int), unavailable

    var message: String {
        switch self {
        case .accountChanged: "Your account changed or expired. Reconnect before calling."
        case .invalidVoice: "Could not get the voice for your ChatGPT account."
        case .invalidOffer, .invalidAnswer: "Could not prepare call audio."
        case .missingCallID: "ChatGPT returned an unrecognized call."
        case .rejected(let status): "ChatGPT rejected the call (\(status)). The conversation did not start."
        case .unavailable: "Could not reach ChatGPT. Check your Internet connection."
        }
    }
}

