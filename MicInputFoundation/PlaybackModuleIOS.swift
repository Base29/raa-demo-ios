import Foundation
import React

@objc(PlaybackModuleIOS)
public class PlaybackModuleIOS: RCTEventEmitter {
    
    private let playback = PlaybackEngineIOS.shared
    private var hasListeners = false
    
    public override init() {
        super.init()
        setupCallbacks()
    }
    
    deinit {
        playback.stop()
    }
    
    private func setupCallbacks() {
        playback.onProgressUpdate = { [weak self] currentTime, duration in
            self?.sendEventIfPossible(withName: "Playback:onPosition", body: [
                "currentTime": currentTime,
                "duration": duration
            ])
        }
        
        playback.onStateChange = { [weak self] state in
            self?.sendEventIfPossible(withName: "Playback:onState", body: [
                "state": state
            ])
        }
        
        playback.onError = { [weak self] message in
            self?.sendEventIfPossible(withName: "Playback:onError", body: [
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
    
    public override static func requiresMainQueueSetup() -> Bool {
        return false
    }
}
