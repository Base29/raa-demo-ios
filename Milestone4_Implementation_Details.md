# Milestone 4: Native iOS Recorder and Playback Implementation

This document details the native Swift implementation for the audio recorder and playback engines, separated into two distinct React Native TurboModules.

## 1. Recorder Module (`RecorderModuleIOS.swift` & `RecorderEngineIOS.swift`)

The `RecorderModuleIOS` manages high-quality mono audio recording.

- **Audio Format**: AAC (MPEG-4 AAC) in `.m4a` container.
- **Configuration**: 44.1 kHz, Mono, 128 kbps.
- **Audio Session**: Uses `.measurement` mode for clean input.
- **Precision Duration**: Uses `audioRecorder.currentTime` for accurate duration tracking.
- **Metering**: Emits `rmsDb` and `peakDb` values every 100ms.
- **Safety**: 
    - **State Guards**: Prevents multiple concurrent recordings.
    - **Interruption Handling**: Uses a dedicated `finalizeInterruptedRecording()` flow to safely stop and finalize recordings on `AVAudioSession` interruptions without redundant event emissions. Emits `interrupted`.
    - **Playback Blocking**: Automatically stops any active playback when a recording session starts.
- **Events**:
    - `Recorder:onMeter`: Metering values (`rmsDb`, `peakDb`).
    - `Recorder:onDuration`: Current recording duration.
    - `Recorder:onState`: `recording`, `stopped`, `interrupted`.
    - `Recorder:onError`: Error messages.

## 2. Playback Module (`PlaybackModuleIOS.swift` & `PlaybackEngineIOS.swift`)

The `PlaybackModuleIOS` provides a deterministic audio player with precision trim handling.

- **Core Features**: Load, Play, Pause, Stop, and Seek.
- **Deterministic Trim Handling**:
    - **Play Behavior**: Always seeks to `trimStart` if the position is at or before the start, or after the end.
    - **Relative Progress**: Emits `currentTime` as `player.currentTime - trimStart` and `duration` as `trimEnd - trimStart`.
    - **Seek Clamping**: Clamps all seek operations within the `trimStart` and `trimEnd` bounds.
    - **Completion**: Pauses and emits `completed` upon reaching `trimEnd` (does not reset to zero).
- **Interruption Handling**: Automatically **stops** playback on interruptions (resetting to `trimStart`). Emits `interrupted`.
- **State Guards**: Prevents operations without a valid loaded state.
- **Events**:
    - `Playback:onPosition`: Relative `currentTime` and `duration`.
    - `Playback:onState`: `loaded`, `playing`, `paused`, `stopped`, `completed`, `interrupted`.
    - `Playback:onError`: Error messages.

## 3. Bridge Integration (`AudioModuleBridge.mm`)

The native modules are exposed to React Native as two separate entities:

### RecorderModuleIOS Methods
- `startRecording(filePath: String)`
- `stopRecording()`

### PlaybackModuleIOS Methods
- `load(filePath: String, options: { trimStart, trimEnd })`
- `play(options?)`
- `pause()`
- `stop()`
- `seek(positionInSeconds: Double)`

## 4. Production Safety
- `requiresMainQueueSetup`: Set to `false` for both modules to improve performance.
- `hasListeners`: Implemented guards to prevent unnecessary event emission when no JS listeners are active.
- `deinit`: Proper cleanup in modules ensures `recorder.stopRecording()` and `playback.stop()` are called when modules are destroyed, guaranteeing safe file finalization and audio termination.
- **Event Ordering**: The engines ensure a final progress/duration update is emitted immediately before a `completed` or `interrupted` state change.

