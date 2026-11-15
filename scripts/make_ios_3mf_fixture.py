#!/usr/bin/env python3
"""Create a minimal Orca-format 3MF for the native mobile import regression."""
import json
from pathlib import Path
import sys
import zipfile


def create_fixture(path):
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
        archive.writestr('[Content_Types].xml', '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/></Types>')
        archive.writestr('_rels/.rels', '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>')
        archive.writestr('3D/3dmodel.model', model)
        archive.writestr('Metadata/project_settings.config', json.dumps({'layer_height': '0.16'}))


if __name__ == '__main__':
    create_fixture(Path(sys.argv[1]))
