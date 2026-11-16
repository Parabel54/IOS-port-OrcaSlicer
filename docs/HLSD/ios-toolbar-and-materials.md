# iOS workspace, materials and preview

The iOS host uses SwiftUI/UIKit and a C ABI over the shared OrcaSlicer engine.
Desktop wxWidgets code supplies the reference layout and setting ownership;
portable core algorithms perform model operations and slicing. The host does
not load desktop executables or claim compatibility with wx/Python plugins.

## Workspace and settings

Prepare, Preview and Device navigation sits outside the viewport's controls.
Compact layouts use dismissible sheets and a short tool strip; wider layouts can
show an inspector beside the viewport. Common setting labels, values and units
share a row when they fit, with stacked layouts for narrow widths, long values
and accessibility text. Native setting explanations load lazily in help sheets.
Independent row buttons prevent Apply, reset and help from sharing a List action.

The setting catalog uses native preset ownership and visibility metadata.
Generated page/group ordering follows desktop `Tab.cpp`, with drift tests for
the generated catalog. Printer, Filament and Process share typed boolean, enum
and serialized-value editors. Vector/nullable values retain their native shape.

Objects settings use the union of `PrintObjectConfig` and `PrintRegionConfig`.
The toolbar and settings tab open the same browser. Inherited and overridden
values remain distinct, with per-key reset. The bridge rejects global/printer
keys as object overrides and stages strict deserialization before committing.
Object edits do not save into a global preset; native 3MF preserves them.
Per-part/height-range editors and desktop dependent-control rules require
separate UI support.

## Model tools and ownership

The host exposes core primitives/handy models, selection, translation, axis
rotation/scaling, mirror, fit/drop, arrange/orient, point measurement, painting
and mesh repair/simplify/cut/boolean/split operations. Split to objects/parts uses
the shared model routines and retains native transforms, overrides and painting.
Lay on Face maps the tapped world point into the touched instance, uses native
hull-plane picking and invokes the shared lay-on-face algorithm. Candidate-plane
highlighting, full part-tree/gizmo interactions, advanced assembly/CAD, emboss,
SVG and texture-displacement interfaces are separate from these tools.

A session gate serializes native imports, slicing, preset mutation and model
algorithms. Heavy model/profile operations prepare a 3MF undo snapshot and run
outside the UI thread. Staged failures preserve the original model/preview.
Successful edits invalidate derived slicing. Undo, Redo and public project saving
honor the same gate, including keyboard-triggered actions.
Single-object imports reuse the same immutable Swift mesh arrays for framing and
selection rather than exporting that geometry twice.

## Variable layer height

An object-level panel exposes adaptive heights, native smoothing with radius
and Keep min, reset and the effective height/thickness graph. `Print::apply` and
validation resolve printer/nozzle variants, shrinkage and object slicing
parameters. The shared adaptive/smoothing algorithms write the existing
`ModelObject::layer_height_profile`; no new project schema or defaults are added.
Quality/Speed balance follows native direction: finer detail at the low end,
faster printing at the high end.

Profile reads and edits own the session gate. Edits use asynchronous snapshot
undo and invalidate slicing without exporting unchanged model meshes. The panel
reloads after its edits and after mesh revisions from Undo/Redo. Reset can clear
a malformed stored curve even when an effective profile cannot be read. Native
3MF stores the profile for later slicing. Surface brushing and 3D layer-band
editing are not represented by the graph-only interface.

## Materials and mixing

Physical slots retain their assigned preset and nozzle variants. Assignment uses
native preset composition/mapping while preserving other slots and unsaved
physical edits. Local process/filament saves use canonical names and independent
scopes. Cloud origin metadata allows personal presets to be presented before
system presets. File persistence and credential storage are independent.

Mixed slots use native component, ratio and gradient metadata. Two/three physical
components share a material type, with native positive proportions and pigment
color blending. Existing-slot edits preserve slot IDs and painted assignments.
Physical color changes recompute valid dependent swatches with the same native
pigment mixer. Single/multi-color fields are staged together in the session and
project configuration. Broken imported component references retain their stored
swatch and metadata while other physical colors remain editable. Ratio and
component edits update both swatch fields without rewriting retained curve text.
A changed first component supplies its material/nozzle variants without replacing
that physical source. Imported ratios and untouched curve text retain precision.
Physical/project and painted/mixed slot limits come from the native ABI; available
printing colors still depend on printer hardware or manual changes.

The curve editor uses native parsing, serialization and Hermite/PCHIP sampling.
Anchor insertion/removal/dragging, automatic or numeric tangents, component views,
reverse and reset edit a draft. Automatic tangents use null values at the ABI;
invalid/overlapping points are rejected. Linear endpoints and retained custom
curves follow the native precedence rules. Desktop line-body/tangent-handle
interactions and pigment-ramp swatches are not provided. Mixed deletion, physical
insertion after mixed slots and full per-slot parameter editing need additional
host support.

## Processed preview

Sliced and opened text G-code use the native `GCodeProcessor` stream. Physical
moves/events retain width, height, roles, tool/color IDs and analysis metrics.
No path/layer sampling is used. An owned-buffer transfer moves the record vector
from the session into an opaque handle, valid until explicit destruction even
across later session mutation/destruction. Swift frees it after conversion; native
statistics/metadata remain available. Another export/take of a consumed cache
fails explicitly until reload/slice repopulates it. Copying export remains an
option for other ABI clients. Swift conversion reserves its known record count
before appending, avoiding array-growth reallocations for large jobs.

SceneKit batches paths below the 16-bit vertex limit, uses normalized byte colors
and shares job materials. Layer/filter/color changes rebuild selected geometry.
Manual scrubbing and playback reuse its buffers: binary-searched primitive ranges
show completed moves and a small partial bead/travel edge follows the fractional
cursor. Original move IDs survive clipping, and compact visible intervals prevent
hidden features from reappearing. Objective-C associations retain cursor state
and are explicitly copied when cloning a preview root.

Manual input keeps a Double cursor with incremental precision control and adjacent
move actions. Optional smoothing samples the actual polyline rather than cutting
across corners. Automatic playback advances by commanded feedrates at selected
speed multipliers; acceleration/dwell physics are not simulated. Show complete,
pause and step actions reuse the cached geometry.

Preview controls expose native feature/event filters, tool/filament visibility,
layer bounds and color metrics. Memory-saving rendering removes expensive shading
while retaining paths, the source file and statistics. Desktop marker meshes,
G-code text editing and binary G-code opening are separate viewer capabilities.

## Camera and plugin boundaries

Camera state includes the target, projection and orientation. Orbit/pan and
centroid pinch zoom preserve that target/framing; explicit projection policy
separates manual orthographic choices from automatic face alignment. Six face
views and Home share the same framing path. Focused camera/GPU assertions are
separate from native/full-app/hardware validation; see [renderer validation](ios-renderer-validation.md).

Native Zmod-compatible hooks run before an exported URL is published for sharing
or upload. Unknown commands fail explicitly. This does not supply the general
desktop plugin runtime, its Python/native dependencies, wx UI or the reported
third-party plugin packages. Account/provider and printer/VPN protocols likewise
require real service/device acceptance beyond fixtures.
