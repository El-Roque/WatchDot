import Foundation
import XCTest
@testable import WatchDotCore

final class VoiceTCPFramingTests: XCTestCase {
    func testEveryPossibleSplitPreservesPacketBoundaries() throws {
        let first = Data((0..<999).map { UInt8($0 & 255) })
        let second = Data([0x16, 0xfe, 0xfd, 1])
        let stream = try VoiceTCPFraming.frame(first) + VoiceTCPFraming.frame(second)
        for split in 0...stream.count {
            var parser = VoiceTCPFraming()
            let a = try parser.append(Data(stream.prefix(split)))
            let b = try parser.append(Data(stream.dropFirst(split)))
            XCTAssertEqual(a + b, [first, second], "split \(split)")
        }
    }
    func testByteByByteCoalescingAndNullFrames() throws {
        let packets = [Data([0, 1, 0x21, 0x12]), Data(repeating: 0x80, count: 2_000)]
        let stream = Data([0, 0]) + (try VoiceTCPFraming.frame(packets[0]))
            + Data([0, 0]) + (try VoiceTCPFraming.frame(packets[1]))
        var parser = VoiceTCPFraming(), result: [Data] = []
        for byte in stream { result += try parser.append(Data([byte])) }
        XCTAssertEqual(result, packets)
    }
    func testRejectsLengthBeforeWaitingForPayload() throws {
        var parser = VoiceTCPFraming()
        XCTAssertThrowsError(try parser.append(Data([0xff, 0xff])))
        XCTAssertThrowsError(try VoiceTCPFraming.frame(Data(repeating: 1, count: 2_001)))
        XCTAssertThrowsError(try parser.append(Data(repeating: 0, count: 16_385)))
    }
}
