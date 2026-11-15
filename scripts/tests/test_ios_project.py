"""Generator checks without Xcode, SDKs, or real engine archives."""
import importlib.util
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[2] / 'ios/generate_xcodeproj.py'


class ProjectGenerationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'ios').mkdir()
        shutil.copy(SOURCE, self.root / 'ios/generate_xcodeproj.py')
        profiles = self.root / 'resources/profiles'
        profiles.mkdir(parents=True)
        (profiles / 'vendor.json').write_text('{}')
        for folder in ('info', 'flush', 'filament_mixing'):
            resource = self.root / 'resources' / folder
            resource.mkdir()
            (resource / 'table.json').write_text('{}')

    def generate(self, sdk):
        return subprocess.run([sys.executable, str(self.root / 'ios/generate_xcodeproj.py'),
                               '--require-engine', sdk], capture_output=True, text=True)

    def engine(self, sdk):
        archive = self.root / f'build-ios-{sdk}-arm64/engine_bundle/lib/liborca_engine.a'
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
        self.assertIn(b'iphoneos*', first)
        for source in (b'PrinterConnections.swift', b'ConnectionsPanel.swift', b'StartupRecovery.swift', b'StartupRecoveryView.swift'):
            self.assertIn(source + b' in Sources', first)
        stale = self.root / 'ios/OrcaSlicerApp/Resources/profiles/stale.json'
        stale.write_text('{}')
        result = self.generate('iphoneos')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(first, project.read_bytes())
        self.assertFalse(stale.exists())

    def test_bundles_engine_tables_and_rejects_missing_tables(self):
        self.engine('iphoneos')
        result = self.generate('iphoneos')
        self.assertEqual(result.returncode, 0, result.stderr)
        project = (self.root / 'ios/OrcaSlicer.xcodeproj/project.pbxproj').read_text()
        for folder in ('info', 'flush', 'filament_mixing'):
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


class AppResourceAuditTests(unittest.TestCase):
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
