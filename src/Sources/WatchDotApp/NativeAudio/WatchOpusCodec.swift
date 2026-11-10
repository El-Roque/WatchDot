import AVFAudio
import Foundation
import WatchDotOpus

final class WatchOpusCodec {
    static let sampleRate = 48000.0
    static let frameCount: AVAudioFrameCount = 960
    let pcmFormat: AVAudioFormat
    private let native: OpaquePointer

    init() throws {
        guard let pcm = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1),
              let native = watchdot_opus_create()
        else {
            throw WatchRealtimeMediaError.unavailable(String(localized: "Opus audio is unavailable on this device."))
        }
        self.pcmFormat = pcm
        self.native = native
    }

    deinit { watchdot_opus_free(self.native) }

    func encode(_ pcm: AVAudioPCMBuffer) throws -> Data? {
        guard pcm.frameLength == Self.frameCount, pcm.format == self.pcmFormat else {
            throw WatchRealtimeMediaError
                .unavailable(String(localized: "Voice capture returned an unexpected audio format."))
        }
        var output = [UInt8](repeating: 0, count: 1275)
        let result = watchdot_opus_encode(self.native, pcm.floatChannelData![0], Int32(Self.frameCount), &output, 1275)
        guard result > 0
        else { throw WatchRealtimeMediaError.unavailable(String(localized: "Voice encoding failed.")) }
        return Data(output.prefix(Int(result)))
    }

    func decode(_ packet: Data) throws -> AVAudioPCMBuffer {
        guard !packet.isEmpty, packet.count <= 2000 else {
            throw WatchRealtimeMediaError.unavailable(String(localized: "Voice received an invalid Opus packet."))
        }
        // Incoming packets may aggregate frames. The native Opus decoder reads their TOC;
        // our 20 ms capture frame size is not a constraint on the remote packet duration.
        guard let output = AVAudioPCMBuffer(pcmFormat: self.pcmFormat, frameCapacity: 5760) else {
            throw WatchRealtimeMediaError.unavailable(String(localized: "Voice playback could not allocate audio."))
        }
        let result = packet.withUnsafeBytes { bytes in
            watchdot_opus_decode(self.native, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                 Int32(bytes.count), output.floatChannelData![0], 5760)
        }
        guard result > 0
        else { throw WatchRealtimeMediaError.unavailable(String(localized: "Voice decoding failed.")) }
        output.frameLength = AVAudioFrameCount(result)
        return output
    }

    func conceal(frames: UInt32) throws -> AVAudioPCMBuffer {
        guard frames >= 120, frames <= 5760, frames % 120 == 0,
              let output = AVAudioPCMBuffer(pcmFormat: self.pcmFormat, frameCapacity: frames) else {
            throw WatchRealtimeMediaError.unavailable("Invalid Opus concealment interval.")
        }
        let result = watchdot_opus_decode(self.native, nil, 0, output.floatChannelData![0], Int32(frames))
        guard result == Int32(frames) else {
            throw WatchRealtimeMediaError.unavailable("Opus could not conceal missing audio.")
        }
        output.frameLength = frames
        return output
    }

    func recover(frames: UInt32, from next: Data) throws -> (pcm: AVAudioPCMBuffer, usedFEC: Bool) {
        guard frames >= 120, frames <= 5760, frames % 120 == 0, !next.isEmpty, next.count <= 2000,
              let output = AVAudioPCMBuffer(pcmFormat: self.pcmFormat, frameCapacity: frames) else {
            throw WatchRealtimeMediaError.unavailable("Invalid Opus recovery interval.")
        }
        var usedFEC: Int32 = 0
        let result = next.withUnsafeBytes { bytes in
            watchdot_opus_recover(self.native, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                Int32(bytes.count), output.floatChannelData![0], Int32(frames), &usedFEC)
        }
        guard result == Int32(frames) else { throw WatchRealtimeMediaError.unavailable("Opus recovery failed.") }
        output.frameLength = frames
        return (output, usedFEC == 1)
    }
}

extension AVAudioConverter {
    func convert(_ input: AVAudioBuffer, to output: AVAudioBuffer) throws -> AVAudioConverterOutputStatus {
        let source = SingleConversionInput(input)
        var error: NSError?
        let result = self.convert(to: output, error: &error) { _, status in
            guard let input = source.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return result
    }
}

/// Owns one borrowed input during the synchronous conversion. The codec's serial
/// owner must not mutate that input until convert() returns. The lock makes the
/// converter's Sendable callback consume the reference exactly once.
private final class SingleConversionInput: @unchecked Sendable {
    private let lock = NSLock()
    private var input: AVAudioBuffer?
    init(_ input: AVAudioBuffer) { self.input = input }
    func take() -> AVAudioBuffer? {
        self.lock.withLock {
            defer { self.input = nil }
            return self.input
        }
    }
}

