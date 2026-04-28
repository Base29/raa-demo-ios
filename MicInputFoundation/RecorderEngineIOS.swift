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
    private var startTime: Date?
    
    // Callbacks for events
    public var onMeterUpdate: ((_ rmsDb: Float, _ peakDb: Float) -> Void)?
    public var onDurationUpdate: ((_ duration: Double) -> Void)?
    
    /**
     * Start recording to the specified file path.
     */
    public func startRecording(filePath: String) throws {
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
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        
        audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
        audioRecorder?.delegate = self
        audioRecorder?.isMeteringEnabled = true
        
        if audioRecorder?.prepareToRecord() == true {
            audioRecorder?.record()
            startTime = Date()
            startMetering()
        } else {
            throw NSError(domain: "RecorderEngineIOS", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare recording"])
        }
    }
    
    /**
     * Stop recording and return the file path.
     */
    public func stopRecording() -> String? {
        let path = audioRecorder?.url.path
        stopMetering()
        audioRecorder?.stop()
        audioRecorder = nil
        
        // Deactivate session if needed
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        
        return path
    }
    
    private func startMetering() {
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let recorder = self.audioRecorder, recorder.isRecording else { return }
            
            recorder.updateMeters()
            let rmsDb = recorder.averagePower(forChannel: 0)
            let peakDb = recorder.peakPower(forChannel: 0)
            
            self.onMeterUpdate?(rmsDb, peakDb)
            
            if let start = self.startTime {
                let duration = Date().timeIntervalSince(start)
                self.onDurationUpdate?(duration)
            }
        }
    }
    
    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
        startTime = nil
    }
}

extension RecorderEngineIOS: AVAudioRecorderDelegate {
    public func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // Handle unexpected finish (e.g. interruption)
        if !flag {
            stopMetering()
        }
    }
    
    public func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        // Handle encode error
        stopMetering()
    }
}
