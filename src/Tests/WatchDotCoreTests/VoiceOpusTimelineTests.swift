import XCTest
@testable import WatchDotCore

final class VoiceOpusTimelineTests: XCTestCase {
    func testMissingTwentyMillisecondsPreservesTimelineAndConcealsOnlyTheHole() {
        var timeline = VoiceOpusTimeline()
        let first = timeline.prepare(48_000)
        timeline.commit(first, frames: 960)
        let afterLoss = timeline.prepare(49_920)
        XCTAssertEqual(afterLoss.missingFrames, 960)
        timeline.commit(afterLoss, frames: 960)
        XCTAssertEqual(timeline.prepare(50_880).missingFrames, 0)
        XCTAssertEqual(timeline.shortGaps, 1)
        XCTAssertEqual(timeline.missingFrames, 960)
    }
    func testLateAndDuplicatePacketsNeverMoveDecoderBackwards() {
        var timeline = VoiceOpusTimeline()
        let first = timeline.prepare(0)
        timeline.commit(first, frames: 2880)
        let duplicate = timeline.prepare(0)
        XCTAssertTrue(duplicate.late)
        timeline.commit(duplicate, frames: 2880)
        XCTAssertTrue(timeline.prepare(960).late)
        XCTAssertFalse(timeline.prepare(2880).late)
        XCTAssertEqual(timeline.latePackets, 2)
    }
    func testConversationPauseDoesNotGenerateSecondsOfSyntheticSpeech() {
        var timeline = VoiceOpusTimeline()
        let first = timeline.prepare(0)
        timeline.commit(first, frames: 960)
        let nextTurn = timeline.prepare(480_000)
        XCTAssertEqual(nextTurn.missingFrames, 0)
        XCTAssertEqual(timeline.longGaps, 1)
        timeline.commit(nextTurn, frames: 960)
        XCTAssertEqual(timeline.prepare(480_960).missingFrames, 0)
    }
    func testRawAndExtendedRTPClockWrapRemainContinuousOnThirtyTwoBitWatch() {
        for rawClock in [true, false] {
            var timeline = VoiceOpusTimeline()
            let cycle: UInt64 = 1 << 32
            let first = timeline.prepare(cycle - 960)
            timeline.commit(first, frames: 960)
            let wrapped = timeline.prepare(rawClock ? 0 : cycle)
            XCTAssertEqual(wrapped.timestamp, cycle)
            XCTAssertFalse(wrapped.late)
            XCTAssertEqual(wrapped.missingFrames, 0)
            timeline.commit(wrapped, frames: 960)
            XCTAssertTrue(timeline.prepare(cycle - 960).late)
        }
    }
}
