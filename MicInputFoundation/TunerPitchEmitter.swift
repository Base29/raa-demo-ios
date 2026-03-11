import Foundation

#if canImport(React)
import React

/// React Native event emitter for stable tuner pitch results.
@objc(TunerPitchEmitter)
final class TunerPitchEmitter: RCTEventEmitter {
    
    private var hasListeners = false
    
    override static func requiresMainQueueSetup() -> Bool {
        return true
    }
    
    override func startObserving() {
        hasListeners = true
    }
    
    override func stopObserving() {
        hasListeners = false
    }
    
    override func supportedEvents() -> [String]! {
        return ["onTunerPitch"]
    }
    
    /// Emit a stable pitch result to JS.
    func emitPitchResult(_ result: PitchResult) {
        guard hasListeners else { return }
        
        let payload: [String: Any?] = [
            "detectedFrequency": result.detectedFrequencyHz,
            "noteName": result.noteName,
            "octave": result.octave,
            "centsOffset": result.centsOffset,
            "confidence": result.confidence,
            "inputLevel": result.inputLevelDbfs
        ]
        
        sendEvent(withName: "onTunerPitch", body: payload)
    }
    
    /// Emit a no-note / unstable state (e.g. silence or unstable pitch).
    func emitNoNote() {
        guard hasListeners else { return }
        
        let payload: [String: Any?] = [
            "detectedFrequency": 0,
            "noteName": nil,
            "octave": 0,
            "centsOffset": 0,
            "confidence": 0,
            "inputLevel": nil
        ]
        
        sendEvent(withName: "onTunerPitch", body: payload)
    }
}

#else

/// Stub implementation so that non-React targets (like the DemoApp)
/// can compile and still use the pitch engine without the bridge.
final class TunerPitchEmitter {
    func emitPitchResult(_ result: PitchResult) {
        // No-op in non-React builds.
    }
    
    func emitNoNote() {
        // No-op in non-React builds.
    }
}

#endif

