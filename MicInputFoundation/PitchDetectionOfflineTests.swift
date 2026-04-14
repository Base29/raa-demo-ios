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
        guard abs(r.detectedFrequencyHz - target) <= 1.5 else {
            throw Failure(message: "Low E test: expected ~\(target)Hz, got \(r.detectedFrequencyHz)Hz")
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
        let errF0 = abs(r.detectedFrequencyHz - f0)
        let errF2 = abs(r.detectedFrequencyHz - f2)
        guard errF0 < errF2 else {
            throw Failure(message: "Harmonic confusion test: expected fundamental near \(f0)Hz, got \(r.detectedFrequencyHz)Hz (closer to \(f2)Hz)")
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
            let r = engine.processAudioFrame(frame, timestamp: t, inputLevelDbfs: nil)
            if let rr = r, rr.tuningState == .silence {
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
        guard abs(s.detectedFrequencyHz - base) < 0.8 else {
            throw Failure(message: "Dead zone test: expected stable readout near \(base)Hz, got \(s.detectedFrequencyHz)Hz")
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
}

