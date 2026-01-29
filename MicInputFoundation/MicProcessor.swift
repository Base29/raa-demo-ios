import Foundation
import Accelerate

// MARK: - Data Models

/// Level data output from microphone processing
struct LevelData {
    let rms: Float
    let peak: Float
    let timestamp: TimeInterval
}

// MARK: - Protocol Definition

/// Protocol for real-time safe microphone processing
protocol MicProcessor {
    /// Process audio buffer and return level data
    /// - Parameters:
    ///   - samples: Pointer to audio samples
    ///   - count: Number of samples to process
    /// - Returns: Level data containing RMS and peak values
    func processBuffer(_ samples: UnsafePointer<Float>, count: Int) -> LevelData
    
    /// Configure smoothing parameters
    /// - Parameters:
    ///   - smoothingEnabled: Whether to enable smoothing
    ///   - smoothingFactor: Smoothing factor (0.0 to 1.0)
    func configure(smoothingEnabled: Bool, smoothingFactor: Float)
    
    /// Reset internal state
    func reset()
}

// MARK: - Testing and Validation Protocol

/// Protocol for testing and validation interfaces
/// Requirement 6.1, 6.4: Clean interface for test audio data injection
protocol MicProcessorTestable {
    /// Process test audio data from array for validation
    /// - Parameter testSamples: Array of test audio samples
    /// - Returns: Level data for validation
    func processTestBuffer(_ testSamples: [Float]) -> LevelData
    
    /// Inject synthetic audio level sequence for smoothing engine testing
    /// Requirement 6.3: Testable smoothing engine with synthetic sequences
    /// - Parameters:
    ///   - rmsSequence: Sequence of RMS values to inject
    ///   - peakSequence: Sequence of peak values to inject
    /// - Returns: Array of smoothed level data
    func processLevelSequence(rmsSequence: [Float], peakSequence: [Float]) -> [LevelData]
    
    /// Get internal state for debugging and validation
    /// Requirement 6.5: Expose internal state for debugging
    /// - Returns: Internal state snapshot
    func getInternalState() -> MicProcessorState
    
    /// Set internal state for deterministic testing
    /// Requirement 6.2: Deterministic output for identical inputs
    /// - Parameter state: State to set for deterministic testing
    func setInternalState(_ state: MicProcessorState)
}

/// Internal state structure for debugging and validation
struct MicProcessorState {
    let smoothingEnabled: Bool
    let smoothingFactor: Float
    let smoothRms: Float
    let smoothPeak: Float
    
    init(smoothingEnabled: Bool, smoothingFactor: Float, smoothRms: Float, smoothPeak: Float) {
        self.smoothingEnabled = smoothingEnabled
        self.smoothingFactor = smoothingFactor
        self.smoothRms = smoothRms
        self.smoothPeak = smoothPeak
    }
}

// MARK: - Implementation

/// Real-time safe microphone processor implementation
/// Calculates RMS and peak values without FFT dependencies
/// No memory allocations or logging in processing methods
class RealtimeMicProcessor: MicProcessor, MicProcessorTestable {
    
    // MARK: - Private Properties
    
    private var smoothingEnabled: Bool = false
    private var smoothingFactor: Float = 0.1
    private var smoothRms: Float = 0.0
    private var smoothPeak: Float = 0.0
    
    // MARK: - Initialization
    
    init() {
        // No initialization needed - all state is primitive types
    }
    
    // MARK: - MicProcessor Protocol Implementation
    
    func processBuffer(_ samples: UnsafePointer<Float>, count: Int) -> LevelData {
        // Early return for invalid input - no logging to maintain real-time safety
        guard count > 0 else {
            return LevelData(rms: 0.0, peak: 0.0, timestamp: getCurrentTimestamp())
        }
        
        // PERFORMANCE OPTIMIZATION: Use single-pass calculation for both RMS and peak
        // This reduces memory access patterns and improves cache efficiency
        var sumSquares: Float = 0.0
        var peak: Float = 0.0
        
        // Vectorized operations using Accelerate framework for optimal performance
        // Calculate sum of squares for RMS
        vDSP_svesq(samples, 1, &sumSquares, vDSP_Length(count))
        
        // Calculate peak (absolute maximum)
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(count))
        
        // Calculate RMS from sum of squares (avoiding sqrt call in Accelerate)
        let rms = sqrt(sumSquares / Float(count))
        
        // Apply smoothing if enabled - optimized for minimal branching
        let finalRms: Float
        let finalPeak: Float
        
        if smoothingEnabled {
            // Exponential smoothing: new_value = old_value + (current - old_value) * factor
            // Use fused multiply-add for better performance
            smoothRms = smoothRms + (rms - smoothRms) * smoothingFactor
            smoothPeak = smoothPeak + (peak - smoothPeak) * smoothingFactor
            finalRms = smoothRms
            finalPeak = smoothPeak
        } else {
            // No smoothing - update internal state for consistency
            smoothRms = rms
            smoothPeak = peak
            finalRms = rms
            finalPeak = peak
        }
        
        return LevelData(
            rms: finalRms,
            peak: finalPeak,
            timestamp: getCurrentTimestamp()
        )
    }
    
    func configure(smoothingEnabled: Bool, smoothingFactor: Float) {
        self.smoothingEnabled = smoothingEnabled
        // Clamp smoothing factor to valid range without logging
        self.smoothingFactor = max(0.0, min(1.0, smoothingFactor))
    }
    
    func reset() {
        smoothRms = 0.0
        smoothPeak = 0.0
    }
    
    // MARK: - Private Helpers
    
    /// Get current timestamp in a real-time safe manner
    /// Uses mach_absolute_time for high precision without system calls
    /// PERFORMANCE OPTIMIZATION: Cached timebase info to avoid repeated system calls
    private func getCurrentTimestamp() -> TimeInterval {
        // Static variables for cached timebase (computed once)
        struct TimebaseCache {
            static var timebase: mach_timebase_info = {
                var info = mach_timebase_info()
                mach_timebase_info(&info)
                return info
            }()
            static let nanosToSeconds: Double = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000.0
        }
        
        let now = mach_absolute_time()
        return TimeInterval(now) * TimebaseCache.nanosToSeconds
    }
    
    // MARK: - MicProcessorTestable Protocol Implementation
    
    func processTestBuffer(_ testSamples: [Float]) -> LevelData {
        // Requirement 6.1, 6.4: Clean interface for test audio data injection
        return testSamples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return LevelData(rms: 0.0, peak: 0.0, timestamp: getCurrentTimestamp())
            }
            return processBuffer(baseAddress, count: testSamples.count)
        }
    }
    
    func processLevelSequence(rmsSequence: [Float], peakSequence: [Float]) -> [LevelData] {
        // Requirement 6.3: Testable smoothing engine with synthetic sequences
        guard rmsSequence.count == peakSequence.count else {
            return []
        }
        
        var results: [LevelData] = []
        let timestamp = getCurrentTimestamp()
        
        for i in 0..<rmsSequence.count {
            let rms = rmsSequence[i]
            let peak = peakSequence[i]
            
            // Apply smoothing if enabled (same logic as processBuffer)
            let finalRms: Float
            let finalPeak: Float
            
            if smoothingEnabled {
                smoothRms = smoothRms + (rms - smoothRms) * smoothingFactor
                smoothPeak = smoothPeak + (peak - smoothPeak) * smoothingFactor
                finalRms = smoothRms
                finalPeak = smoothPeak
            } else {
                smoothRms = rms
                smoothPeak = peak
                finalRms = rms
                finalPeak = peak
            }
            
            results.append(LevelData(
                rms: finalRms,
                peak: finalPeak,
                timestamp: timestamp + TimeInterval(i) * 0.001 // Simulate 1ms intervals
            ))
        }
        
        return results
    }
    
    func getInternalState() -> MicProcessorState {
        // Requirement 6.5: Expose internal state for debugging
        return MicProcessorState(
            smoothingEnabled: smoothingEnabled,
            smoothingFactor: smoothingFactor,
            smoothRms: smoothRms,
            smoothPeak: smoothPeak
        )
    }
    
    func setInternalState(_ state: MicProcessorState) {
        // Requirement 6.2: Deterministic output for identical inputs
        self.smoothingEnabled = state.smoothingEnabled
        self.smoothingFactor = state.smoothingFactor
        self.smoothRms = state.smoothRms
        self.smoothPeak = state.smoothPeak
    }
}