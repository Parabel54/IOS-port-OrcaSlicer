"""The native inspector must follow desktop setting ownership and locations."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('ios_settings_generator', ROOT/'scripts/generate_ios_settings.py')
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class DesktopSettingsTests(unittest.TestCase):
    def test_desktop_locations(self):
        locations, pages = generator.catalog()
        self.assertEqual(locations['0:layer_height'][:2], ('Quality', 'Layer height'))
        self.assertEqual(locations['0:post_process'][:2], ('Others', 'Post-processing Scripts'))
        self.assertEqual(locations['1:filament_type'][0], 'Filament')
        self.assertEqual(locations['2:nozzle_diameter'][0], 'Extruder')
        self.assertEqual(locations['2:machine_start_gcode'][0], 'Machine G-code')
        self.assertEqual(pages[0], ['Quality', 'Strength', 'Speed', 'Support', 'Multimaterial', 'Others'])
        self.assertEqual(len({item[2] for item in locations.values()}), len(locations))

    def test_generated_catalog_is_current(self):
        source = (ROOT/'ios/OrcaSlicerApp/ProcessOptions.swift').read_text()
        expected = generator.generated()
        self.assertEqual(source.count(expected), 1)


if __name__ == '__main__':
    unittest.main()
