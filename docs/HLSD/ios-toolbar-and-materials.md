# iOS desktop toolbar and materials parity

Desktop references: `GLCanvas3D::_init_main_toolbar`, `GLGizmosManager::EType`,
`Sidebar::create_mixed_filament_from_result`/`MixedFilamentDialog`, and `Tab.cpp`.
The comparison is against source and official reference screenshots. A live desktop
session was unavailable. A matching label is not evidence of interaction parity.

| Desktop action | Mobile implementation / remaining work |
|---|---|
| Open, add, primitives/handy models | Native header File menu and document picker/model library |
| Add/select plate | Snapshot-backed plate selector; desktop multi-plate layout remains different |
| Auto orient, arrange | Native orient/libnest handlers; interactive desktop arrangement controls need comparison |
| More/fewer copies, delete | Native duplicate/delete and undo; inspect selection behavior on devices |
| Split objects / parts | Native ModelObject/ModelVolume split exposed in Mesh tools, selected solid-part picker, optional object auto-drop and undo; full desktop part-tree selection/editing remains incomplete |
| Move, rotate, scale | Native transforms and camera gestures; desktop gizmo handles/constraints are partial |
| Lay on face | Explicit world-space face pick calls the shared native hull-face picker and lay_on_face, including scale/mirror/rotation and instance auto-drop. One-finger drag still orbits and pinch zooms. Desktop hull highlights/plane handles remain incomplete |
| Plane cut, mesh boolean, simplify | Native algorithms with numeric mobile controls and existing geometry tests; gizmo UI parity partial |
| Support/seam/MMU/fuzzy/brim-ear paint | Native facet annotations; persistent per-filament Prepare regions; full desktop brush modes remain incomplete |
| Emboss, SVG, texture displacement | Full desktop workflows missing; a text plate is not general emboss |
| Variable layer height | Interactive desktop profile editor missing |
| Assembly view/tools | Explode/assembly-related operations are partial; full desktop assembly workflow missing |
| Views / Home | Six-face camera cube, Home, direct View menu, orbit/pan/zoom, persistent perspective/orthographic choice; optional Auto Perspective with manual overrides; additional desktop preferences remain incomplete |
| Global / Objects | Explicit target tabs; initial object layer height, walls, infill and filament overrides with reset to Global |
| Filament colors | Native color pickers, project slots, object display colors and Filament preview default; persistent painted facet colors remain attached during live transforms; each physical slot has a grouped material preset picker; full per-slot parameter editing remains incomplete |
| Mixed Filament | Native FilamentMixer color blending, 2/3 physical components, positive percentages totaling 100, linear height gradient/direction/per-part option |
| Mixed editing / custom curves | Stable-ID component/proportion/gradient editing, native-sampled curve graph, anchor drag/add/remove, two component views, automatic or explicit tangents, reverse/reset. Untouched imported data stays exact. Desktop line-body gestures, gradient swatches and deletion remain incomplete |
| Plugin manager | General desktop plugin runtime remains missing. Native Zmod processing is not compatibility with the 18 reported plugins |

The mobile painting selector no longer cycles over only four filaments. Project
slots use desktop PresetBundle sizing; the native painting representation has a
32-state painting limit and 64 project slots in this source. Mixed slots are virtual sublayer combinations, not a mixing-nozzle
ratio command. Components must be distinct physical slots with matching material
types. New physical slots currently must be added before mixed slots.

Persistence corrections capture saved selections before printer restoration,
include personal presets in restore lookup, retain canonical sanitized names,
keep active personal names while refreshing catalogs, and scope saved/loaded
filament and process JSON independently. Scoped loading also handles older full
snapshots without letting filament settings overwrite process settings. Applying
changes to an existing personal preset persists them; Save preset creates a copy.

Preview has one upper-layer slider. Toolhead scrubbing appears above the lower
layer control. Cached primitive ranges and a small partial edge reveal extrusion
and travel in sync with the interpolated marker during dragging/playback, without
rebuilding the job on each frame or release. An explicit smooth-motion toggle
controls interpolation. These controls do not modify G-code.

Validation added: cold-session preset restoration and scope isolation, canonical
names, native filament growth, mixed-ratio rejection and gradient metadata, marker
interpolation, and a UI assertion against duplicate upper-layer sliders. Apple
SDK/runtime results must be recorded separately; local catalog tests alone do not
prove these workflows work on device. This document is a parity audit and working
implementation record, not a claim that the entire desktop toolbar is ported.

Prepare color follow-up: world-space MMU facets are exported separately for each
native painting state and attached beneath their object node. Color changes
refresh materials without flattening all painted states into a single mask. The
cache is refreshed on model import/edit/undo and MMU paint changes, not camera
frames. Paint changes invalidate old slicing results. Support/seam/fuzzy diagnostic
overlays remain separate. Mixed regions use their derived swatch; matching a
height-gradient swatch in the Prepare surface is still separate from sliced
filament preview. Native tests isolate the first and highest paint states; a GPU
test checks distinct red/green regions and object attachment. Runtime validation
is tracked in CI, not implied by the source change.

View menu follow-up: desktop MainFrame View/Camera selection was compared to the
mobile camera. The header menu now exposes six face views and Home, plus a saved
perspective/orthographic choice shared with Preferences. Switching projection
keeps the target/orientation and matches the target-plane visible span. Pinch
changes orthographic scale while preserving the point under the fingers; it does
not merely move a parallel camera. Fit uses projection/aspect-aware bounds for
models, G-code and an empty bed. Camera regression cases cover both projections,
anchor preservation, pan and all face views in phone/tablet bounds. The following batch adds the desktop Auto Perspective policy.

Auto Perspective is now optional in View and Preferences. Selecting a face through
the menu or cube uses orthographic projection, and orbit/Home returns to
perspective after automatic alignment. An explicit manual projection selection
cancels that automatic return; pan/zoom keep the projection. The existing manual
behavior remains the default. Policy regression cases cover disabled mode, face
selection, orbit/Home transitions and explicit manual orthographic selection.

Runtime checkpoint: source 39167d7016f2/build b94f7b395389 passes native paint
state isolation, material/profile persistence, GPU color/camera checks and both
phone plus all three tablet UI tests (run 43839633585). Phone/tablet portrait
preview screenshots were reviewed. The landscape capture shows clipped header
content despite the old rotation predicate passing. The UI test now waits for
both header edges, all main tabs and Home/Slice to fit stable landscape bounds
before capturing. That stronger landscape check is pending. This runtime pass
predates the manual/automatic projection controls and last-object cache cleanup.

Split operations now call the same ModelObject::split and ModelVolume::split
routines as desktop Plater/ObjectList, with painting remapping enabled. The
bridge stages a Model copy and commits only a real split; invalid targets and
connected single pieces leave model/config/preview intact. Objects can preserve
Z or drop to the bed. Parts remain volumes within the same object. Native
modifier-removal behavior for Split to objects is explained in the mobile panel.
The existing async model-edit gate and snapshot undo are reused; a direct Mesh
tools chip reaches the panel without expanding the workspace. Per-part transform
selection is still separate work. Regression coverage uses disconnected solids,
nonuniform scale/rotation/translation, bounds, overrides, paint, snapshot restore
and failed-split preview retention. Native compile/runtime results remain pending.

Physical filament slots now select system/cloud/personal profiles through the
shared grouped picker. Native construct_full_config and map_variant_indices
compose nozzle variants while retaining other slots' edited values; process,
printer, project colors and mixing metadata are reapplied independently. Mixed
slots derived from a changed first component follow its profile; incompatible
component material types are rejected before applying configuration. Legacy
project-wide filament saves are scoped to their first material and variants on
read; new saves use that scope. Ambiguous device/variant layouts return errors
instead of guessing. Full per-slot parameter editing remains separate work.

CI runner annotations for source 9bf56cfefec7 report hosted ARM capacity failures
without executed steps. SDK checks and device cross-builds now use the standard
macos-15-intel image. Simulator builds now support an explicit x86_64 bundle
and execute on the Intel host, with ARM simulator support retained for local
Apple Silicon builds. Device artifacts still target arm64. The audit verifies
the requested CPU and SDK independently; project/toolchain tests reject bundle
selection mismatches and Intel device targets. Host and target architecture
remain part of dependency/compiler/engine cache keys. GPU and UI assertions are
retained; successful SDK type checks are not native runtime acceptance.

Preview motion now samples the actual G-code polyline while interpolating a
fractional move cursor; a Cartesian SceneKit tween no longer cuts corners.
The coordinator updates only the marker at up to 60 Hz and cancels its timer on
scene replacement/dismantle. Play/Pause supports 1/10/100x commanded-feedrate
playback within the selected layer range. It omits dwell and acceleration; this
is a toolhead-motion preview, not a print-time simulator. The selected range
stays visible during playback and is clipped to the cursor when paused. No bead
mesh rebuild is requested for each motion tick. Layer changes, file replacement,
backgrounding, leaving Preview and memory warnings stop playback. Fractional
slider state is retained. Regression cases cover right-angle paths, different
feedrates across segment boundaries, zero-length/unknown-feed moves, end clamps
and invalid cursor input; the phone UI test checks Play/Pause, cursor progress
and layer-change cancellation. Apple SDK/runtime checks for this batch are
pending until recorded in the build evidence.

Manual toolpath scrubbing now uses a native slider with incremental precision:
drag horizontally for the whole file, or move the finger above/below the track
for 1/10, 1/100 and move-by-move sensitivity. Switching precision does not jump
the cursor. Previous/Next and VoiceOver adjustments step to the adjacent move.
The move readout and marker retain fractional positions; releasing the control
clips the path to that same fractional endpoint rather than the preceding
integer move. Existing integer clipping remains compatible. The selected layer
range stays visible while the finger is tracking; geometry is rebuilt on release,
with no full bead-mesh rebuild on each touch event. Regression cases cover a
million-move range, precision transitions/reversal/clamps, accessibility stepping,
partial corner endpoints and integer/start clipping; phone tests exercise direct
manual adjustment and adjacent-move buttons. SDK/native validation for this batch
is pending until recorded separately.

Existing mixed rows now open the proportion/linear-gradient editor. Native edits
stage configuration, validate with validate_mixed_filament_params, and commit
without changing component or slot IDs, model painting, preset identity or other
process/printer/material values. Invalid edits retain the previous configuration.
The editor preserves original ratio text when only gradient settings change and
skips a no-op save. Imported custom curves/nonstandard ranges stay intact and
are not replaced by the linear controls. Custom-curve editing and deletion remain separate work. Native cases cover invalid edit
isolation, ratio/reverse-gradient updates, identity/process preservation and
byte-identical retained custom curves; native execution is pending.

Existing mixes can now replace their physical components and switch between two
and three components without changing the virtual slot index. When the first
component changes, the same native preset/variant composition used for slot
assignment updates only the virtual material, retaining unsaved physical values
and the global selection. Ratios remain byte-identical unless edited; derived
swatches refresh. Invalid/duplicate/virtual references, mismatched materials and
three-way gradients are rejected before commit. Imported custom gradients keep
two components so changing the count cannot silently discard their curve.
Regression cases cover virtual nozzle-variant inheritance, physical/process
isolation, rejected replacements, two/three transitions and retained object/facet
assignments. Native execution remains pending.

Linear gradient endpoints are now editable when creating or editing a mix, with
bounds queried from native FilamentMixer constants. Bottom/top shares can be
reversed. Imported ranges retain their exact text when not changed. Imported
custom curves take precedence in desktop GCode/ToolOrdering, so their linear
endpoint controls stay hidden while the curve is retained. Users can explicitly
choose linear mode; disabling/re-enabling a gradient otherwise preserves its
curve/range. Gradient and component/proportion edits share a staged transaction.
New mix gradient metadata is validated before appending a slot. Native regression
cases cover nondefault ranges, curve retention, explicit linear selection,
invalid endpoint isolation and unchanged slot count on failed creation. Custom
anchor/tangent controls are added below; native execution is pending.

Custom gradient editing now uses the native curve parser, serializer and
Hermite/PCHIP sampler through pure C helpers. The mobile graph shows both
component shares, with 44-point anchor targets, translation-based dragging,
numeric height/share controls, insert/remove, reverse and reset. Incoming/outgoing
tangents can stay automatic or be set explicitly. Reversal negates tangent slopes;
moving an anchor restores its automatic tangents as desktop does. Imported text
is kept when the editor is opened without changes or returned to its original
serialized shape. Leaving the child editor without Use curve cancels the draft.
The native helper rejects non-finite values, crossing/overlapping points and
points that collapse under native four-decimal serialization. This does not add
a project schema or change desktop defaults. Native curve/math cases are added;
Apple/native/touch execution must be recorded separately. Desktop line-body
interaction and pigment-mixed ramp swatches remain separate work.

Lay on face now resolves the tapped model/object and world-space point, finds a
valid native hull face in the touched instance's coordinates and calls the shared
`lay_on_face` routine used by desktop/CLI. The operation stages the model, uses the
existing async edit gate and snapshot undo, and preserves the prior preview on a
miss. It drops only the touched instance, even when automatic drop is disabled.
The toolbar mode keeps one-finger orbit for reaching other faces and pinch zoom;
taps place faces, while empty-bed taps do nothing. Native tests cover nonuniform
scale, compound rotation, facet annotation retention, bad-pick isolation, existing
preview retention and snapshot restoration. Desktop hull-plane highlights remain
unfinished, and native/touch execution is pending.

Progressive toolpaths now share the marker's fractional cursor. The renderer
retains the selected layer/filter geometry and updates SceneKit primitive ranges;
only the current partial edge gets a small geometry update. Job materials and
large vertex/index buffers are reused while scrubbing forward/backward, stepping,
playing or showing the complete path. This avoids per-move materials, per-vertex
cursor attributes and full mesh rebuilds on every frame or pause. Z-clipped runs
keep their original move IDs and fractional endpoint positions so inclined/vase
edges appear at the correct cursor time. The full model is still not rebuilt as
the nozzle moves. Added runtime cases cover prefix ranges, partial beads/travel,
reverse scrubbing, layer clipping, buffer identity and actual GPU pixels before,
during and after a move. Native/GPU/touch and dense-project memory verification
remain pending; playback still does not simulate acceleration or dwell.

A standalone simulator harness now compiles the production SceneKit source and
runs camera, geometry, primitive-range and GPU pixel checks without waiting for
the C++ slicing dependencies. It uses a separate test-only UIKit bundle and the
same SDK-matched runtime/timeout helpers as full engine validation. Its result
cannot establish native slicing, full-app UI or physical-device compatibility.
The first renderer SDK attempts exposed two metadata attachment errors (SCNNode
has no userData; an instance method must qualify the static association key).
Both are corrected in source; new SDK/runtime results remain separate evidence.
