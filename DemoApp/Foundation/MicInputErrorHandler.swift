import Foundation
import AVFoundation

/**
 * Enhanced error handling for iOS MicInput implementation.
 * 
 * This class provides comprehensive error handling for AVAudioEngine configuration failures,
 * graceful degradation for unsupported configurations, and platform-specific error recovery.
 * 
 * Requirements: 9.1, 9.2
 */
@objc public class MicInputErrorHandler: NSObject {
    
    /**
     * Supported sample rates in order of preference (highest quality first)
     */
    private static let preferredSampleRates: [Double] = [48000, 44100, 22050, 16000, 8000]
    
    /**
     * Supported channel counts in order of preference
     */
    private static let preferredChannelCounts: [UInt32] = [1, 2] // Mono, Stereo
    
    /**
     * Supported buffer sizes in order of preference
     */
    private static let preferredBufferSizes: [UInt32] = [1024, 512, 256, 2048, 4096]
    
    /**
     * Result of attempting to configure AVAudioEngine with error handling and fallback.
     */
    @objc public class AudioEngineResult: NSObject {
        public let audioEngine: AVAudioEngine?
        public let inputNode: AVAudioInputNode?
        public let actualConfig: MicInputConfig?
        public let error: MicInputException?
        
        public var isSuccess: Bool { return audioEngine != nil && actualConfig != nil }
        public var isFailure: Bool { return !isSuccess }
        
        init(audioEngine: AVAudioEngine?, inputNode: AVAudioInputNode?, actualConfig: MicInputConfig?, error: MicInputException?) {
            self.audioEngine = audioEngine
            self.inputNode = inputNode
            self.actualConfig = actualConfig
            self.error = error
            super.init()
        }
    }
    
    /**
     * Configure AVAudioEngine with comprehensive error handling and graceful degradation.
     * 
     * This method attempts to configure AVAudioEngine with the requested configuration.
     * If the exact configuration fails, it tries fallback configurations in order
     * of preference to find a working setup.
     * 
     * @param requestedConfig The desired audio configuration
     * @return AudioEngineResult containing the configured engine and actual config, or error
     */
    @objc public func configureAudioEngineWithFallback(requestedConfig: MicInputConfig) -> AudioEngineResult {
        // First, try the exact requested configuration
        let exactResult = tryConfigureAudioEngine(config: requestedConfig)
        if exactResult.isSuccess {
            return exactResult
        }
        
        // If exact config failed, try fallback configurations
        let fallbackConfigs = generateFallbackConfigurations(requestedConfig: requestedConfig)
        
        for fallbackConfig in fallbackConfigs {
            let fallbackResult = tryConfigureAudioEngine(config: fallbackConfig)
            if fallbackResult.isSuccess {
                return fallbackResult
            }
        }
        
        // All configurations failed - return the original error with enhanced details
        return AudioEngineResult(
            audioEngine: nil,
            inputNode: nil,
            actualConfig: nil,
            error: MicInputException(
                errorType: .hardwareUnavailable,
                message: "Failed to configure AVAudioEngine with requested configuration and all fallbacks. " +
                        "Original error: \(exactResult.error?.localizedDescription ?? "Unknown error")",
                cause: exactResult.error
            )
        )
    }
    
    /**
     * Attempt to configure AVAudioEngine with a specific configuration.
     * 
     * @param config The audio configuration to try
     * @return AudioEngineResult with success/failure information
     */
    private func tryConfigureAudioEngine(config: MicInputConfig) -> AudioEngineResult {
        do {
            // Configure audio session first
            try configureAudioSession()
            
            // Create audio engine
            let audioEngine = AVAudioEngine()
            let inputNode = audioEngine.inputNode
            
            // Get current input format
            let inputFormat = inputNode.outputFormat(forBus: 0)
            
            // Create desired format
            guard let desiredFormat = AVAudioFormat(
                standardFormatWithSampleRate: Double(config.sampleRate),
                channels: UInt32(config.channels)
            ) else {
                return AudioEngineResult(
                    audioEngine: nil,
                    inputNode: nil,
                    actualConfig: nil,
                    error: MicInputException(
                        errorType: .formatNotSupported,
                        message: "Cannot create audio format with sampleRate=\(config.sampleRate), channels=\(config.channels)"
                    )
                )
            }
            
            // Check if the hardware supports the desired format
            if !isFormatSupported(format: desiredFormat, inputFormat: inputFormat) {
                return AudioEngineResult(
                    audioEngine: nil,
                    inputNode: nil,
                    actualConfig: nil,
                    error: MicInputException(
                        errorType: .formatNotSupported,
                        message: "Hardware does not support the requested audio format: \(desiredFormat)"
                    )
                )
            }
            
            // Try to install tap with the desired format
            do {
                inputNode.installTap(onBus: 0, bufferSize: UInt32(config.bufferSize), format: desiredFormat) { _, _ in
                    // Placeholder callback - will be replaced by actual implementation
                }
                
                // Remove the placeholder tap immediately
                inputNode.removeTap(onBus: 0)
                
                // Success - return the configured engine
                return AudioEngineResult(
                    audioEngine: audioEngine,
                    inputNode: inputNode,
                    actualConfig: config,
                    error: nil
                )
                
            } catch {
                return AudioEngineResult(
                    audioEngine: nil,
                    inputNode: nil,
                    actualConfig: nil,
                    error: MicInputException(
                        errorType: .formatNotSupported,
                        message: "Failed to install tap with requested format: \(error.localizedDescription)",
                        cause: error
                    )
                )
            }
            
        } catch let error as MicInputException {
            return AudioEngineResult(
                audioEngine: nil,
                inputNode: nil,
                actualConfig: nil,
                error: error
            )
        } catch {
            return AudioEngineResult(
                audioEngine: nil,
                inputNode: nil,
                actualConfig: nil,
                error: MicInputException(
                    errorType: .platformError,
                    message: "Platform-specific error during AVAudioEngine configuration: \(error.localizedDescription)",
                    cause: error
                )
            )
        }
    }
    
    /**
     * Configure the audio session for microphone capture with error handling.
     * 
     * @throws MicInputException if audio session configuration fails
     */
    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        
        do {
            // Check microphone permission
            let permissionStatus = audioSession.recordPermission
            if permissionStatus == .denied {
                throw MicInputException(
                    errorType: .permissionDenied,
                    message: "Microphone permission denied. Please grant microphone access in Settings."
                )
            }
            
            // Request permission if undetermined
            if permissionStatus == .undetermined {
                var permissionGranted = false
                let semaphore = DispatchSemaphore(value: 0)
                
                audioSession.requestRecordPermission { granted in
                    permissionGranted = granted
                    semaphore.signal()
                }
                
                semaphore.wait()
                
                if !permissionGranted {
                    throw MicInputException(
                        errorType: .permissionDenied,
                        message: "Microphone permission denied by user."
                    )
                }
            }
            
            // Configure audio session category and mode
            try audioSession.setCategory(.record, mode: .measurement, options: [.allowBluetooth])
            
            // Activate audio session
            try audioSession.setActive(true, options: [])
            
        } catch let error as MicInputException {
            throw error
        } catch {
            // Handle specific AVAudioSession errors
            if let nsError = error as NSError? {
                switch nsError.code {
                case AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue:
                    throw MicInputException(
                        errorType: .hardwareUnavailable,
                        message: "Cannot interrupt other audio sessions. Another app may be using the microphone.",
                        cause: error
                    )
                case AVAudioSession.ErrorCode.incompatibleCategory.rawValue:
                    throw MicInputException(
                        errorType: .formatNotSupported,
                        message: "Incompatible audio session category.",
                        cause: error
                    )
                default:
                    throw MicInputException(
                        errorType: .platformError,
                        message: "Audio session configuration failed: \(error.localizedDescription)",
                        cause: error
                    )
                }
            } else {
                throw MicInputException(
                    errorType: .platformError,
                    message: "Audio session configuration failed: \(error.localizedDescription)",
                    cause: error
                )
            }
        }
    }
    
    /**
     * Check if a desired audio format is supported by the hardware.
     * 
     * @param format The desired audio format
     * @param inputFormat The current hardware input format
     * @return true if the format is likely supported, false otherwise
     */
    private func isFormatSupported(format: AVAudioFormat, inputFormat: AVAudioFormat) -> Bool {
        // Check sample rate compatibility
        let sampleRateRatio = format.sampleRate / inputFormat.sampleRate
        if sampleRateRatio < 0.5 || sampleRateRatio > 2.0 {
            return false // Sample rate too different from hardware capability
        }
        
        // Check channel count compatibility
        if format.channelCount > inputFormat.channelCount {
            return false // Cannot create more channels than hardware provides
        }
        
        // Check if it's a standard format
        if !format.isStandard {
            return false // Non-standard formats may not be supported
        }
        
        return true
    }
    
    /**
     * Generate fallback configurations to try if the requested configuration fails.
     * 
     * Fallbacks are generated in order of preference:
     * 1. Same sample rate, different buffer sizes
     * 2. Different sample rates, same channels
     * 3. Different sample rates, mono only
     * 
     * @param requestedConfig The original requested configuration
     * @return Array of fallback configurations to try
     */
    private func generateFallbackConfigurations(requestedConfig: MicInputConfig) -> [MicInputConfig] {
        var fallbacks: [MicInputConfig] = []
        
        // Try different buffer sizes with same sample rate and channels
        let bufferSizes = MicInputErrorHandler.preferredBufferSizes.filter { $0 != UInt32(requestedConfig.bufferSize) }
        for bufferSize in bufferSizes {
            fallbacks.append(MicInputConfig(
                sampleRate: requestedConfig.sampleRate,
                channels: requestedConfig.channels,
                bufferSize: Int(bufferSize)
            ))
        }
        
        // Try different sample rates with same channels
        let sampleRates = MicInputErrorHandler.preferredSampleRates.filter { $0 != Double(requestedConfig.sampleRate) }
        for sampleRate in sampleRates {
            fallbacks.append(MicInputConfig(
                sampleRate: Int(sampleRate),
                channels: requestedConfig.channels,
                bufferSize: requestedConfig.bufferSize
            ))
        }
        
        // Try mono if stereo was requested
        if requestedConfig.channels == 2 {
            for sampleRate in MicInputErrorHandler.preferredSampleRates {
                fallbacks.append(MicInputConfig(
                    sampleRate: Int(sampleRate),
                    channels: 1,
                    bufferSize: requestedConfig.bufferSize
                ))
            }
        }
        
        // Remove duplicates
        return Array(Set(fallbacks.map { "\($0.sampleRate)-\($0.channels)-\($0.bufferSize)" }))
            .compactMap { key in
                let components = key.split(separator: "-").compactMap { Int($0) }
                guard components.count == 3 else { return nil }
                return MicInputConfig(sampleRate: components[0], channels: components[1], bufferSize: components[2])
            }
    }
    
    /// Error domain strings (not always exposed as Swift constants in AVFoundation).
    private static let audioEngineConfigurationErrorDomain = "AVAudioEngineConfigurationErrorDomain"
    private static let audioSessionErrorDomain = "AVAudioSessionErrorDomain"

    /**
     * Handle AVAudioEngine runtime errors during recording.
     * 
     * @param error The error that occurred
     * @return MicInputException with appropriate error type and message
     */
    @objc public func handleEngineError(_ error: Error) -> MicInputException {
        if let nsError = error as NSError? {
            switch nsError.domain {
            case MicInputErrorHandler.audioEngineConfigurationErrorDomain:
                return MicInputException(
                    errorType: .formatNotSupported,
                    message: "AVAudioEngine configuration error: \(error.localizedDescription)",
                    cause: error
                )
            case MicInputErrorHandler.audioSessionErrorDomain:
                switch nsError.code {
                case AVAudioSession.ErrorCode.insufficientPriority.rawValue:
                    return MicInputException(
                        errorType: .hardwareUnavailable,
                        message: "Audio session interrupted by higher priority session",
                        cause: error
                    )
                case AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue:
                    return MicInputException(
                        errorType: .hardwareUnavailable,
                        message: "Cannot interrupt other audio sessions",
                        cause: error
                    )
                default:
                    return MicInputException(
                        errorType: .platformError,
                        message: "Audio session error: \(error.localizedDescription)",
                        cause: error
                    )
                }
            default:
                return MicInputException(
                    errorType: .platformError,
                    message: "AVAudioEngine error: \(error.localizedDescription)",
                    cause: error
                )
            }
        } else {
            return MicInputException(
                errorType: .platformError,
                message: "Unknown engine error: \(error.localizedDescription)",
                cause: error
            )
        }
    }
    
    /**
     * Check if the current iOS device supports the requested configuration.
     * 
     * @param config The configuration to check
     * @return true if likely supported, false if definitely not supported
     */
    @objc public func isConfigurationLikelySupported(_ config: MicInputConfig) -> Bool {
        // Check against known limitations
        if !MicInputErrorHandler.preferredSampleRates.contains(Double(config.sampleRate)) {
            return false
        }
        
        if config.channels < 1 || config.channels > 2 {
            return false
        }
        
        if config.bufferSize < 64 || config.bufferSize > 8192 {
            return false
        }
        
        // Check if buffer size is power of 2
        let bufferSize = UInt32(config.bufferSize)
        if (bufferSize & (bufferSize - 1)) != 0 {
            return false
        }
        
        return true
    }
}

// MARK: - Extensions for MicInputConfig equality comparison

extension MicInputConfig {
    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? MicInputConfig else { return false }
        return sampleRate == other.sampleRate && 
               channels == other.channels && 
               bufferSize == other.bufferSize
    }
    
    override public var hash: Int {
        return sampleRate.hashValue ^ channels.hashValue ^ bufferSize.hashValue
    }
}
