"""Generator checks without Xcode, SDKs, or real engine archives."""
import importlib.util
import plistlib
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[2] / 'ios/generate_xcodeproj.py'


class DocumentAssociationTests(unittest.TestCase):
    def test_native_documents_use_model_and_preset_types(self):
        info = plistlib.loads((SOURCE.parent / 'OrcaSlicerApp/Info.plist').read_bytes())
        declared = {ext: item for item in info['UTImportedTypeDeclarations']
                    for ext in item['UTTypeTagSpecification']['public.filename-extension']}
        for ext in ('stl', 'obj', 'amf', '3mf', 'orca_printer', 'orca_filament', 'orca_bundle'):
            self.assertIn(ext, declared)
        handlers = {uti for item in info['CFBundleDocumentTypes'] for uti in item['LSItemContentTypes']}
        self.assertIn('public.geometry-definition-format', handlers)
        self.assertIn('public.zip-archive', handlers)
        self.assertNotIn('public.object-code', handlers)
        self.assertFalse(info['UIRequiresFullScreen'])
        for item in info['CFBundleDocumentTypes']:
            self.assertEqual(item['LSHandlerRank'], 'Alternate')
        self.assertNotIn('NSAllowsArbitraryLoadsInLocalNetwork', info['NSAppTransportSecurity'])

    def test_gcode_is_a_viewer_document(self):
        info = plistlib.loads((SOURCE.parent / 'OrcaSlicerApp/Info.plist').read_bytes())
        declaration = next(item for item in info['UTImportedTypeDeclarations'] if item['UTTypeIdentifier'] == 'com.orcaslicer.ios.gcode')
        self.assertEqual(set(declaration['UTTypeTagSpecification']['public.filename-extension']), {'gcode', 'gco', 'g'})
        handler = next(item for item in info['CFBundleDocumentTypes'] if 'com.orcaslicer.ios.gcode' in item['LSItemContentTypes'])
        self.assertEqual(handler['CFBundleTypeRole'], 'Viewer')
        self.assertEqual(handler['LSHandlerRank'], 'Alternate')


class ProjectGenerationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'ios').mkdir()
        shutil.copy(SOURCE, self.root / 'ios/generate_xcodeproj.py')
        shutil.copytree(SOURCE.parent / 'licenses', self.root / 'ios/licenses')
        profiles = self.root / 'resources/profiles'
        profiles.mkdir(parents=True)
        (profiles / 'vendor.json').write_text('{}')
        for folder in ('info', 'flush', 'filament_mixing', 'handy_models'):
            resource = self.root / 'resources' / folder
            resource.mkdir()
            (resource / 'table.json').write_text('{}')

    def generate(self, sdk, arch="arm64"):
        return subprocess.run([sys.executable, str(self.root / 'ios/generate_xcodeproj.py'),
                               '--require-engine', sdk, '--simulator-arch', arch], capture_output=True, text=True)

    def engine(self, sdk, arch="arm64"):
        archive = self.root / f'build-ios-{sdk}-{arch}/engine_bundle/lib/liborca_engine.a'
        archive.parent.mkdir(parents=True, exist_ok=True)
        archive.write_bytes(b'!<arch>\n')
        return archive

    def test_rejects_missing_empty_and_wrong_sdk_archives(self):
        self.assertNotEqual(self.generate('iphoneos').returncode, 0)
        self.engine('iphonesimulator')
        self.assertNotEqual(self.generate('iphoneos').returncode, 0)
        self.engine('iphoneos').write_bytes(b'')
        self.assertNotEqual(self.generate('iphoneos').returncode, 0)

    def test_linked_project_is_stable_and_refreshes_profiles(self):
        self.engine('iphoneos')
        result = self.generate('iphoneos')
        self.assertEqual(result.returncode, 0, result.stderr)
        project = self.root / 'ios/OrcaSlicer.xcodeproj/project.pbxproj'
        first = project.read_bytes()
        self.assertIn(b'ORCA_LINKED', first)
        self.assertIn(b'com.apple.product-type.bundle.ui-testing', first)
        self.assertIn(b'TEST_TARGET_NAME = OrcaSlicer', first)
        self.assertTrue((project.parent / 'xcshareddata/xcschemes/OrcaSlicerUITests.xcscheme').is_file())
        self.assertIn(b'iphoneos*', first)
        for source in (b'PrinterConnections.swift', b'ConnectionsPanel.swift', b'StartupRecovery.swift', b'StartupRecoveryView.swift', b'DocumentImport.swift', b'NativeDocumentPicker.swift', b'OrcaCloudAPI.swift', b'NativeCloudSignIn.swift', b'OrcaCloudAccount.swift', b'CloudAccountPanel.swift', b'FlashforgeClient.swift', b'NativePostProcessing.swift'):
            self.assertIn(source + b' in Sources', first)
        stale = self.root / 'ios/OrcaSlicerApp/Resources/profiles/stale.json'
        stale.write_text('{}')
        result = self.generate('iphoneos')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(first, project.read_bytes())
        self.assertFalse(stale.exists())

    def test_simulator_archive_is_never_linked_into_device_app(self):
        self.engine('iphonesimulator')
        self.assertEqual(self.generate('iphonesimulator').returncode, 0)
        project = (self.root / 'ios/OrcaSlicer.xcodeproj/project.pbxproj').read_text()
        self.assertIn('LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]', project)
        self.assertNotIn('LIBRARY_SEARCH_PATHS[sdk=iphoneos*]', project)
        self.assertNotIn('SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=iphoneos*]', project)
        self.assertNotIn('SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx"', project)
        self.assertIn('TARGETED_DEVICE_FAMILY = "1,2"', project)

    def test_explicit_intel_simulator_keeps_device_bundle_separate(self):
        self.engine('iphonesimulator', 'x86_64')
        self.engine('iphoneos')
        # An Intel archive must not silently satisfy the default ARM build.
        self.assertNotEqual(self.generate('iphonesimulator').returncode, 0)
        result = self.generate('iphonesimulator', 'x86_64')
        self.assertEqual(result.returncode, 0, result.stderr)
        project = (self.root / 'ios/OrcaSlicer.xcodeproj/project.pbxproj').read_text()
        self.assertIn('build-ios-iphonesimulator-x86_64/engine_bundle/lib', project)
        self.assertNotIn('build-ios-iphonesimulator-arm64/engine_bundle/lib', project)
        self.assertIn('"ARCHS[sdk=iphonesimulator*]" = x86_64;', project)
        self.assertIn('"EXCLUDED_ARCHS[sdk=iphonesimulator*]" = "arm64 i386";', project)
        self.assertIn('build-ios-iphoneos-arm64/engine_bundle/lib', project)
        self.assertNotIn('build-ios-iphoneos-x86_64', project)

    def test_bundles_engine_tables_and_rejects_missing_tables(self):
        self.engine('iphoneos')
        result = self.generate('iphoneos')
        self.assertEqual(result.returncode, 0, result.stderr)
        project = (self.root / 'ios/OrcaSlicer.xcodeproj/project.pbxproj').read_text()
        for folder in ('info', 'flush', 'filament_mixing', 'handy_models'):
            self.assertIn(f'path = Resources/{folder};', project)
            self.assertTrue((self.root / 'ios/OrcaSlicerApp/Resources' / folder / 'table.json').is_file())
        shutil.rmtree(self.root / 'resources/info')
        self.assertNotEqual(self.generate('iphoneos').returncode, 0)

    def test_excludes_desktop_binaries_and_versions_profile_cache(self):
        self.engine('iphoneos')
        profiles = self.root / 'resources/profiles'
        vendor = profiles / 'vendor'
        vendor.mkdir()
        for name in ('vendor.opc', 'plugin.DLL', 'helper.exe', 'libplugin.so.1', 'libplugin.dylib'):
            (vendor / name).write_bytes(b'not an iOS resource')
        (vendor / 'printer.json').write_text('{}')
        self.assertEqual(self.generate('iphoneos').returncode, 0)
        copied = self.root / 'ios/OrcaSlicerApp/Resources/profiles/vendor'
        self.assertEqual([p.name for p in copied.iterdir()], ['printer.json'])
        project = self.root / 'ios/OrcaSlicer.xcodeproj/project.pbxproj'
        first = project.read_text()
        self.assertIn('ORCA_PROFILE_REVISION', first)
        (vendor / 'printer.json').write_text('{"version":"2"}')
        self.assertEqual(self.generate('iphoneos').returncode, 0)
        self.assertNotEqual(first, project.read_text())

    def test_requires_profiles(self):
        self.engine('iphoneos')
        shutil.rmtree(self.root / 'resources/profiles')
        self.assertNotEqual(self.generate('iphoneos').returncode, 0)


class ToolchainArchitectureTests(unittest.TestCase):
    def test_mpfr_uses_the_same_target_as_gmp(self):
        deps = SOURCE.parents[1] / 'deps'
        with tempfile.TemporaryDirectory() as directory:
            check = Path(directory) / 'dependencies.cmake'
            output = Path(directory) / 'flags.txt'
            check.write_text('set(APPLE TRUE)\nset(CMAKE_SYSTEM_NAME iOS)\n'
                             'set(CMAKE_SYSTEM_PROCESSOR x86_64)\nset(DEP_OSX_TARGET 16.0)\n'
                             'function(ExternalProject_Add)\nendfunction()\n'
                             f'include("{deps}/GMP/GMP.cmake")\n'
                             f'include("{deps}/MPFR/MPFR.cmake")\n'
                             'file(WRITE "${OUT}" "${_gmp_ccflags}\\n${_mpfr_cflags}\\n'
                             '${_gmp_ldflags}\\n${_mpfr_ldflags}\\n")\n')
            for sdk, arch, minimum in (('iPhoneOS', 'arm64', '-miphoneos-version-min=16.0'),
                                        ('iPhoneSimulator', 'arm64', '-mios-simulator-version-min=16.0'),
                                        ('iPhoneSimulator', 'x86_64', '-mios-simulator-version-min=16.0')):
                with self.subTest(sdk=sdk, arch=arch):
                    sysroot = f'/SDKs/{sdk}.sdk'
                    result = subprocess.run(['cmake', f'-DCMAKE_OSX_SYSROOT={sysroot}',
                                             f'-DCMAKE_OSX_ARCHITECTURES={arch}', f'-DOUT={output}',
                                             '-P', str(check)], capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    flags = [shlex.split(line) for line in output.read_text().splitlines()]
                    for options in flags:
                        self.assertEqual(options.count('-arch'), 1)
                        self.assertEqual(options[options.index('-arch') + 1], arch)
                        self.assertEqual(options[options.index('-isysroot') + 1], sysroot)
                        self.assertIn(minimum, options)
                        self.assertFalse(any(option.startswith('-mmacosx') for option in options))

    def test_device_and_both_simulator_architectures(self):
        toolchain = SOURCE.parents[1] / 'cmake/ios.toolchain.cmake'
        with tempfile.TemporaryDirectory() as directory:
            check = Path(directory) / 'check.cmake'
            check.write_text(f'include("{toolchain}")\n'
                             'if(NOT CMAKE_OSX_SYSROOT STREQUAL EXPECTED_SDK OR '
                             'NOT CMAKE_OSX_ARCHITECTURES STREQUAL EXPECTED_ARCH)\n'
                             '  message(FATAL_ERROR "Wrong SDK/architecture")\nendif()\n')
            for platform, sdk, arch in (('OS64', 'iphoneos', 'arm64'),
                                        ('OS64SIMULATOR', 'iphonesimulator', 'arm64'),
                                        ('SIMULATORARM64', 'iphonesimulator', 'arm64'),
                                        ('SIMULATOR64', 'iphonesimulator', 'x86_64')):
                with self.subTest(platform=platform):
                    result = subprocess.run(['cmake', f'-DPLATFORM={platform}', f'-DEXPECTED_SDK={sdk}',
                                             f'-DEXPECTED_ARCH={arch}', '-P', str(check)],
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)


class AppResourceAuditTests(unittest.TestCase):
    def test_binary_platform_and_architecture_must_match_requested_target(self):
        script = SOURCE.parents[1] / 'scripts/audit_ios_app.py'
        spec = importlib.util.spec_from_file_location('audit_ios_app', script)
        audit = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(audit)
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)
            (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'OrcaSlicer'}))
            (app / 'OrcaSlicer').write_bytes(b'\xcf\xfa\xed\xfe')
            for sdk, arch, actual_arch, platform, passes in (
                ('iphoneos', 'arm64', 'arm64', 'IOS', True),
                ('iphoneos', 'x86_64', 'x86_64', 'IOS', False),
                ('iphonesimulator', 'arm64', 'arm64', 'IOSSIMULATOR', True),
                ('iphonesimulator', 'x86_64', 'x86_64', 'IOSSIMULATOR', True),
                ('iphonesimulator', 'x86_64', 'arm64', 'IOSSIMULATOR', False),
                ('iphonesimulator', 'x86_64', 'x86_64', 'MACOS', False),
                ('iphoneos', 'arm64', 'arm64', 'IOSSIMULATOR', False),
            ):
                with self.subTest(sdk=sdk, arch=arch, actual_arch=actual_arch, platform=platform):
                    def output(command, **kwargs):
                        if command[:3] == ['xcrun', 'lipo', '-archs']:
                            return actual_arch + '\n'
                        if command[:3] == ['xcrun', 'vtool', '-show-build']:
                            return ' platform ' + platform + '\n'
                        self.assertEqual(command[:2], ['otool', '-L'])
                        return 'OrcaSlicer:\n /usr/lib/libc++.1.dylib (compatibility version 1.0)\n'
                    argv = ['audit', str(app), sdk, '--arch', arch]
                    with mock.patch.object(sys, 'argv', argv), mock.patch.object(audit.subprocess, 'check_output', side_effect=output):
                        if passes:
                            audit.main()
                        else:
                            with self.assertRaises(SystemExit):
                                audit.main()

    def test_rejects_foreign_executables_and_profile_caches(self):
        script = SOURCE.parents[1] / 'scripts/audit_ios_app.py'
        spec = importlib.util.spec_from_file_location('audit_ios_app', script)
        audit = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(audit)
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)
            (app / 'profile.json').write_text('{}')
            self.assertEqual(audit.audit_resources(app), [])
            (app / 'hidden-linux-binary').write_bytes(b'\x7fELFcontent')
            (app / 'plugin.DLL').write_bytes(b'MZcontent')
            (app / 'vendor.opc').write_bytes(b'cache')
            errors = '\n'.join(audit.audit_resources(app))
            for filename in ('hidden-linux-binary', 'plugin.DLL', 'vendor.opc'):
                self.assertIn(filename, errors)


if __name__ == '__main__':
    unittest.main()
