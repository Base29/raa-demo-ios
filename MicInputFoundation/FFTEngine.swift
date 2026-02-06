import Foundation
import Accelerate

// MARK: - Protocol Definition

/// Protocol for FFT processing engines
protocol FFTEngine {
    /// Process audio buffer and return frequency data
    /// - Parameters:
    ///   - samples: Pointer to audio samples
    ///   - count: Number of samples
    /// - Returns: FFT data if processing succeeds, nil otherwise
    func processBuffer(_ samples: UnsafePointer<Float>, count: Int) -> FFTData?
    
    /// Configure FFT parameters
    /// - Parameters:
    ///   - fftSize: Size of FFT (should be power of 2)
    ///   - downsampleBins: Number of bins to downsample to (-1 for no downsampling)
    func configure(fftSize: Int, downsampleBins: Int)
    
    /// Enable or disable FFT processing
    var isEnabled: Bool { get set }
    
    /// Reset FFT state
    func reset()
}

// MARK: - Data Structures

/// FFT output data structure
struct FFTData {
    let magnitudes: [Float]
    let timestamp: TimeInterval
}

// MARK: - Implementation

/// Real-time safe FFT engine implementation
/// Operates independently of microphone processing
/// No memory allocations or logging in processing methods
class RealtimeFFTEngine: FFTEngine {
    
    // MARK: - Configuration
    
    var isEnabled: Bool = true
    private var fftSize: Int = 1024
    private var downsampleBins: Int = -1
    
    // MARK: - FFT State
    
    private var fftSetup: vDSP_DFT_Setup?
    private var logN: vDSP_Length = 10
    
    // MARK: - Pre-allocated Buffers
    
    private var window: [Float] = []
    private var windowedInput: [Float] = []
    private var fftReal: [Float] = []
    private var fftImag: [Float] = []
    private var zerosImag: [Float] = []
    private var magnitudes: [Float] = []
    
    // MARK: - Initialization
    
    init(fftSize: Int = 1024, downsampleBins: Int = -1) {
        self.fftSize = fftSize
        self.downsampleBins = downsampleBins
        setupFFT()
    }
    
    deinit {
        cleanup()
    }
    
    // MARK: - FFTEngine Protocol Implementation
    
    /// NON-REAL-TIME: Helper method that allocates arrays in the return value.
    /// For real-time audio callbacks, use `processBufferWritingTo(_:count:outputMagnitudes:outputCapacity:)` instead.
    /// This method is provided for convenience in non-RT contexts (testing, offline processing, etc.).
    func processBuffer(_ samples: UnsafePointer<Float>, count: Int) -> FFTData? {
        // Early return if disabled - no logging to maintain real-time safety
        guard isEnabled else { return nil }
        
        // Early return if setup failed - no logging to maintain real-time safety
        guard let setup = fftSetup else { return nil }
        
        // Early return for invalid input - no logging to maintain real-time safety
        guard count > 0 else { return nil }
        
        let n = window.count
        let processCount = min(count, n)
        
        // Copy input and apply window (reusing pre-allocated windowedInput)
        for i in 0..<processCount {
            windowedInput[i] = samples[i] * window[i]
        }
        
        // Zero pad if necessary
        if processCount < n {
            for i in processCount..<n {
                windowedInput[i] = 0
            }
        }
        
        // Execute FFT (real input + zero imaginary)
        vDSP_DFT_Execute(setup, windowedInput, zerosImag, &fftReal, &fftImag)
        
        // Calculate magnitudes (n/2) using pre-allocated buffer
        magnitudes.withUnsafeMutableBufferPointer { magPtr in
            fftReal.withUnsafeMutableBufferPointer { realPtr in
                fftImag.withUnsafeMutableBufferPointer { imagPtr in
                    var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                    vDSP_zvabs(&split, 1, magPtr.baseAddress!, 1, vDSP_Length(n / 2))
                }
            }
        }
        
        // Normalize magnitudes
        var scale = (2.0 / Float(n))
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(n / 2))
        
        // Prepare output data
        let outputMagnitudes: [Float]
        if downsampleBins > 0 && downsampleBins < (n / 2) {
            outputMagnitudes = resample(magnitudes, targetCount: downsampleBins)
        } else {
            outputMagnitudes = Array(magnitudes[0..<(n / 2)])
        }
        
        let timestamp = getCurrentTimestamp()
        return FFTData(magnitudes: outputMagnitudes, timestamp: timestamp)
    }
    
    /// Real-time safe: process FFT and write magnitudes into a preallocated buffer.
    /// No heap allocations. Returns number of magnitudes written, or 0 on failure.
    func processBufferWritingTo(_ samples: UnsafePointer<Float>, count: Int, outputMagnitudes: UnsafeMutablePointer<Float>, outputCapacity: Int) -> Int {
        guard isEnabled else { return 0 }
        guard let setup = fftSetup else { return 0 }
        guard count > 0, outputCapacity > 0 else { return 0 }
        
        let n = window.count
        let processCount = min(count, n)
        
        for i in 0..<processCount {
            windowedInput[i] = samples[i] * window[i]
        }
        if processCount < n {
            for i in processCount..<n {
                windowedInput[i] = 0
            }
        }
        
        vDSP_DFT_Execute(setup, windowedInput, zerosImag, &fftReal, &fftImag)
        
        magnitudes.withUnsafeMutableBufferPointer { magPtr in
            fftReal.withUnsafeMutableBufferPointer { realPtr in
                fftImag.withUnsafeMutableBufferPointer { imagPtr in
                    var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                    vDSP_zvabs(&split, 1, magPtr.baseAddress!, 1, vDSP_Length(n / 2))
                }
            }
        }
        
        var scale = (2.0 / Float(n))
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(n / 2))
        
        let halfN = n / 2
        if downsampleBins > 0 && downsampleBins < halfN {
            let outCount = min(downsampleBins, outputCapacity)
            resampleToBuffer(magnitudes: magnitudes, sourceCount: halfN, output: outputMagnitudes, targetCount: outCount)
            return outCount
        }
        let copyCount = min(halfN, outputCapacity)
        for i in 0..<copyCount {
            outputMagnitudes[i] = magnitudes[i]
        }
        return copyCount
    }
    
    func configure(fftSize: Int, downsampleBins: Int) {
        // Only reconfigure if parameters changed
        guard self.fftSize != fftSize || self.downsampleBins != downsampleBins else {
            return
        }
        
        self.fftSize = fftSize
        self.downsampleBins = downsampleBins
        
        // Cleanup old setup and create new one
        cleanup()
        setupFFT()
    }
    
    func reset() {
        // Reset smoothing state if any (currently none)
        // Reset buffers to zero
        if !windowedInput.isEmpty {
            windowedInput.withUnsafeMutableBufferPointer { ptr in
                memset(ptr.baseAddress, 0, ptr.count * MemoryLayout<Float>.size)
            }
        }
        if !fftReal.isEmpty {
            fftReal.withUnsafeMutableBufferPointer { ptr in
                memset(ptr.baseAddress, 0, ptr.count * MemoryLayout<Float>.size)
            }
        }
        if !fftImag.isEmpty {
            fftImag.withUnsafeMutableBufferPointer { ptr in
                memset(ptr.baseAddress, 0, ptr.count * MemoryLayout<Float>.size)
            }
        }
        if !magnitudes.isEmpty {
            magnitudes.withUnsafeMutableBufferPointer { ptr in
                memset(ptr.baseAddress, 0, ptr.count * MemoryLayout<Float>.size)
            }
        }
    }
    
    // MARK: - Private Implementation
    
    private func setupFFT() {
        // Use power-of-2 based on fftSize
        let n = nextPowerOfTwo(fftSize)
        logN = vDSP_Length(round(log2(Double(n))))
        
        // Create FFT setup
        fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), vDSP_DFT_Direction.FORWARD)
        
        // If setup failed, fail silently - logging would be a real-time violation
        guard fftSetup != nil else { return }
        
        // Allocate and initialize buffers
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        
        windowedInput = [Float](repeating: 0, count: n)
        fftReal = [Float](repeating: 0, count: n)
        fftImag = [Float](repeating: 0, count: n)
        zerosImag = [Float](repeating: 0, count: n)
        magnitudes = [Float](repeating: 0, count: n / 2)
    }
    
    private func cleanup() {
        if let setup = fftSetup {
            vDSP_DFT_DestroySetup(setup)
            fftSetup = nil
        }
    }
    
    private func nextPowerOfTwo(_ x: Int) -> Int {
        var v = 1
        while v < x { v <<= 1 }
        return v
    }
    
    private func getCurrentTimestamp() -> TimeInterval {
        // Cache timebase info to avoid system call per invocation
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
    
    private func resample(_ input: [Float], targetCount: Int) -> [Float] {
        let sourceCount = input.count
        if targetCount <= 0 || sourceCount == 0 { return [] }
        if targetCount >= sourceCount { return input }
        
        var result = [Float](repeating: 0, count: targetCount)
        let ratio = Float(sourceCount) / Float(targetCount)
        
        for i in 0..<targetCount {
            let start = Int(Float(i) * ratio)
            let end = min(Int(Float(i + 1) * ratio), sourceCount)
            if start >= end {
                result[i] = input[min(start, sourceCount - 1)]
                continue
            }
            var sum: Float = 0
            for j in start..<end { sum += input[j] }
            result[i] = sum / Float(end - start)
        }
        return result
    }
    
    /// Real-time safe: resample magnitudes into a preallocated buffer. No allocations.
    private func resampleToBuffer(magnitudes: [Float], sourceCount: Int, output: UnsafeMutablePointer<Float>, targetCount: Int) {
        if targetCount <= 0 || sourceCount == 0 { return }
        if targetCount >= sourceCount {
            for i in 0..<min(sourceCount, targetCount) {
                output[i] = magnitudes[i]
            }
            return
        }
        let ratio = Float(sourceCount) / Float(targetCount)
        for i in 0..<targetCount {
            let start = Int(Float(i) * ratio)
            let end = min(Int(Float(i + 1) * ratio), sourceCount)
            if start >= end {
                output[i] = magnitudes[min(start, sourceCount - 1)]
                continue
            }
            var sum: Float = 0
            for j in start..<end { sum += magnitudes[j] }
            output[i] = sum / Float(end - start)
        }
    }
}