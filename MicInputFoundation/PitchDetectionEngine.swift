import Foundation

// MARK: - Pitch Engine Data Models

/// Raw pitch detection output before note mapping or stability logic.
struct PitchRaw {
    let frequencyHz: Double
    let confidence: Double
    let inputLevelDbfs: Double?
    let debug: PitchDebug?
}

/// High-level pitch result exposed to the JS / app layer.
struct PitchResult {
    /// Detected frequency in Hz (nil when no pitch is present).
    let detectedFrequencyHz: Double?
    let noteName: String?
    let octave: Int?
    /// Clamped cents offset in range [-50, +50] (nil when no pitch is present).
    let centsOffset: Double?
    let confidence: Double
    let inputLevelDbfs: Double?
    let isStable: Bool
    let tuningState: TuningState
}

enum TuningState: String {
    case inTune = "inTune"
    case near = "near"
    case outOfTune = "outOfTune"
    case unstable = "unstable"
    case silence = "silence"
}

// MARK: - YIN Pitch Detection Engine

/// DSP-only pitch detection engine using YIN / CMND.
/// Real-time safe: avoids per-frame heap allocations in `processAudioFrame`.
final class PitchDetectionEngine {
    
    // MARK: Configuration
    
    private let sampleRate: Double
    private var calibrationA4: Double = 440.0
    
    // YIN parameters
    private let yinThreshold: Double = TunerDSPConfig.yinThreshold
    private let minFrequency: Double = TunerDSPConfig.minDetectableFrequencyHz
    private let maxFrequency: Double = TunerDSPConfig.maxDetectableFrequencyHz
    
    private let maxTau: Int
    private let minTau: Int
    
    // Preallocated buffers for YIN
    private var differenceBuffer: [Double]
    private var cmndBuffer: [Double]
    
    // Scratch for FFT verification / scoring (no per-frame allocations)
    private var fftScratchMagnitudes: [Float]
    private var fftScratchCapacity: Int = 0
    
    // Smoothing state
    private var hasSmoothed: Bool = false
    private var smoothedFrequency: Double = 0
    
    private var centsStats = RollingWindowStats(windowSize: 10)
    private var lastMappedCents: Double = 0
    private var lastStableFrequency: Double = 0
    private var lastStableCents: Double = 0
    private var wasStableLastFrame: Bool = false
    
    // Stability tracker
    private let stabilityLogic = StabilityLogic()
    
    // Silence threshold (dBFS)
    private var noiseFloorDbfs: Double?
    
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
        self.fftScratchMagnitudes = []
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
        return processAudioFrame(frame, timestamp: timestamp, inputLevelDbfs: inputLevelDbfs, fftMagnitudes: nil, fftSize: nil)
    }
    
    /// Process a frame with optional FFT magnitudes (verification only).
    /// - Parameters:
    ///   - fftMagnitudes: Magnitudes for bins [0..<fftSize/2]. If you are downsampling bins, pass nil here (verification expects native bin mapping).
    ///   - fftSize: FFT size used to compute magnitudes (must match the magnitudes length at `fftSize/2`).
    func processAudioFrame(
        _ frame: [Float],
        timestamp: TimeInterval,
        inputLevelDbfs: Double?,
        fftMagnitudes: UnsafePointer<Float>?,
        fftSize: Int?
    ) -> PitchResult? {
        guard !frame.isEmpty else { return nil }
        
        let level = inputLevelDbfs ?? estimateInputLevelDbfs(frame)
        let isSilent = isSilence(levelDbfs: level)
        if isSilent {
            resetOnSilence()
            return PitchResult(
                detectedFrequencyHz: nil,
                noteName: nil,
                octave: nil,
                centsOffset: nil,
                confidence: 0,
                inputLevelDbfs: level,
                isStable: false,
                tuningState: .silence
            )
        }
        
        let yin = detectPitchYIN(frame: frame)
        guard yin.frequencyHz > 0 else {
            return PitchResult(
                detectedFrequencyHz: nil,
                noteName: nil,
                octave: nil,
                centsOffset: nil,
                confidence: 0,
                inputLevelDbfs: level,
                isStable: false,
                tuningState: .unstable
            )
        }
        
        let verified = verifySubharmonicsAndChooseFrequency(
            yin: yin,
            frame: frame,
            fftMagnitudes: fftMagnitudes,
            fftSize: fftSize
        )
        
        let confidence = computeCompositeConfidence(
            yin: verified.yin,
            chosenFrequencyHz: verified.frequencyHz,
            levelDbfs: level,
            fftConfirmation: verified.fftConfirmation
        )
        
        // If confidence is extremely low, treat as "no pitch" rather than emitting unstable note guesses.
        if confidence < 0.10 {
            updateNoiseFloor(with: level)
            stabilityLogic.reset()
            wasStableLastFrame = false
            return PitchResult(
                detectedFrequencyHz: nil,
                noteName: nil,
                octave: nil,
                centsOffset: nil,
                confidence: 0,
                inputLevelDbfs: level,
                isStable: false,
                tuningState: .unstable
            )
        }
        
        // Update noise floor only when there is no strong pitch evidence.
        if confidence < 0.25 {
            updateNoiseFloor(with: level)
        }
        
        let centsVariance = centsStats.variance
        let adaptiveAlpha = adaptiveSmoothingAlpha(
            confidence: confidence,
            centsVariance: centsVariance,
            wasStable: wasStableLastFrame
        )
        
        // Explicit smoothing reset on large jumps (Android parity): re-seed smoothing so we don't lag.
        if shouldResetSmoothing(forNewFrequency: verified.frequencyHz) {
            reseedAfterLargeJump(newFrequencyHz: verified.frequencyHz)
        }
        
        let frequency = applySmoothing(to: verified.frequencyHz, alpha: adaptiveAlpha)
        let mapping = NoteMapper.mapFrequency(frequency, calibrationA4: calibrationA4)
        
        var cents = mapping.centsOffset
        if cents < -50 { cents = -50 }
        if cents > 50 { cents = 50 }
        
        centsStats.push(mapping.centsOffset)
        lastMappedCents = mapping.centsOffset
        
        // According to spec: beyond ±50 cents -> unstable / note change
        if abs(mapping.centsOffset) > 50 {
            stabilityLogic.reset()
            hasSmoothed = false
            wasStableLastFrame = false
            return PitchResult(
                detectedFrequencyHz: frequency,
                noteName: mapping.noteName,
                octave: mapping.octave,
                centsOffset: cents,
                confidence: confidence,
                inputLevelDbfs: level,
                isStable: false,
                tuningState: .unstable
            )
        }
        
        let requiredStableWindow = adaptiveStabilityWindowSeconds(
            confidence: confidence,
            centsVariance: centsVariance
        )
        
        let isStable = stabilityLogic.update(
            noteName: mapping.noteName,
            octave: mapping.octave,
            centsOffset: mapping.centsOffset,
            timestamp: timestamp,
            requiredStableDuration: requiredStableWindow
        )
        
        // Stable-mode dead zone to reduce jitter: keep the previously stable readout
        // if the user is within a tiny cents neighborhood.
        let finalFrequency: Double
        let finalCents: Double
        if isStable {
            if !wasStableLastFrame {
                lastStableFrequency = frequency
                lastStableCents = mapping.centsOffset
            } else if abs(mapping.centsOffset - lastStableCents) <= TunerDSPConfig.stableDeadZoneCents {
                finalFrequency = lastStableFrequency
                finalCents = lastStableCents
                wasStableLastFrame = true
                return buildPitchResult(
                    frequencyHz: finalFrequency,
                    mapping: mapping,
                    overrideCentsOffset: finalCents,
                    confidence: confidence,
                    inputLevelDbfs: level,
                    isStable: true
                )
            } else {
                lastStableFrequency = frequency
                lastStableCents = mapping.centsOffset
            }
        }
        
        wasStableLastFrame = isStable
        
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
            confidence: confidence,
            inputLevelDbfs: level,
            isStable: isStable,
            tuningState: tuningState
        )
    }
    
    // MARK: Internal helpers
    
    private func resetOnSilence() {
        hasSmoothed = false
        smoothedFrequency = 0
        stabilityLogic.reset()
        centsStats.reset()
        wasStableLastFrame = false
        lastMappedCents = 0
        lastStableFrequency = 0
        lastStableCents = 0
    }

    private func applySmoothing(to frequency: Double, alpha: Double) -> Double {
        if !hasSmoothed {
            smoothedFrequency = frequency
            hasSmoothed = true
            return frequency
        }
        // Exponential smoothing: y_t = y_{t-1} + alpha (x_t - y_{t-1})
        smoothedFrequency = smoothedFrequency + alpha * (frequency - smoothedFrequency)
        return smoothedFrequency
    }
    
    private func detectPitchYIN(frame: [Float]) -> YinCandidate {
        let frameCount = frame.count
        if frameCount <= maxTau {
            return YinCandidate(frequencyHz: 0, refinedTau: 0, tauEstimate: 0, cmndAtTau: 1, cmndQuality: 0)
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
            return YinCandidate(frequencyHz: 0, refinedTau: 0, tauEstimate: 0, cmndAtTau: 1, cmndQuality: 0)
        }
        
        return refineTauAndBuildResult(tauEstimate: tauEstimate)
    }
    
    private func refineTauAndBuildResult(tauEstimate: Int) -> YinCandidate {
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
            return YinCandidate(frequencyHz: 0, refinedTau: 0, tauEstimate: 0, cmndAtTau: 1, cmndQuality: 0)
        }
        
        let cmndAtTau = cmndBuffer[tau]
        let cmndQuality = max(0.0, min(1.0, 1.0 - cmndAtTau / yinThreshold))
        
        if debugLoggingEnabled {
            print("[PitchDetectionEngine] tau=\(refinedTau), freq=\(frequency), cmnd=\(cmndAtTau), cmndQ=\(cmndQuality)")
        }
        
        return YinCandidate(
            frequencyHz: frequency,
            refinedTau: refinedTau,
            tauEstimate: tau,
            cmndAtTau: cmndAtTau,
            cmndQuality: cmndQuality
        )
    }
}

// MARK: - Internal models / utilities

private struct PitchDebug {
    let cmndAtTau: Double
    let chosenBySubharmonic: Bool
    let fftConfirmation: Double
}

private struct YinCandidate {
    let frequencyHz: Double
    let refinedTau: Double
    let tauEstimate: Int
    let cmndAtTau: Double
    let cmndQuality: Double
}

private struct FftConfirmation {
    /// 0..1 strength of confirmation for the chosen fundamental.
    let strength: Double
    /// 0..1 evidence that the signal's energy aligns with a harmonic series.
    let harmonicConsistency: Double
}

private extension PitchDetectionEngine {
    func shouldResetSmoothing(forNewFrequency newFrequencyHz: Double) -> Bool {
        guard hasSmoothed, smoothedFrequency > 0, newFrequencyHz > 0 else { return false }
        let centsJump = 1200.0 * log2(newFrequencyHz / smoothedFrequency)
        return abs(centsJump) >= TunerDSPConfig.smoothingResetJumpCents
    }
    
    func reseedAfterLargeJump(newFrequencyHz: Double) {
        stabilityLogic.reset()
        centsStats.reset()
        wasStableLastFrame = false
        lastStableFrequency = 0
        lastStableCents = 0
        lastMappedCents = 0
        
        smoothedFrequency = newFrequencyHz
        hasSmoothed = true
    }
    
    func buildPitchResult(
        frequencyHz: Double,
        mapping: NoteMapping,
        overrideCentsOffset: Double?,
        confidence: Double,
        inputLevelDbfs: Double?,
        isStable: Bool
    ) -> PitchResult {
        var cents = overrideCentsOffset ?? mapping.centsOffset
        if cents < -50 { cents = -50 }
        if cents > 50 { cents = 50 }
        let tuningState: TuningState
        let absCents = abs(cents)
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
            detectedFrequencyHz: frequencyHz,
            noteName: mapping.noteName,
            octave: mapping.octave,
            centsOffset: cents,
            confidence: confidence,
            inputLevelDbfs: inputLevelDbfs,
            isStable: isStable,
            tuningState: tuningState
        )
    }
    
    func estimateInputLevelDbfs(_ frame: [Float]) -> Double {
        // RMS -> dBFS. Avoid allocations; use a simple loop.
        var sum: Double = 0
        for x in frame {
            let v = Double(x)
            sum += v * v
        }
        let mean = sum / Double(max(1, frame.count))
        let rms = sqrt(mean)
        if rms <= 0 { return -120.0 }
        return 20.0 * log10(rms)
    }
    
    func isSilence(levelDbfs: Double) -> Bool {
        // Adaptive silence threshold derived from a running noise floor estimate.
        // When we haven't learned a noise floor yet, fall back to a safe absolute threshold.
        let base = noiseFloorDbfs ?? TunerDSPConfig.absoluteSilenceThresholdDbfs
        let threshold = max(TunerDSPConfig.absoluteSilenceThresholdDbfs, base + TunerDSPConfig.noiseFloorMarginDb)
        return levelDbfs < threshold
    }
    
    func updateNoiseFloor(with levelDbfs: Double) {
        if let current = noiseFloorDbfs {
            noiseFloorDbfs = current + TunerDSPConfig.noiseFloorAlpha * (levelDbfs - current)
        } else {
            noiseFloorDbfs = levelDbfs
        }
    }
    
    func adaptiveSmoothingAlpha(confidence: Double, centsVariance: Double, wasStable: Bool) -> Double {
        // Deterministic mapping:
        // - lower confidence and higher variance => stronger smoothing (smaller alpha)
        // - stable tracking gets slightly more smoothing to reduce jitter
        let varianceClamped = max(0.0, min(100.0, centsVariance))
        let v = varianceClamped / 100.0 // 0..1
        let c = max(0.0, min(1.0, confidence))
        
        // Base responsiveness from confidence (high confidence => higher alpha).
        let alphaFromConfidence = TunerDSPConfig.smoothingAlphaMin +
            (TunerDSPConfig.smoothingAlphaMax - TunerDSPConfig.smoothingAlphaMin) * c
        
        // Variance pushes alpha down (more smoothing).
        let variancePenalty = 0.65 * v
        var alpha = alphaFromConfidence * (1.0 - variancePenalty)
        
        if wasStable {
            alpha *= 0.85
        }
        
        return max(TunerDSPConfig.smoothingAlphaMin, min(TunerDSPConfig.smoothingAlphaMax, alpha))
    }
    
    func adaptiveStabilityWindowSeconds(confidence: Double, centsVariance: Double) -> TimeInterval {
        // Clean, stable => shorter window. Noisy/unstable => longer window.
        let varianceClamped = max(0.0, min(100.0, centsVariance))
        let v = varianceClamped / 100.0
        let c = max(0.0, min(1.0, confidence))
        
        // v increases window; confidence decreases it.
        let tMin = TunerDSPConfig.stabilityWindowMinSeconds
        let tMax = TunerDSPConfig.stabilityWindowMaxSeconds
        let mix = max(0.0, min(1.0, 0.75 * v + 0.25 * (1.0 - c)))
        return tMin + (tMax - tMin) * mix
    }
    
    func computeCompositeConfidence(
        yin: YinCandidate,
        chosenFrequencyHz: Double,
        levelDbfs: Double,
        fftConfirmation: FftConfirmation?
    ) -> Double {
        let cmnd = yin.cmndQuality
        
        // Energy quality: map [-80, -20] dBFS to 0..1.
        let energy = max(-80.0, min(-20.0, levelDbfs))
        let energyQ = (energy + 80.0) / 60.0
        
        let harmonicQ = fftConfirmation?.harmonicConsistency ?? 0.0
        let fftQ = fftConfirmation?.strength ?? 0.0
        
        var score =
            TunerDSPConfig.confidenceWeightCmnd * cmnd +
            TunerDSPConfig.confidenceWeightEnergy * energyQ +
            TunerDSPConfig.confidenceWeightHarmonic * harmonicQ +
            TunerDSPConfig.confidenceWeightFft * fftQ
        
        // Light penalty when outside configured detectable range.
        if chosenFrequencyHz < minFrequency || chosenFrequencyHz > maxFrequency {
            score *= 0.6
        }
        
        return max(0.0, min(1.0, score))
    }
    
    struct VerifiedPitch {
        let frequencyHz: Double
        let yin: YinCandidate
        let fftConfirmation: FftConfirmation?
    }
    
    func verifySubharmonicsAndChooseFrequency(
        yin: YinCandidate,
        frame: [Float],
        fftMagnitudes: UnsafePointer<Float>?,
        fftSize: Int?
    ) -> VerifiedPitch {
        guard yin.frequencyHz > 0 else {
            return VerifiedPitch(frequencyHz: 0, yin: yin, fftConfirmation: nil)
        }
        
        // Candidate tau indices for subharmonics (fundamental lower frequency => larger tau).
        let tau = yin.tauEstimate
        let tau2 = tau * 2
        let tau3 = tau * 3
        
        // Scoring: prefer lower frequency only when supported by evidence.
        let baseScore = yin.cmndQuality
        
        var best = (freq: yin.frequencyHz, tau: tau, score: baseScore)
        
        if tau2 > 0 && tau2 < maxTau {
            let cmndQ2 = max(0.0, min(1.0, 1.0 - cmndBuffer[tau2] / yinThreshold))
            // Require non-trivial quality; otherwise ignore.
            let score2 = cmndQ2 * 0.95
            if score2 > best.score + 0.08 {
                best = (freq: sampleRate / Double(tau2), tau: tau2, score: score2)
            }
        }
        
        if tau3 > 0 && tau3 < maxTau {
            let cmndQ3 = max(0.0, min(1.0, 1.0 - cmndBuffer[tau3] / yinThreshold))
            let score3 = cmndQ3 * 0.90
            if score3 > best.score + 0.10 {
                best = (freq: sampleRate / Double(tau3), tau: tau3, score: score3)
            }
        }
        
        // FFT verification layer (if available): can override to subharmonic if clearly supported.
        let fftConf = fftMagnitudes.flatMap { mags in
            fftSize.flatMap { size in
                verifyWithFFT(
                    magnitudes: mags,
                    magnitudeCount: size / 2,
                    fftSize: size,
                    sampleRate: sampleRate,
                    fundamentalHz: best.freq
                )
            }
        }
        
        if let conf = fftConf {
            // If FFT strongly disagrees (weak confirmation), check if f/2 or f/3 has stronger confirmation.
            if conf.strength < 0.25 {
                let f2 = best.freq / 2.0
                let f3 = best.freq / 3.0
                let c2 = verifyWithFFT(
                    magnitudes: fftMagnitudes!,
                    magnitudeCount: (fftSize! / 2),
                    fftSize: fftSize!,
                    sampleRate: sampleRate,
                    fundamentalHz: f2
                )
                let c3 = verifyWithFFT(
                    magnitudes: fftMagnitudes!,
                    magnitudeCount: (fftSize! / 2),
                    fftSize: fftSize!,
                    sampleRate: sampleRate,
                    fundamentalHz: f3
                )
                
                if c2.strength > conf.strength * 1.6 && c2.harmonicConsistency >= conf.harmonicConsistency {
                    return VerifiedPitch(frequencyHz: f2, yin: yin, fftConfirmation: c2)
                }
                if c3.strength > conf.strength * 1.8 && c3.harmonicConsistency >= conf.harmonicConsistency {
                    return VerifiedPitch(frequencyHz: f3, yin: yin, fftConfirmation: c3)
                }
            }
            return VerifiedPitch(frequencyHz: best.freq, yin: yin, fftConfirmation: conf)
        }
        
        return VerifiedPitch(frequencyHz: best.freq, yin: yin, fftConfirmation: nil)
    }
    
    func verifyWithFFT(
        magnitudes: UnsafePointer<Float>,
        magnitudeCount: Int,
        fftSize: Int,
        sampleRate: Double,
        fundamentalHz: Double
    ) -> FftConfirmation {
        // Verification only. We look for a local peak near f0 and check that
        // harmonics 2f0 and 3f0 also have reasonable energy.
        // Note: this assumes magnitudes are *not* downsampled (1:1 mapping for bins).
        guard magnitudeCount == fftSize / 2, magnitudeCount > 8, fundamentalHz > 0 else {
            return FftConfirmation(strength: 0, harmonicConsistency: 0)
        }
        
        let binHz = sampleRate / Double(fftSize)
        func bin(for hz: Double) -> Int { Int(round(hz / binHz)) }
        
        let b0 = bin(for: fundamentalHz)
        if b0 <= 0 || b0 >= magnitudeCount { return FftConfirmation(strength: 0, harmonicConsistency: 0) }
        
        // Local peak around target bin.
        let tol = TunerDSPConfig.fftPeakBinTolerance
        let start = max(1, b0 - tol)
        let end = min(magnitudeCount - 2, b0 + tol)
        var peak: Float = 0
        for b in start...end {
            let v = magnitudes[b]
            if v > peak { peak = v }
        }
        
        // Estimate nearby noise floor as median-ish of a small neighborhood excluding the peak bin.
        var neighSum: Double = 0
        var neighCount = 0
        for b in max(1, b0 - 6)...min(magnitudeCount - 2, b0 + 6) {
            if b >= start && b <= end { continue }
            neighSum += Double(magnitudes[b])
            neighCount += 1
        }
        let neighAvg = neighCount > 0 ? (neighSum / Double(neighCount)) : 0.0
        let ratio = neighAvg > 0 ? Double(peak) / neighAvg : Double(peak > 0 ? 10.0 : 0.0)
        
        let strength = max(0.0, min(1.0, (ratio - 1.0) / 4.0))
        
        // Harmonic consistency: check energy at 2f0 and 3f0 (if within range).
        let b1 = bin(for: fundamentalHz * 2.0)
        let b2 = bin(for: fundamentalHz * 3.0)
        var harmonicScore: Double = 0
        var harmonicChecks: Double = 0
        if b1 > 0 && b1 < magnitudeCount {
            harmonicScore += Double(magnitudes[b1]) / Double(max(peak, 1e-6))
            harmonicChecks += 1
        }
        if b2 > 0 && b2 < magnitudeCount {
            harmonicScore += Double(magnitudes[b2]) / Double(max(peak, 1e-6))
            harmonicChecks += 1
        }
        let harmonicConsistency = harmonicChecks > 0 ? max(0.0, min(1.0, harmonicScore / harmonicChecks)) : 0.0
        
        return FftConfirmation(strength: strength, harmonicConsistency: harmonicConsistency)
    }
}

/// Fixed-size rolling window stats for a scalar stream.
/// Maintains mean/variance without allocations on push.
private struct RollingWindowStats {
    private let windowSize: Int
    private var values: [Double]
    private var index: Int = 0
    private var count: Int = 0
    private var sum: Double = 0
    private var sumSq: Double = 0
    
    init(windowSize: Int) {
        self.windowSize = max(1, windowSize)
        self.values = [Double](repeating: 0, count: max(1, windowSize))
    }
    
    mutating func reset() {
        index = 0
        count = 0
        sum = 0
        sumSq = 0
        for i in 0..<values.count { values[i] = 0 }
    }
    
    mutating func push(_ x: Double) {
        if count < windowSize {
            values[index] = x
            count += 1
            sum += x
            sumSq += x * x
            index = (index + 1) % windowSize
            return
        }
        
        let old = values[index]
        values[index] = x
        sum += x - old
        sumSq += x * x - old * old
        index = (index + 1) % windowSize
    }
    
    var variance: Double {
        guard count > 1 else { return 0 }
        let mean = sum / Double(count)
        let v = (sumSq / Double(count)) - (mean * mean)
        return max(0, v)
    }
}

