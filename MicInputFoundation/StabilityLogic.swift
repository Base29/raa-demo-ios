import Foundation

/// Tracks short-term stability of the detected note and cents offset.
/// Designed to be deterministic and allocation-free per update.
final class StabilityLogic {
    private(set) var lastNoteName: String?
    private(set) var lastOctave: Int?

    private var windowStartTime: TimeInterval = 0
    private var minCents: Double = 0
    private var maxCents: Double = 0

    func reset() {
        lastNoteName = nil
        lastOctave = nil
        windowStartTime = 0
        minCents = 0
        maxCents = 0
    }

    /// Update stability with a dynamic required duration.
    /// - Returns: true when stable criteria have been met.
    func update(
        noteName: String,
        octave: Int,
        centsOffset: Double,
        timestamp: TimeInterval,
        requiredStableDuration: TimeInterval
    ) -> Bool {
        if lastNoteName != noteName || lastOctave != octave {
            lastNoteName = noteName
            lastOctave = octave
            windowStartTime = timestamp
            minCents = centsOffset
            maxCents = centsOffset
            return false
        }

        if centsOffset < minCents { minCents = centsOffset }
        if centsOffset > maxCents { maxCents = centsOffset }
        
        // Defensive restart rule (Android parity): if cents spread gets too wide while accumulating
        // stability, restart the window so stale history doesn't "carry" through instability.
        let spread = maxCents - minCents
        if spread > (2.0 * TunerDSPConfig.stabilityVariationCents) {
            windowStartTime = timestamp
            minCents = centsOffset
            maxCents = centsOffset
            return false
        }

        let duration = timestamp - windowStartTime
        if duration >= requiredStableDuration &&
            (maxCents - minCents) <= (2.0 * TunerDSPConfig.stabilityVariationCents) {
            return true
        }

        return false
    }
}

