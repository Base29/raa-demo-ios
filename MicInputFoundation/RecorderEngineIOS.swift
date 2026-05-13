import Foundation
import AVFoundation

/**
 * RecorderEngineIOS
 * 
 * Native Swift recorder implementation using AVFoundation.
 * Configured for AAC .m4a, Mono, 44.1 kHz, 128 kbps.
 */
public class RecorderEngineIOS: NSObject {
    
    private var audioRecorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var isRecording: Bool = false
    
    // Callbacks for events
    public var onMeterUpdate: ((_ rmsDb: Float, _ peakDb: Float) -> Void)?
    public var onDurationUpdate: ((_ duration: Double) -> Void)?
    public var onStateChange: ((_ state: String) -> Void)?
    public var onError: ((_ message: String) -> Void)?
    
    public override init() {
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
    }
    
    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        
        if type == .began {
            if isRecording {
                finalizeInterruptedRecording()
            }
        }
    }
    
    /**
     * Force cleanup of all resources without emitting events.
     */
    public func forceCleanup() {
        safeStopRecorder(emitState: false)
    }
    
    /**
     * Internal flow to finalize an interrupted recording without double-emitting events.
     */
    private func finalizeInterruptedRecording() {
        // Use "interrupted" state instead of "stopped"
        safeStopRecorder(emitState: true, state: "interrupted")
    }
    
    /**
     * Centralized stop logic to ensure consistency and safety.
     * Guaranteed to clear all references and deactivate session.
     */
    private func safeStopRecorder(emitState: Bool, state: String = "stopped") {
        stopMetering()
        
        if let recorder = audioRecorder {
            // Guard against stopping too soon or crashes during stop
            if recorder.isRecording {
                recorder.stop()
            }
        }
        
        audioRecorder = nil
        isRecording = false
        
        if emitState {
            onStateChange?(state)
        }
        
        // Always deactivate session safely
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    
    /**
     * Start recording to the specified file path.
     */
    public func startRecording(filePath: String) throws {
        if isRecording {
            throw NSError(domain: "RecorderEngineIOS", code: 2, userInfo: [NSLocalizedDescriptionKey: "Recording is already in progress"])
        }
        
        // Ensure clean state before starting
        forceCleanup()
        
        let fileURL = URL(fileURLWithPath: filePath)
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            // Setup Audio Session
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
            try session.setActive(true)
            
            audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
            guard let recorder = audioRecorder else {
                throw NSError(domain: "RecorderEngineIOS", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize AVAudioRecorder"])
            }
            
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            
            if recorder.prepareToRecord() {
                recorder.record()
                isRecording = true
                onStateChange?("recording")
                startMetering()
            } else {
                throw NSError(domain: "RecorderEngineIOS", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare recording"])
            }
        } catch {
            let errorMsg = error.localizedDescription
            onError?(errorMsg)
            forceCleanup() // Ensure session is deactivated and state is cleared
            throw error
        }
    }
    
    /**
     * Stop recording and return the file path.
     */
    public func stopRecording() -> String? {
        guard isRecording, let recorder = audioRecorder else {
            return nil
        }
        
        let path = recorder.url.path
        safeStopRecorder(emitState: true, state: "stopped")
        return path
    }
    
    private func startMetering() {
        stopMetering()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let recorder = self.audioRecorder, self.isRecording, recorder.isRecording else { return }
            
            recorder.updateMeters()
            let rawRms = recorder.averagePower(forChannel: 0)
            let rawPeak = recorder.peakPower(forChannel: 0)
            
            // Clamp to [-60, 0] as per requirements
            let rmsDb = max(-60.0, min(0.0, rawRms))
            let peakDb = max(-60.0, min(0.0, rawPeak))
            
            self.onMeterUpdate?(rmsDb, peakDb)
            self.onDurationUpdate?(recorder.currentTime)
        }
    }
    
    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
    }
}

extension RecorderEngineIOS: AVAudioRecorderDelegate {
    public func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // If isRecording is still true, it means it stopped naturally or due to error
        // but not via internalStop().
        if isRecording {
            // Requirement 1: State "stopped" should only be emitted from stopRecording().
            // So here we only clean up silently if it was already stopped via internalStop.
            // But if it finished naturally (not expected in this setup), we should still clean up.
            safeStopRecorder(emitState: false)
        }
    }
    
    public func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let errorMsg = error?.localizedDescription ?? "Encode error occurred"
        onError?(errorMsg)
        safeStopRecorder(emitState: false)
    }
}

