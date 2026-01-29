# Project Setup Reference

Quick reference for building the Demo App. **See [README.md](../README.md) for full, step-by-step build instructions.**

## Why "DemoApp folder already exists"?

Xcode creates a folder with the **project name** inside the **Save** location. If you choose a path that already has a `DemoApp` folder (e.g. inside `DemoApp/` or `DemoAppSources/`), Xcode refuses and shows that error.

**Fix:** Create the new project with **Save in** = the **repository root** (`raa-demo-ios`), not inside `DemoApp` or `DemoAppSources`. App sources stay in `DemoAppSources/DemoApp/`; you add them to the project after creation.

## File locations

| What | Where |
|------|--------|
| App source files | `DemoAppSources/DemoApp/` |
| Foundation (MicInputIOS, etc.) | `DemoAppSources/DemoApp/Foundation/` |
| Info.plist (mic permission) | `DemoAppSources/DemoApp/Info.plist` |
| Xcode project (after you create it) | `DemoApp/DemoApp.xcodeproj` |

## Build flow (summary)

1. **Create** new iOS App project "DemoApp" in Xcode; **Save in** `raa-demo-ios` (repo root).
2. **Remove** Xcode’s default app Swift files (ContentView, App entry point, etc.).
3. **Add** files from `DemoAppSources/DemoApp/` (including `Foundation/`) to the DemoApp target.
4. **Add** `Privacy - Microphone Usage Description` to the target Info.
5. **Build** (Cmd+B) and **Run** (Cmd+R).

## Notes

- Project compiles on Simulator; mic capture requires a **real device**.
- Foundation code has no React Native or other external dependencies.
