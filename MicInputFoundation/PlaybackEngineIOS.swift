import Foundation
import AVFoundation

/**
 * PlaybackEngineIOS
 * 
 * Native Swift playback implementation using AVFoundation.
 * Supports trimStart and trimEnd metadata.
 */
public class PlaybackEngineIOS: NSObject {
    
    public static let shared = PlaybackEngineIOS()
    
    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?
    
    private var trimStart: Double = 0
    private var trimEnd: Double = 0
    
    private enum PlaybackState: String {
        case idle
        case loaded
        case playing
        case paused
        case stopped
        case completed
        case interrupted
        case error
    }
    
    private var currentState: PlaybackState = .idle
    
    // Callbacks for events
    public var onProgressUpdate: ((_ currentTime: Double, _ duration: Double) -> Void)?
    public var onStateChange: ((_ state: String) -> Void)?
    public var onError: ((_ message: String) -> Void)?
    
    private override init() {
        super.init()
        setupNotifications()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        forceCleanup()
    }
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleInterruption),
                                               name: AVAudioSession.interruptionNotification,
                                               object: AVAudioSession.sharedInstance())
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleRouteChange),
                                               name: AVAudioSession.routeChangeNotification,
                                               object: AVAudioSession.sharedInstance())
    }
    
    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        
        if type == .began {
            stopForInterruption()
        }
    }
    
    @objc private func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        
        if reason == .oldDeviceUnavailable {
            // Headphones unplugged, pause playback
            pause()
        }
    }
    
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
    }
    
    private func forceCleanup() {
        stopProgressTimer()
        audioPlayer?.stop()
        audioPlayer = nil
        currentState = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    
    /**
     * Internal stop logic.
     */
    private func internalStop(silent: Bool, state: PlaybackState = .stopped) {
        stopProgressTimer()
        audioPlayer?.stop()
        audioPlayer?.currentTime = trimStart
        
        if !silent {
            currentState = state
            onStateChange?(state.rawValue)
            emitProgress()
        }
        
        // Always try to deactivate session if stopping completely
        if state == .stopped || state == .interrupted || state == .error {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
    
    /**
     * Stop specifically for interruption.
     */
    public func stopForInterruption() {
        internalStop(silent: false, state: .interrupted)
    }
    
    /**
     * Load an audio file from the specified path with optional trim settings.
     */
    public func load(filePath: String, trimStart: Double = 0, trimEnd: Double = 0) throws {
        let fileURL = URL(fileURLWithPath: filePath)
        
        // Silent reset before loading
        internalStop(silent: true)
        
        do {
            try configureAudioSession()
            
            audioPlayer = try AVAudioPlayer(contentsOf: fileURL)
            guard let player = audioPlayer else {
                throw NSError(domain: "PlaybackEngineIOS", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize AVAudioPlayer"])
            }
            
            player.delegate = self
            player.prepareToPlay()
            
            self.trimStart = max(0, trimStart)
            let duration = player.duration
            self.trimEnd = (trimEnd > 0 && trimEnd <= duration) ? trimEnd : duration
            
            if self.trimStart >= self.trimEnd {
                self.trimStart = 0
            }
            
            player.currentTime = self.trimStart
            currentState = .loaded
            onStateChange?("loaded")
            emitProgress()
        } catch {
            currentState = .error
            onError?(error.localizedDescription)
            throw error
        }
    }
    
    /**
     * Start or resume playback.
     */
    public func play() {
        guard let player = audioPlayer, currentState != .idle && currentState != .error else {
            onError?("Cannot play: No file loaded")
            return
        }
        
        do {
            try configureAudioSession()
        } catch {
            onError?(error.localizedDescription)
            return
        }
        
        // Always seek to trimStart for deterministic behavior if at or before trimStart
        if player.currentTime < trimStart || player.currentTime >= trimEnd {
            player.currentTime = trimStart
        }
        
        if player.play() {
            currentState = .playing
            onStateChange?("playing")
            startProgressTimer()
        } else {
            currentState = .error
            onError?("Failed to start playback")
        }
    }
    
    /**
     * Pause playback.
     */
    public func pause() {
        guard let player = audioPlayer, currentState == .playing else { return }
        player.pause()
        currentState = .paused
        onStateChange?("paused")
        stopProgressTimer()
    }
    
    /**
     * Stop playback and reset position.
     */
    public func stop() {
        internalStop(silent: false, state: .stopped)
    }
    
    /**
     * Seek to a specific position in seconds.
     */
    public func seek(to position: Double) {
        guard let player = audioPlayer, currentState != .idle && currentState != .error else {
            onError?("Cannot seek: No file loaded")
            return
        }
        
        // Clamp within trim bounds
        let absolutePosition = max(trimStart, min(trimEnd, trimStart + position))
        player.currentTime = absolutePosition
        emitProgress()
    }
    
    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.audioPlayer, self.currentState == .playing else { return }
            
            // Check if reached trimEnd
            if player.currentTime >= self.trimEnd {
                self.handlePlaybackCompletion()
                return
            }
            
            self.emitProgress()
        }
    }
    
    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
    
    private func handlePlaybackCompletion() {
        guard currentState != .completed else { return }
        
        stopProgressTimer()
        audioPlayer?.pause()
        audioPlayer?.currentTime = trimEnd
        emitProgress()
        
        currentState = .completed
        onStateChange?("completed")
        
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    
    private func emitProgress() {
        guard let player = audioPlayer else { 
            onProgressUpdate?(0, 0)
            return 
        }
        
        let relativeCurrentTime = max(0, player.currentTime - trimStart)
        let relativeDuration = max(0, trimEnd - trimStart)
        
        onProgressUpdate?(relativeCurrentTime, relativeDuration)
    }
}

extension PlaybackEngineIOS: AVAudioPlayerDelegate {
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        handlePlaybackCompletion()
    }
    
    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        currentState = .error
        onError?(error?.localizedDescription ?? "Decode error occurred")
        internalStop(silent: true)
    }
}

