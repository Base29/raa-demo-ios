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
        cleanup()
        super.invalidate()
    }
    
    private func cleanup() {
        playback.releaseCurrentPlayerSilently()
        playback.onProgressUpdate = nil
        playback.onStateChange = nil
        playback.onError = nil
    }
    
    private func setupCallbacks() {
        playback.onProgressUpdate = { [weak self] currentTime, duration in
            guard let self = self, self.hasListeners else { return }
            self.sendEventOnMain(withName: "Playback:onPosition", body: [
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
            guard let self = self else { return }
            self.isPlaying = false
            // Note: isLoaded might still be true if the player is still valid but just errored during a seek/play
            // but for terminal errors, the engine sets state to .error which we handle in onStateChange.
            
            self.sendEventOnMain(withName: "Playback:onError", body: [
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
            isLoaded = true
            isPlaying = false
            resolve(nil)
        } catch {
            isLoaded = false
            isPlaying = false
            reject("PLAYBACK_ERROR", error.localizedDescription, error)
        }
    }
    
    @objc(play:resolver:rejecter:)
    public func play(options: [String: Any]?, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard isLoaded else {
            reject("PLAYBACK_ERROR", "Cannot play: No file loaded", nil)
            return
        }
        if playback.play() {
            isPlaying = true
            resolve(nil)
        } else {
            isPlaying = false
            reject("PLAYBACK_ERROR", "Failed to start playback", nil)
        }
    }
    
    @objc(pause:resolver:rejecter:)
    public func pause(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard isPlaying else {
            // Already paused or not playing, resolve silently but maybe check if loaded
            resolve(nil)
            return
        }
        playback.pause()
        isPlaying = false
        resolve(nil)
    }
    
    @objc(stop:resolver:rejecter:)
    public func stop(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard isLoaded else {
            resolve(nil) // Silent no-op if nothing loaded
            return
        }
        playback.stop()
        isPlaying = false
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
