# Run the iOS port (Simulator + physical iPhone)

Branch: **`ios-port`** on this fork.  
Engine: **official `libslic3r`** exposed through a thin C ABI (`src/ios/orca_slice_c_api.*`) — **not** a Swift rewrite of the slicer.

The SwiftUI host lives under `ios/`. Desktop **wxWidgets** is not used on iPhone.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| **macOS** | Recent macOS with enough free disk (deps builds are large) |
| **Xcode** | Full Xcode from the App Store (not only Command Line Tools). Open once and accept the license. |
| **Apple ID** | Free Apple ID is enough for personal device installs; paid Apple Developer Program optional |
| **CMake ≥ 3.13** | Needed only if you rebuild deps/engine scripts |
| **USB cable** (device) | For first install / trust on a physical iPhone |

Optional: set `PATH` so a custom CMake is found, e.g. `export PATH="$HOME/local/bin:$PATH"`.

---

## Simulator run

1. Ensure Simulator engine libraries exist (or rebuild — see [Rebuild engine](#rebuild-engine-if-needed)):
   - `build-ios-iphonesimulator-arm64/engine_bundle/lib/liborca_engine.a`
2. Open the host project:
   ```bash
   open ios/OrcaSlicer.xcodeproj
   ```
3. In Xcode, choose an **iPhone Simulator** destination (e.g. iPhone 16 / 17).
4. Press **Run** (⌘R).
5. In the app: load the sample cube (or import a model) → **Slice plate**. With `ORCA_LINKED`, slicing uses official `libslic3r` via the C API.

**Mac “My Mac”** destination also works when the macOS headless engine bundle is present (`build-macos-headless-arm64/engine_bundle`).

---

## Physical iPhone

### 1. Trust the Mac / cable

1. Connect the iPhone with a data-capable USB cable.
2. Unlock the phone; if prompted, tap **Trust This Computer** and enter the passcode.

### 2. Developer Mode (iOS 16+)

On iOS 16 and later, apps signed for development require **Developer Mode**:

1. On the iPhone: **Settings → Privacy & Security → Developer Mode** → enable.
2. Restart when prompted, then confirm.
3. If the toggle is missing, connect the device to Xcode once (or install any development build); the option usually appears afterward.

### 3. Signing Team in Xcode

1. Open `ios/OrcaSlicer.xcodeproj`.
2. Select the **OrcaSlicer** target → **Signing & Capabilities**.
3. Enable **Automatically manage signing**.
4. Choose your **Team** (personal team from your Apple ID is fine for local install).
5. If the bundle id `com.orcaslicer.ios` is already taken for your team, change **Bundle Identifier** to something unique (e.g. `com.yourname.orcaslicer.ios`).

`generate_xcodeproj.py` leaves `DEVELOPMENT_TEAM` empty so each developer picks their own Team in the UI (or sets it in the project).

### 4. Device engine + Run

1. Confirm the **device** engine library exists:
   - `build-ios-iphoneos-arm64/engine_bundle/lib/liborca_engine.a`  
   If missing, rebuild for `iphoneos` (below).
2. Select your **physical iPhone** as the run destination.
3. Press **Run** (⌘R). First install may take longer; keep the device unlocked.
4. On the phone, if you see an untrusted developer alert, follow [Untrusted developer](#untrusted-developer) below, then launch the app again.

---

## Rebuild engine if needed

Build **deps first**, then the **engine** (and Xcode project regen). Target and arch:

| Destination | `TARGET` | `ARCH` | Engine bundle path |
|---|---|---|---|
| iOS Simulator | `iphonesimulator` | `arm64` | `build-ios-iphonesimulator-arm64/engine_bundle/` |
| Physical iPhone | `iphoneos` | `arm64` | `build-ios-iphoneos-arm64/engine_bundle/` |

```bash
cd /path/to/OrcaSlicer   # this repo, branch ios-port
export PATH="$HOME/local/bin:$PATH"

# Simulator
./scripts/build_ios_deps.sh iphonesimulator arm64
./scripts/build_ios_engine_after_deps.sh iphonesimulator arm64

# Physical device
./scripts/build_ios_deps.sh iphoneos arm64
./scripts/build_ios_engine_after_deps.sh iphoneos arm64
```

- Deps install under `deps/build-ios-<target>-arm64/OrcaSlicer_dep/usr/local`.
- Engine script configures CMake with `ORCA_IOS=ON` / `ORCA_IOS_API=ON`, builds `orca_ios_api`, runs `bundle_engine_libs.sh`, and regenerates `ios/OrcaSlicer.xcodeproj`.
- Logs: `build_logs/ios_deps_*.log`, engine configure/build logs under `build_logs/`.
- After a successful engine build, rebuild/run from Xcode so `ORCA_LINKED` links `liborca_engine.a`.

**macOS headless proof** (optional, not required for iPhone install):

```bash
./scripts/build_macos_headless_api.sh
./scripts/bundle_engine_libs.sh
```

---

## Troubleshooting

### Signing / provisioning

- **Failed to register bundle identifier** — pick a unique Bundle ID under Signing & Capabilities.
- **No profiles for team** — sign in to Xcode with your Apple ID (**Xcode → Settings → Accounts**), select a Team, clean build folder (⇧⌘K), try again.
- **Device not listed** — unlock phone, trust the Mac, use a data cable; check **Window → Devices and Simulators**.

### Untrusted developer

After first install from a free/personal team:

1. On iPhone: **Settings → General → VPN & Device Management** (wording varies by iOS version).
2. Select your developer certificate / Apple ID.
3. Tap **Trust**, then open the app from the home screen.

### Icon cache (stale app icon)

The port ships a **3D Orca** app icon via `ios/OrcaSlicerApp/Assets.xcassets/AppIcon.appiconset`. If the home screen still shows an old/generic icon:

1. Delete the app from the device/simulator.
2. In Xcode: **Product → Clean Build Folder**.
3. Rebuild and reinstall.
4. If needed on Simulator: **Device → Erase All Content and Settings**, or reboot the physical device.

### Missing `ORCA_LINKED` / slice disabled

- Engine static lib missing for that SDK → rebuild deps + engine for `iphonesimulator` or `iphoneos` as appropriate.
- After building engine, reopen or regenerate the Xcode project (`python3 ios/generate_xcodeproj.py` is also run by `build_ios_engine_after_deps.sh`).

### Link errors for `liborca_engine`

Confirm the library path matches the destination:

- Simulator → `build-ios-iphonesimulator-arm64/engine_bundle/lib`
- Device → `build-ios-iphoneos-arm64/engine_bundle/lib`

Do not mix simulator and device archives.

---

## Architecture note

```
Official libslic3r (C++ — upstream engine sources)
        ↑
   orca_ios_api  (src/ios — thin C ABI)
        ↑
   SwiftUI app   (ios/OrcaSlicerApp — mobile UI only)
```

This is a **port host** for the official engine, not a reimplementation of Arachne, supports, or G-code export in Swift.

**License:** same as upstream — **AGPL-3.0**. Review obligations before any App Store or closed distribution.

### App closes during startup

A startup marker is written before entering the native engine. If startup is interrupted, reopen the app to reach **Startup recovery** before the engine is constructed. Choose **Open without system profiles** to bypass profile loading, or **Rebuild profile cache and retry** to recreate the generated system profiles.

Rebuilding moves only `Documents/OrcaSlicer/system` into `Documents/OrcaSlicer/Recovered system profiles/<unique ID>`. Projects, plates, user presets, saved printer connections and Keychain credentials remain in place. A changed bundled profile revision also replaces that generated mirror. Profile-cache completion is recorded only after profile loading succeeds.

The iOS resource generator excludes desktop executables, libraries and `.opc` profile caches. The simulator package audit rejects Windows/ELF binaries, desktop caches, wrong-platform Mach-O binaries and unexpected dynamic dependencies. These checks do not diagnose every possible device crash.

If the app closes before displaying recovery, or still closes with system profiles bypassed, collect its crash report from **Settings → Privacy & Security → Analytics & Improvements → Analytics Data**. Look for `OrcaSlicer` or a matching `JetsamEvent` and share the `.ips` report. It can distinguish a signing or dynamic-loader failure, an exception and an OS memory termination. Deleting the app is not required to try recovery and can remove its local projects.

The supplied LiveContainer crash report on iOS 26.4 showed `EXC_BAD_ACCESS / KERN_PROTECTION_FAILURE` in a main-thread stack-guard page while Swift and SwiftUI were resolving generic view metadata during first layout. It did not show a desktop library-loader failure. Screen-sized `AnyView` boundaries now limit the root composition's metadata depth. The simulator launch check also requests root view metadata on a 1 MB worker stack before UI startup. These checks do not reproduce LiveContainer or establish physical iOS 26.4 compatibility; that still requires retesting the rebuilt app on the affected phone.

### Opening models and settings

Open/Add use a native document picker. Preset import first dismisses the process sheet so the picker has a free presenter. STL, OBJ, 3MF and AMF are supported model inputs. JSON settings and `.orca_printer`, `.orca_filament`, `.orca_bundle` or ZIP preset exports use the settings importer. Open also routes preset files to this importer. The app also registers these document types for Files/Share opening.

Selected and externally opened files are read under security-scoped access with `NSFileCoordinator`, then copied into uniquely named folders in `Documents/OrcaSlicer/Imports`. Recent-file entries refer to those local copies. The import queue waits for profile startup and slicing to finish before calling the engine. Temporary engine staging also uses unique directories and never removes an identically named source before copying.

Orca/Bambu 3MF imports explicitly request both model geometry and project settings. Missing these flags previously made a valid archive report as empty. Reader failures preserve the previous model and preview. Native parsing runs away from the UI thread while model editing is paused. The simulator regression imports a synthetic archive larger than 100 MB through the engine and native document inbox; it contains a small mesh and padding, so it does not establish memory limits for complex meshes.

Prepare and Preview start with a compact controls drawer. Swipe its handle down to hide controls, swipe up to expand them, or use the chevron. Expanded controls scroll within the drawer. The camera frames the model using the visible viewport rather than the full printer bed.

### Native Orca Cloud account and printers

The Device page discovers enabled sign-in methods from the official authentication service. Google, Apple, Facebook and GitHub use `ASWebAuthenticationSession` with the upstream PKCE protocol and registered `http://localhost:41172/callback` redirect. Email/password is also supported. SMS and enterprise SSO appear only if enabled by the service. Verified TOTP/phone factors can complete a second authentication step; provisional tokens are not saved before verification. Passwords are not persisted.

Only loopback peers, the expected host/path, and a single matching state/code are accepted for browser callbacks. Authentication codes are exchanged at the official token endpoint; refresh/access tokens stay in a distinct device-only Keychain item. HTTP redirects are rejected on token and printer API requests. Provider and verification flows have protocol fixture coverage; successful interactive sign-in still depends on the provider's configuration and needs an account test on the device.

The account restores its session, refreshes tokens, and fetches `/api/v1/printers` and `/api/v1/sync/pull` manually or while the account panel is visible. Printer, filament and process presets load into the official native catalog. Use **Show all synced presets in Process** if compatibility filtering hides a preset, and **Upload local presets to Orca Cloud** to send user presets through the conflict-checked sync API. A conflict preserves both versions; automatic deletion of local presets from cloud tombstones is not implemented. Cloud printer metadata, connection state and job state appear natively. A cloud printer can be linked to one saved local connection; this association persists without uploading LAN addresses or access codes. Registration of new cloud printers remains on the cloud website. Native printer transport and cloud account membership are separate: account synchronization does not discover a Flashforge IP address or obtain its LAN access code automatically.

### Flashforge AD5X and Adventurer 5M

Choose **Flashforge** on Device, enter the printer IP/URL (default HTTP port 8898), serial number and LAN access code, then Connect. Saved connections keep the serial in local metadata and the access code in Keychain. This uses the modern local HTTP protocol supported by upstream `Flashforge.cpp`; it does not load a desktop plugin or use a Flashforge cloud account. Legacy 8899-only firmware is not implemented.

Select the matching official Flashforge slicing profile in Process before uploading. The connector reads `/detail` for temperatures, status and AD5X material slots. An AD5X material station can map generated G-code tools 0–3 to loaded slots 1–4. Only tools found in the G-code are sent in the mapping; empty/missing slots and unsupported tools are rejected. UI tool labels are 1-based. File upload streams a temporary multipart body and sets `printNow=false`. **Start print** sends a separate `/printGcode` request for that upload; changing the connection, slice or print options invalidates the start target. Cancel uses `/control` with `jobCtl_cmd`.

Protocol fixtures verify requests and error handling without contacting a printer. Physical firmware compatibility, IFS color/material behavior and actual printing still require testing on the AD5X and 5M.

### Touch controls and installed build

Choose **Orbit**, **Pan**, **Move**, **Rotate** or **Select** in the viewport strip. Each uses one finger. Pinch with two fingers to zoom in any mode. Move translates the object on the bed; Rotate turns it around Z. Use **Fit** to frame the model again. The drawer handle can still hide the lower controls. **About** shows the build revision so an older installed IPA can be distinguished from a new build.
