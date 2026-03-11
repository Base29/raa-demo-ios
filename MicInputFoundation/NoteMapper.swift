import Foundation

/// Mapping result for a detected frequency.
struct NoteMapping {
    let midiNote: Int
    let noteName: String
    let octave: Int
    let centsOffset: Double
}

/// Maps raw frequencies to musical notes using 12-TET with configurable A4 calibration.
enum NoteMapper {
    
    private static let noteNames = [
        "C", "C#", "D", "D#", "E", "F",
        "F#", "G", "G#", "A", "A#", "B"
    ]
    
    /// Map a frequency in Hz to the nearest note, octave, and cents offset.
    /// - Parameters:
    ///   - frequency: Frequency in Hz.
    ///   - calibrationA4: Reference A4 frequency in Hz (default 440).
    /// - Returns: NoteMapping describing the nearest note; if frequency is non-positive, returns A4 with 0 cents.
    static func mapFrequency(_ frequency: Double, calibrationA4: Double = 440.0) -> NoteMapping {
        guard frequency > 0, calibrationA4 > 0 else {
            return NoteMapping(
                midiNote: 69,
                noteName: "A",
                octave: 4,
                centsOffset: 0
            )
        }
        
        let midi = 69.0 + 12.0 * log2(frequency / calibrationA4)
        let nearestMidi = Int(round(midi))
        let centsOffset = 100.0 * (midi - Double(nearestMidi))
        
        let noteIndex = (nearestMidi % 12 + 12) % 12
        let noteName = noteNames[noteIndex]
        let octave = (nearestMidi / 12) - 1
        
        return NoteMapping(
            midiNote: nearestMidi,
            noteName: noteName,
            octave: octave,
            centsOffset: centsOffset
        )
    }
}

