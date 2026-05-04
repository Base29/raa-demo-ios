import Foundation
import React

@objc(RecorderModuleIOS)
public class RecorderModuleIOS: RCTEventEmitter {
    
    private let recorder = RecorderEngineIOS()
    private var hasListeners = false
    
    public override init() {
        super.init()
        setupCallbacks()
    }
    
    deinit {
        _ = recorder.stopRecording()
    }
    
    private func setupCallbacks() {
        recorder.onMeterUpdate = { [weak self] rmsDb, peakDb in
            self?.sendEventIfPossible(withName: "Recorder:onMeter", body: [
                "rmsDb": rmsDb,
                "peakDb": peakDb
            ])
        }
        
        recorder.onDurationUpdate = { [weak self] duration in
            self?.sendEventIfPossible(withName: "Recorder:onDuration", body: [
                "duration": duration
            ])
        }
        
        recorder.onStateChange = { [weak self] state in
            self?.sendEventIfPossible(withName: "Recorder:onState", body: [
                "state": state
            ])
        }
        
        recorder.onError = { [weak self] message in
            self?.sendEventIfPossible(withName: "Recorder:onError", body: [
                "message": message
            ])
        }
    }
    
    public override func startObserving() {
        hasListeners = true
    }
    
    public override func stopObserving() {
        hasListeners = false
    }
    
    private func sendEventIfPossible(withName name: String, body: Any!) {
        if hasListeners {
            sendEvent(withName: name, body: body)
        }
    }
    
    public override func supportedEvents() -> [String]! {
        return [
            "Recorder:onMeter",
            "Recorder:onDuration",
            "Recorder:onState",
            "Recorder:onError"
        ]
    }
    
    @objc(startRecording:resolver:rejecter:)
    public func startRecording(filePath: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        do {
            // Block playback while recording
            PlaybackEngineIOS.shared.stop()
            
            try recorder.startRecording(filePath: filePath)
            resolve(filePath)
        } catch {
            reject("RECORDER_ERROR", error.localizedDescription, error)
        }
    }
    
    @objc(stopRecording:rejecter:)
    public func stopRecording(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if let filePath = recorder.stopRecording() {
            resolve(filePath)
        } else {
            reject("RECORDER_ERROR", "No active recording to stop", nil)
        }
    }
    
    public override static func requiresMainQueueSetup() -> Bool {
        return false
    }
}
