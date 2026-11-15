#!/usr/bin/env python3
"""Generate Xcode project for the OrcaSlicer iOS host (official libslic3r via C ABI)."""
from pathlib import Path
import uuid
import argparse
import hashlib
import os

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--require-engine", choices=("iphoneos", "iphonesimulator"),
                    help="Fail instead of generating an unlinked app for this SDK")
args = parser.parse_args()

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent
PROJ = ROOT / "OrcaSlicer.xcodeproj"
PROJ.mkdir(exist_ok=True)

ENGINE_IOS_SIM = REPO / "build-ios-iphonesimulator-arm64" / "engine_bundle" / "lib"
ENGINE_IOS_DEV = REPO / "build-ios-iphoneos-arm64" / "engine_bundle" / "lib"

has_ios_sim_engine = (ENGINE_IOS_SIM / "liborca_engine.a").is_file()
has_ios_dev_engine = (ENGINE_IOS_DEV / "liborca_engine.a").is_file()
if args.require_engine:
    archive = (ENGINE_IOS_DEV if args.require_engine == "iphoneos" else ENGINE_IOS_SIM) / "liborca_engine.a"
    if not archive.is_file() or archive.stat().st_size == 0:
        parser.error(f"Missing or empty engine archive for {args.require_engine}: {archive}")



def uid(key):
    return uuid.uuid5(uuid.NAMESPACE_URL, "orca-ios-project/" + key).hex[:24].upper()


IDs = {k: uid(k) for k in [
    "project", "target", "sources", "resources", "frameworks", "product",
    "swift_app", "swift_engine", "swift_plate", "swift_process", "swift_connections", "swift_connections_panel", "swift_startup", "swift_documentimport", "swift_nativedocumentpicker", "swift_orcacloudapi", "swift_nativecloudsignin", "swift_orcacloudaccount", "swift_cloudaccountpanel", "swift_flashforge", "swift_postprocessing", "swift_startup_view", "logo", "assets",
    "process_profile", "process_profile_fine", "profiles_folder", "calib_folder", "scenekit_fw",
    "config_list_proj", "config_list_tgt",
    "debug_proj", "release_proj", "debug_tgt", "release_tgt",
    "group_main", "group_app", "group_products",
]}

# Full official vendor trees (~79MB) for all printers/process/filament/covers
PROFILES_DIR = ROOT / "OrcaSlicerApp" / "Resources" / "profiles"
# Keep profiles in sync with the engine revision, including upstream removals.
import shutil

# Desktop preset caches and native executables are not portable iOS resources.
def ignore_desktop_files(directory, names):
    excluded = {".opc", ".dll", ".exe", ".so", ".dylib", ".pdb", ".lib", ".a"}
    return [name for name in names if Path(name).suffix.lower() in excluded or ".so." in name.lower()]

if (REPO / "resources" / "profiles").is_dir():
    PROFILES_DIR.parent.mkdir(parents=True, exist_ok=True)
    if PROFILES_DIR.exists():
        shutil.rmtree(PROFILES_DIR)
    shutil.copytree(REPO / "resources" / "profiles", PROFILES_DIR, ignore=ignore_desktop_files)
has_profiles = PROFILES_DIR.is_dir() and any(PROFILES_DIR.glob("*.json"))
if args.require_engine and not has_profiles:
    parser.error("Official resources/profiles must be present for an engine build")
# Official calibration meshes (temp tower, flow, PA, retraction, …)
# Resources/ is gitignored (large); sync from repo resources/calib when missing/stale.
CALIB_DIR = ROOT / "OrcaSlicerApp" / "Resources" / "calib"
_SRC_CALIB = REPO / "resources" / "calib"
if _SRC_CALIB.is_dir():
    import shutil as _shutil
    CALIB_DIR.parent.mkdir(parents=True, exist_ok=True)
    if CALIB_DIR.exists():
        _shutil.rmtree(CALIB_DIR)
    _shutil.copytree(_SRC_CALIB, CALIB_DIR, ignore=ignore_desktop_files)
    print("Synced calib →", CALIB_DIR)
has_calib = CALIB_DIR.is_dir() and any(CALIB_DIR.rglob("*"))

# Small engine data tables used by nozzle validation, flush prediction and mixing.
engine_resource_folders = []
for folder in ("info", "flush", "filament_mixing"):
    source = REPO / "resources" / folder
    destination = ROOT / "OrcaSlicerApp" / "Resources" / folder
    if source.is_dir():
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(source, destination, ignore=ignore_desktop_files)
        engine_resource_folders.append(folder)
    elif args.require_engine:
        parser.error(f"Missing required engine resources: {source}")

# Third-party notices travel with the app binary.
license_destination = ROOT / "OrcaSlicerApp" / "Resources" / "licenses"
if license_destination.exists():
    shutil.rmtree(license_destination)
shutil.copytree(ROOT / "licenses", license_destination)
engine_resource_folders.append("licenses")

ios_sim_lib_path = "$(SRCROOT)/../build-ios-iphonesimulator-arm64/engine_bundle/lib"
ios_dev_lib_path = "$(SRCROOT)/../build-ios-iphoneos-arm64/engine_bundle/lib"
hdr_path = "$(SRCROOT)/../src/ios"

ios_ld = (
    "-lorca_engine -lc++ -lz -liconv -lexpat "
    "-framework Foundation -framework ModelIO "
    "-framework Security -framework SystemConfiguration "
    "-framework SceneKit -framework UIKit -framework Network"
)


# A changed profile tree invalidates only the generated on-device system mirror.
profile_digest = hashlib.sha256()
for profile in sorted(PROFILES_DIR.rglob("*")):
    if profile.is_file():
        profile_digest.update(profile.relative_to(PROFILES_DIR).as_posix().encode())
        profile_digest.update(b"\0")
        profile_digest.update(profile.read_bytes())
        profile_digest.update(b"\0")
PROFILE_REVISION = profile_digest.hexdigest()
BUILD_REVISION = os.environ.get("GITHUB_SHA", "development")[:12]

# Team for Automatic signing (override with ORCA_IOS_DEVELOPMENT_TEAM).
# Empty → Xcode shows "Signing requires a development team" until set in UI.
import os as _os
DEVELOPMENT_TEAM = _os.environ.get("ORCA_IOS_DEVELOPMENT_TEAM", "")


def tgt_settings(name: str) -> str:
    # Base: no engine. SDK-conditional ORCA_LINKED + link flags when bundles exist.
    lines = [
        "\t\t\tisa = XCBuildConfiguration;",
        "\t\t\tbuildSettings = {",
        "\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;",
        "\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;",
        "\t\t\t\tCLANG_ENABLE_MODULES = YES;",
        "\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;",
        "\t\t\t\tCODE_SIGN_STYLE = Automatic;",
        "\t\t\t\tCURRENT_PROJECT_VERSION = 1;",
        f'\t\t\t\tDEVELOPMENT_TEAM = "{DEVELOPMENT_TEAM}";',
        "\t\t\t\tENABLE_PREVIEWS = YES;",
        "\t\t\t\tGENERATE_INFOPLIST_FILE = NO;",
        "\t\t\t\tHEADER_SEARCH_PATHS = (",
        f'\t\t\t\t\t"{hdr_path}",',
        '\t\t\t\t\t"$(inherited)",',
        "\t\t\t\t);",
        "\t\t\t\tINFOPLIST_FILE = OrcaSlicerApp/Info.plist;",
        "\t\t\t\tINFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;",
        "\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 16.0;",
        "\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (",
        '\t\t\t\t\t"$(inherited)",',
        '\t\t\t\t\t"@executable_path/Frameworks",',
        "\t\t\t\t);",
        "\t\t\t\tLIBRARY_SEARCH_PATHS = (",
        '\t\t\t\t\t"$(inherited)",',
        "\t\t\t\t);",
        "\t\t\t\tMARKETING_VERSION = 2.5.1;",
        f"\t\t\t\tORCA_PROFILE_REVISION = {PROFILE_REVISION};",
        f"\t\t\t\tORCA_BUILD_REVISION = {BUILD_REVISION};",
        # Engine bundles are arm64-only (Apple Silicon). Exclude x86_64 so Xcode
        # does not try to link Intel-sim slices that do not exist → linker fail.
        '\t\t\t\t"EXCLUDED_ARCHS[sdk=iphonesimulator*]" = "x86_64 i386";',
        "\t\t\t\tONLY_ACTIVE_ARCH = YES;",
        "\t\t\t\tOTHER_LDFLAGS = (",
        '\t\t\t\t\t"$(inherited)",',
        "\t\t\t\t);",
        "\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.orcaslicer.ios;",
        '\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";',
        '\t\t\t\tSUPPORTED_PLATFORMS = "iphoneos iphonesimulator";',
        "\t\t\t\tSUPPORTS_MACCATALYST = NO;",
        '\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "";',
        "\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;",
        '\t\t\t\tSWIFT_OBJC_BRIDGING_HEADER = "OrcaSlicerApp/Bridging-Header.h";',
        "\t\t\t\tSWIFT_VERSION = 5.0;",
        '\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";',
    ]
    if has_ios_sim_engine:
        lines += [
            f'\t\t\t\t"LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]" = (',
            f'\t\t\t\t\t"{ios_sim_lib_path}",',
            '\t\t\t\t\t"$(inherited)",',
            "\t\t\t\t);",
            f'\t\t\t\t"OTHER_LDFLAGS[sdk=iphonesimulator*]" = (',
            '\t\t\t\t\t"$(inherited)",',
            f'\t\t\t\t\t"{ios_ld}",',
            "\t\t\t\t);",
            '\t\t\t\t"SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=iphonesimulator*]" = "ORCA_LINKED";',
            # Force arm64 sim slices when Xcode would otherwise prefer x86_64
            '\t\t\t\t"ARCHS[sdk=iphonesimulator*]" = arm64;',
            '\t\t\t\t"VALID_ARCHS[sdk=iphonesimulator*]" = arm64;',
        ]
    if has_ios_dev_engine:
        lines += [
            f'\t\t\t\t"LIBRARY_SEARCH_PATHS[sdk=iphoneos*]" = (',
            f'\t\t\t\t\t"{ios_dev_lib_path}",',
            '\t\t\t\t\t"$(inherited)",',
            "\t\t\t\t);",
            f'\t\t\t\t"OTHER_LDFLAGS[sdk=iphoneos*]" = (',
            '\t\t\t\t\t"$(inherited)",',
            f'\t\t\t\t\t"{ios_ld}",',
            "\t\t\t\t);",
            '\t\t\t\t"SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=iphoneos*]" = "ORCA_LINKED";',
        ]
    lines += [
        "\t\t\t};",
        f"\t\t\tname = {name};",
    ]
    return "\n".join(lines)


pbx = f'''// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{}};
	objectVersion = 56;
	objects = {{

/* Begin PBXBuildFile section */
		{IDs["swift_app"]} /* OrcaSlicerApp.swift in Sources */ = {{isa = PBXBuildFile; fileRef = A10000000000000000000001 /* OrcaSlicerApp.swift */; }};
		{IDs["swift_engine"]} /* OrcaEngine.swift in Sources */ = {{isa = PBXBuildFile; fileRef = A10000000000000000000002 /* OrcaEngine.swift */; }};
		{IDs["swift_plate"]} /* PlateSceneView.swift in Sources */ = {{isa = PBXBuildFile; fileRef = A10000000000000000000008 /* PlateSceneView.swift */; }};
		{IDs["swift_process"]} /* ProcessOptions.swift in Sources */ = {{isa = PBXBuildFile; fileRef = A1000000000000000000000C /* ProcessOptions.swift */; }};
		{IDs["swift_postprocessing"]} /* NativePostProcessing.swift in Sources */ = {{isa = PBXBuildFile; fileRef = A1000000000000000000001A /* NativePostProcessing.swift */; }};
		{IDs["swift_flashforge"]} /* FlashforgeClient.swift in Sources */ = {{isa = PBXBuildFile; fileRef = A10000000000000000000018 /* FlashforgeClient.swift */; }};
		{IDs["swift_cloudaccountpanel"]} /* CloudAccountPanel.swift in Sources */ = {{isa = PBXBuildFile; fileRef = A10000000000000000000017 /* CloudAccountPanel.swift */; }};
		{IDs["swift_orcacloudaccount"]} /* OrcaCloudAccount.swift in Sources */ = {{isa = PBXBuildFile; fileRef = A10000000000000000000016 /* OrcaCloudAccount.swift */; }};
		{IDs["swift_nativecloudsignin"]} /* NativeCloudSignIn.swift in Sources */ = {{isa = PBXBuildFile; fileRef = A10000000000000000000015 /* NativeCloudSignIn.swift */; }};
		{IDs["swift_orcacloudapi"]} /* OrcaCloudAPI.swift in Sources */ = {{isa = PBXBuildFile; fileRef = A10000000000000000000014 /* OrcaCloudAPI.swift */; }};
		{IDs["swift_nativedocumentpicker"]} /* NativeDocumentPicker.swift in Sources */ = {{isa = PBXBuildFile; fileRef = A10000000000000000000013 /* NativeDocumentPicker.swift */; }};
		{IDs["swift_documentimport"]} /* DocumentImport.swift in Sources */ = {{isa = PBXBuildFile; fileRef = A10000000000000000000012 /* DocumentImport.swift */; }};
		{IDs["swift_startup_view"]} /* StartupRecoveryView.swift in Sources */ = {{isa = PBXBuildFile; fileRef = A10000000000000000000011 /* StartupRecoveryView.swift */; }};
		{IDs["swift_startup"]} /* StartupRecovery.swift in Sources */ = {{isa = PBXBuildFile; fileRef = A10000000000000000000010 /* StartupRecovery.swift */; }};
		{IDs["swift_connections_panel"]} /* ConnectionsPanel.swift in Sources */ = {{isa = PBXBuildFile; fileRef = A1000000000000000000000F /* ConnectionsPanel.swift */; }};
		{IDs["swift_connections"]} /* PrinterConnections.swift in Sources */ = {{isa = PBXBuildFile; fileRef = A1000000000000000000000E /* PrinterConnections.swift */; }};
		{IDs["logo"]} /* OrcaSlicerLogo.png in Resources */ = {{isa = PBXBuildFile; fileRef = A10000000000000000000006 /* OrcaSlicerLogo.png */; }};
		{IDs["assets"]} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = A10000000000000000000007 /* Assets.xcassets */; }};
		{IDs["process_profile"]} /* process_0.20mm_Standard.json in Resources */ = {{isa = PBXBuildFile; fileRef = A10000000000000000000009 /* process_0.20mm_Standard.json */; }};
		{IDs["process_profile_fine"]} /* process_0.16mm_Fine.json in Resources */ = {{isa = PBXBuildFile; fileRef = A1000000000000000000000A /* process_0.16mm_Fine.json */; }};
''' + (f'''		{IDs["profiles_folder"]} /* profiles in Resources */ = {{isa = PBXBuildFile; fileRef = A1000000000000000000000B /* profiles */; }};
''' if has_profiles else '') + (f'''		{IDs["calib_folder"]} /* calib in Resources */ = {{isa = PBXBuildFile; fileRef = A1000000000000000000000D /* calib */; }};
''' if has_calib else '') + f'''/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		A10000000000000000000001 /* OrcaSlicerApp.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = OrcaSlicerApp.swift; sourceTree = "<group>"; }};
		A10000000000000000000002 /* OrcaEngine.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = OrcaEngine.swift; sourceTree = "<group>"; }};
		A10000000000000000000003 /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};
		A10000000000000000000004 /* Bridging-Header.h */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = "Bridging-Header.h"; sourceTree = "<group>"; }};
		A10000000000000000000006 /* OrcaSlicerLogo.png */ = {{isa = PBXFileReference; lastKnownFileType = image.png; path = OrcaSlicerLogo.png; sourceTree = "<group>"; }};
		A10000000000000000000007 /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};
		A10000000000000000000008 /* PlateSceneView.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PlateSceneView.swift; sourceTree = "<group>"; }};
		A1000000000000000000000C /* ProcessOptions.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ProcessOptions.swift; sourceTree = "<group>"; }};
		A1000000000000000000001A /* NativePostProcessing.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = NativePostProcessing.swift; sourceTree = "<group>"; }};
		A10000000000000000000018 /* FlashforgeClient.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = FlashforgeClient.swift; sourceTree = "<group>"; }};
		A10000000000000000000017 /* CloudAccountPanel.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CloudAccountPanel.swift; sourceTree = "<group>"; }};
		A10000000000000000000016 /* OrcaCloudAccount.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = OrcaCloudAccount.swift; sourceTree = "<group>"; }};
		A10000000000000000000015 /* NativeCloudSignIn.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = NativeCloudSignIn.swift; sourceTree = "<group>"; }};
		A10000000000000000000014 /* OrcaCloudAPI.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = OrcaCloudAPI.swift; sourceTree = "<group>"; }};
		A10000000000000000000013 /* NativeDocumentPicker.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = NativeDocumentPicker.swift; sourceTree = "<group>"; }};
		A10000000000000000000012 /* DocumentImport.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DocumentImport.swift; sourceTree = "<group>"; }};
		A10000000000000000000011 /* StartupRecoveryView.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = StartupRecoveryView.swift; sourceTree = "<group>"; }};
		A10000000000000000000010 /* StartupRecovery.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = StartupRecovery.swift; sourceTree = "<group>"; }};
		A1000000000000000000000F /* ConnectionsPanel.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ConnectionsPanel.swift; sourceTree = "<group>"; }};
		A1000000000000000000000E /* PrinterConnections.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PrinterConnections.swift; sourceTree = "<group>"; }};
		A10000000000000000000009 /* process_0.20mm_Standard.json */ = {{isa = PBXFileReference; lastKnownFileType = text.json; path = process_0.20mm_Standard.json; sourceTree = "<group>"; }};
		A1000000000000000000000A /* process_0.16mm_Fine.json */ = {{isa = PBXFileReference; lastKnownFileType = text.json; path = process_0.16mm_Fine.json; sourceTree = "<group>"; }};
''' + ('''		A1000000000000000000000B /* profiles */ = {isa = PBXFileReference; lastKnownFileType = folder; name = profiles; path = Resources/profiles; sourceTree = "<group>"; };
''' if has_profiles else '') + ('''		A1000000000000000000000D /* calib */ = {isa = PBXFileReference; lastKnownFileType = folder; name = calib; path = Resources/calib; sourceTree = "<group>"; };
''' if has_calib else '') + f'''		{IDs["product"]} /* OrcaSlicer.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = OrcaSlicer.app; sourceTree = BUILT_PRODUCTS_DIR; }};
/* End PBXFileReference section */

/* Begin PBXGroup section */
		{IDs["group_main"]} = {{
			isa = PBXGroup;
			children = (
				{IDs["group_app"]},
				{IDs["group_products"]},
			);
			sourceTree = "<group>";
		}};
		{IDs["group_app"]} = {{
			isa = PBXGroup;
			children = (
				A10000000000000000000001 /* OrcaSlicerApp.swift */,
				A10000000000000000000002 /* OrcaEngine.swift */,
				A10000000000000000000008 /* PlateSceneView.swift */,
				A1000000000000000000000C /* ProcessOptions.swift */,
				A1000000000000000000001A /* NativePostProcessing.swift */,
				A10000000000000000000018 /* FlashforgeClient.swift */,
				A10000000000000000000017 /* CloudAccountPanel.swift */,
				A10000000000000000000016 /* OrcaCloudAccount.swift */,
				A10000000000000000000015 /* NativeCloudSignIn.swift */,
				A10000000000000000000014 /* OrcaCloudAPI.swift */,
				A10000000000000000000013 /* NativeDocumentPicker.swift */,
				A10000000000000000000012 /* DocumentImport.swift */,
				A10000000000000000000011 /* StartupRecoveryView.swift */,
				A10000000000000000000010 /* StartupRecovery.swift */,
				A1000000000000000000000F /* ConnectionsPanel.swift */,
				A1000000000000000000000E /* PrinterConnections.swift */,
				A10000000000000000000003 /* Info.plist */,
				A10000000000000000000004 /* Bridging-Header.h */,
				A10000000000000000000006 /* OrcaSlicerLogo.png */,
				A10000000000000000000007 /* Assets.xcassets */,
				A10000000000000000000009 /* process_0.20mm_Standard.json */,
				A1000000000000000000000A /* process_0.16mm_Fine.json */,
''' + ('''				A1000000000000000000000B /* profiles */,
''' if has_profiles else '') + ('''				A1000000000000000000000D /* calib */,
''' if has_calib else '') + f'''			);
			path = OrcaSlicerApp;
			sourceTree = "<group>";
		}};
		{IDs["group_products"]} = {{
			isa = PBXGroup;
			children = (
				{IDs["product"]} /* OrcaSlicer.app */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{IDs["target"]} /* OrcaSlicer */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {IDs["config_list_tgt"]} /* Build configuration list for PBXNativeTarget "OrcaSlicer" */;
			buildPhases = (
				{IDs["sources"]} /* Sources */,
				{IDs["frameworks"]} /* Frameworks */,
				{IDs["resources"]} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = OrcaSlicer;
			productName = OrcaSlicer;
			productReference = {IDs["product"]} /* OrcaSlicer.app */;
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{IDs["project"]} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1600;
				LastUpgradeCheck = 1600;
			}};
			buildConfigurationList = {IDs["config_list_proj"]} /* Build configuration list for PBXProject "OrcaSlicer" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = {IDs["group_main"]};
			productRefGroup = {IDs["group_products"]};
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{IDs["target"]} /* OrcaSlicer */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{IDs["resources"]} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{IDs["logo"]} /* OrcaSlicerLogo.png in Resources */,
				{IDs["assets"]} /* Assets.xcassets in Resources */,
				{IDs["process_profile"]} /* process_0.20mm_Standard.json in Resources */,
				{IDs["process_profile_fine"]} /* process_0.16mm_Fine.json in Resources */,
''' + (f'''				{IDs["profiles_folder"]} /* profiles in Resources */,
''' if has_profiles else '') + (f'''				{IDs["calib_folder"]} /* calib in Resources */,
''' if has_calib else '') + f'''			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXFrameworksBuildPhase section */
		{IDs["frameworks"]} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{IDs["sources"]} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{IDs["swift_app"]} /* OrcaSlicerApp.swift in Sources */,
				{IDs["swift_engine"]} /* OrcaEngine.swift in Sources */,
				{IDs["swift_plate"]} /* PlateSceneView.swift in Sources */,
				{IDs["swift_process"]} /* ProcessOptions.swift in Sources */,
				{IDs["swift_postprocessing"]} /* NativePostProcessing.swift in Sources */,
				{IDs["swift_flashforge"]} /* FlashforgeClient.swift in Sources */,
				{IDs["swift_cloudaccountpanel"]} /* CloudAccountPanel.swift in Sources */,
				{IDs["swift_orcacloudaccount"]} /* OrcaCloudAccount.swift in Sources */,
				{IDs["swift_nativecloudsignin"]} /* NativeCloudSignIn.swift in Sources */,
				{IDs["swift_orcacloudapi"]} /* OrcaCloudAPI.swift in Sources */,
				{IDs["swift_nativedocumentpicker"]} /* NativeDocumentPicker.swift in Sources */,
				{IDs["swift_documentimport"]} /* DocumentImport.swift in Sources */,
				{IDs["swift_startup_view"]} /* StartupRecoveryView.swift in Sources */,
				{IDs["swift_startup"]} /* StartupRecovery.swift in Sources */,
				{IDs["swift_connections_panel"]} /* ConnectionsPanel.swift in Sources */,
				{IDs["swift_connections"]} /* PrinterConnections.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		{IDs["debug_proj"]} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 16.0;
				MACOSX_DEPLOYMENT_TARGET = 13.0;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = iphoneos;
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
			}};
			name = Debug;
		}};
		{IDs["release_proj"]} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 16.0;
				MACOSX_DEPLOYMENT_TARGET = 13.0;
				SDKROOT = iphoneos;
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
			}};
			name = Release;
		}};
		{IDs["debug_tgt"]} /* Debug */ = {{
{tgt_settings("Debug")}
		}};
		{IDs["release_tgt"]} /* Release */ = {{
{tgt_settings("Release")}
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{IDs["config_list_proj"]} /* Build configuration list for PBXProject "OrcaSlicer" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{IDs["debug_proj"]} /* Debug */,
				{IDs["release_proj"]} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{IDs["config_list_tgt"]} /* Build configuration list for PBXNativeTarget "OrcaSlicer" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{IDs["debug_tgt"]} /* Debug */,
				{IDs["release_tgt"]} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */
	}};
	rootObject = {IDs["project"]} /* Project object */;
}}
'''

for folder in engine_resource_folders:
    file_id = uid("engine-resource-file/" + folder)
    build_id = uid("engine-resource-build/" + folder)
    pbx = pbx.replace("/* End PBXBuildFile section */",
        f"\t\t{build_id} /* {folder} in Resources */ = {{isa = PBXBuildFile; fileRef = {file_id}; }};\n"
        "/* End PBXBuildFile section */")
    pbx = pbx.replace("/* End PBXFileReference section */",
        f'\t\t{file_id} /* {folder} */ = {{isa = PBXFileReference; lastKnownFileType = folder; '
        f'path = Resources/{folder}; sourceTree = "<group>"; }};\n'
        "/* End PBXFileReference section */")
    pbx = pbx.replace("A1000000000000000000000C /* ProcessOptions.swift */,",
        f"A1000000000000000000000C /* ProcessOptions.swift */,\n\t\t\t\t{file_id} /* {folder} */,")
    pbx = pbx.replace(f'{IDs["assets"]} /* Assets.xcassets in Resources */,',
        f'{IDs["assets"]} /* Assets.xcassets in Resources */,\n\t\t\t\t{build_id} /* {folder} in Resources */,')

# UI automation owns device rotation; multitasking apps may not force their
# interface orientation through UIWindowScene.requestGeometryUpdate.
ui = {key: uid("ui-tests/" + key) for key in
      ("target", "product", "file", "build", "sources", "frameworks", "resources",
       "configs", "debug", "release", "proxy", "dependency")}

def ui_section(section, objects):
    global pbx
    end = "/* End " + section + " section */"
    pbx = pbx.replace(end, objects + "\n" + end)

pbx = pbx.replace("LastUpgradeCheck = 1600;", f"LastUpgradeCheck = 1600; TargetAttributes = {{{ui['target']} = {{CreatedOnToolsVersion = 16.4; TestTargetID = {IDs['target']}; }}; }};")
ui_section("PBXBuildFile", f'{ui["build"]} = {{isa = PBXBuildFile; fileRef = {ui["file"]}; }};')
ui_section("PBXFileReference", f'''{ui["file"]} /* WorkspaceUITests.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = tests/WorkspaceUITests.swift; sourceTree = "<group>"; }};
{ui["product"]} /* OrcaSlicerUITests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = OrcaSlicerUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};''')
pbx = pbx.replace(f'{IDs["group_products"]},', f'{IDs["group_products"]},\n                {ui["file"]},', 1)
pbx = pbx.replace(f'{IDs["product"]} /* OrcaSlicer.app */,', f'{IDs["product"]} /* OrcaSlicer.app */,\n                {ui["product"]},', 1)
ui_section("PBXNativeTarget", f'''{ui["target"]} /* OrcaSlicerUITests */ = {{isa = PBXNativeTarget;
    buildConfigurationList = {ui["configs"]};
    buildPhases = ({ui["sources"]}, {ui["frameworks"]}, {ui["resources"]});
    buildRules = (); dependencies = ({ui["dependency"]});
    name = OrcaSlicerUITests; productName = OrcaSlicerUITests;
    productReference = {ui["product"]}; productType = "com.apple.product-type.bundle.ui-testing";
}};''')
pbx = pbx.replace(f'{IDs["target"]} /* OrcaSlicer */,', f'{IDs["target"]} /* OrcaSlicer */,\n                {ui["target"]},', 1)
ui_section("PBXSourcesBuildPhase", f'{ui["sources"]} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({ui["build"]}); runOnlyForDeploymentPostprocessing = 0; }};')
ui_section("PBXFrameworksBuildPhase", f'{ui["frameworks"]} = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};')
ui_section("PBXResourcesBuildPhase", f'{ui["resources"]} = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};')
# These object kinds are absent from the single-target app project.
pbx = pbx.replace("/* Begin PBXNativeTarget section */", f'''/* Begin PBXContainerItemProxy section */
{ui["proxy"]} = {{isa = PBXContainerItemProxy; containerPortal = {IDs["project"]}; proxyType = 1; remoteGlobalIDString = {IDs["target"]}; remoteInfo = OrcaSlicer; }};
/* End PBXContainerItemProxy section */
/* Begin PBXTargetDependency section */
{ui["dependency"]} = {{isa = PBXTargetDependency; target = {IDs["target"]}; targetProxy = {ui["proxy"]}; }};
/* End PBXTargetDependency section */
/* Begin PBXNativeTarget section */''')
for configuration, key in (("Debug", "debug"), ("Release", "release")):
    ui_section("XCBuildConfiguration", f'''{ui[key]} = {{isa = XCBuildConfiguration; name = {configuration}; buildSettings = {{
        PRODUCT_BUNDLE_IDENTIFIER = com.orcaslicer.ios.uitests;
        PRODUCT_NAME = "$(TARGET_NAME)";
        GENERATE_INFOPLIST_FILE = YES; SWIFT_VERSION = 5.0;
        IPHONEOS_DEPLOYMENT_TARGET = 16.0;
        SDKROOT = iphonesimulator; SUPPORTED_PLATFORMS = iphonesimulator;
        TARGETED_DEVICE_FAMILY = "1,2"; TEST_TARGET_NAME = OrcaSlicer;
        CODE_SIGNING_ALLOWED = NO;
        LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks");
    }}; }};''')
ui_section("XCConfigurationList", f'{ui["configs"]} = {{isa = XCConfigurationList; buildConfigurations = ({ui["debug"]}, {ui["release"]}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};')
scheme_directory = PROJ / "xcshareddata" / "xcschemes"
scheme_directory.mkdir(parents=True, exist_ok=True)
reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ui["target"]}" BuildableName="OrcaSlicerUITests.xctest" BlueprintName="OrcaSlicerUITests" ReferencedContainer="container:OrcaSlicer.xcodeproj"/>'
(scheme_directory / "OrcaSlicerUITests.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1640" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Release" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
    <Testables><TestableReference skipped="NO" parallelizable="NO">{reference}</TestableReference></Testables>
  </TestAction>
</Scheme>
''')

(PROJ / "project.pbxproj").write_text(pbx)
print("Wrote", PROJ / "project.pbxproj")
print("has_ios_sim_engine=", has_ios_sim_engine)
print("has_ios_dev_engine=", has_ios_dev_engine)
print("has_profiles=", has_profiles, PROFILES_DIR if has_profiles else "")
print("has_calib=", has_calib, CALIB_DIR if has_calib else "")
