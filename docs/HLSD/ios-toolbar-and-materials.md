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
| Split objects / parts | Full desktop split workflows remain incomplete |
| Move, rotate, scale | Native transforms and camera gestures; desktop gizmo handles/constraints are partial |
| Lay on face | Auto-orient is available; explicit desktop face picking is not equivalent and remains incomplete |
| Plane cut, mesh boolean, simplify | Native algorithms with numeric mobile controls and existing geometry tests; gizmo UI parity partial |
| Support/seam/MMU/fuzzy/brim-ear paint | Native facet annotations; persistent per-filament Prepare regions; full desktop brush modes remain incomplete |
| Emboss, SVG, texture displacement | Full desktop workflows missing; a text plate is not general emboss |
| Variable layer height | Interactive desktop profile editor missing |
| Assembly view/tools | Explode/assembly-related operations are partial; full desktop assembly workflow missing |
| Views / Home | Six-face camera cube, Home, direct View menu, orbit/pan/zoom, persistent perspective/orthographic choice; Auto Perspective and additional desktop preferences remain incomplete |
| Global / Objects | Explicit target tabs; initial object layer height, walls, infill and filament overrides with reset to Global |
| Filament colors | Native color pickers, project slots, object display colors and Filament preview default; persistent painted facet colors remain attached during live transforms; full per-slot preset editor remains incomplete |
| Mixed Filament | Native FilamentMixer color blending, 2/3 physical components, positive percentages totaling 100, linear height gradient/direction/per-object option |
| Mixed custom curves | Existing core data retained on import; desktop custom curve and existing-slot editing/deletion are not exposed on mobile yet |
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
layer control and interpolates a separate marker without rebuilding every path
on every drag update; clipped toolpath geometry is rebuilt on release. An explicit
smooth-motion toggle controls interpolation. These controls do not modify G-code.

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
anchor preservation, pan and all face views in phone/tablet bounds. The desktop
Auto Perspective policy is not ported in this change.
