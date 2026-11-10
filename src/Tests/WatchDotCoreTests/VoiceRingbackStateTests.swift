import XCTest
@testable import WatchDotCore

final class VoiceRingbackStateTests: XCTestCase {
    func testInitialGraphCleanupAllowsToneButCancellationBeforeStartDoesNot() {
        var sound = VoiceRingbackState()
        XCTAssertFalse(sound.finish(reason: .graphReset))
        XCTAssertTrue(sound.begin(), "audio setup must not silently disable ringback")

        var cancelled = VoiceRingbackState()
        XCTAssertFalse(cancelled.finish())
        XCTAssertFalse(cancelled.finish(reason: .graphReset))
        XCTAssertFalse(cancelled.begin(), "graph setup must not undo cancellation")
    }
    func testGraphResetStopsAnActiveToneAndCannotRestartAfterVoice() {
        var sound = VoiceRingbackState()
        XCTAssertTrue(sound.begin())
        XCTAssertTrue(sound.finish(reason: .graphReset))
        XCTAssertFalse(sound.isPlaying)
        XCTAssertFalse(sound.begin())
        XCTAssertFalse(sound.finish(), "later ready event must leave speech alone")
    }
    func testOnlyOneLoopStartsAndRemoteAudioStopsItPermanently() {
        var sound = VoiceRingbackState()
        XCTAssertTrue(sound.begin())
        XCTAssertFalse(sound.begin())
        XCTAssertTrue(sound.isPlaying)
        XCTAssertTrue(sound.finish())
        XCTAssertFalse(sound.isPlaying)
        XCTAssertFalse(sound.begin(), "a late start must not replace the remote voice")
        XCTAssertFalse(sound.finish(), "a later ready event must not stop remote playback")
    }
    func testReadyOrCancelBeforeAudioSetupPreventsDelayedTone() {
        var sound = VoiceRingbackState()
        XCTAssertFalse(sound.finish())
        XCTAssertFalse(sound.begin())
        XCTAssertFalse(sound.isPlaying)
    }
    func testASecondCallHasItsOwnSoundLifecycle() {
        var old = VoiceRingbackState()
        _ = old.begin(); old.finish()
        var next = VoiceRingbackState()
        XCTAssertTrue(next.begin())
        XCTAssertFalse(old.begin())
        XCTAssertTrue(next.isPlaying)
    }
}
