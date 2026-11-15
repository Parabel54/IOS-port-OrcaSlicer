# iOS modernization — November 14, 2026

The source integrates official OrcaSlicer **v2.5.1** with the existing iOS branch.
Unsigned iPhone and simulator builds pass CI. The engine workflow and app launch are verified on the iOS Simulator; this is not a physical-device-verified release. The source merge
includes upstream engine, profiles, dependency versions and desktop changes.
The mobile CAD interface remains unimplemented; SLIC3R_CAD is disabled only for
the iOS/headless dependency path. Normal desktop configuration retains upstream defaults.

## Implemented in this integration

- Resolve upstream/iOS build conflicts while preserving headless iOS exclusions.
- Add Assimp to the mobile dependency set because current libslic3r requires it.
- Keep upstream GMP 6.3.0 and iOS cross-compilation flags.
- Forward real engine slicing status into the existing C/Swift progress callback.
- Generate stable Xcode project IDs and synchronize official profiles on generation.
- Remove a previous developer's signing team as the generator default.
- Require a nonempty SDK-specific engine archive and bundled profiles for CI builds.
- Reject missing core archives during engine bundling.
- Bundle nozzle, flush-prediction and filament-mixing tables required by the engine.
- Add unsigned device/simulator build workflow: `.github/workflows/ios-engine.yml`.

The mobile bootstrap initializes writable temporary storage for model backups. Saved Slic3r-format 3MF projects use the matching upstream reader. Fallback printer settings provide the layer reset required for relative extrusion.

The app clears stale G-code before a new slice and disables editing while the shared C session is slicing. The cancel control requests cancellation on the active Print; the simulator smoke test also checks cancellation and recovery. Print validation runs before processing. Preview comes from the official GCodeProcessorResult, with a bounded sample across the entire job and an explicit simplified-preview notice for large models. CI exercises the simulator C ABI (3MF import, slice, preview, G-code export, invalid-config rejection), caches dependencies after they build successfully, and packages unsigned apps. The runtime smoke test passes, including the packaged resource check, repair, 3MF geometry/settings round trip, slicing, processed preview, export, invalid-config rejection, cancellation and recovery. The compiled simulator app also installs and launches.

## Verified builds and artifacts

[Successful CI run](https://github.com/Parabel54/IOS-port-OrcaSlicer/actions/runs/43668911943), commit `da025e94cc45d2b01bc54d69b77b0e1c8d11b679`:

- [Unsigned iPhone IPA artifact](https://github.com/Parabel54/IOS-port-OrcaSlicer/actions/runs/43668911943/artifacts/14143159653).
- [Simulator app artifact](https://github.com/Parabel54/IOS-port-OrcaSlicer/actions/runs/43668911943/artifacts/14144131914).
- [Simulator logs, generated projects/G-code and launch screenshot](https://github.com/Parabel54/IOS-port-OrcaSlicer/actions/runs/43668911943/artifacts/14144037238).

Extract the IPA from the GitHub artifact ZIP and sign it before installation on a phone. See [device setup](RUN_ON_DEVICE.md). No provisioning profile or developer certificate is embedded in the CI build.

The simulator test exercises the actual mobile C ABI and linked C++ engine. It is not an automated test of taps through the document picker and share sheet. The launch screenshot was captured by CI; it has not been visually reviewed from this workspace because artifact downloads returned 403.

## Verification

Passed locally on Linux:

```sh
python3 -m unittest discover -s scripts/tests -p test_ios_project.py -v
cmake -S deps -B /tmp/orca-deps-check -DORCA_IOS_DEPS=ON -DSLIC3R_CAD=OFF -DCMAKE_BUILD_TYPE=Release
bash -n scripts/build_ios_deps.sh scripts/build_ios_engine_after_deps.sh scripts/bundle_engine_libs.sh scripts/test_ios_simulator.sh
```

The dependency check configures the headless dependency graph; it does not compile
libraries or validate Apple SDK behavior. Generator tests use fixture archives;
they verify build configuration, not binary contents. Xcode and Apple SDKs are
not available in this Linux workspace; compilation and runtime checks ran on the macOS
CI runner with Xcode 16.4 and the iOS 18.5 SDK/runtime. Both app builds passed, and
the simulator engine workflow and app launch passed. Physical iPhone execution and
older iOS versions remain unverified. OpenSSL object deployment-version warnings
need review before claiming support for the minimum iOS 16 deployment target.

## Remaining acceptance work

| Area | Current evidence | Required next |
|---|---|---|
| v2.5.1 iOS engine | Both SDK builds and simulator workflow passed | Test signed app on actual iPhones and audit minimum OS compatibility |
| Correct slicing | Official engine calls | Compare desktop/mobile output across printers, supports, variable layers, multi-material |
| Slice lifecycle | Validation, cancellation and recovery passed native simulator tests; progress and UI edit lock implemented | Complete session-access audit and touch-driven UI checks |
| Preview | Official processed moves; bounded full-job sampling | Pass simulator smoke test; verify arc-heavy and large jobs visually |
| Projects | One-model 3MF geometry and layer-height round trip passed | Desktop multi-plate round trips preserving settings, painting and assignments |
| Editing | Existing basic painting/cut/assembly | Font emboss geometry, connectors, richer paint tools; verify undo persistence |
| Printer workflows | Existing host implementations | Protocol-specific tests, AMS mapping, supported Bambu integration |
| Mobile quality | Historical checks only | Memory/thermal stress, lifecycle recovery, actual supported-device testing |
| Release | Passing CI and unsigned app artifacts | Physical-device checks, signing, full regression coverage and distribution readiness |

No completion percentage is assigned: historical checkboxes are not device or parity evidence.
