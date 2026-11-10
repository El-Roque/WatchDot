import Foundation
import XCTest
@testable import WatchDotCore

private final class DiagnosticWrites: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []
    func append(_ data: Data) { lock.withLock { values.append(data) } }
    var all: [Data] { lock.withLock { values } }
}

final class VoicePerformanceTraceTests: XCTestCase {
    func testBlockedDiskDoesNotBlockSubmitAndIntermediateSnapshotsAreCoalesced() async {
        let entered = expectation(description: "Writer reached disk")
        let release = DispatchSemaphore(value: 0)
        let writes = DiagnosticWrites()
        let store = VoiceDiagnosticStore { data, _ in
            if writes.all.isEmpty { entered.fulfill(); _ = release.wait(timeout: .now() + 3) }
            writes.append(data)
        }
        let url = URL(fileURLWithPath: "/private/tmp/watchdot-diagnostic-test")
        store.submit(Data("first".utf8), to: url)
        await fulfillment(of: [entered], timeout: 2)
        for index in 0..<100 { store.submit(Data(String(index).utf8), to: url) }
        release.signal()
        await store.flush()
        XCTAssertEqual(writes.all.count, 2)
        XCTAssertEqual(writes.all.last, Data("99".utf8))
    }

    func testTraceRecordsStartupSeparatelyFromReceivedSpeechEventsAndNeverKeepsContent() throws {
        let trace = VoicePerformanceTrace()
        trace.mark(.callTapped)
        trace.mark(.phoneReady)
        trace.mark(.decodeWork, duration: .milliseconds(31))
        trace.mark(.decodeWork, duration: .milliseconds(2))
        trace.observeServerEvent(Data(#"{"type":"input_audio_buffer.speech_stopped","transcript":"PRIVATE_TEST_CONTENT"}"#.utf8))
        trace.audioArrived(); trace.audioArrived()
        trace.observeServerEvent(Data(#"{"type":"PRIVATE_TEST_CONTENT","secret":"PRIVATE_TEST_CONTENT"}"#.utf8))
        let snapshot = trace.snapshot()
        XCTAssertEqual(snapshot.counts["firstAudioReceived"], 1)
        XCTAssertEqual(snapshot.counts["audioAfterSpeechStop"], 1)
        XCTAssertEqual(snapshot.maximumMS["decodeWork"], 31)
        XCTAssertNotNil(snapshot.firstMS["phoneReady"])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).contains("PRIVATE_TEST_CONTENT"))
    }

    func testTraceRemainsBoundedDuringLongCallWithoutLosingFirstStartupTimes() {
        let trace = VoicePerformanceTrace()
        trace.mark(.callTapped)
        for _ in 0..<1_000 { trace.mark(.playbackQueueWait, duration: .milliseconds(40)) }
        let snapshot = trace.snapshot()
        XCTAssertEqual(snapshot.events.count, 160)
        XCTAssertNotNil(snapshot.firstMS["callTapped"])
        XCTAssertEqual(snapshot.counts["playbackQueueWait"], 1_000)
    }

    func testMuteMarkerTimesFirstSpeechOnceAndIgnoresSilenceAndCancelledTurn() {
        let trace = VoicePerformanceTrace()
        trace.questionEndedByMute()
        trace.observeResponseSpeech(rms: 0, estimatedPlaybackDelayMS: 200)
        XCTAssertNil(trace.snapshot().counts["responseSpeechReceived"])
        trace.observeResponseSpeech(rms: 0.02, estimatedPlaybackDelayMS: 200)
        trace.observeResponseSpeech(rms: 0.03, estimatedPlaybackDelayMS: 200)
        XCTAssertEqual(trace.snapshot().counts["responseSpeechReceived"], 1)
        XCTAssertEqual(trace.snapshot().maximumMS["responsePlaybackDelayEstimate"], 200)
        trace.questionEndedByMute()
        trace.cancelQuestionTiming()
        trace.observeResponseSpeech(rms: 0.04, estimatedPlaybackDelayMS: 200)
        XCTAssertEqual(trace.snapshot().counts["responseSpeechReceived"], 1)
    }
    func testDetectedSpeechEndHasItsOwnMarkerAndTimesOnlyTheFirstNewVoice() {
        let trace = VoicePerformanceTrace()
        trace.questionEndedByDetector()
        trace.observeResponseSpeech(rms: 0, estimatedPlaybackDelayMS: 200)
        trace.observeResponseSpeech(rms: 0.03, estimatedPlaybackDelayMS: 200)
        trace.observeResponseSpeech(rms: 0.04, estimatedPlaybackDelayMS: 200)
        XCTAssertEqual(trace.snapshot().counts["questionEndedByDetector"], 1)
        XCTAssertNil(trace.snapshot().counts["questionEndedByMute"])
        XCTAssertEqual(trace.snapshot().counts["responseSpeechReceived"], 1)
    }

}
