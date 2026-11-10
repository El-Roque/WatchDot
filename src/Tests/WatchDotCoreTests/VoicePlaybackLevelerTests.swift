import Foundation
import XCTest
@testable import WatchDotCore

final class VoicePlaybackLevelerTests: XCTestCase {
    private func tone(count: Int = 960, amplitude: Float = 0.025) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * .pi * 200 * Double($0) / 48_000)) }
    }

    func testQuietVoiceReachesUsefulLevelWithoutExceedingPeakCeiling() {
        var leveler = VoicePlaybackLeveler()
        var last: VoicePlaybackLeveler.Levels?
        var output = [Float]()
        for _ in 0..<50 {
            output = tone()
            last = output.withUnsafeMutableBufferPointer { leveler.process($0, sampleRate: 48_000) }
        }
        let rms = sqrt(output.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(output.count))
        XCTAssertGreaterThan(rms, 0.17)
        XCTAssertLessThan(rms, 0.19)
        XCTAssertGreaterThan(last!.appliedGain, 8)
        XCTAssertLessThanOrEqual(last!.appliedGain, 16)
        XCTAssertLessThanOrEqual(last!.outputPeak, 0.950001)
    }

    func testLoudTransientAfterBoostStaysBoundedAndNonfiniteSamplesBecomeSilence() {
        var leveler = VoicePlaybackLeveler()
        for _ in 0..<50 {
            var quiet = tone()
            _ = quiet.withUnsafeMutableBufferPointer { leveler.process($0, sampleRate: 48_000) }
        }
        var transient: [Float] = [-2, 1.5, -0.7, 0.7, .nan, .infinity, -.infinity, 0]
        _ = transient.withUnsafeMutableBufferPointer { leveler.process($0, sampleRate: 48_000) }
        XCTAssertTrue(transient.allSatisfy { $0.isFinite && abs($0) <= 0.950001 })
        XCTAssertEqual(Array(transient[4...]), [0, 0, 0, 0])
        XCTAssertLessThan(transient[0], 0)
        XCTAssertGreaterThan(transient[1], 0)
    }

    func testSilenceAndLowNoiseAreNotRaisedAfterLoudnessGain() {
        var leveler = VoicePlaybackLeveler()
        for _ in 0..<50 {
            var quiet = tone()
            _ = quiet.withUnsafeMutableBufferPointer { leveler.process($0, sampleRate: 48_000) }
        }
        var noise = [Float](repeating: 0.0001, count: 960)
        let original = noise
        _ = noise.withUnsafeMutableBufferPointer { leveler.process($0, sampleRate: 48_000) }
        XCTAssertEqual(noise, original)
    }

    func testHeadphoneRouteDisablesPreviouslyAccumulatedBoost() {
        var leveler = VoicePlaybackLeveler()
        for _ in 0..<50 {
            var quiet = tone()
            _ = quiet.withUnsafeMutableBufferPointer { leveler.process($0, sampleRate: 48_000) }
        }
        var headphones = tone(amplitude: 0.1)
        let original = headphones
        let levels = headphones.withUnsafeMutableBufferPointer {
            leveler.process($0, sampleRate: 48_000, enabled: false)
        }
        XCTAssertEqual(headphones, original)
        XCTAssertEqual(levels.appliedGain, 1)
    }

    func testOpusPacketAggregationDoesNotChangeSteadySpeechGain() {
        func run(frames: Int, packets: Int) -> Float {
            var leveler = VoicePlaybackLeveler()
            var gain: Float = 0
            for _ in 0..<packets {
                var samples = tone(count: frames)
                gain = samples.withUnsafeMutableBufferPointer {
                    leveler.process($0, sampleRate: 48_000).appliedGain
                }
            }
            return gain
        }
        XCTAssertEqual(run(frames: 960, packets: 120), run(frames: 5760, packets: 20), accuracy: 0.01)
    }
}
