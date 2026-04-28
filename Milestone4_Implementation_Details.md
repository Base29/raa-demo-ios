# Milestone 4: Native iOS Recorder and Playback Implementation

This document details the native Swift implementation for the audio recorder and playback engines, designed to be used via a React Native TurboModule bridge.

## 1. Recorder Engine (`RecorderEngineIOS.swift`)

The `RecorderEngineIOS` handles high-quality mono audio recording using the `AVFoundation` framework.

- **Audio Format**: AAC (MPEG-4 AAC)
- **Container**: `.m4a`
- **Sample Rate**: 44.1 kHz
- **Channels**: 1 (Mono)
- **Bitrate**: 128 kbps
- **Metering**: Emits `rmsDb` and `peakDb` values every 100ms during recording.
- **Duration**: Emits real-time recording duration in seconds.
- **Safety**: 
    - Automatically activates and configures the `AVAudioSession`.
    - Handles safe file finalization on manual stop or unexpected interruptions (e.g., incoming calls).
    - Prevents file corruption by ensuring the recorder is properly closed before returning the file path.

## 2. Playback Engine (`PlaybackEngineIOS.swift`)

The `PlaybackEngineIOS` provides a robust audio player with support for virtual trimming.

- **Core Features**: Load, Play, Pause, Stop, and Seek.
- **Trim Support**: 
    - Supports `trimStart` and `trimEnd` metadata.
    - If `trimStart` is provided, playback starts at that position.
    - If `trimEnd` is provided, the engine automatically stops playback once `currentTime >= trimEnd`.
    - **Note**: The original file is never modified or sliced.
- **Events**: Emits `currentTime` and `duration` every 150ms.
- **States**: Emits state changes: `loaded`, `playing`, `paused`, `stopped`, `completed`, `error`.
- **Interruption Handling**: Automatically stops playback if interrupted.

## 3. TurboModule Integration (`AudioModuleIOS.swift` & `AudioModuleBridge.mm`)

The integration layer bridges the native Swift engines to React Native.

### JS Methods Exposed
- **Recorder**:
    - `startRecording(filePath: String)`: Starts recording to the specified path.
    - `stopRecording()`: Returns a Promise resolving to the finalized file path.
- **Playback**:
    - `load(filePath: String, options: { trimStart, trimEnd })`: Prepares a file for playback.
    - `play(options?)`: Starts or resumes playback (respecting trim bounds).
    - `pause()`: Pauses playback.
    - `stop()`: Stops playback and resets position to zero.
    - `seek(positionInSeconds: Double)`: Jumps to a specific time.

### Events Emitted to JS
- `onRecorderMeter`: `{ rmsDb: Float, peakDb: Float }`
- `onRecorderDuration`: `{ duration: Double }`
- `onPlaybackPosition`: `{ currentTime: Double, duration: Double }`
- `onPlaybackState`: `{ state: String }`

### Orchestration Rules
- **Recording Priority**: If `startRecording` is called while playback is active, the engine automatically stops playback immediately to prevent feedback and session conflicts.
- **Single Instance**: Both engines are managed as single instances within the module, ensuring consistent state between "Preview" and "Full Player" components in the JS app.
