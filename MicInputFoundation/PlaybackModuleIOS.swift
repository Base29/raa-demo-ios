import Foundation
import React

@objc(PlaybackModuleIOS)
public class PlaybackModuleIOS: RCTEventEmitter {
    
    private let playback = PlaybackEngineIOS.shared
    private var hasListeners = false
    
    // Module-level state tracking for deterministic behavior
    private var isLoaded: Bool = false
    private var isPlaying: Bool = false
    
    public override init() {
        super.init()
        setupCallbacks()
    }
    
    deinit {
        cleanup()
    }
    
    public override func invalidate() {
        super.invalidate()
        cleanup()
    }
    
    private func cleanup() {
        playback.stop()
        playback.onProgressUpdate = nil
        playback.onStateChange = nil
        playback.onError = nil
    }
    
    private func setupCallbacks() {
        playback.onProgressUpdate = { [weak self] currentTime, duration in
            self?.sendEventOnMain(withName: "Playback:onPosition", body: [
                "currentTime": currentTime,
                "duration": duration
            ])
        }
        
        playback.onStateChange = { [weak self] state in
            guard let self = self else { return }
            
            // Update internal state tracking
            if state == "playing" {
                self.isPlaying = true
            } else if state == "paused" || state == "stopped" || state == "completed" || state == "interrupted" || state == "error" {
                self.isPlaying = false
            }
            
            if state == "loaded" {
                self.isLoaded = true
            } else if state == "idle" || state == "error" {
                self.isLoaded = false
                self.isPlaying = false
            }
            
            self.sendEventOnMain(withName: "Playback:onState", body: [
                "state": state
            ])
        }
        
        playback.onError = { [weak self] message in
            self?.sendEventOnMain(withName: "Playback:onError", body: [
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
            "Playback:onPosition",
            "Playback:onState",
            "Playback:onError"
        ]
    }
    
    @objc(load:options:resolver:rejecter:)
    public func load(filePath: String, options: [String: Any]?, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        let trimStart = options?["trimStart"] as? Double ?? 0
        let trimEnd = options?["trimEnd"] as? Double ?? 0
        
        do {
            try playback.load(filePath: filePath, trimStart: trimStart, trimEnd: trimEnd)
            resolve(nil)
        } catch {
            reject("PLAYBACK_ERROR", error.localizedDescription, error)
        }
    }
    
    @objc(play:resolver:rejecter:)
    public func play(options: [String: Any]?, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard isLoaded else {
            reject("PLAYBACK_ERROR", "Cannot play: No file loaded", nil)
            return
        }
        playback.play()
        resolve(nil)
    }
    
    @objc(pause:resolver:rejecter:)
    public func pause(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard isPlaying else {
            // Already paused or not playing, resolve silently but maybe check if loaded
            resolve(nil)
            return
        }
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
        guard isLoaded else {
            reject("PLAYBACK_ERROR", "Cannot seek: No file loaded", nil)
            return
        }
        playback.seek(to: positionInSeconds)
        resolve(nil)
    }
    
    public override static func requiresMainQueueSetup() -> Bool {
        return false
    }
}
