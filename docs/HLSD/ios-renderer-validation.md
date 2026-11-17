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
source. Each simulator phase is bounded, including 360 seconds for cold runtime
migration and 240 seconds for app installation. Separate boot/install logs retain
infrastructure failures even when the simulator cannot serve unified logs.
Runtime selection stays within the chosen SDK's iOS version family.
Fresh devices isolate test state and are shut down/deleted during cleanup.

Full-app test products build for the generic simulator platform, reusing the
app's generic resource compilation. Device-specific thinning does not belong in
that build. The 600-second build bound remains separate from boot, install and
test bounds. Actual test-without-building commands select the intended phone or
tablet device and retain their required assertions.

SDK/interface checks, focused graphics, C++ implementation builds, native engine
execution, full-app UI tests and physical-device/printer acceptance are separate
evidence. Native integration builds the bridge against real dependencies before
bundling the engine and exercising simulator slicing/UI flows. Comparing a PR
checkout's tree with its source tree pins results to exact code. Job status alone
is insufficient evidence for a successful graphics or native-runtime result.

The full-app import fixture also requires a session-ownership receipt. It invokes
public model/configuration/painting/plate/undo actions under each import, slice
and preset ownership flag, and compares native bounds, settings, paint counts and
host history state. Every blocked action must leave them intact; a valid edit
must work when ownership is released. This deterministic fixture tests command
guards without intentionally racing native code.

A separate full-app history receipt exercises native instance deletion through
Undo/Redo, empty-plate settings, first-primitive history and failed snapshot
restoration. It uses real native serialization and public host commands; a
source/SDK check alone does not execute this fixture.

The native ABI executable prints an entry marker and line-buffered fixture
results. A timeout or abort retains completed assertions in the result log;
the marker distinguishes entering the executable from merely building it.
