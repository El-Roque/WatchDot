import XCTest
@testable import WatchDotCore

final class VoicePlaybackReservoirTests: XCTestCase {
    func testSixteenPacketRadioBurstPreservesEveryFrameWithoutResettingPlayer() {
        var buffer = VoicePlaybackReservoir()
        for _ in 0..<16 { XCTAssertFalse(buffer.append(960)) }
        XCTAssertEqual(buffer.queuedFrames, 15_360)
        buffer.start()
        for _ in 0..<16 { buffer.played(960) }
        XCTAssertEqual(buffer.queuedFrames, 0)
        XCTAssertFalse(buffer.isPlaying)
    }

    func testPrerollAbsorbsVariableDeliveryWhilePreservingBoundedSpeech() {
        var buffer = VoicePlaybackReservoir()
        // Eight packets per 160 ms; alternating 120/200 ms radio intervals.
        // Start after the same preroll interval as the audio owner's timer.
        for _ in 0..<8 { XCTAssertFalse(buffer.append(960)) }
        var nextBurst = 120
        for time in stride(from: 0, to: 3_200, by: 20) {
            if time == nextBurst {
                for _ in 0..<8 { XCTAssertFalse(buffer.append(960)) }
                nextBurst += (nextBurst % 320 == 120) ? 200 : 120
            }
            if time == VoicePlaybackReservoir.prerollMilliseconds { buffer.start() }
            if time >= VoicePlaybackReservoir.prerollMilliseconds {
                XCTAssertTrue(buffer.isPlaying, "The radio variation must not drain the playback reserve")
                buffer.played(960)
            }
            XCTAssertLessThanOrEqual(buffer.queuedFrames, 48_000)
        }
    }

    func testShortReplyCanStartAfterDeadlineAndExcessiveBacklogResets() {
        var buffer = VoicePlaybackReservoir()
        XCTAssertFalse(buffer.append(960))
        buffer.start() // Audio owner also starts a short reply at its deadline.
        XCTAssertTrue(buffer.isPlaying)
        buffer.played(960)
        for _ in 0..<50 { XCTAssertFalse(buffer.append(960)) }
        XCTAssertTrue(buffer.append(960))
        XCTAssertEqual(buffer.queuedFrames, 960)
        XCTAssertFalse(buffer.isPlaying)
    }

    func testReserveCoversObservedRadioStallThatDrainedPreviousPreroll() {
        func starvedTicks(prerollMS: Int) -> Int {
            var buffer = VoicePlaybackReservoir()
            var nextDelivery = 100
            var nextMedia = 0
            var startAt: Int?
            var starved = 0
            for time in stride(from: 0, to: 3_000, by: 20) {
                // A 460 ms gap between deliveries, comparable to the measured
                // 407 ms polling gap / 507 ms complete radio round trip.
                let stalled = time > 1_000 && time < 1_460
                if time >= nextDelivery && !stalled {
                    while nextMedia < time - 100 {
                        XCTAssertFalse(buffer.append(960))
                        nextMedia += 20
                        if startAt == nil { startAt = time + prerollMS }
                    }
                    nextDelivery = time + 100
                }
                if let startAt, time >= startAt {
                    if buffer.queuedFrames == 0 { starved += 1 }
                    else { buffer.start(); buffer.played(960) }
                }
            }
            return starved
        }
        XCTAssertGreaterThan(starvedTicks(prerollMS: 160), 0)
        XCTAssertEqual(starvedTicks(prerollMS: VoicePlaybackReservoir.recoveryPrerollMilliseconds), 0)
    }

    func testFreshAnswerUsesLowerDelayButShortStarvationKeepsRecoveryReserve() {
        var warmup = VoicePlaybackWarmup()
        XCTAssertEqual(warmup.milliseconds, 200)
        warmup.resume(afterIdleMS: 80)
        XCTAssertEqual(warmup.milliseconds, 400)
        XCTAssertEqual(warmup.recoveryStarts, 1)
        warmup.resume(afterIdleMS: 2_000)
        XCTAssertEqual(warmup.milliseconds, 200)
        warmup.resume(afterIdleMS: .nan)
        XCTAssertEqual(warmup.milliseconds, 200)
    }
}
