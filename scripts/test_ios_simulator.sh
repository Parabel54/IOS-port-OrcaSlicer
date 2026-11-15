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
python3 "$ROOT/scripts/make_ios_3mf_fixture.py" "$TEST_DIR/orca-project.3mf" --padding-mib 100
xcrun --sdk iphonesimulator clang++ -std=c++17 -arch arm64 \
  -isysroot "$SDK_PATH" -mios-simulator-version-min=16.0 \
  -I "$ROOT/src/ios" "$ROOT/ios/tests/engine_smoke.cpp" \
  "$ROOT/build-ios-iphonesimulator-arm64/engine_bundle/lib/liborca_engine.a" \
  -lc++ -lz -liconv -lexpat -framework Foundation -framework ModelIO \
  -framework Security -framework SystemConfiguration -framework UIKit \
  -framework SceneKit -framework Network -o "$TEST_DIR/engine_smoke"
codesign --force --sign - "$TEST_DIR/engine_smoke"
# Use a runtime from the selected Xcode SDK family. Hosted runners can also
# contain several runtime families; keep the build and test toolchains aligned.
SDK_VERSION="$(xcrun --sdk iphonesimulator --show-sdk-version)"
RUNTIME="$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
sdk = sys.argv[1].split(".")
rows = [r for r in json.load(sys.stdin)["runtimes"] if r["isAvailable"]
        and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
        and r["version"].split(".")[0] == sdk[0]]
if not rows:
    raise SystemExit("No available simulator runtime matches selected iOS SDK " + sys.argv[1])
rows.sort(key=lambda r: (r["version"] == sys.argv[1], tuple(map(int, r["version"].split(".")))))
print(rows[-1]["identifier"])
' "$SDK_VERSION")"
echo "Simulator runtime: $RUNTIME; selected SDK: $SDK_VERSION"
DEVICE="$(ios_test_run 120 xcrun simctl create OrcaEngineSmoke com.apple.CoreSimulator.SimDeviceType.iPhone-16 "$RUNTIME")"
cleanup() {
  smoke_exit=$?
  if [[ "$smoke_exit" != 0 ]]; then
    ios_test_run 15 xcrun simctl io "$DEVICE" screenshot "$TEST_DIR/failure.png" >/dev/null 2>&1 || true
    ios_test_run 20 xcrun simctl spawn "$DEVICE" log show --last 3m --style compact \
      --predicate 'process == "OrcaSlicer"' > "$TEST_DIR/app-diagnostic.log" 2>&1 || true
    ios_test_run 20 xcrun simctl spawn "$DEVICE" launchctl list > "$TEST_DIR/simulator-processes.log" 2>&1 || true
    ios_test_run 20 xcrun simctl spawn "$DEVICE" log show --last 3m --style compact \
      --predicate 'process == "SpringBoard" OR process == "runningboardd" OR process == "launchd_sim" OR process == "installd"' \
      > "$TEST_DIR/launcher-diagnostic.log" 2>&1 || true
    python3 - "$TEST_DIR" "${APP_DATA:-}" "${APP_BUNDLE:-}" <<'PYDIAG'
from pathlib import Path
import json
import plistlib
import shutil
import sys
output = Path(sys.argv[1])
container = Path(sys.argv[2]) if sys.argv[2] else None
bundle = Path(sys.argv[3]) if sys.argv[3] else None
if bundle and (bundle / 'Info.plist').is_file():
    with (bundle / 'Info.plist').open('rb') as stream:
        (output / 'built-app-info.json').write_text(json.dumps(plistlib.load(stream), indent=2, default=str))
if container and container.is_dir():
    markers = list((container / 'tmp').glob('orca-*-smoke.txt'))
    (output / 'startup-markers.json').write_text(json.dumps([str(path.relative_to(container)) for path in markers]))
    for marker in markers:
        shutil.copy2(marker, output / marker.name)
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
# bootstatus can finish while SpringBoard's launch service is still warming up.
# A system app proves that service responds before installing the slicer.
ios_test_run 90 xcrun simctl launch "$DEVICE" com.apple.Preferences
APP_BUNDLE="$ROOT/build-ios-app/Build/Products/Release-iphonesimulator/OrcaSlicer.app"
ios_test_run 360 xcodebuild build-for-testing -project "$ROOT/ios/OrcaSlicer.xcodeproj" \
  -scheme OrcaSlicerUITests -configuration Release -sdk iphonesimulator \
  -destination "id=$DEVICE" -derivedDataPath "$ROOT/build-ios-app" CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee "$TEST_DIR/ui-build.log"
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --force --deep --sign - "$ROOT/build-ios-app/Build/Products/Release-iphonesimulator/OrcaSlicerUITests-Runner.app"
UI_RUN_FILE="$(rg --files --no-ignore "$ROOT/build-ios-app/Build/Products" -g '*.xctestrun' | head -n 1)"
ios_test_run 180 xcrun simctl spawn "$DEVICE" "$TEST_DIR/engine_smoke" "$TEST_DIR" "$APP_BUNDLE" \
  2>&1 | tee "$TEST_DIR/result.log"
python3 "$ROOT/scripts/audit_ios_app.py" "$APP_BUNDLE" iphonesimulator
ios_test_run 120 xcrun simctl install "$DEVICE" "$APP_BUNDLE"
APP_DATA="$(xcrun simctl get_app_container "$DEVICE" com.orcaslicer.ios data)"
mkdir -p "$APP_DATA/Documents"
cp "$TEST_DIR/orca-project.3mf" "$APP_DATA/Documents/ios-import-smoke.3mf"
ios_test_run 90 xcrun simctl launch "$DEVICE" com.orcaslicer.ios --test-view-metadata --test-document-import \
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
camera = Path(sys.argv[1]) / 'tmp/orca-camera-smoke.txt'
if not camera.is_file() or not camera.read_text().startswith('PASS:'):
    raise SystemExit('Camera pan/orbit/zoom smoke test failed')
print(camera.read_text())
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

# A narrow phone and a large tablet exercise real adaptive SwiftUI layouts.
ios_test_run 20 xcrun simctl shutdown "$DEVICE"
ios_test_run 20 xcrun simctl delete "$DEVICE"
for variant in compact tablet; do
  if [[ "$variant" == compact ]]; then
    device_type=com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation
  else
    device_type=com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB
  fi
  DEVICE="$(ios_test_run 120 xcrun simctl create "OrcaWorkspace-$variant" "$device_type" "$RUNTIME")"
  ios_test_run 120 xcrun simctl boot "$DEVICE"
  ios_test_run 240 xcrun simctl bootstatus "$DEVICE" -b
  # Check the system launcher before exercising the slicer on a fresh device.
  ios_test_run 90 xcrun simctl launch "$DEVICE" com.apple.Preferences
  ios_test_run 120 xcrun simctl install "$DEVICE" "$APP_BUNDLE"
  APP_DATA="$(xcrun simctl get_app_container "$DEVICE" com.orcaslicer.ios data)"
  mkdir -p "$APP_DATA/Documents"
  cp "$TEST_DIR/orca-project.3mf" "$APP_DATA/Documents/ios-import-smoke.3mf"
  for presentation in workspace settings; do
    if [[ "$variant" == tablet && "$presentation" == settings ]]; then continue; fi
    if [[ "$presentation" != workspace ]]; then
      ios_test_run 20 xcrun simctl terminate "$DEVICE" com.orcaslicer.ios
    fi
    rm -f "$APP_DATA/tmp/orca-document-import-smoke.txt" "$APP_DATA/tmp/orca-workspace-layout.json"
    workspace_flags=(--test-view-metadata --test-document-import)
    if [[ "$presentation" == settings ]]; then workspace_flags+=(--test-show-settings); fi
    ios_test_run 90 xcrun simctl launch "$DEVICE" com.orcaslicer.ios "${workspace_flags[@]}"
    python3 - "$APP_DATA" "$variant" "$presentation" <<'PYLAYOUT'
from pathlib import Path
import json
import sys
import time
root = Path(sys.argv[1]) / 'tmp'
deadline = time.monotonic() + 180
while True:
    marker = root/'orca-document-import-smoke.txt'
    geometry = root/'orca-workspace-layout.json'
    if marker.is_file() and geometry.is_file():
        layout = json.loads(geometry.read_text())
        break
    if time.monotonic() > deadline:
        raise SystemExit('Responsive workspace did not finish loading/rotating')
    time.sleep(1)
if sys.argv[2] == 'compact':
    assert layout['width'] <= 400 and not layout['sidebar'], layout
else:
    assert layout['width'] >= 1000 and layout['sidebar'], layout
print('PASS: responsive workspace', sys.argv[2:], layout)
time.sleep(3)
PYLAYOUT
    xcrun simctl io "$DEVICE" screenshot "$TEST_DIR/$variant-$presentation.png"
    cp "$APP_DATA/tmp/orca-workspace-layout.json" "$TEST_DIR/$variant-$presentation.json"
  done
  if [[ "$variant" == tablet ]]; then
    # Rotate the simulated device through XCTest. A multitasking app cannot
    # force interface orientation through UIWindowScene.requestGeometryUpdate.
    ios_test_run 360 xcodebuild test-without-building -xctestrun "$UI_RUN_FILE" \
      -destination "id=$DEVICE" -parallel-testing-enabled NO \
      -resultBundlePath "$TEST_DIR/tablet-orientation.xcresult" \
      2>&1 | tee "$TEST_DIR/ui-test.log"
    xcrun xcresulttool export attachments --path "$TEST_DIR/tablet-orientation.xcresult" \
      --output-path "$TEST_DIR/ui-attachments"
    cp "$APP_DATA/tmp/orca-workspace-landscape.json" "$TEST_DIR/tablet-landscape.json"
  fi
  ios_test_run 20 xcrun simctl shutdown "$DEVICE"
  ios_test_run 20 xcrun simctl delete "$DEVICE"
done
