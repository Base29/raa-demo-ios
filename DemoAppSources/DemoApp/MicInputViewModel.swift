import Foundation
import AVFoundation
import Combine

class MicInputViewModel: ObservableObject {
    @Published var sampleRate: Int = 0
    @Published var channels: Int = 0
    @Published var bufferSize: Int = 0
    @Published var totalFramesReceived: Int64 = 0
    @Published var isRunning: Bool = false
    @Published var permissionDenied: Bool = false
    
    private var micInput: MicInputIOS?
    private var updateTimer: Timer?
    
    // Thread-safe atomic counter for frames
    // Using OSAtomicIncrement64 for lock-free atomic operations
    private var atomicFrameCounter: UnsafeMutablePointer<Int64> = {
        let ptr = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
        ptr.pointee = 0
        return ptr
    }()
    
    init() {
        // Initialize with default config values
        sampleRate = 48000
        channels = 1
        bufferSize = 1024
    }
    
    deinit {
        atomicFrameCounter.deallocate()
        updateTimer?.invalidate()
    }
    
    func checkPermission() {
        let audioSession = AVAudioSession.sharedInstance()
        let permissionStatus = audioSession.recordPermission
        
        DispatchQueue.main.async {
            if permissionStatus == .denied {
                self.permissionDenied = true
            } else if permissionStatus == .undetermined {
                // Request permission
                audioSession.requestRecordPermission { [weak self] granted in
                    DispatchQueue.main.async {
                        self?.permissionDenied = !granted
                    }
                }
            } else {
                self.permissionDenied = false
            }
        }
    }
    
    func startCapture() {
        guard !isRunning else { return }
        guard !permissionDenied else { return }
        
        // Reset frame counter atomically (on main thread before capture starts, so direct write is safe)
        atomicFrameCounter.pointee = 0
        totalFramesReceived = 0
        
        // Create mic input instance
        micInput = MicInputIOS()
        
        // Create configuration
        let config = MicInputConfig(
            sampleRate: 48000,
            channels: 1,
            bufferSize: 1024
        )
        
        // Define PCM callback - this runs in real-time audio thread
        // DO NOT allocate, log, or block here
        let onPCM: PCMCallback = { [weak self] (samples, frameCount) in
            guard let self = self else { return }
            
            // Atomically increment frame counter (lock-free, no allocation)
            OSAtomicAdd64Barrier(Int64(frameCount), self.atomicFrameCounter)
        }
        
        do {
            // Start capture
            try micInput?.start(config: config, onPCM: onPCM)
            
            // Update UI with actual config (may differ from requested due to fallback)
            if let actualConfig = getActualConfig() {
                DispatchQueue.main.async {
                    self.sampleRate = actualConfig.sampleRate
                    self.channels = actualConfig.channels
                    self.bufferSize = actualConfig.bufferSize
                    self.isRunning = true
                }
            } else {
                DispatchQueue.main.async {
                    self.sampleRate = config.sampleRate
                    self.channels = config.channels
                    self.bufferSize = config.bufferSize
                    self.isRunning = true
                }
            }
            
            // Start UI update timer (runs on main thread)
            startUpdateTimer()
            
        } catch {
            DispatchQueue.main.async {
                self.isRunning = false
                if let micError = error as? MicInputException,
                   micError.errorType == .permissionDenied {
                    self.permissionDenied = true
                }
                print("Failed to start capture: \(error.localizedDescription)")
            }
        }
    }
    
    func stopCapture() {
        guard isRunning else { return }
        
        // Stop timer
        stopUpdateTimer()
        
        // Stop capture
        do {
            try micInput?.stop()
        } catch {
            print("Failed to stop capture: \(error.localizedDescription)")
        }
        
        // Update UI
        DispatchQueue.main.async {
            self.isRunning = false
            self.micInput = nil
        }
    }
    
    private func getActualConfig() -> MicInputConfig? {
        // The actual config is stored internally in MicInputIOS
        // For simplicity, we'll use the requested config
        // In a real implementation, you might want to expose this from MicInputIOS
        return nil
    }
    
    private func startUpdateTimer() {
        stopUpdateTimer() // Ensure no duplicate timers
        
        // Update UI every 250ms on main thread
        // Timer.scheduledTimer runs on the current RunLoop (main thread by default)
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            // Atomically read frame counter (lock-free)
            // OSAtomicAdd64Barrier with 0 adds 0 and returns the current value
            let currentFrames = OSAtomicAdd64Barrier(0, self.atomicFrameCounter)
            
            // Update published property (already on main thread from Timer)
            self.totalFramesReceived = currentFrames
        }
    }
    
    private func stopUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }
}
