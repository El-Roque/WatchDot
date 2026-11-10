import Foundation
import XCTest
@testable import WatchDotCore

private final class AnalysisEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [VoiceBargeInDetector.Change] = []
    func append(_ change: VoiceBargeInDetector.Change) { lock.withLock { values.append(change) } }
    var changes: [VoiceBargeInDetector.Change] { lock.withLock { values } }
}

final class VoiceInterruptionTests: XCTestCase {
    private func output(_ t: Double) -> Float {
        Float(0.08 * (sin(t * 2 * .pi * 137) + 0.5 * sin(t * 2 * .pi * 319) + 0.3 * sin(t * 2 * .pi * 607)))
    }
    private func user(_ t: Double) -> Float {
        Float(0.05 * (sin(t * 2 * .pi * 223) + 0.4 * sin(t * 2 * .pi * 467)))
    }
    private func feed(_ detector: inout VoiceBargeInDetector, index: Int, userSpeaking: Bool,
                      enabled: Bool = true, outputActive: Bool = true, impulse: Bool = false) -> VoiceBargeInDetector.Change? {
        let start = Double(index) * 0.02
        let reference = (0..<40).map { output(start + Double($0) / 2_000) }
        detector.observeOutput(reference, startSeconds: start)
        let input = (0..<40).map { i -> Float in
            let t = start + Double(i) / 2_000
            return output(t - 0.08) * 0.15 + (userSpeaking ? user(t) : 0) + (impulse ? 0.08 : 0)
        }
        return detector.observeInput(input, startSeconds: start, enabled: enabled, outputActive: outputActive)
    }
    func testSpeakerEchoAndAnIsolatedImpulseDoNotInterrupt() {
        var detector = VoiceBargeInDetector()
        for i in 0..<200 { XCTAssertNil(feed(&detector, index: i, userSpeaking: false, impulse: i == 130)) }
        XCTAssertGreaterThan(detector.echoRejectedFrames, 100)
        XCTAssertFalse(detector.speaking)
    }
    func testIndependentSpeechOverEchoTriggersOnceAndEndsAfterQuiet() {
        var detector = VoiceBargeInDetector()
        for i in 0..<100 { XCTAssertNil(feed(&detector, index: i, userSpeaking: false)) }
        var starts: [Int] = []
        for i in 100..<130 {
            if feed(&detector, index: i, userSpeaking: true) == .began { starts.append(i) }
        }
        XCTAssertEqual(starts.count, 1)
        XCTAssertLessThanOrEqual(starts.first ?? 1_000, 110)
        var ended = 0
        for i in 130..<160 {
            if detector.observeInput(Array(repeating: 0, count: 40), startSeconds: Double(i) * 0.02,
                                     enabled: true, outputActive: false) == .ended { ended += 1 }
        }
        XCTAssertEqual(ended, 1)
    }
    func testEchoWithFractionalDelayAndReflectionStillCalibratesWithoutCuttingVoice() {
        var detector = VoiceBargeInDetector()
        for index in 0..<160 {
            let start = Double(index) * 0.02 + 0.00015
            detector.observeOutput((0..<40).map { output(Double(index) * 0.02 + Double($0) / 2_000) },
                                   startSeconds: Double(index) * 0.02)
            let input = (0..<40).map { i -> Float in
                let t = start + Double(i) / 2_000
                return output(t - 0.0825) * 0.15 + output(t - 0.087) * 0.025
            }
            XCTAssertNil(detector.observeInput(input, startSeconds: start, enabled: true, outputActive: true))
        }
        XCTAssertGreaterThan(detector.echoRejectedFrames, 100)
    }
    func testMuteAndIdlePlaybackDoNotStartAnInterruption() {
        var detector = VoiceBargeInDetector()
        for i in 0..<120 { XCTAssertNil(feed(&detector, index: i, userSpeaking: true, enabled: false)) }
        for i in 120..<180 { XCTAssertNil(feed(&detector, index: i, userSpeaking: true, outputActive: false)) }
        XCTAssertFalse(detector.speaking)
    }
    func testStableEchoReusesItsDelayInsteadOfSearchingEveryLagOnEveryFrame() {
        var detector = VoiceBargeInDetector()
        for i in 0..<180 { XCTAssertNil(feed(&detector, index: i, userSpeaking: false)) }
        XCTAssertLessThan(detector.fullSearches, 20)
        XCTAssertGreaterThan(detector.narrowSearches, 100)
        XCTAssertGreaterThan(detector.echoRejectedFrames, 100)
    }
    func testSpeakerReferenceStartsAtPlaybackTimeAndResetDiscardsOldPendingReference() {
        var reference = VoicePlaybackReference()
        let samples = Array(repeating: Float(0.02), count: 40)
        XCTAssertTrue(reference.enqueue(samples, frames: 960).isEmpty)
        XCTAssertTrue(reference.enqueue(samples, frames: 960).isEmpty)
        let first = reference.start(at: 10)
        XCTAssertEqual(first.map(\.startSeconds), [10, 10.02])
        XCTAssertEqual(reference.enqueue(samples, frames: 960).first?.startSeconds, 10.04)
        reference.reset()
        XCTAssertTrue(reference.enqueue(samples, frames: 960).isEmpty)
        let next = reference.start(at: 20)
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next.first?.startSeconds, 20)
    }
    func testPendingSpeakerReferenceRemainsBoundedBeforePlayerStarts() {
        var reference = VoicePlaybackReference()
        for _ in 0..<80 { _ = reference.enqueue(Array(repeating: 0.01, count: 40), frames: 960) }
        let chunks = reference.start(at: 0)
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.samples.count }, 2_000)
    }
    func testInterruptedTailCannotResumeBeforeUserEndsAndRemoteCrossesQuietBoundary() {
        var gate = VoiceOutputInterruptionGate()
        XCTAssertEqual(gate.admit(rms: 0.1, frames: 960, nowSeconds: 0), .play)
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin())
        for i in 1...30 { XCTAssertEqual(gate.admit(rms: 0.1, frames: 960, nowSeconds: Double(i) * 0.02), .discard) }
        gate.userEnded()
        XCTAssertEqual(gate.admit(rms: 0.1, frames: 960, nowSeconds: 0.62), .discard)
        for i in 32...45 { XCTAssertEqual(gate.admit(rms: 0, frames: 960, nowSeconds: Double(i) * 0.02), .discard) }
        XCTAssertEqual(gate.admit(rms: 0.1, frames: 960, nowSeconds: 0.92), .resumed)
        XCTAssertEqual(gate.admit(rms: 0.1, frames: 960, nowSeconds: 0.94), .play)
    }
    func testOldQuietBeforeUserEndsDoesNotAuthorizeOldSpeechAndConfirmedNewResponseCanResume() {
        var gate = VoiceOutputInterruptionGate()
        _ = gate.begin()
        for i in 0..<20 { _ = gate.admit(rms: 0, frames: 960, nowSeconds: Double(i) * 0.02) }
        gate.userEnded()
        XCTAssertEqual(gate.admit(rms: 0.1, frames: 960, nowSeconds: 0.4), .discard)
        gate.confirmNewResponse()
        XCTAssertEqual(gate.admit(rms: 0.1, frames: 960, nowSeconds: 0.42), .resumed)
    }
    func testReferenceDownsamplingIsBoundedForHardwareSampleRates() {
        for rate in [44_100.0, 48_000.0] {
            let input = Array(repeating: Float(0.01), count: Int(rate / 10))
            let result = input.withUnsafeBufferPointer { VoiceBargeInDetector.downsample($0, sampleRate: rate) }
            XCTAssertEqual(result.count, 200)
            XCTAssertTrue(result.allSatisfy { $0.isFinite })
        }
    }
    func testAnalysisAdmissionIsNonblockingAndBoundedWhenWorkerIsBusy() async {
        let queue = DispatchQueue(label: "test.barge.busy")
        queue.suspend()
        let analyzer = VoiceBargeInAnalyzer(queue: queue, onChange: { _ in })
        for _ in 0..<3 { analyzer.input([Float](repeating: 0, count: 40), startSeconds: 1, enabled: true, outputActive: true) }
        for _ in 0..<17 { analyzer.output([Float](repeating: 0, count: 40), startSeconds: 1) }
        let pending = analyzer.snapshot
        queue.resume()
        await analyzer.flush()
        XCTAssertEqual(pending.pendingInputs, 2); XCTAssertEqual(pending.pendingOutputs, 16)
        XCTAssertEqual(pending.droppedInputs, 1); XCTAssertEqual(pending.droppedOutputs, 1)
        XCTAssertEqual(analyzer.snapshot.pendingInputs, 0); XCTAssertEqual(analyzer.snapshot.pendingOutputs, 0)
        analyzer.stop()
    }

    func testAnalysisStopDiscardsQueuedPCMAndNeverEmitsLateChanges() async {
        let queue = DispatchQueue(label: "test.barge.stop")
        queue.suspend()
        let events = AnalysisEvents()
        let analyzer = VoiceBargeInAnalyzer(queue: queue, onChange: { events.append($0) })
        analyzer.output([Float](repeating: 0.1, count: 40), startSeconds: 1)
        analyzer.input([Float](repeating: 0.2, count: 40), startSeconds: 1, enabled: true, outputActive: true)
        analyzer.stop(); analyzer.stop()
        queue.resume()
        await analyzer.flush()
        XCTAssertTrue(events.changes.isEmpty)
        XCTAssertEqual(analyzer.snapshot.referenceChunks, 0)
        XCTAssertEqual(analyzer.snapshot.pendingInputs, 0); XCTAssertEqual(analyzer.snapshot.pendingOutputs, 0)
    }

    func testObsoleteMicrophoneWindowIsNotAnalyzed() async {
        let analyzer = VoiceBargeInAnalyzer(maximumInputAge: .zero, onChange: { _ in XCTFail("obsolete input must not interrupt") })
        analyzer.input([Float](repeating: 0.1, count: 40), startSeconds: 1, enabled: true, outputActive: true)
        await analyzer.flush()
        XCTAssertEqual(analyzer.snapshot.staleInputs, 1)
        XCTAssertEqual(analyzer.snapshot.fullSearches, 0)
        analyzer.stop()
    }

    func testSeparateWorkerRetainsEchoRejectionAndDetectsSpeechStartAndEnd() async {
        let events = AnalysisEvents()
        let analyzer = VoiceBargeInAnalyzer(onChange: { events.append($0) })
        for index in 0..<130 {
            let start = Double(index) * 0.02
            analyzer.output((0..<40).map { output(start + Double($0) / 2000) }, startSeconds: start)
            let mic = (0..<40).map { i -> Float in
                let t = start + Double(i) / 2000
                return output(t - 0.08) * 0.15 + (index >= 100 ? user(t) : 0)
            }
            analyzer.input(mic, startSeconds: start, enabled: true, outputActive: true)
            await analyzer.flush()
        }
        for index in 130..<150 {
            analyzer.input([Float](repeating: 0, count: 40), startSeconds: Double(index) * 0.02, enabled: true, outputActive: false)
            await analyzer.flush()
        }
        XCTAssertEqual(events.changes, [.began, .ended])
        XCTAssertGreaterThan(analyzer.snapshot.echoRejectedFrames, 50)
        XCTAssertEqual(analyzer.snapshot.droppedInputs, 0)
        analyzer.stop()
    }

}
