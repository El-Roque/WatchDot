import Foundation

/// Terminal stop is latched: a late start must never replace connected speech.
struct VoiceRingbackState {
    enum StopReason { case graphReset, terminal }
    static let repeatSilenceSeconds = 3
    private(set) var isPlaying = false
    private var mayStart = true
    mutating func begin() -> Bool {
        guard mayStart, !isPlaying else { return false }
        isPlaying = true
        return true
    }
    @discardableResult mutating func finish(reason: StopReason = .terminal) -> Bool {
        // Initial graph cleanup is not cancellation: a tone not yet requested
        // must remain eligible. Actual cancellation/remote audio always latches.
        guard reason == .terminal || isPlaying else { return false }
        mayStart = false
        let wasPlaying = isPlaying
        isPlaying = false
        return wasPlaying
    }
}
