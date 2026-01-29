
# Mic Input Foundation - iOS Demo App

This repository validates Milestone 1 "Mic Input Foundation" by providing a buildable iOS Xcode project that demonstrates microphone capture functionality.

## Project Structure

```
raa-demo-ios/
├── DemoAppSources/           ← App source files (do not use as Xcode "Save" location)
│   └── DemoApp/
│       ├── DemoAppApp.swift
│       ├── ContentView.swift
│       ├── MicInputViewModel.swift
│       ├── Info.plist
│       └── Foundation/
│           ├── MicInputIOS.swift
│           └── MicInputErrorHandler.swift
├── MicInputFoundation/       ← Original foundation (reference)
└── README.md
```

After you create the Xcode project (see below), Xcode will add a `DemoApp/` folder containing `DemoApp.xcodeproj` and the app target files.

## Requirements

- **Xcode**: 14.0 or later  
- **iOS Deployment Target**: 15.0 or later  
- **Swift**: 5.0 or later  

---

## How to Build

App sources live in `DemoAppSources/DemoApp/`. Xcode expects to **create** a folder named `DemoApp` when you make a new project. If you choose a save location that already contains a `DemoApp` folder (e.g. inside `DemoApp/` or where `DemoApp/` exists), Xcode will show **"DemoApp folder already exists"** and refuse to create the project.

**Rule**: Create the new Xcode project with **Save in** = the **repository root** (`raa-demo-ios`), **not** inside `DemoApp` or `DemoAppSources`. The sources stay in `DemoAppSources/`; you will add them to the project in a later step.

---

### Option 1: Create New Xcode Project (Recommended)

Do these steps in order.

#### Step 1: Create the Xcode project

1. Open **Xcode**.
2. **File → New → Project** (or press **Shift+Cmd+N**).
3. Choose **iOS → App**, then **Next**.
4. Set:
   - **Product Name**: `DemoApp`
   - **Team**: your team (or none for simulator-only)
   - **Organization Identifier**: e.g. `com.example`
   - **Interface**: **SwiftUI**
   - **Language**: **Swift**
   - **Storage**: None. Uncheck "Use Core Data" and "Include Tests" if shown.
5. Click **Next**.
6. **Choose the save location**:
   - Navigate to the **repository root**:  
     `.../raa-demo-ios`  
     (e.g. `/Users/faisalhussain/Desktop/raa-demo-ios`).
   - **Do not** select `DemoApp` or `DemoAppSources`. Select the **raa-demo-ios** folder itself.
7. Click **Create**.

Xcode will create `raa-demo-ios/DemoApp/` with `DemoApp.xcodeproj` and a default `DemoApp/` app target folder (with `ContentView.swift`, `DemoAppApp.swift`, etc.).

#### Step 2: Replace default app files with our sources

1. In the **Project Navigator** (left sidebar), expand the **DemoApp** group.
2. Select the default app files Xcode created (e.g. `ContentView.swift`, `DemoAppApp.swift`, and `DemoApp.entitlements` if present). **Do not** delete `Assets.xcassets` or the project/target entries.
3. Right‑click → **Delete** → choose **Move to Trash**.
4. Right‑click the **DemoApp** group → **Add Files to "DemoApp"...**.
5. Navigate to **`DemoAppSources/DemoApp/`** inside the repo.
6. Select:
   - `DemoAppApp.swift`
   - `ContentView.swift`
   - `MicInputViewModel.swift`
   - **`Foundation`** folder (contains `MicInputIOS.swift` and `MicInputErrorHandler.swift`)
   - `Info.plist`
7. Options:
   - **Copy items if needed**: **unchecked** (we want references into `DemoAppSources`).
   - **Add to targets**: **DemoApp** checked.
   - **Create groups** (not "Create folder references").
8. Click **Add**.

#### Step 3: Use our Info.plist and add microphone permission

1. Select the **DemoApp** project (blue icon) in the Project Navigator.
2. Select the **DemoApp** target.
3. Open the **Info** tab.
4. Add an entry:
   - **Key**: `Privacy - Microphone Usage Description`  
   - **Value**: `This app needs microphone access to demonstrate mic input capture.`  

   If you added `Info.plist` from `DemoAppSources/DemoApp/`, it may already contain `NSMicrophoneUsageDescription`. If the target’s **Custom iOS Target Properties** still show no microphone usage description, add the key above there.

5. **Use our Info.plist:** In **Build Settings**, search **Info.plist File** and set it to the `Info.plist` you added (e.g. `DemoAppSources/DemoApp/Info.plist`). Then add the microphone key via the **Info** tab if it’s not already in that plist.

#### Step 4: Build and run

1. Select a **simulator** or a **real device** in the scheme selector.
2. **Product → Build** (or **Cmd+B**).
3. **Product → Run** (or **Cmd+R**).

The project should compile on the simulator. Microphone capture only works on a **real device**; the frame counter will stay at 0 on the simulator.

---

### Option 2: Create Project on Desktop, Then Move Into Repo

Use this if you prefer not to create the project inside the repo first (e.g. to avoid any existing folder).

1. In Xcode, **File → New → Project** → iOS App → **Next**.
2. Product Name: **DemoApp**, Interface: **SwiftUI**, Language: **Swift** → **Next**.
3. **Save in**: your **Desktop** (or any folder that does **not** contain a `DemoApp` folder). Click **Create**.
4. Follow **Step 2** and **Step 3** from Option 1, but when adding files, navigate to `raa-demo-ios/DemoAppSources/DemoApp/` on your machine.
5. Build and run to confirm it works.
6. **Quit Xcode.** Move the entire **`DemoApp`** folder (the one Xcode created on the Desktop) into **`raa-demo-ios/`**. Replace the existing `DemoApp` folder there if you had created one earlier.
7. Reopen the project from **`raa-demo-ios/DemoApp/DemoApp.xcodeproj`** and build again.

---

### Option 3: Add Sources to an Existing Xcode Project

If you already have an iOS app project:

1. Copy (or add by reference) the contents of **`DemoAppSources/DemoApp/`** into your project (including the **Foundation** folder).
2. Add those files to your app target (right‑click → **Add Files to "...**" → ensure your target is checked).
3. Add **Privacy - Microphone Usage Description** to your target’s Info, as in Step 3 of Option 1.
4. Build and run.

---

## Troubleshooting

### "Multiple commands produce ... Info.plist"

Xcode is copying `Info.plist` twice: once via the target’s **Info.plist File** setting and once from **Copy Bundle Resources**.

**Fix:** Remove `Info.plist` from the **Copy Bundle Resources** build phase (it must only be set as the target’s Info.plist, not copied again):

1. Select the **DemoApp** project in the Project Navigator.
2. Select the **DemoApp** target.
3. Open the **Build Phases** tab.
4. Expand **Copy Bundle Resources**.
5. Find **Info.plist** in the list.
6. Select it and click the **−** (minus) button to remove it.
7. Build again (Cmd+B).

The target’s **Build Settings → Info.plist File** still points to your plist; Xcode will copy it once from there. Do **not** add `Info.plist` back to Copy Bundle Resources.

### "DemoApp folder already exists"

- You chose a **Save** location that already has a folder named **DemoApp** (e.g. inside `DemoApp/` or `DemoAppSources/`).
- **Fix**: Use **Option 1** and set **Save in** to the **repository root** (`raa-demo-ios`), **not** `DemoApp` or `DemoAppSources`. Xcode will create a new `DemoApp/` there.

### "Cannot find type 'MicInputIOS'" / foundation symbols missing

- The **Foundation** folder (`MicInputIOS.swift`, `MicInputErrorHandler.swift`) was not added, or is not part of the **DemoApp** target.
- **Fix**: **Add Files to "DemoApp"** → add the **Foundation** folder from `DemoAppSources/DemoApp/`, and ensure **Add to targets: DemoApp** is checked.

### Microphone permission denied / Start disabled

- The app needs **Privacy - Microphone Usage Description** in the target **Info**.
- **Fix**: Add the key as in Step 3 of Option 1. If permission was denied earlier, enable it in **Settings → Privacy & Security → Microphone** for your app.

### App builds but frame counter stays 0

- Expected on the **simulator**; there is no real microphone.
- **Fix**: Run on a **physical device** to test capture and the frame counter.

---

## Features

### Foundation (MicInputIOS, MicInputErrorHandler)

- **Capture-only**: No DSP (no RMS/peak/FFT).
- **No routing/orchestration**: Pure mic capture.
- **Real-time safe**: No allocations, logging, locks, or blocking in the audio callback.
- **Thread-safe**: Lock-free atomics where needed.

### Demo app

- **Start / Stop** mic capture.
- **Labels**: sample rate, channels, buffer size, total frames received.
- **Frame counter** updated every 250 ms on the main thread.
- **Microphone permission** handling; Start disabled if denied.

---

## Runtime Behavior

**Start**: Creates `MicInputIOS`, calls `start(config:onPCM:)` with 48 kHz, 1 channel, 1024-frame buffers. The `onPCM` callback only atomically adds `frameCount` to a counter. A **Timer** on the main thread updates the UI every 250 ms.

**Stop**: Calls `stop()`, invalidates the timer. The frame count is left as-is (not reset).

---

## Testing

| Environment | Build | Mic capture / frame counter |
|-------------|--------|-----------------------------|
| **Simulator** | ✅ | ❌ (no mic; counter stays 0) |
| **Real device** | ✅ | ✅ |

---

## Code Compliance

- **No DSP, routing, timestamps, or logging** in the mic foundation.
- **No allocations, locks, or blocking** in the real-time audio callback.
- **Atomic, thread-safe** frame counter; UI updates on the main thread only.

---

## Notes

- The foundation has no dependency on React Native or other external libraries.
- Types like `MicInputConfig`, `MicInputException`, `PCMCallback` are defined in the foundation.
- The demo only counts frames; it does not process audio.
