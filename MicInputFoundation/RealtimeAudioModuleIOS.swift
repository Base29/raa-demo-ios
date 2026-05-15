import Foundation

#if canImport(React)
import React

/**
 * RealtimeAudioModuleIOS
 *
 * React Native bridge for RealtimeAudioAnalyzer.
 * Emits FFT, level metering (rmsDb, peakDb), and time data to JS.
 */
@objc(RealtimeAudioModuleIOS)
public class RealtimeAudioModuleIOS: RCTEventEmitter {
    
    private let analyzer = RealtimeAudioAnalyzer()
    private var hasListeners = false
    
    public override static func requiresMainQueueSetup() -> Bool {
        return false
    }
    
    public override func supportedEvents() -> [String]! {
        return ["RealtimeAudioAnalyzer:onData"]
    }
    
    public override func startObserving() {
        hasListeners = true
    }
    
    public override func stopObserving() {
        hasListeners = false
    }
    
    private func sendEventOnMain(withName name: String, body: Any!) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.hasListeners else { return }
            self.sendEvent(withName: name, body: body)
        }
    }
    
    /**
     * Start the realtime audio analysis.
     * Maps JS options dictionary to native AnalysisOptions.
     */
    @objc(startAnalysis:resolver:rejecter:)
    public func startAnalysis(options: [String: Any]?, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        var analysisOptions = RealtimeAudioAnalyzer.AnalysisOptions.default()
        
        if let opts = options {
            if let sampleRate = opts["sampleRate"] as? Int { analysisOptions.sampleRate = sampleRate }
            if let channels = opts["channels"] as? Int { analysisOptions.channels = channels }
            if let bufferSize = opts["bufferSize"] as? Int { analysisOptions.bufferSize = bufferSize }
            if let fftSize = opts["fftSize"] as? Int { analysisOptions.fftSize = fftSize }
            if let downsampleBins = opts["downsampleBins"] as? Int { analysisOptions.downsampleBins = downsampleBins }
            if let refreshRateHz = opts["refreshRateHz"] as? Double { analysisOptions.refreshRateHz = refreshRateHz }
            if let includeTimeData = opts["includeTimeData"] as? Bool { analysisOptions.includeTimeData = includeTimeData }
            if let useHanningWindow = opts["useHanningWindow"] as? Bool { analysisOptions.useHanningWindow = useHanningWindow }
            if let skipZeroPadding = opts["skipZeroPadding"] as? Bool { analysisOptions.skipZeroPadding = skipZeroPadding }
        }
        
        do {
            try analyzer.startAnalysis(options: analysisOptions) { [weak self] payload in
                guard let self = self, self.hasListeners else { return }
                // The payload already contains rmsDb, peakDb, frequencyData, etc.
                self.sendEventOnMain(withName: "RealtimeAudioAnalyzer:onData", body: payload)
            }
            resolve(nil)
        } catch {
            reject("ANALYZER_ERROR", "Failed to start analysis: \(error.localizedDescription)", error)
        }
    }
    
    /**
     * Stop the realtime audio analysis.
     */
    @objc(stopAnalysis:resolver:rejecter:)
    public func stopAnalysis(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        analyzer.stopAnalysis()
        resolve(nil)
    }
    
    /**
     * Ensure resources are cleaned up when the module is invalidated by RN.
     */
    public override func invalidate() {
        analyzer.stopAnalysis()
        super.invalidate()
    }
}

#else

// Stub for non-React targets
@objc(RealtimeAudioModuleIOS)
public class RealtimeAudioModuleIOS: NSObject {
    @objc public func startAnalysis(options: [String: Any]?, resolve: @escaping (Any?) -> Void, reject: @escaping (String?, String?, Error?) -> Void) {
        reject("NOT_IMPLEMENTED", "React is not available in this target", nil)
    }
    @objc public func stopAnalysis(resolve: @escaping (Any?) -> Void, reject: @escaping (String?, String?, Error?) -> Void) {
        resolve(nil)
    }
}

#endif
