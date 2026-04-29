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
    private var isLoaded: Bool = false
    
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
        stopProgressTimer()
    }
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleInterruption),
                                               name: AVAudioSession.interruptionNotification,
                                               object: AVAudioSession.sharedInstance())
    }
    
    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        
        if type == .began {
            pause()
            onStateChange?("interrupted")
        }
    }
    
    /**
     * Load an audio file from the specified path with optional trim settings.
     */
    public func load(filePath: String, trimStart: Double = 0, trimEnd: Double = 0) throws {
        let fileURL = URL(fileURLWithPath: filePath)
        
        // Stop current playback if any
        stop()
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: fileURL)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            
            self.trimStart = max(0, trimStart)
            let duration = audioPlayer?.duration ?? 0
            self.trimEnd = (trimEnd > 0 && trimEnd <= duration) ? trimEnd : duration
            
            if self.trimStart >= self.trimEnd {
                self.trimStart = 0
            }
            
            isLoaded = true
            onStateChange?("loaded")
            emitProgress()
        } catch {
            isLoaded = false
            onError?(error.localizedDescription)
            throw error
        }
    }
    
    /**
     * Start or resume playback.
     */
    public func play() {
        guard let player = audioPlayer, isLoaded else { return }
        
        // Always seek to trimStart for deterministic behavior if at or before trimStart
        if player.currentTime <= trimStart || player.currentTime >= trimEnd {
            player.currentTime = trimStart
        }
        
        player.play()
        onStateChange?("playing")
        startProgressTimer()
    }
    
    /**
     * Pause playback.
     */
    public func pause() {
        guard let player = audioPlayer, player.isPlaying else { return }
        player.pause()
        onStateChange?("paused")
        stopProgressTimer()
    }
    
    /**
     * Stop playback and reset position.
     */
    public func stop() {
        audioPlayer?.stop()
        audioPlayer?.currentTime = trimStart
        onStateChange?("stopped")
        stopProgressTimer()
        emitProgress()
    }
    
    /**
     * Seek to a specific position in seconds.
     */
    public func seek(to position: Double) {
        guard let player = audioPlayer, isLoaded else { return }
        
        // Clamp within trim bounds
        let absolutePosition = max(trimStart, min(trimEnd, trimStart + position))
        player.currentTime = absolutePosition
        emitProgress()
    }
    
    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.audioPlayer else { return }
            
            // Check if reached trimEnd
            if player.currentTime >= self.trimEnd {
                player.pause()
                player.currentTime = self.trimEnd
                self.stopProgressTimer()
                self.emitProgress()
                self.onStateChange?("completed")
                return
            }
            
            self.emitProgress()
        }
    }
    
    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
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
        stopProgressTimer()
        onStateChange?("completed")
    }
}

