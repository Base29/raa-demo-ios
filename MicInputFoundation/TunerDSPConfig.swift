import Foundation

/// Shared DSP parameters for tuner behavior.
/// Keep these values in sync with Android for parity.
enum TunerDSPConfig {
    // MARK: - Detection range
    static let minDetectableFrequencyHz: Double = 30.0
    static let maxDetectableFrequencyHz: Double = 2000.0

    // MARK: - YIN / CMND
    /// Classic YIN threshold. Lower is stricter.
    static let yinThreshold: Double = 0.15

    // MARK: - Smoothing (adaptive)
    /// Bounds for adaptive exponential smoothing alpha.
    /// Larger alpha = more responsive; smaller alpha = stronger smoothing.
    static let smoothingAlphaMin: Double = 0.08
    static let smoothingAlphaMax: Double = 0.35

    // MARK: - Stability (adaptive)
    /// Dynamic stable window bounds in seconds.
    static let stabilityWindowMinSeconds: TimeInterval = 0.080
    static let stabilityWindowMaxSeconds: TimeInterval = 0.150
    /// Required cents span within the stability window (min..max range).
    static let stabilityVariationCents: Double = 3.0

    // MARK: - Silence / noise floor
    /// Fallback absolute silence threshold if no noise floor is established.
    static let absoluteSilenceThresholdDbfs: Double = -55.0
    /// How much louder than the estimated noise floor we consider "non-silence".
    static let noiseFloorMarginDb: Double = 10.0
    /// Background noise estimator smoothing (only updates when no strong pitch).
    static let noiseFloorAlpha: Double = 0.02

    // MARK: - Stable-mode dead zone
    /// Ignore tiny cents fluctuations only when already stable.
    static let stableDeadZoneCents: Double = 1.5

    // MARK: - Confidence weighting
    static let confidenceWeightCmnd: Double = 0.55
    static let confidenceWeightEnergy: Double = 0.20
    static let confidenceWeightHarmonic: Double = 0.15
    static let confidenceWeightFft: Double = 0.10

    // MARK: - FFT verification
    /// Tolerance (in bins) when matching a target frequency peak.
    static let fftPeakBinTolerance: Int = 1
    /// Minimum relative strength for an FFT confirmation to contribute meaningfully.
    static let fftConfirmationMinRatio: Double = 1.25
}

