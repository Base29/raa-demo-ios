import Foundation
import AVFoundation

// MARK: - Analysis Options

/// Options for starting real-time audio analysis (FFT + RMS/Peak).
/// Used by startAnalysis(options:onData:).
public struct AnalysisOptions {
    public var sampleRate: Int
    public var channels: Int
    public var bufferSize: Int
    public var fftSize: Int
    public var downsampleBins: Int
    public var refreshRateHz: Double
    public var includeTimeData: Bool
    
    public static func `default`() -> AnalysisOptions {
        AnalysisOptions(
            sampleRate: 48000,
            channels: 1,
            bufferSize: 1024,
            fftSize: 1024,
            downsampleBins: 256,
            refreshRateHz: 30,
            includeTimeData: false
        )
    }
}

// MARK: - Event Payload

/// Keys for the RealtimeAudioAnalyzer:onData event payload.
public struct AnalyzerEventKeys {
    public static let timestamp = "timestamp"
    public static let rms = "rms"
    public static let peak = "peak"
    public static let volume = "volume"
    public static let sampleRate = "sampleRate"
    public static let fftSize = "fftSize"
    public static let frequencyData = "frequencyData"
    public static let timeData = "timeData"
}

// MARK: - Realtime Audio Analyzer

/// Orchestrates microphone capture, FFT, RMS/Peak metering, and rate-limited event emission.
/// Owns one RealtimeFFTEngine and one RealtimeMicProcessor. Real-time safe audio callback.
public final class RealtimeAudioAnalyzer {
    
    // MARK: - Configuration
    
    private var options: AnalysisOptions
    private var onData: (([String: Any]) -> Void)?
    
    // MARK: - Pipeline (owned, one instance each)
    
    private var micInput: MicInputIOS?
    private let ffEngine: RealtimeFFTEngine
    private let micProcessor: RealtimeMicProcessor
    
    // MARK: - Preallocated buffers (real-time safe)
    
    private var monoBuffer: UnsafeMutablePointer<Float>?
    private var monoBufferCapacity: Int = 0
    private var frequencyBuffer: UnsafeMutablePointer<Float>?
    private var frequencyBufferCapacity: Int = 0
    private var emitBuffers: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>)?
    private var emitBufferCapacity: Int = 0
    private var nextEmitBufferIndex: Int = 0
    
    // MARK: - Throttling (monotonic)
    
    private var lastEmitTimeNanos: UnsafeMutablePointer<UInt64>?
    private var refreshIntervalNanos: UInt64 = 0
    
    // MARK: - State
    
    private var actualChannels: UInt32 = 1
    private var actualSampleRate: Double = 0
    private var actualFftSize: Int = 1024
    private var actualDownsampleBins: Int = 256
    private let stateQueue = DispatchQueue(label: "com.realtimeaudio.analyzer.state")
    private let emitQueue = DispatchQueue(label: "com.realtimeaudio.analyzer.emit", qos: .userInitiated)
    private var isAnalyzing: Bool = false
    
#if DEBUG
    private var debugEmitCount: Int64 = 0
    private var debugLastLogTime: CFAbsoluteTime = 0
#endif
    
    // MARK: - Initialization
    
    public init() {
        self.options = .default()
        self.ffEngine = RealtimeFFTEngine(fftSize: 1024, downsampleBins: 256)
        self.micProcessor = RealtimeMicProcessor()
    }
    
    deinit {
        stopAnalysis()
        monoBuffer?.deallocate()
        frequencyBuffer?.deallocate()
        if let (a, b) = emitBuffers {
            a.deallocate()
            b.deallocate()
        }
        lastEmitTimeNanos?.deallocate()
    }
    
    // MARK: - Public API
    
    /// Start analysis with the given options. Emits events to onData at up to refreshRateHz.
    public func startAnalysis(options: AnalysisOptions, onData: @escaping ([String: Any]) -> Void) throws {
        try stateQueue.sync {
            if isAnalyzing {
                throw MicInputException(errorType: .alreadyRunning, message: "Analysis already running")
            }
            
            self.options = options
            self.onData = onData
            
            let fftSize = options.fftSize
            let downsampleBins = options.downsampleBins
            let bufferSize = max(options.bufferSize, 256)
            let maxFrames = max(bufferSize, fftSize)
            
            actualFftSize = fftSize
            actualDownsampleBins = downsampleBins
            refreshIntervalNanos = UInt64(1_000_000_000.0 / max(1.0, min(120.0, options.refreshRateHz)))
            
            ffEngine.configure(fftSize: fftSize, downsampleBins: downsampleBins)
            ffEngine.isEnabled = true
            micProcessor.reset()
            
            if monoBufferCapacity < maxFrames {
                monoBuffer?.deallocate()
                monoBuffer = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
                monoBufferCapacity = maxFrames
            }
            
            let freqCapacity = max(512, downsampleBins)
            if frequencyBufferCapacity < freqCapacity {
                frequencyBuffer?.deallocate()
                frequencyBuffer = UnsafeMutablePointer<Float>.allocate(capacity: freqCapacity)
                frequencyBufferCapacity = freqCapacity
            }
            
            if emitBufferCapacity < freqCapacity {
                emitBuffers?.0.deallocate()
                emitBuffers?.1.deallocate()
                emitBuffers = (
                    UnsafeMutablePointer<Float>.allocate(capacity: freqCapacity),
                    UnsafeMutablePointer<Float>.allocate(capacity: freqCapacity)
                )
                emitBufferCapacity = freqCapacity
            }
            
            if lastEmitTimeNanos == nil {
                lastEmitTimeNanos = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
            }
            lastEmitTimeNanos?.pointee = 0
            
#if DEBUG
            debugEmitCount = 0
            debugLastLogTime = CFAbsoluteTimeGetCurrent() // first log after ~1 second
#endif
            
            nextEmitBufferIndex = 0
            
            let config = MicInputConfig(
                sampleRate: options.sampleRate,
                channels: options.channels,
                bufferSize: bufferSize
            )
            
            let mic = MicInputIOS()
            self.micInput = mic
            actualChannels = UInt32(options.channels)
            actualSampleRate = Double(options.sampleRate)
            
            let weakSelf = WeakRef(self)
            let pcmCallback: PCMCallback = { samples, frameCount in
                weakSelf.target?.processAudioCallback(samples: samples, frameCount: frameCount)
            }
            
            try mic.start(config: config, onPCM: pcmCallback)
            isAnalyzing = true
        }
    }
    
    /// Stop analysis: remove tap, stop engine, reset FFT.
    public func stopAnalysis() {
        stateQueue.sync {
            guard isAnalyzing else { return }
            isAnalyzing = false
            do {
                try micInput?.stop()
            } catch {}
            micInput = nil
            ffEngine.reset()
            ffEngine.isEnabled = false
        }
    }
    
    public func isRunning() -> Bool {
        stateQueue.sync { isAnalyzing }
    }
    
    // MARK: - Audio callback (real-time safe: no alloc, no log, no lock)
    
    private func processAudioCallback(samples: UnsafePointer<Float>, frameCount: Int) {
        guard let monoBuf = monoBuffer,
              let freqBuf = frequencyBuffer,
              let emitBufs = emitBuffers,
              let lastEmit = lastEmitTimeNanos else { return }
        
        let channels = actualChannels
        let monoPtr: UnsafePointer<Float>
        
        if channels == 2 {
            for i in 0..<frameCount {
                monoBuf[i] = (samples[i * 2] + samples[i * 2 + 1]) * 0.5
            }
            monoPtr = UnsafePointer(monoBuf)
        } else {
            monoPtr = samples
        }
        
        let levelData = micProcessor.processBuffer(monoPtr, count: frameCount)
        let outCount = ffEngine.processBufferWritingTo(
            channels == 2 ? UnsafePointer(monoBuf) : monoPtr,
            frameCount,
            freqBuf,
            frequencyBufferCapacity
        )
        
        if outCount <= 0 { return }
        
        var now = mach_absolute_time()
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let nowNanos = now * UInt64(timebase.numer) / UInt64(timebase.denom)
        let prev = lastEmit.pointee
        if prev != 0 && nowNanos < prev + refreshIntervalNanos { return }
        
        lastEmit.pointee = nowNanos
        
        let idx = nextEmitBufferIndex
        nextEmitBufferIndex = 1 - nextEmitBufferIndex
        let dest = idx == 0 ? emitBufs.0 : emitBufs.1
        for i in 0..<outCount {
            dest[i] = freqBuf[i]
        }
        
        let rms = levelData.rms
        let peak = levelData.peak
        let sampleRate = actualSampleRate
        let fftSizeVal = actualFftSize
        let freqCount = outCount
        
        emitQueue.async { [weak self] in
            self?.emitPayload(
                rms: rms,
                peak: peak,
                sampleRate: sampleRate,
                fftSize: fftSizeVal,
                frequencyBuffer: dest,
                frequencyCount: freqCount,
                includeTimeData: self?.options.includeTimeData ?? false
            )
        }
    }
    
    private func emitPayload(
        rms: Float,
        peak: Float,
        sampleRate: Double,
        fftSize: Int,
        frequencyBuffer: UnsafeMutablePointer<Float>,
        frequencyCount: Int,
        includeTimeData: Bool
    ) {
        let timestampMs = Date().timeIntervalSince1970 * 1000.0
        
        var freqArray: [Double] = []
        freqArray.reserveCapacity(frequencyCount)
        for i in 0..<frequencyCount {
            let v = Double(frequencyBuffer[i])
            freqArray.append(min(1.0, max(0.0, v)))
        }
        
        var payload: [String: Any] = [
            AnalyzerEventKeys.timestamp: timestampMs,
            AnalyzerEventKeys.rms: Double(min(1.0, max(0.0, rms))),
            AnalyzerEventKeys.peak: Double(min(1.0, max(0.0, peak))),
            AnalyzerEventKeys.volume: Double(min(1.0, max(0.0, rms))),
            AnalyzerEventKeys.sampleRate: sampleRate,
            AnalyzerEventKeys.fftSize: fftSize,
            AnalyzerEventKeys.frequencyData: freqArray
        ]
        if includeTimeData {
            payload[AnalyzerEventKeys.timeData] = [] as [Float]
        }
        
#if DEBUG
        debugEmitCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        if now - debugLastLogTime >= 1.0 {
            let eventRate = debugEmitCount
            let minMag = freqArray.min() ?? 0
            let maxMag = freqArray.max() ?? 0
            print("[RealtimeAudioAnalyzer] eventRate=\(eventRate) Hz, frequencyData.count=\(frequencyCount), min=\(String(format: "%.4f", minMag)), max=\(String(format: "%.4f", maxMag))")
            debugEmitCount = 0
            debugLastLogTime = now
        }
#endif
        
        onData?(payload)
    }
}

// MARK: - Weak ref for callback

private final class WeakRef<T: AnyObject> {
    weak var target: T?
    init(_ t: T) { target = t }
}
