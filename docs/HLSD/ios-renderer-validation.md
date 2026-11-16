# iOS renderer validation

The fast validation workflow runs device SDK checks, simulator/UI-test source
checks, Mac host fixtures and a standalone graphics harness on one acquired Mac.
Host fixtures exercise storage, document coordination, protocol requests and
post-processing with injected test data. They do not authenticate a real account
or connect to a physical printer.

## Graphics harness

`PreviewSmokeApp` is a test-only UIKit application compiled with the production
`PlateSceneView.swift`. It uses the selected iOS SDK's simulator runtime and does
not link the slicing engine. Its independent checks cover camera transforms and
projection, painted-filament GPU colors, progressive primitive ranges, actual
progressive GPU pixels and static preview geometry.

The app writes an atomic JSON receipt after each check. Progress receipts remain
incomplete until the complete suite finishes. A receipt contains the checkout
commit, named boolean results, completion/summary flags and camera assertion
locations with measured values. The script preserves a partial receipt on a
stalled run. Unified logs and failure screenshots supplement this durable data.

Acceptance requires explicit completion, the exact checked-out commit, every
required check and literal true results. A green summary or an incomplete file
cannot pass. The app must still be running when the script terminates it; a later
crash therefore fails the gate as well.

## Execution boundaries

The shared timeout helper forwards caller stdin separately from its own Python
source. Each simulator phase is bounded, including a 240-second cold app-install
phase. Runtime selection stays within the chosen SDK's iOS version family.
Fresh devices isolate test state and are shut down/deleted during cleanup.

SDK/interface checks, focused graphics, C++ implementation builds, native engine
execution, full-app UI tests and physical-device/printer acceptance are separate
evidence. Native integration builds the bridge against real dependencies before
bundling the engine and exercising simulator slicing/UI flows. Comparing a PR
checkout's tree with its source tree pins results to exact code. Job status alone
is insufficient evidence for a successful graphics or native-runtime result.
