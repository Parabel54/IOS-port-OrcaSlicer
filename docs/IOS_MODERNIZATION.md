# iOS modernization — November 14, 2026

The source integrates official OrcaSlicer **v2.5.1** with the existing iOS branch.
This is an integration candidate, not a verified iOS release. The source merge
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

The app clears stale G-code before a new slice and disables editing while the shared C session is slicing. Print validation runs before processing. Preview comes from the official GCodeProcessorResult, with a bounded sample across the entire job and an explicit simplified-preview notice for large models. CI exercises the simulator C ABI (3MF import, slice, preview, G-code export, invalid-config rejection), caches dependencies after they build successfully, and packages unsigned apps. The runtime smoke test has not yet passed.

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
not available in this workspace. Neither mobile C++ compilation nor device execution
has been verified. Run the iOS workflow after publishing this branch; fix compilation
and linking failures before treating the integration as usable.

## Remaining acceptance work

| Area | Current evidence | Required next |
|---|---|---|
| v2.5.1 iOS engine | Source integration, dependency configure | Build both SDKs; resolve ABI and linker errors |
| Correct slicing | Official engine calls | Compare desktop/mobile output across printers, supports, variable layers, multi-material |
| Slice lifecycle | Detailed progress, validation, stale-result invalidation and UI edit lock implemented | Pass runtime tests; add cancellation and complete session-access audit |
| Preview | Official processed moves; bounded full-job sampling | Pass simulator smoke test; verify arc-heavy and large jobs visually |
| Projects | Existing 3MF snapshots | Desktop multi-plate round trips preserving settings, painting and assignments |
| Editing | Existing basic painting/cut/assembly | Font emboss geometry, connectors, richer paint tools; verify undo persistence |
| Printer workflows | Existing host implementations | Protocol-specific tests, AMS mapping, supported Bambu integration |
| Mobile quality | Historical checks only | Memory/thermal stress, lifecycle recovery, actual supported-device testing |
| Release | Source and workflow | Passing CI, physical-device checks, reproducible artifacts and distribution readiness |

No completion percentage is assigned: historical checkboxes are not device or parity evidence.
