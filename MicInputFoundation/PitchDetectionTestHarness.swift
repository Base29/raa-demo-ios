import Foundation

/// Simple offline harness utilities for validating the pitch engine.
enum PitchDetectionTestHarness {
    
    /// Generate a mono sine wave buffer at a given frequency.
    static func generateSineWave(
        frequency: Double,
        sampleRate: Double,
        durationSeconds: Double
    ) -> [Float] {
        let totalSamples = Int(sampleRate * durationSeconds)
        var buffer = [Float](repeating: 0, count: totalSamples)
        let twoPi = 2.0 * Double.pi
        for i in 0..<totalSamples {
            let t = Double(i) / sampleRate
            buffer[i] = Float(sin(twoPi * frequency * t))
        }
        return buffer
    }
    
    /// Run a basic detection on a synthetic sine wave and return the last result.
    static func runBasicDetection(
        frequency: Double,
        sampleRate: Double = 48000,
        durationSeconds: Double = 0.5
    ) -> PitchResult? {
        let engine = PitchDetectionEngine(sampleRate: sampleRate)
        let buffer = generateSineWave(
            frequency: frequency,
            sampleRate: sampleRate,
            durationSeconds: durationSeconds
        )
        
        // Use a modest frame size compatible with existing pipeline.
        let frameSize = 2048
        var offset = 0
        var timestamp: TimeInterval = 0
        let frameDuration = Double(frameSize) / sampleRate
        var lastResult: PitchResult?
        
        while offset + frameSize <= buffer.count {
            let frame = Array(buffer[offset..<(offset + frameSize)])
            lastResult = engine.processAudioFrame(
                frame,
                timestamp: timestamp,
                inputLevelDbfs: nil
            )
            offset += frameSize
            timestamp += frameDuration
        }
        
        return lastResult
    }
    
    /// Quick NoteMapper checks to be called from a unit test target.
    static func debugNoteMapperChecks() {
        let a4 = NoteMapper.mapFrequency(440.0, calibrationA4: 440.0)
        print("A4 -> note=\(a4.noteName)\(a4.octave), cents=\(a4.centsOffset)")
        
        let c4 = NoteMapper.mapFrequency(261.63, calibrationA4: 440.0)
        print("C4 -> note=\(c4.noteName)\(c4.octave), cents=\(c4.centsOffset)")
    }
}

