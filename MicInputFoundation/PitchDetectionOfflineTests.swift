import Foundation

/// Lightweight offline tests for the native tuner engine logic.
/// These are intentionally dependency-free (no XCTest target required) and can be invoked from a debug entrypoint.
enum PitchDetectionOfflineTests {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
    
    static func runAll() throws {
        try testLowEBassDetection()
        try testHarmonicConfusionOctaveError()
        try testSilenceWithNoisyBackground()
        try testStableDeadZone()
        try testAdaptiveStabilityWindowFasterOnCleanTone()
        try testStabilityRestartsOnWideCentsSpread()
        try testSmoothingResetsOnLargePitchJump()
        try testEmitterPayloadContainsStateAndCleanSilence()
    }
    
    // MARK: - Tests
    
    /// Low E1 is ~41.2Hz. We validate that the engine can report near this range (min 30Hz support).
    static func testLowEBassDetection() throws {
        let sr = 48_000.0
        let engine = PitchDetectionEngine(sampleRate: sr)
        let target = 41.2
        let buffer = PitchDetectionTestHarness.generateSineWave(frequency: target, sampleRate: sr, durationSeconds: 1.0)
        
        let frameSize = 4096
        var t: TimeInterval = 0
        let dt = Double(frameSize) / sr
        
        var last: PitchResult?
        var offset = 0
        while offset + frameSize <= buffer.count {
            let frame = Array(buffer[offset..<(offset + frameSize)])
            last = engine.processAudioFrame(frame, timestamp: t, inputLevelDbfs: -12.0)
            offset += frameSize
            t += dt
        }
        guard let r = last else { throw Failure(message: "Low E test: no result") }
        guard let f = r.detectedFrequencyHz else { throw Failure(message: "Low E test: missing frequency") }
        guard abs(f - target) <= 1.5 else {
            throw Failure(message: "Low E test: expected ~\(target)Hz, got \(f)Hz")
        }
    }
    
    /// Construct a signal where the 2nd harmonic dominates to provoke octave errors.
    /// Expected: post-check should prefer the true fundamental when supported.
    static func testHarmonicConfusionOctaveError() throws {
        let sr = 48_000.0
        let engine = PitchDetectionEngine(sampleRate: sr)
        
        let f0 = 82.4069 // E2
        let f2 = f0 * 2.0
        let duration = 1.0
        let n = Int(sr * duration)
        var buf = [Float](repeating: 0, count: n)
        let twoPi = 2.0 * Double.pi
        for i in 0..<n {
            let t = Double(i) / sr
            // Dominant harmonic at 2*f0, weaker fundamental.
            let x = 0.25 * sin(twoPi * f0 * t) + 1.0 * sin(twoPi * f2 * t)
            buf[i] = Float(x)
        }
        
        let frameSize = 4096
        var t: TimeInterval = 0
        let dt = Double(frameSize) / sr
        
        var last: PitchResult?
        var offset = 0
        while offset + frameSize <= buf.count {
            let frame = Array(buf[offset..<(offset + frameSize)])
            last = engine.processAudioFrame(frame, timestamp: t, inputLevelDbfs: -10.0)
            offset += frameSize
            t += dt
        }
        guard let r = last else { throw Failure(message: "Harmonic confusion test: no result") }
        
        // Accept either exact f0 or close neighborhood; should not lock to 2*f0.
        guard let f = r.detectedFrequencyHz else { throw Failure(message: "Harmonic confusion test: missing frequency") }
        let errF0 = abs(f - f0)
        let errF2 = abs(f - f2)
        guard errF0 < errF2 else {
            throw Failure(message: "Harmonic confusion test: expected fundamental near \(f0)Hz, got \(f)Hz (closer to \(f2)Hz)")
        }
    }
    
    /// Simulate a noisy environment with no strong pitch. The adaptive noise floor should
    /// prevent constant false 'non-silence' behavior and should emit silence state.
    static func testSilenceWithNoisyBackground() throws {
        let sr = 48_000.0
        let engine = PitchDetectionEngine(sampleRate: sr)
        
        // Background noise at around -45 dBFS RMS.
        let duration = 1.0
        let n = Int(sr * duration)
        var buf = [Float](repeating: 0, count: n)
        var seed: UInt64 = 0x12345678abcdef
        func nextRand() -> Double {
            // xorshift64*
            seed ^= seed >> 12
            seed ^= seed << 25
            seed ^= seed >> 27
            let x = seed &* 2685821657736338717
            return Double(x % 10_000) / 10_000.0
        }
        // Uniform-ish noise, scaled down.
        for i in 0..<n {
            let u = nextRand() * 2.0 - 1.0
            buf[i] = Float(u * 0.006) // ~ -44..-46 dBFS RMS-ish
        }
        
        let frameSize = 4096
        var t: TimeInterval = 0
        let dt = Double(frameSize) / sr
        
        var sawSilence = false
        var offset = 0
        while offset + frameSize <= buf.count {
            let frame = Array(buf[offset..<(offset + frameSize)])
            let rr = engine.processAudioFrame(frame, timestamp: t, inputLevelDbfs: nil)
            if let rr, rr.tuningState == .silence {
                sawSilence = true
                break
            }
            offset += frameSize
            t += dt
        }
        
        guard sawSilence else {
            throw Failure(message: "Noisy silence test: expected at least one .silence result")
        }
    }
    
    /// When stable, tiny cents movements (<= dead zone) should not jitter the output.
    static func testStableDeadZone() throws {
        let sr = 48_000.0
        let engine = PitchDetectionEngine(sampleRate: sr)
        
        let base = 440.0
        let tinyCents = 1.0
        let detuned = base * pow(2.0, tinyCents / 1200.0)
        
        let baseBuf = PitchDetectionTestHarness.generateSineWave(frequency: base, sampleRate: sr, durationSeconds: 0.6)
        let detuneBuf = PitchDetectionTestHarness.generateSineWave(frequency: detuned, sampleRate: sr, durationSeconds: 0.6)
        
        let frameSize = 4096
        let dt = Double(frameSize) / sr
        var t: TimeInterval = 0
        
        func run(_ buf: [Float]) -> [PitchResult] {
            var out: [PitchResult] = []
            var offset = 0
            while offset + frameSize <= buf.count {
                let frame = Array(buf[offset..<(offset + frameSize)])
                if let r = engine.processAudioFrame(frame, timestamp: t, inputLevelDbfs: -12.0) {
                    out.append(r)
                }
                offset += frameSize
                t += dt
            }
            return out
        }
        
        _ = run(baseBuf)
        let after = run(detuneBuf)
        
        // Find a stable sample and ensure frequency didn't jump significantly.
        let stableSamples = after.filter { $0.isStable }
        guard let s = stableSamples.last else {
            throw Failure(message: "Dead zone test: expected stable samples")
        }
        guard let f = s.detectedFrequencyHz else { throw Failure(message: "Dead zone test: missing frequency") }
        guard abs(f - base) < 0.8 else {
            throw Failure(message: "Dead zone test: expected stable readout near \(base)Hz, got \(f)Hz")
        }
    }
    
    /// Clean tone should reach stability faster than a jittery tone (adaptive stability window).
    static func testAdaptiveStabilityWindowFasterOnCleanTone() throws {
        let sr = 48_000.0
        let clean = PitchDetectionEngine(sampleRate: sr)
        let jittery = PitchDetectionEngine(sampleRate: sr)
        
        let base = 220.0
        let duration = 1.0
        let n = Int(sr * duration)
        let twoPi = 2.0 * Double.pi
        
        var cleanBuf = [Float](repeating: 0, count: n)
        var jitterBuf = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sr
            cleanBuf[i] = Float(sin(twoPi * base * t))
            
            // Inject slow cents wobble (~±15 cents) to increase variance.
            let wobbleCents = 15.0 * sin(twoPi * 2.0 * t)
            let f = base * pow(2.0, wobbleCents / 1200.0)
            jitterBuf[i] = Float(sin(twoPi * f * t))
        }
        
        let frameSize = 4096
        let dt = Double(frameSize) / sr
        
        func timeToStable(_ engine: PitchDetectionEngine, _ buf: [Float]) -> TimeInterval? {
            var t: TimeInterval = 0
            var offset = 0
            while offset + frameSize <= buf.count {
                let frame = Array(buf[offset..<(offset + frameSize)])
                if let r = engine.processAudioFrame(frame, timestamp: t, inputLevelDbfs: -12.0), r.isStable {
                    return t
                }
                offset += frameSize
                t += dt
            }
            return nil
        }
        
        guard let tClean = timeToStable(clean, cleanBuf) else {
            throw Failure(message: "Adaptive stability test: clean tone never stabilized")
        }
        guard let tJitter = timeToStable(jittery, jitterBuf) else {
            throw Failure(message: "Adaptive stability test: jittery tone never stabilized (unexpected)")
        }
        
        guard tClean < tJitter else {
            throw Failure(message: "Adaptive stability test: expected clean to stabilize faster (clean=\(tClean)s, jitter=\(tJitter)s)")
        }
    }
    
    static func testStabilityRestartsOnWideCentsSpread() throws {
        let s = StabilityLogic()
        let note = "A"
        let octave = 4
        
        // Feed same note but with a spread exceeding allowed range; stability should never lock using stale window.
        var t: TimeInterval = 0
        let dt: TimeInterval = 0.020
        let required: TimeInterval = 0.100
        
        // First half: oscillate beyond allowed spread (±10 cents).
        for i in 0..<8 {
            let cents = (i % 2 == 0) ? -10.0 : 10.0
            let stable = s.update(noteName: note, octave: octave, centsOffset: cents, timestamp: t, requiredStableDuration: required)
            if stable {
                throw Failure(message: "Stability restart test: should not become stable during wide spread")
            }
            t += dt
        }
        
        // Then tighten within ±1 cents; should lock after required duration from the restart point.
        var locked = false
        for _ in 0..<10 {
            locked = s.update(noteName: note, octave: octave, centsOffset: 0.5, timestamp: t, requiredStableDuration: required)
            t += dt
            if locked { break }
        }
        guard locked else {
            throw Failure(message: "Stability restart test: expected to lock after returning to tight cents")
        }
    }
    
    static func testSmoothingResetsOnLargePitchJump() throws {
        let sr = 48_000.0
        let engine = PitchDetectionEngine(sampleRate: sr)
        
        let a = PitchDetectionTestHarness.generateSineWave(frequency: 220.0, sampleRate: sr, durationSeconds: 0.5)
        let b = PitchDetectionTestHarness.generateSineWave(frequency: 330.0, sampleRate: sr, durationSeconds: 0.5) // ~ +702 cents
        
        let frameSize = 4096
        let dt = Double(frameSize) / sr
        var t: TimeInterval = 0
        
        func runLast(_ buf: [Float]) -> PitchResult? {
            var last: PitchResult?
            var offset = 0
            while offset + frameSize <= buf.count {
                let frame = Array(buf[offset..<(offset + frameSize)])
                last = engine.processAudioFrame(frame, timestamp: t, inputLevelDbfs: -12.0)
                offset += frameSize
                t += dt
            }
            return last
        }
        
        _ = runLast(a)
        let firstAfterJump = engine.processAudioFrame(Array(b[0..<frameSize]), timestamp: t, inputLevelDbfs: -12.0)
        guard let r = firstAfterJump, let f = r.detectedFrequencyHz else {
            throw Failure(message: "Smoothing reset test: expected frequency after jump")
        }
        // With smoothing reseed, we should be close to the new frequency quickly (within ~10Hz for one frame).
        guard abs(f - 330.0) < 10.0 else {
            throw Failure(message: "Smoothing reset test: expected fast response near 330Hz, got \(f)Hz")
        }
    }
    
    static func testEmitterPayloadContainsStateAndCleanSilence() throws {
        // Silence-style result should produce null note fields and explicit state.
        let silence = PitchResult(
            detectedFrequencyHz: nil,
            noteName: nil,
            octave: nil,
            centsOffset: nil,
            confidence: 0,
            inputLevelDbfs: -60,
            isStable: false,
            tuningState: .silence
        )
        let payload = TunerPitchEmitter.makePayload(result: silence)
        guard payload["isStable"] as? Bool == false else { throw Failure(message: "Emitter payload test: missing/invalid isStable") }
        guard payload["tuningState"] as? String == "silence" else { throw Failure(message: "Emitter payload test: missing/invalid tuningState") }
        guard payload["noteName"] == nil else { throw Failure(message: "Emitter payload test: silence noteName should be nil") }
        guard payload["centsOffset"] == nil else { throw Failure(message: "Emitter payload test: silence centsOffset should be nil") }
        
        // Legacy detectedFrequency remains present as number for compatibility.
        guard (payload["detectedFrequency"] as? Double) == 0 else { throw Failure(message: "Emitter payload test: expected legacy detectedFrequency=0") }
    }
}

