#!/usr/bin/env python3
"""Create a minimal Orca-format 3MF for the native mobile import regression."""
import argparse
import json
from pathlib import Path
import zipfile


def create_fixture(path, padding_mib=0):
    vertices = [(0, 0, 0), (20, 0, 0), (20, 20, 0), (0, 20, 0),
                (0, 0, 20), (20, 0, 20), (20, 20, 20), (0, 20, 20)]
    triangles = [(0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7),
                 (0, 1, 5), (0, 5, 4), (1, 2, 6), (1, 6, 5),
                 (2, 3, 7), (2, 7, 6), (3, 0, 4), (3, 4, 7)]
    mesh = '<vertices>' + ''.join(f'<vertex x="{x}" y="{y}" z="{z}"/>' for x, y, z in vertices) + '</vertices>'
    mesh += '<triangles>' + ''.join(f'<triangle v1="{a}" v2="{b}" v3="{c}"/>' for a, b, c in triangles) + '</triangles>'
    model = ('<?xml version="1.0" encoding="UTF-8"?>'
             '<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">'
             '<metadata name="Application">OrcaSlicer-2.5.1</metadata>'
             '<resources><object id="1" type="model" name="Orca import regression"><mesh>' + mesh + '</mesh></object></resources>'
             '<build><item objectid="1" transform="1 0 0 0 1 0 0 0 1 0 0 0"/></build></model>')
    with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('[Content_Types].xml', '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/><Default Extension="bin" ContentType="application/octet-stream"/></Types>')
        archive.writestr('_rels/.rels', '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>')
        archive.writestr('3D/3dmodel.model', model)
        archive.writestr('Metadata/project_settings.config', json.dumps({'layer_height': '0.16'}))
        # Exercise document staging and ZIP offsets beyond 100 MB without a
        # huge mesh or a huge in-memory buffer. This is not a mesh stress test.
        if padding_mib:
            padding = zipfile.ZipInfo('Metadata/import-regression.bin')
            padding.compress_type = zipfile.ZIP_STORED
            with archive.open(padding, 'w') as stream:
                chunk = bytes(1024 * 1024)
                for _ in range(padding_mib):
                    stream.write(chunk)


def create_preset_fixtures(directory):
    printer = {'name': 'iOS imported printer', 'version': '2.5.1', 'from': 'User', 'type': 'machine',
               'inherits': '', 'printer_settings_id': 'iOS imported printer', 'printer_technology': 'FFF',
               'nozzle_diameter': ['0.4'], 'printable_area': ['0x0', '220x0', '220x220', '0x220']}
    filament = {'name': 'iOS imported PLA', 'version': '2.5.1', 'from': 'User', 'type': 'filament',
                'inherits': '', 'filament_settings_id': ['iOS imported PLA'], 'filament_type': ['PLA'],
                'filament_diameter': ['1.75']}
    with zipfile.ZipFile(directory / 'mobile-presets.orca_bundle', 'w') as archive:
        archive.writestr('printer.json', json.dumps(printer))
        archive.writestr('filament.json', json.dumps(filament))
    cloud = []
    for index, content in enumerate([printer, filament]):
        content = dict(content)
        content['name'] = content['name'].replace('imported', 'cloud')
        if index == 0:
            content['type'] = 'printer'
            content['printer_settings_id'] = content['name']
        else:
            content['filament_settings_id'] = [content['name']]
        cloud.append({'id': f'00000000-0000-4000-8000-{index + 1:012d}', 'name': content['name'],
                      'updated_time': 42, 'content': content})
    (directory / 'cloud-presets.json').write_text(json.dumps(cloud))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('path', type=Path)
    parser.add_argument('--padding-mib', type=int, choices=range(0, 101), default=0)
    arguments = parser.parse_args()
    create_fixture(arguments.path, arguments.padding_mib)
    create_preset_fixtures(arguments.path.parent)
