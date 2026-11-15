#!/usr/bin/env bash
# Run the linked mobile ABI against a real iOS Simulator runtime.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -m)" != arm64 ]]; then
  echo "The arm64 engine smoke test requires an Apple Silicon runner" >&2
  exit 1
fi
# CoreSimulator commands can stall without returning a diagnostic. Bound each
# phase so a failed install/launch cannot block subsequent validation builds.
ios_test_run() {
  python3 - "$@" <<'PYRUN'
import subprocess
import sys
seconds = int(sys.argv[1])
command = sys.argv[2:]
print('Simulator phase: ' + ' '.join(command[:4]), file=sys.stderr, flush=True)
subprocess.run(command, timeout=seconds, check=True)
PYRUN
}
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
DEVICE="$(ios_test_run 120 xcrun simctl create OrcaEngineSmoke com.apple.CoreSimulator.SimDeviceType.iPhone-16 "$RUNTIME")"
cleanup() {
  smoke_exit=$?
  if [[ "$smoke_exit" != 0 ]]; then
    ios_test_run 15 xcrun simctl io "$DEVICE" screenshot "$TEST_DIR/failure.png" >/dev/null 2>&1 || true
    ios_test_run 20 xcrun simctl spawn "$DEVICE" log show --last 3m --style compact \
      --predicate 'process == "OrcaSlicer"' > "$TEST_DIR/app-diagnostic.log" 2>&1 || true
    python3 - "$TEST_DIR" <<'PYDIAG'
from pathlib import Path
import shutil
import sys
for crash in sorted((Path.home() / 'Library/Logs/DiagnosticReports').glob('OrcaSlicer*.ips'), key=lambda p: p.stat().st_mtime)[-3:]:
    shutil.copy2(crash, Path(sys.argv[1]) / crash.name)
PYDIAG
  fi
  ios_test_run 20 xcrun simctl shutdown "$DEVICE" >/dev/null 2>&1 || true
  ios_test_run 20 xcrun simctl delete "$DEVICE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
ios_test_run 120 xcrun simctl boot "$DEVICE"
ios_test_run 240 xcrun simctl bootstatus "$DEVICE" -b
APP_BUNDLE="$ROOT/build-ios-app/Build/Products/Release-iphonesimulator/OrcaSlicer.app"
ios_test_run 180 xcrun simctl spawn "$DEVICE" "$TEST_DIR/engine_smoke" "$TEST_DIR" "$APP_BUNDLE" \
  2>&1 | tee "$TEST_DIR/result.log"
python3 "$ROOT/scripts/audit_ios_app.py" "$APP_BUNDLE" iphonesimulator
ios_test_run 120 xcrun simctl install "$DEVICE" "$APP_BUNDLE"
APP_DATA="$(xcrun simctl get_app_container "$DEVICE" com.orcaslicer.ios data)"
mkdir -p "$APP_DATA/Documents"
cp "$TEST_DIR/cube.3mf" "$APP_DATA/Documents/ios-import-smoke.3mf"
ios_test_run 90 xcrun simctl launch --terminate-running-process "$DEVICE" com.orcaslicer.ios --test-view-metadata --test-document-import \
  | tee "$TEST_DIR/app-launch.log"
# Wait for the app's full profile startup, not just its initial process spawn.
APP_DATA="$(xcrun simctl get_app_container "$DEVICE" com.orcaslicer.ios data)"
python3 - "$APP_DATA" <<'PYTEST'
from pathlib import Path
import sys
import time
stamp = Path(sys.argv[1]) / 'Documents/OrcaSlicer/.ios-system-profiles-revision'
deadline = time.monotonic() + 180
import_result = Path(sys.argv[1]) / 'tmp/orca-document-import-smoke.txt'
while not stamp.is_file() or not import_result.is_file():
    if time.monotonic() >= deadline:
        raise SystemExit('App did not finish system-profile startup within 180 seconds')
    time.sleep(2)
metadata = Path(sys.argv[1]) / 'tmp/orca-view-metadata-smoke.txt'
if not metadata.is_file():
    raise SystemExit('Missing small-stack view metadata test result')
print(metadata.read_text())
picker = Path(sys.argv[1]) / 'tmp/orca-document-picker-smoke.txt'
if not picker.is_file():
    raise SystemExit('Native document picker did not present')
print(picker.read_text())
print(import_result.read_text())
print('PASS: app completed engine and system-profile startup')
PYTEST
# Allow the first SwiftUI frame before preserving a diagnostic screenshot.
sleep 3
xcrun simctl io "$DEVICE" screenshot "$TEST_DIR/app-launch.png"
