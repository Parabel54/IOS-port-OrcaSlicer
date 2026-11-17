# iOS port — build notes

Branch: `ios-modernization`
Engine: official `libslic3r` via `src/ios/orca_slice_c_api` → `liborca_engine.a`  
Host: SwiftUI app in `ios/OrcaSlicerApp` (`ORCA_LINKED` when engine is linked).

## Prerequisites

- Xcode 16+ / iOS 16.0 deployment target  
- cmake at `$HOME/local/bin/cmake` (or on `PATH`)  
- iOS deps already built under:
  - `deps/build-ios-iphonesimulator-arm64/OrcaSlicer_dep/usr/local`
  - `deps/build-ios-iphoneos-arm64/OrcaSlicer_dep/usr/local`
  - Intel simulator builds use `deps/build-ios-iphonesimulator-x86_64/OrcaSlicer_dep/usr/local` instead of the ARM simulator prefix.

## Engine rebuild

```bash
export PATH="$HOME/local/bin:$PATH"
# Apple Silicon simulator
./scripts/build_ios_engine_after_deps.sh iphonesimulator arm64
# Intel simulator (build dependencies for the same target architecture first)
./scripts/build_ios_deps.sh iphonesimulator x86_64
./scripts/build_ios_engine_after_deps.sh iphonesimulator x86_64
# Device
./scripts/build_ios_engine_after_deps.sh iphoneos arm64
```

Bundles land in:

- `build-ios-iphonesimulator-arm64/engine_bundle/lib/liborca_engine.a`
- `build-ios-iphoneos-arm64/engine_bundle/lib/liborca_engine.a`
- `build-ios-iphonesimulator-x86_64/engine_bundle/lib/liborca_engine.a` (Intel simulator)

## App build

```bash
# Generator defaults to an ARM simulator. On Intel, add --simulator-arch x86_64.
python3 ios/generate_xcodeproj.py --require-engine iphonesimulator --simulator-arch arm64
xcodebuild -project ios/OrcaSlicer.xcodeproj -scheme OrcaSlicer \
  -sdk iphonesimulator -configuration Release -derivedDataPath build-ios-app \
  ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build
# Run native, GPU and phone/tablet UI tests on the matching Mac architecture.
bash scripts/test_ios_simulator.sh arm64
```

On Intel, use `x86_64` for both generator/build arguments and the simulator test.
Choose an available iOS runtime from the selected Xcode SDK family; the smoke
script selects one automatically. Device builds always target `iphoneos arm64`.
Set your own development team in Xcode for physical installation.

CI uses standard `macos-15-intel` hosts for both targets because ARM hosted jobs
have been failing to acquire runners. Engine/dependency/compiler caches include
host and target architectures. Native, GPU rendering and UI assertions remain
enabled on the Intel simulator. `audit_ios_app.py` checks the requested CPU,
iOS versus simulator platform, Apple runtime dependencies and foreign binaries.
An SDK type-check pass alone does not establish native runtime correctness.

## Profiles

Full vendor trees live in `ios/OrcaSlicerApp/Resources/profiles` (copied into the app bundle).  
First launch installs them into Documents via `orca_session_load_all_presets` (can take several seconds).  
Subsequent launches **skip reinstall** when `Documents/OrcaSlicer/system/<vendor>/` already exists.  
User process presets: `Documents/OrcaSlicer/user_presets/process/*.json`.

## Memory (full profile tree)

- Official `PresetBundle` keeps system presets in process memory (same model as desktop).
- Mitigations on iOS:
  - Skip vendor reinstall after first run
  - Compatible-only process/filament name lists after printer select
  - Lazy enum lists in the settings browser
  - G-code path cap (~60k points) + travel subsampling; ribbon sampling
  - `UIApplication.didReceiveMemoryWarning` drops G-code preview + option caches
- After load, status line reports approximate RSS (`~N MB`).

## Status

See `docs/IOS_PORT_COMPLETION.md` and `docs/IOS_PORT_STATUS.json`.
