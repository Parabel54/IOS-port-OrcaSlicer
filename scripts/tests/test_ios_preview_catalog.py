"""Guard the mobile Preview catalog against changes in the desktop viewer."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class PreviewCatalogTests(unittest.TestCase):
    def test_desktop_color_modes_are_available_on_mobile(self):
        desktop = (ROOT / 'src/libvgcode/include/Types.hpp').read_text()
        enum = re.search(r'enum class EViewType[^\{]*\{(.*?)\};', desktop, re.S).group(1)
        names = set(re.findall(r'^\s*(\w+)\s*,', enum, re.M)) - {'COUNT'}
        mapping = {
            'Summary': 'summary', 'FeatureType': 'feature', 'ColorPrint': 'filament',
            'Speed': 'speed', 'ActualSpeed': 'actualSpeed', 'Height': 'layerHeight',
            'Width': 'lineWidth', 'VolumetricFlowRate': 'flow',
            'ActualVolumetricFlowRate': 'actualFlow', 'LayerTimeLinear': 'layerTime',
            'LayerTimeLogarithmic': 'layerTimeLog', 'FanSpeed': 'fan',
            'Temperature': 'temperature', 'PressureAdvance': 'pressureAdvance',
            'Acceleration': 'acceleration', 'Jerk': 'jerk', 'Tool': 'tool',
        }
        self.assertEqual(names, set(mapping), 'Desktop view modes changed; review the mobile catalog')
        mobile = (ROOT / 'ios/OrcaSlicerApp/PlateSceneView.swift').read_text()
        enum = mobile.split('enum ColorMode:', 1)[1].split('var id:', 1)[0]
        cases = {name.strip() for line in re.findall(r'^\s*case (.+)$', enum, re.M)
                 for name in line.split(',')}
        self.assertTrue(set(mapping.values()) <= cases)

    def test_feature_palette_matches_desktop_defaults(self):
        desktop = (ROOT / 'src/libvgcode/src/ViewerImpl.cpp').read_text()
        palette = desktop.split('DEFAULT_EXTRUSION_ROLES_COLORS =', 1)[1].split('} };', 1)[0]
        entries = re.findall(r'\{\s*(\d+),\s*(\d+),\s*(\d+)\s*\},?\s*//\s*(\w+)', palette)
        roles = (ROOT / 'src/libslic3r/ExtrusionEntity.cpp').read_text()
        labels = dict(re.findall(r'case er(\w+)\s*:\s*return L\("([^"]+)"\)', roles))
        mobile = (ROOT / 'ios/OrcaSlicerApp/PlateSceneView.swift').read_text()
        palette = mobile.split('static let featurePalette:', 1)[1].split('static func color(', 1)[0]
        colors = {label: int(value, 16) for label, value in re.findall(r'"([^"]+)": 0x([0-9a-f]+)', palette)}
        self.assertEqual(len(entries), 20)
        for r, g, b, role in entries:
            with self.subTest(role=role):
                expected = (int(r) << 16) | (int(g) << 8) | int(b)
                self.assertEqual(colors[labels[role].lower()], expected)


if __name__ == '__main__':
    unittest.main()
