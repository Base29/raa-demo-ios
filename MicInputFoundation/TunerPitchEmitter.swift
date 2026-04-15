import Foundation

#if canImport(React)
import React

/// React Native event emitter for stable tuner pitch results.
@objc(TunerPitchEmitter)
final class TunerPitchEmitter: RCTEventEmitter {
    
    enum EventName {
        /// Legacy iOS event name (kept for compatibility).
        static let legacy = "onTunerPitch"
        /// Preferred parity event name for cross-platform consumers.
        /// (JS can subscribe to either; native emits both.)
        static let parity = "onTunerPitchV2"
    }
    
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
        return [EventName.legacy, EventName.parity]
    }
    
    /// Emit a stable pitch result to JS.
    func emitPitchResult(_ result: PitchResult) {
        guard hasListeners else { return }
        
        let payload = Self.makePayload(result: result)
        sendEvent(withName: EventName.legacy, body: payload)
        sendEvent(withName: EventName.parity, body: payload)
    }
    
    /// Emit a no-note / unstable state (e.g. silence or unstable pitch).
    func emitNoNote() {
        guard hasListeners else { return }
        
        let payload = Self.makePayload(result: PitchResult(
            detectedFrequencyHz: nil,
            noteName: nil,
            octave: nil,
            centsOffset: nil,
            confidence: 0,
            inputLevelDbfs: nil,
            isStable: false,
            tuningState: .unstable
        ))
        sendEvent(withName: EventName.legacy, body: payload)
        sendEvent(withName: EventName.parity, body: payload)
    }
    
    /// Build a predictable cross-platform payload.
    /// - Important: Keeps legacy `detectedFrequency` (non-null) for older JS consumers,
    ///   while adding `frequencyHz` (nullable) as the clean representation.
    static func makePayload(result: PitchResult) -> [String: Any?] {
        let hasPitch = (result.detectedFrequencyHz ?? 0) > 0 && result.noteName != nil && result.octave != nil && result.centsOffset != nil
        return [
            // New, clean contract (preferred)
            "frequencyHz": result.detectedFrequencyHz,
            "hasPitch": hasPitch,
            "noteName": result.noteName,
            "octave": result.octave,
            "centsOffset": result.centsOffset,
            "confidence": result.confidence,
            "inputLevel": result.inputLevelDbfs,
            "isStable": result.isStable,
            "tuningState": result.tuningState.rawValue,
            
            // Legacy compatibility
            "detectedFrequency": result.detectedFrequencyHz ?? 0
        ]
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
    
    static func makePayload(result: PitchResult) -> [String: Any?] {
        // Keep behavior identical across build targets for offline tests.
        let hasPitch = (result.detectedFrequencyHz ?? 0) > 0 && result.noteName != nil && result.octave != nil && result.centsOffset != nil
        return [
            "frequencyHz": result.detectedFrequencyHz,
            "hasPitch": hasPitch,
            "noteName": result.noteName,
            "octave": result.octave,
            "centsOffset": result.centsOffset,
            "confidence": result.confidence,
            "inputLevel": result.inputLevelDbfs,
            "isStable": result.isStable,
            "tuningState": result.tuningState.rawValue,
            "detectedFrequency": result.detectedFrequencyHz ?? 0
        ]
    }
}

#endif

