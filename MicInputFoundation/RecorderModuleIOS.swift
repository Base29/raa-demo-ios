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
        cleanup()
    }
    
    public override func invalidate() {
        cleanup()
        super.invalidate()
    }
    
    private func cleanup() {
        recorder.forceCleanup()
        recorder.onMeterUpdate = nil
        recorder.onDurationUpdate = nil
        recorder.onStateChange = nil
        recorder.onError = nil
    }
    
    private func setupCallbacks() {
        recorder.onMeterUpdate = { [weak self] rmsDb, peakDb in
            guard let self = self, self.hasListeners else { return }
            self.sendEventOnMain(withName: "Recorder:onMeter", body: [
                "rmsDb": rmsDb,
                "peakDb": peakDb
            ])
        }
        
        recorder.onDurationUpdate = { [weak self] duration in
            guard let self = self, self.hasListeners else { return }
            self.sendEventOnMain(withName: "Recorder:onDuration", body: [
                "duration": duration
            ])
        }
        
        recorder.onStateChange = { [weak self] state in
            self?.sendEventOnMain(withName: "Recorder:onState", body: [
                "state": state
            ])
        }
        
        recorder.onError = { [weak self] message in
            self?.sendEventOnMain(withName: "Recorder:onError", body: [
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
    
    private func sendEventOnMain(withName name: String, body: Any!) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.hasListeners else { return }
            self.sendEvent(withName: name, body: body)
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
    
    @objc(stopRecording:resolver:rejecter:)
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
