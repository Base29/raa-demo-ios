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
        stopMetering()
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
     * Internal flow to finalize an interrupted recording without double-emitting events.
     */
    private func finalizeInterruptedRecording() {
        guard let recorder = audioRecorder, isRecording else { return }
        
        stopMetering()
        recorder.stop()
        audioRecorder = nil
        isRecording = false
        
        onStateChange?("interrupted")
        
        // Deactivate session
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    
    /**
     * Start recording to the specified file path.
     */
    public func startRecording(filePath: String) throws {
        if isRecording {
            throw NSError(domain: "RecorderEngineIOS", code: 2, userInfo: [NSLocalizedDescriptionKey: "Recording is already in progress"])
        }
        
        let fileURL = URL(fileURLWithPath: filePath)
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        // Setup Audio Session
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try session.setActive(true)
        
        audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
        audioRecorder?.delegate = self
        audioRecorder?.isMeteringEnabled = true
        
        if audioRecorder?.prepareToRecord() == true {
            audioRecorder?.record()
            isRecording = true
            onStateChange?("recording")
            startMetering()
        } else {
            let errorMsg = "Failed to prepare recording"
            onError?(errorMsg)
            throw NSError(domain: "RecorderEngineIOS", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
    }
    
    /**
     * Stop recording and return the file path.
     */
    public func stopRecording() -> String? {
        guard let recorder = audioRecorder, isRecording else {
            return nil
        }
        
        let path = recorder.url.path
        stopMetering()
        recorder.stop()
        audioRecorder = nil
        isRecording = false
        
        onStateChange?("stopped")
        
        // Deactivate session
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        
        return path
    }
    
    private func startMetering() {
        stopMetering()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let recorder = self.audioRecorder, recorder.isRecording else { return }
            
            recorder.updateMeters()
            let rmsDb = recorder.averagePower(forChannel: 0)
            let peakDb = recorder.peakPower(forChannel: 0)
            
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
        if isRecording {
            stopMetering()
            isRecording = false
            onStateChange?("stopped")
        }
        // Clear stale reference
        audioRecorder = nil
    }
    
    public func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        stopMetering()
        isRecording = false
        onError?(error?.localizedDescription ?? "Encode error occurred")
    }
}

