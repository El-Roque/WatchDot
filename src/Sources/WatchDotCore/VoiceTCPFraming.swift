import Foundation

/// RFC 4571 framing applies equally to ICE checks, DTLS and encrypted media.
/// The RTC engine receives complete unframed packets, never TCP read fragments.
struct VoiceTCPFraming: Sendable {
    enum Failure: Error { case oversizedPacket, oversizedRead }
    static let maximumPacket = 2_000 // Same bound as the native RTC receive ABI.
    private var pending = Data()

    static func frame(_ packet: Data) throws -> Data {
        guard packet.count <= maximumPacket else { throw Failure.oversizedPacket }
        var result = Data([UInt8(packet.count >> 8), UInt8(packet.count & 255)])
        result.append(packet)
        return result
    }

    mutating func append(_ bytes: Data) throws -> [Data] {
        guard bytes.count <= 16_384 else { throw Failure.oversizedRead }
        pending.append(bytes)
        var packets: [Data] = []
        var consumed = 0
        while pending.count - consumed >= 2 {
            let length = Int(pending[consumed]) << 8 | Int(pending[consumed + 1])
            guard length <= Self.maximumPacket else {
                pending = Data()
                throw Failure.oversizedPacket
            }
            guard pending.count - consumed >= length + 2 else { break }
            // RFC 4571 null packets are valid and carry no application payload.
            if length > 0 { packets.append(Data(pending[(consumed + 2)..<(consumed + 2 + length)])) }
            consumed += length + 2
        }
        if consumed > 0 { pending = Data(pending.dropFirst(consumed)) }
        return packets
    }
}
