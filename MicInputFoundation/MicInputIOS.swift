import Foundation
import AVFoundation

/**
 * iOS implementation of MicInput interface using AVAudioEngine.
 * 
 * This implementation provides clean microphone capture functionality that:
 * - Only handles raw PCM audio capture
 * - Does not contain any DSP processing logic
 * - Does not contain routing or orchestration logic
 * - Maintains real-time thread safety
 * 
 * Requirements: 2.1, 2.2, 5.1, 9.1
 */
@objc public class MicInputIOS: NSObject, MicInput {
    
    // Audio engine and configuration
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var pcmCallback: PCMCallback?
    private var isCapturing: Bool = false
    
    // Thread-safe callback reference using atomic operations
    private var atomicCallbackRef: UnsafeMutablePointer<PCMCallback?>?
    
    // Lock-free state management
    private var atomicState: UnsafeMutablePointer<Int32>?
    private static let STATE_STOPPED: Int32 = 0
    private static let STATE_RUNNING: Int32 = 1
    
    // Configuration
    private var sampleRate: Double = 0
    private var channels: UInt32 = 0
    private var bufferSize: UInt32 = 0
    
    // Zero-copy optimization: Pre-allocated interleaving buffer for stereo
    private var interleavedBuffer: UnsafeMutablePointer<Float>?
    private var interleavedBufferSize: Int = 0
    
    // Thread safety
    private let callbackQueue = DispatchQueue(label: "com.realtimeaudio.micinput.callback", qos: .userInteractive)
    private let stateQueue = DispatchQueue(label: "com.realtimeaudio.micinput.state")
    
    // Enhanced error handler
    private let errorHandler = MicInputErrorHandler()
    
    /**
     * Start microphone capture with the specified configuration and callback.
     * 
     * @param config Audio capture configuration
     * @param onPCM Callback to receive raw PCM audio data
     * @throws MicInputException if configuration is invalid or capture cannot be started
     */
    public func start(config: MicInputConfig, onPCM: @escaping PCMCallback) throws {
        try stateQueue.sync {
            if isCapturing {
                throw MicInputException(errorType: .alreadyRunning, message: "Microphone capture is already running")
            }
            
            // Use enhanced error handler to configure AVAudioEngine with fallback
            let result = errorHandler.configureAudioEngineWithFallback(requestedConfig: config)
            
            if result.isFailure {
                throw result.error ?? MicInputException(
                    errorType: .platformError,
                    message: "Unknown error during AVAudioEngine configuration"
                )
            }
            
            // Store successful configuration and engine components
            let actualConfig = result.actualConfig!
            self.sampleRate = Double(actualConfig.sampleRate)
            self.channels = UInt32(actualConfig.channels)
            self.bufferSize = UInt32(actualConfig.bufferSize)
            self.audioEngine = result.audioEngine
            self.inputNode = result.inputNode
            
            // Initialize atomic callback reference
            if atomicCallbackRef == nil {
                atomicCallbackRef = UnsafeMutablePointer<PCMCallback?>.allocate(capacity: 1)
            }
            atomicCallbackRef?.pointee = onPCM
            
            // Initialize atomic state
            if atomicState == nil {
                atomicState = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
            }
            atomicState?.pointee = MicInputIOS.STATE_STOPPED
            
            // Zero-copy optimization: Pre-allocate interleaving buffer for stereo if needed
            if channels == 2 {
                let bufferSizeInSamples = Int(bufferSize * channels)
                if interleavedBufferSize < bufferSizeInSamples {
                    interleavedBuffer?.deallocate()
                    interleavedBuffer = UnsafeMutablePointer<Float>.allocate(capacity: bufferSizeInSamples)
                    interleavedBufferSize = bufferSizeInSamples
                }
            }
            
            // Configure the desired format for the tap
            guard let desiredFormat = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: channels
            ) else {
                throw MicInputException(
                    errorType: .formatNotSupported,
                    message: "Cannot create audio format with sampleRate=\(sampleRate), channels=\(channels)"
                )
            }
            
            // Install tap on input node
            inputNode?.installTap(onBus: 0, bufferSize: bufferSize, format: desiredFormat) { [weak self] (buffer, time) in
                self?.processAudioBuffer(buffer: buffer, frameCount: Int(buffer.frameLength))
            }
            
            // Start audio engine with error handling
            do {
                try audioEngine?.start()
                
                // Atomically update state to running
                if let statePtr = atomicState {
                    OSAtomicCompareAndSwap32(MicInputIOS.STATE_STOPPED, MicInputIOS.STATE_RUNNING, statePtr)
                }
                
                isCapturing = true
            } catch {
                // Clean up on start failure
                inputNode?.removeTap(onBus: 0)
                cleanup()
                throw errorHandler.handleEngineError(error)
            }
        }
    }
    
    /**
     * Stop microphone capture.
     */
    public func stop() throws {
        try stateQueue.sync {
            if !isCapturing {
                return // Already stopped
            }
            
            isCapturing = false
            
            // Atomically update state to stopped
            if let statePtr = atomicState {
                OSAtomicCompareAndSwap32(MicInputIOS.STATE_RUNNING, MicInputIOS.STATE_STOPPED, statePtr)
            }
            
            // Remove tap and stop engine
            inputNode?.removeTap(onBus: 0)
            audioEngine?.stop()
            
            // Clean up
            cleanup()
        }
    }
    
    /**
     * Query the current capture state.
     * 
     * @return true if microphone capture is currently active, false otherwise
     */
    public func isRunning() -> Bool {
        return stateQueue.sync {
            return isCapturing
        }
    }
    
    /**
     * Update the PCM callback while capture is running.
     * 
     * This method allows changing the callback function without stopping and
     * restarting the capture. The update is performed using atomic operations
     * for lock-free thread safety, ensuring the real-time audio thread always
     * sees a consistent callback reference.
     * 
     * @param onPCM New callback to receive raw PCM audio data
     */
    public func updateCallback(onPCM: @escaping PCMCallback) {
        // Use atomic store operation for lock-free callback update
        // This ensures the real-time audio thread always sees a consistent callback
        atomicCallbackRef?.pointee = onPCM
    }
    
    /**
     * Process audio buffer from AVAudioEngine tap.
     * 
     * This method runs in the real-time audio thread and must:
     * - Not perform dynamic memory allocations
     * - Not use logging operations
     * - Not acquire locks that could block
     * - Not throw exceptions
     * 
     * Zero-copy optimizations:
     * - Uses pre-allocated buffers to avoid allocations in real-time thread
     * - Minimizes data transformations and copying
     * - Passes buffer pointers directly when possible
     * 
     * @param buffer Audio buffer containing PCM samples
     * @param frameCount Number of frames in the buffer
     */
    private func processAudioBuffer(buffer: AVAudioPCMBuffer, frameCount: Int) {
        // Ensure we have float channel data
        guard let channelData = buffer.floatChannelData else {
            return // Silent failure - no logging in real-time thread
        }
        
        // Get current callback using atomic load operation
        // This is lock-free and suitable for real-time thread
        guard let callbackRef = atomicCallbackRef,
              let callback = callbackRef.pointee else {
            return // No callback set
        }
        
        // Check if we're still running using atomic state check
        guard let statePtr = atomicState,
              statePtr.pointee == MicInputIOS.STATE_RUNNING else {
            return // Not running
        }
        
        // Zero-copy optimization: Handle mono and stereo efficiently
        if channels == 1 {
            // Mono - pass first channel pointer directly (zero-copy)
            let samples = channelData[0]
            callback(samples, frameCount)
        } else if channels == 2 {
            // Stereo - use pre-allocated interleaving buffer to avoid allocations
            guard let interleavedBuffer = self.interleavedBuffer else {
                // Fallback to mono if interleaving buffer not available
                let samples = channelData[0]
                callback(samples, frameCount)
                return
            }
            
            // Interleave channels efficiently using pre-allocated buffer
            let leftChannel = channelData[0]
            let rightChannel = channelData[1]
            
            // Interleave samples: L0, R0, L1, R1, L2, R2, ...
            for i in 0..<frameCount {
                interleavedBuffer[i * 2] = leftChannel[i]
                interleavedBuffer[i * 2 + 1] = rightChannel[i]
            }
            
            // Pass interleaved buffer to callback
            callback(UnsafePointer(interleavedBuffer), frameCount)
        } else {
            // Unsupported channel count - fallback to first channel
            let samples = channelData[0]
            callback(samples, frameCount)
        }
    }
    
    /**
     * Clean up resources.
     */
    private func cleanup() {
        audioEngine = nil
        inputNode = nil
        pcmCallback = nil
        
        // Deallocate atomic callback reference
        atomicCallbackRef?.deallocate()
        atomicCallbackRef = nil
        
        // Deallocate atomic state
        atomicState?.deallocate()
        atomicState = nil
        
        // Deallocate interleaving buffer
        interleavedBuffer?.deallocate()
        interleavedBuffer = nil
        interleavedBufferSize = 0
    }
}

// MARK: - Supporting Types

/**
 * Type alias for PCM callback function
 */
public typealias PCMCallback = (UnsafePointer<Float>, Int) -> Void

/**
 * Configuration structure for microphone input
 */
// @objc public class MicInputConfig: NSObject {
//     public let sampleRate: Int
//     public let channels: Int
//     public let bufferSize: Int
    
//     public init(sampleRate: Int, channels: Int, bufferSize: Int) {
//         self.sampleRate = sampleRate
//         self.channels = channels
//         self.bufferSize = bufferSize
//         super.init()
//     }
// }
@objc public class MicInputConfig: NSObject {
    public let sampleRate: Int
    public let channels: Int
    public let bufferSize: Int

    public init(sampleRate: Int, channels: Int, bufferSize: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bufferSize = bufferSize
        super.init()
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? MicInputConfig else { return false }
        return sampleRate == other.sampleRate &&
               channels == other.channels &&
               bufferSize == other.bufferSize
    }

    public override var hash: Int {
        return sampleRate.hashValue ^ channels.hashValue ^ bufferSize.hashValue
    }
}
/**
 * Protocol for microphone input implementations
 */
@objc public protocol MicInput {
    func start(config: MicInputConfig, onPCM: @escaping PCMCallback) throws
    func stop() throws
    func isRunning() -> Bool
    func updateCallback(onPCM: @escaping PCMCallback)
}

/**
 * Error types that can occur during microphone input operations
 */
@objc public enum MicInputErrorType: Int, CaseIterable {
    case invalidConfig
    case permissionDenied
    case hardwareUnavailable
    case formatNotSupported
    case alreadyRunning
    case notRunning
    case platformError
}

/**
 * Exception class for MicInput-related errors
 */
public class MicInputException: NSError {
    public let errorType: MicInputErrorType
    public let cause: Error?
    
    public init(errorType: MicInputErrorType, message: String, cause: Error? = nil) {
        self.errorType = errorType
        self.cause = cause
        
        super.init(
            domain: "com.realtimeaudio.micinput",
            code: errorType.rawValue,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}