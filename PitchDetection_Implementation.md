### Pitch Detection Implementation Summary

This document briefly describes the native pitch detection implementation added for the tuner engine on iOS.

---

### What Has Been Implemented

- **YIN-based pitch detection engine**
  - Implements the YIN algorithm (difference function + CMND) with parabolic interpolation for sub-sample accuracy.
  - Detects the fundamental frequency (not just the strongest harmonic) for guitar/bass/piano/voice.
  - Provides a **confidence** metric derived from the CMND minimum around the detected period.
  - Applies **exponential smoothing** (\( \alpha \approx 0.15 \)) to the detected frequency to reduce jitter without adding significant latency.

- **Stability logic**
  - Tracks the most recent detected note and its cents offset over time.
  - Marks a note as **stable** when:
    - The same note name/octave has been detected for **≥ 120 ms**, and
    - The cents variation in that window is within **±3 cents**.
  - Resets state on:
    - Silence (input level below -50 dBFS), or
    - Large deviations beyond **±50 cents** (treated as unstable/note change).

- **Note mapping with calibration**
  - Maps raw frequencies to notes using 12-TET:
    - \( \text{midi} = 69 + 12 \log_2(f / A_4) \)
    - Supports adjustable **A4 calibration** (e.g. 432–446 Hz).
  - Returns **note name**, **octave**, and **cents offset**, with final output cents clamped to **[-50, +50]**.

- **JS bridge emission (React Native compatible)**
  - Emits stable tuner results over an event named `onTunerPitch` with payload:
    - `detectedFrequency`
    - `noteName`
    - `octave`
    - `centsOffset`
    - `confidence`
    - `inputLevel` (optional)
  - Emits a consistent **“no note / unstable”** payload (e.g. `noteName = null`, `confidence = 0`) for silence or unstable pitch.

- **Offline test harness**
  - Provides helpers to:
    - Generate synthetic sine waves at known frequencies.
    - Run the pitch engine on these buffers to validate detected frequency and stability.
    - Quickly sanity-check `NoteMapper` (e.g., 440 Hz → A4, 261.63 Hz → C4).

---

### What Has Been Changed

- **Core mic capture and FFT pipeline** (`MicInputIOS`, `RealtimeMicProcessor`, `RealtimeFFTEngine`, `RealtimeAudioAnalyzer`) are **unchanged** in this commit.
- All new behavior (pitch detection, stability, note mapping, and JS bridge emission) is implemented in **separate, self-contained Swift files** under `MicInputFoundation`, so the existing real-time audio pipeline and UI remain unaffected.
- The UI layer is still responsible only for **consuming** emitted values; it does **not** perform any DSP or pitch calculations.

---

### New Files Created

- **`MicInputFoundation/PitchDetectionEngine.swift`**
  - Core YIN-based pitch engine.
  - Implements:
    - `PitchRaw`
    - `PitchResult`
    - `TuningState`
    - `PitchStabilityTracker`
  - Handles:
    - YIN difference and CMND calculations.
    - Thresholding and parabolic interpolation.
    - Smoothing of detected frequency.
    - Silence detection and state reset.

- **`MicInputFoundation/NoteMapper.swift`**
  - Implements `NoteMapper` and `NoteMapping`.
  - Maps a frequency to MIDI note, note name, octave, and cents offset using adjustable A4.

- **`MicInputFoundation/TunerPitchEmitter.swift`**
  - React Native `RCTEventEmitter` (when `React` is available) to send tuner events to JS.
  - Provides a stub implementation for non-React builds so the demo app can compile without RN.

- **`MicInputFoundation/PitchDetectionTestHarness.swift`**
  - Offline test utilities:
    - Sine-wave generation.
    - Basic pitch detection run helper.
    - Debug helpers for `NoteMapper` (e.g. for A4 and C4).

---

### Integration Notes (High Level)

- The pitch engine is designed to be fed from the **existing mic pipeline**:
  - Use the PCM float buffers from `MicInputIOS` / `RealtimeAudioAnalyzer`.
  - Compute an input level in dBFS (from RMS/peak) and pass it into `processAudioFrame`.
  - Use `TunerPitchEmitter` to emit stable results or “no note” states to JS.
- The overall architecture follows:
  - **Mic Input → PitchDetectionEngine → Stability Logic → JS TunerPitchEmitter → UI Needle**

