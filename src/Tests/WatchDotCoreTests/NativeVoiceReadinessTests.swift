import XCTest
@testable import WatchDotCore

final class NativeVoiceReadinessTests: XCTestCase {
    func testObservedGreetingAdmitsDuplexBeforeLateHTTPAcknowledgement() {
        var state = NativeVoiceReadiness()
        state.attachmentRequested = true
        state.mediaConnected = true
        XCTAssertFalse(state.permitsAudio(currentAccount: true, activeCall: true))
        state.remoteAudioReceived = true
        XCTAssertFalse(state.permitsAudio(currentAccount: true, activeCall: true))
        state.eventsOpen = true
        XCTAssertTrue(state.permitsAudio(currentAccount: true, activeCall: true))
        XCTAssertFalse(state.attachmentAccepted)
        state.attachmentAccepted = true
        XCTAssertTrue(state.permitsAudio(currentAccount: true, activeCall: true))
    }

    func testTransportConnectionWithoutGreetingOrAttachProofStaysMuted() {
        let state = NativeVoiceReadiness(mediaConnected: true, eventsOpen: true,
            attachmentRequested: true)
        XCTAssertFalse(state.permitsAudio(currentAccount: true, activeCall: true))
    }

    func testRemoteAudioCannotBypassAttachIntentOrEventHandshake() {
        var state = NativeVoiceReadiness(mediaConnected: true, remoteAudioReceived: true)
        XCTAssertFalse(state.permitsAudio(currentAccount: true, activeCall: true))
        state.eventsOpen = true
        XCTAssertFalse(state.permitsAudio(currentAccount: true, activeCall: true))
        state.attachmentRequested = true
        XCTAssertTrue(state.permitsAudio(currentAccount: true, activeCall: true))
        state.mediaConnected = false
        XCTAssertFalse(state.permitsAudio(currentAccount: true, activeCall: true))
    }

    func testAcceptedAttachStillAdmitsCallsWithoutAnInitialGreeting() {
        let state = NativeVoiceReadiness(mediaConnected: true, eventsOpen: true,
            attachmentRequested: true, attachmentAccepted: true)
        XCTAssertFalse(state.remoteAudioReceived)
        XCTAssertTrue(state.permitsAudio(currentAccount: true, activeCall: true))
    }

    func testChangedAccountAndCancelledCallRejectLateReadiness() {
        let state = NativeVoiceReadiness(mediaConnected: true, eventsOpen: true,
            attachmentRequested: true, attachmentAccepted: true, remoteAudioReceived: true)
        XCTAssertFalse(state.permitsAudio(currentAccount: false, activeCall: true))
        XCTAssertFalse(state.permitsAudio(currentAccount: true, activeCall: false))
        XCTAssertFalse(state.permitsAudio(currentAccount: false, activeCall: false))
    }

    func testNextCallStartsWithNoInheritedReadiness() {
        XCTAssertFalse(NativeVoiceReadiness().permitsAudio(currentAccount: true, activeCall: true))
    }
}
