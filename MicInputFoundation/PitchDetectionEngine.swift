import Foundation

// MARK: - Pitch Engine Data Models

/// Raw pitch detection output before note mapping or stability logic.
struct PitchRaw {
    let frequencyHz: Double
    let confidence: Double
    let inputLevelDbfs: Double?
}

/// High-level pitch result exposed to the JS / app layer.
struct PitchResult {
    let detectedFrequencyHz: Double
    let noteName: String
    let octave: Int
    /// Clamped cents offset in range [-50, +50].
    let centsOffset: Double
    let confidence: Double
    let inputLevelDbfs: Double?
    let isStable: Bool
    let tuningState: TuningState
}

enum TuningState {
    case inTune
    case near
    case outOfTune
    case unstable
    case silence
}

// MARK: - Stability Logic

/// Tracks short-term stability of the detected note and cents offset.
final class PitchStabilityTracker {
    private var lastNoteName: String?
    private var lastOctave: Int?
    private var windowStartTime: TimeInterval = 0
    private var minCents: Double = 0
    private var maxCents: Double = 0
    private let stableDuration: TimeInterval = 0.120 // 120 ms
    private let stableVariationCents: Double = 3.0
    
    func reset() {
        lastNoteName = nil
        lastOctave = nil
        windowStartTime = 0
        minCents = 0
        maxCents = 0
    }
    
    func update(noteName: String, octave: Int, centsOffset: Double, timestamp: TimeInterval) -> Bool {
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
        
        let duration = timestamp - windowStartTime
        if duration >= stableDuration && (maxCents - minCents) <= (2.0 * stableVariationCents) {
            return true
        }
        
        return false
    }
}

// MARK: - YIN Pitch Detection Engine

/// DSP-only pitch detection engine using YIN / CMND.
/// Real-time safe: avoids per-frame heap allocations in `processAudioFrame`.
final class PitchDetectionEngine {
    
    // MARK: Configuration
    
    private let sampleRate: Double
    private var calibrationA4: Double = 440.0
    
    // YIN parameters
    private let yinThreshold: Double = 0.15
    private let minFrequency: Double = 50.0
    private let maxFrequency: Double = 2000.0
    
    private let maxTau: Int
    private let minTau: Int
    
    // Preallocated buffers for YIN
    private var differenceBuffer: [Double]
    private var cmndBuffer: [Double]
    
    // Smoothing state
    private var hasSmoothed: Bool = false
    private var smoothedFrequency: Double = 0
    private let smoothingAlpha: Double = 0.15
    
    // Stability tracker
    private let stabilityTracker = PitchStabilityTracker()
    
    // Silence threshold (dBFS)
    private let silenceThresholdDbfs: Double = -50.0
    
    // Debug logging
    var debugLoggingEnabled: Bool = false
    
    // MARK: Init
    
    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        
        let maxTauDouble = Int(sampleRate / minFrequency)
        self.maxTau = max(1, maxTauDouble)
        let minTauDouble = Int(sampleRate / maxFrequency)
        self.minTau = max(1, minTauDouble)
        
        self.differenceBuffer = [Double](repeating: 0.0, count: maxTau)
        self.cmndBuffer = [Double](repeating: 0.0, count: maxTau)
    }
    
    // MARK: Public API
    
    func setCalibrationA4(_ hz: Double) {
        calibrationA4 = hz
    }
    
    /// Process a frame of mono PCM audio.
    /// This method is designed to be called from a non-real-time context
    /// (e.g., after the mic callback), because it uses Swift arrays for
    /// the input frame. Internally it avoids per-call allocations.
    func processAudioFrame(_ frame: [Float], timestamp: TimeInterval, inputLevelDbfs: Double?) -> PitchResult? {
        guard !frame.isEmpty else { return nil }
        
        // Silence handling based on input level (if provided)
        if let level = inputLevelDbfs, level < silenceThresholdDbfs {
            resetOnSilence()
            return PitchResult(
                detectedFrequencyHz: 0,
                noteName: "",
                octave: 0,
                centsOffset: 0,
                confidence: 0,
                inputLevelDbfs: inputLevelDbfs,
                isStable: false,
                tuningState: .silence
            )
        }
        
        let raw = detectPitchYIN(frame: frame)
        guard raw.confidence > 0, raw.frequencyHz > 0 else {
            // Unstable / no reliable pitch
            return nil
        }
        
        let frequency = applySmoothing(to: raw.frequencyHz)
        let mapping = NoteMapper.mapFrequency(frequency, calibrationA4: calibrationA4)
        
        var cents = mapping.centsOffset
        if cents < -50 { cents = -50 }
        if cents > 50 { cents = 50 }
        
        // According to spec: beyond ±50 cents -> unstable / note change
        if abs(mapping.centsOffset) > 50 {
            stabilityTracker.reset()
            hasSmoothed = false
            return PitchResult(
                detectedFrequencyHz: frequency,
                noteName: mapping.noteName,
                octave: mapping.octave,
                centsOffset: cents,
                confidence: raw.confidence,
                inputLevelDbfs: inputLevelDbfs,
                isStable: false,
                tuningState: .unstable
            )
        }
        
        let isStable = stabilityTracker.update(
            noteName: mapping.noteName,
            octave: mapping.octave,
            centsOffset: mapping.centsOffset,
            timestamp: timestamp
        )
        
        let tuningState: TuningState
        let absCents = abs(mapping.centsOffset)
        if !isStable {
            tuningState = .unstable
        } else if absCents <= 3 {
            tuningState = .inTune
        } else if absCents <= 10 {
            tuningState = .near
        } else {
            tuningState = .outOfTune
        }
        
        return PitchResult(
            detectedFrequencyHz: frequency,
            noteName: mapping.noteName,
            octave: mapping.octave,
            centsOffset: cents,
            confidence: raw.confidence,
            inputLevelDbfs: inputLevelDbfs,
            isStable: isStable,
            tuningState: tuningState
        )
    }
    
    // MARK: Internal helpers
    
    private func resetOnSilence() {
        hasSmoothed = false
        smoothedFrequency = 0
        stabilityTracker.reset()
    }
    
    private func applySmoothing(to frequency: Double) -> Double {
        if !hasSmoothed {
            smoothedFrequency = frequency
            hasSmoothed = true
            return frequency
        }
        // Exponential smoothing: y_t = y_{t-1} + alpha (x_t - y_{t-1})
        smoothedFrequency = smoothedFrequency + smoothingAlpha * (frequency - smoothedFrequency)
        return smoothedFrequency
    }
    
    private func detectPitchYIN(frame: [Float]) -> PitchRaw {
        let frameCount = frame.count
        if frameCount <= maxTau {
            return PitchRaw(frequencyHz: 0, confidence: 0, inputLevelDbfs: nil)
        }
        
        // Step 1: Difference function d(tau)
        for tau in 0..<maxTau {
            var sum: Double = 0
            let limit = frameCount - tau
            var i = 0
            while i < limit {
                let diff = Double(frame[i]) - Double(frame[i + tau])
                sum += diff * diff
                i += 1
            }
            differenceBuffer[tau] = sum
        }
        
        // Step 2: Cumulative mean normalized difference function (CMND)
        cmndBuffer[0] = 1.0
        var runningSum: Double = 0
        for tau in 1..<maxTau {
            runningSum += differenceBuffer[tau]
            let denom = runningSum / Double(tau)
            cmndBuffer[tau] = denom > 0 ? differenceBuffer[tau] / denom : 1.0
        }
        
        // Step 3: Absolute threshold
        var tauEstimate = -1
        for tau in minTau..<maxTau {
            if cmndBuffer[tau] < yinThreshold {
                // Search for local minimum
                while tau + 1 < maxTau && cmndBuffer[tau + 1] < cmndBuffer[tau] {
                    tauEstimate = tau + 1
                    return refineTauAndBuildResult(tauEstimate: tauEstimate)
                }
                tauEstimate = tau
                break
            }
        }
        
        if tauEstimate == -1 {
            // No threshold crossing; use global min
            var minVal = Double.greatestFiniteMagnitude
            var minIndex = -1
            for tau in minTau..<maxTau {
                let v = cmndBuffer[tau]
                if v < minVal {
                    minVal = v
                    minIndex = tau
                }
            }
            tauEstimate = minIndex
        }
        
        if tauEstimate <= 0 || tauEstimate >= maxTau - 1 {
            return PitchRaw(frequencyHz: 0, confidence: 0, inputLevelDbfs: nil)
        }
        
        return refineTauAndBuildResult(tauEstimate: tauEstimate)
    }
    
    private func refineTauAndBuildResult(tauEstimate: Int) -> PitchRaw {
        // Parabolic interpolation using CMND around tauEstimate
        let tau = tauEstimate
        let x0 = Double(cmndBuffer[tau - 1])
        let x1 = Double(cmndBuffer[tau])
        let x2 = Double(cmndBuffer[tau + 1])
        
        let denom = (x0 - 2 * x1 + x2)
        let delta: Double
        if denom == 0 {
            delta = 0
        } else {
            delta = 0.5 * (x0 - x2) / denom
        }
        
        let refinedTau = Double(tau) + delta
        let frequency = sampleRate / refinedTau
        if frequency.isNaN || frequency <= 0 {
            return PitchRaw(frequencyHz: 0, confidence: 0, inputLevelDbfs: nil)
        }
        
        // Confidence can be derived from CMND minimum near tau
        let cmndAtTau = cmndBuffer[tau]
        let confidence = max(0.0, min(1.0, 1.0 - cmndAtTau / yinThreshold))
        
        if debugLoggingEnabled {
            print("[PitchDetectionEngine] tau=\(refinedTau), freq=\(frequency), cmnd=\(cmndAtTau), conf=\(confidence)")
        }
        
        return PitchRaw(frequencyHz: frequency, confidence: confidence, inputLevelDbfs: nil)
    }
}

