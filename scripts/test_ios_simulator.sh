#!/usr/bin/env bash
# Run the linked mobile ABI against a real iOS Simulator runtime.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -m)" != arm64 ]]; then
  echo "The arm64 engine smoke test requires an Apple Silicon runner" >&2
  exit 1
fi
SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TEST_DIR="$ROOT/build_logs/simulator-smoke"
mkdir -p "$TEST_DIR"
xcrun --sdk iphonesimulator clang++ -std=c++17 -arch arm64 \
  -isysroot "$SDK_PATH" -mios-simulator-version-min=16.0 \
  -I "$ROOT/src/ios" "$ROOT/ios/tests/engine_smoke.cpp" \
  "$ROOT/build-ios-iphonesimulator-arm64/engine_bundle/lib/liborca_engine.a" \
  -lc++ -lz -liconv -lexpat -framework Foundation -framework ModelIO \
  -framework Security -framework SystemConfiguration -framework UIKit \
  -framework SceneKit -framework Network -o "$TEST_DIR/engine_smoke"
codesign --force --sign - "$TEST_DIR/engine_smoke"
RUNTIME="$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; print(sorted(r["identifier"] for r in json.load(sys.stdin)["runtimes"] if r["isAvailable"] and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-"))[-1])')"
DEVICE="$(xcrun simctl create OrcaEngineSmoke com.apple.CoreSimulator.SimDeviceType.iPhone-16 "$RUNTIME")"
cleanup() {
  xcrun simctl shutdown "$DEVICE" >/dev/null 2>&1 || true
  xcrun simctl delete "$DEVICE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
xcrun simctl boot "$DEVICE"
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl spawn "$DEVICE" "$TEST_DIR/engine_smoke" "$TEST_DIR" \
  2>&1 | tee "$TEST_DIR/result.log"
APP_BUNDLE="$ROOT/build-ios-app/Build/Products/Release-iphonesimulator/OrcaSlicer.app"
xcrun simctl install "$DEVICE" "$APP_BUNDLE"
xcrun simctl launch --terminate-running-process "$DEVICE" com.orcaslicer.ios \
  | tee "$TEST_DIR/app-launch.log"
# Allow the first SwiftUI frame before preserving a diagnostic screenshot.
sleep 3
xcrun simctl io "$DEVICE" screenshot "$TEST_DIR/app-launch.png"
