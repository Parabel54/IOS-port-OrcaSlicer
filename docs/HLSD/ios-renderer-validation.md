# Standalone iOS renderer validation

The UIKit harness compiles production SceneKit code without the slicing engine.
It checks camera transforms/projection, painted-filament GPU colors, progressive
cursor ranges, actual progressive GPU pixels and static preview geometry.
A complete passing receipt must match the checked-out commit, name every
required check and contain literal boolean true results. The app must still be
running when the script terminates it. This is separate from native slicing,
full-app UI tests and physical-device acceptance.

SDK63/source ae676 passed both Apple SDK steps and Mac fixtures. Its receipt
records painted-filament GPU, progressive GPU/ranges and static geometry passes,
but camera fails. Unified-log collection then timed out, losing the assertion
message; the original receipt/artifact remains a failed overall result.

Camera failures now report the assertion location and measured values directly
into the durable JSON receipt. An atomic progress receipt is written after every
check and marked incomplete until all checks finish. If execution stalls, the
script preserves any partial receipt and fails. The validator independently
requires completion, source identity and all checks, so neither a green summary
nor a partial file can pass. Unified logs remain supplementary diagnostics.

The earlier SDK59 green job was invalid because the timeout wrapper consumed
stdin meant for its child receipt check. Caller stdin now uses a separate file
descriptor; local regressions require real execution and failure propagation.
SDK60's independent artifact has real progressive GPU/range/static passes and a
failed camera aggregate. SDK61 never acquired a hosted runner. SDK62 exposed a
private slicing-state access error. These observations must remain distinct from
successful interface checks, native engine execution or package validation.
