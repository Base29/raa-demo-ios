import Foundation
import React

@objc(AudioModuleIOS)
public class AudioModuleIOS: RCTEventEmitter {
    
    private let recorder = RecorderEngineIOS()
    private let playback = PlaybackEngineIOS()
    
    public override init() {
        super.init()
        setupCallbacks()
    }
    
    private func setupCallbacks() {
        // Recorder callbacks
        recorder.onMeterUpdate = { [weak self] rmsDb, peakDb in
            self?.sendEvent(withName: "onRecorderMeter", body: [
                "rmsDb": rmsDb,
                "peakDb": peakDb
            ])
        }
        
        recorder.onDurationUpdate = { [weak self] duration in
            self?.sendEvent(withName: "onRecorderDuration", body: [
                "duration": duration
            ])
        }
        
        // Playback callbacks
        playback.onProgressUpdate = { [weak self] currentTime, duration in
            self?.sendEvent(withName: "onPlaybackPosition", body: [
                "currentTime": currentTime,
                "duration": duration
            ])
        }
        
        playback.onStateChange = { [weak self] state in
            self?.sendEvent(withName: "onPlaybackState", body: [
                "state": state
            ])
        }
    }
    
    // MARK: - Supported Events
    
    public override func supportedEvents() -> [String]! {
        return [
            "onRecorderMeter",
            "onRecorderDuration",
            "onPlaybackPosition",
            "onPlaybackState"
        ]
    }
    
    // MARK: - Recorder Methods
    
    @objc(startRecording:resolver:rejecter:)
    public func startRecording(filePath: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        do {
            // Stop playback immediately if recording starts
            playback.stop()
            
            try recorder.startRecording(filePath: filePath)
            resolve(filePath)
        } catch {
            reject("RECORDER_ERROR", "Failed to start recording", error)
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
    
    // MARK: - Playback Methods
    
    @objc(load:options:resolver:rejecter:)
    public func load(filePath: String, options: [String: Any]?, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        let trimStart = options?["trimStart"] as? Double ?? 0
        let trimEnd = options?["trimEnd"] as? Double ?? 0
        
        do {
            try playback.load(filePath: filePath, trimStart: trimStart, trimEnd: trimEnd)
            resolve(nil)
        } catch {
            reject("PLAYBACK_ERROR", "Failed to load audio file", error)
        }
    }
    
    @objc(play:resolver:rejecter:)
    public func play(options: [String: Any]?, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        // If options are provided during play, update trim settings if needed
        // (Though typically handled in load, user specified options in play too)
        playback.play()
        resolve(nil)
    }
    
    @objc(pause:resolver:rejecter:)
    public func pause(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        playback.pause()
        resolve(nil)
    }
    
    @objc(stop:resolver:rejecter:)
    public func stop(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        playback.stop()
        resolve(nil)
    }
    
    @objc(seek:resolver:rejecter:)
    public func seek(positionInSeconds: Double, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        playback.seek(to: positionInSeconds)
        resolve(nil)
    }
    
    // Ensure we run on the main thread for UI/Timer related tasks if necessary, 
    // although AVFoundation is largely thread-safe.
    public override static func requiresMainQueueSetup() -> Bool {
        return true
    }
}
