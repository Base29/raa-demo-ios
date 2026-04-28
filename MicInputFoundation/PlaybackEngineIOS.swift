import Foundation
import AVFoundation

/**
 * PlaybackEngineIOS
 * 
 * Native Swift playback implementation using AVFoundation.
 * Supports trimStart and trimEnd metadata.
 */
public class PlaybackEngineIOS: NSObject {
    
    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?
    
    private var trimStart: Double = 0
    private var trimEnd: Double = 0
    
    // Callbacks for events
    public var onProgressUpdate: ((_ currentTime: Double, _ duration: Double) -> Void)?
    public var onStateChange: ((_ state: String) -> Void)?
    
    /**
     * Load an audio file from the specified path with optional trim settings.
     */
    public func load(filePath: String, trimStart: Double = 0, trimEnd: Double = 0) throws {
        let fileURL = URL(fileURLWithPath: filePath)
        
        // Stop current playback if any
        stop()
        
        audioPlayer = try AVAudioPlayer(contentsOf: fileURL)
        audioPlayer?.delegate = self
        audioPlayer?.prepareToPlay()
        
        self.trimStart = trimStart
        self.trimEnd = trimEnd > 0 ? trimEnd : (audioPlayer?.duration ?? 0)
        
        onStateChange?("loaded")
        emitProgress()
    }
    
    /**
     * Start or resume playback.
     */
    public func play() {
        guard let player = audioPlayer else { return }
        
        // If current position is outside trim bounds, seek to trimStart
        if player.currentTime < trimStart || (trimEnd > 0 && player.currentTime >= trimEnd) {
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
        audioPlayer?.pause()
        onStateChange?("paused")
        stopProgressTimer()
    }
    
    /**
     * Stop playback and reset position.
     */
    public func stop() {
        audioPlayer?.stop()
        audioPlayer?.currentTime = 0
        onStateChange?("stopped")
        stopProgressTimer()
        emitProgress()
    }
    
    /**
     * Seek to a specific position in seconds.
     */
    public func seek(to position: Double) {
        audioPlayer?.currentTime = position
        emitProgress()
    }
    
    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.audioPlayer else { return }
            
            // Check if reached trimEnd
            if self.trimEnd > 0 && player.currentTime >= self.trimEnd {
                self.stop()
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
        guard let player = audioPlayer else { return }
        onProgressUpdate?(player.currentTime, player.duration)
    }
}

extension PlaybackEngineIOS: AVAudioPlayerDelegate {
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stopProgressTimer()
        onStateChange?("completed")
    }
    
    public func audioPlayerBeginInterruption(_ player: AVAudioPlayer) {
        stop()
    }
}
