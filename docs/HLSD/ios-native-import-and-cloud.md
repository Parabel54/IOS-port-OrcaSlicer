# iOS documents, presets and touch interaction

The UIKit/SwiftUI host calls the official C++ engine through the mobile C ABI. Native document presentation, cloud authentication and touch interaction belong to the iOS host; model parsing, preset inheritance, compatibility and slicing belong to libslic3r.

## Documents and preset catalogs

The document picker opens provider documents in place. The inbox acquires security-scoped access before the picker closes, coordinates the read and stages a unique persistent copy. Parser work runs off the UI thread while session editing and cache mutation are paused. External Files opening uses the same inbox.

STL, OBJ, 3MF and AMF go to the model reader. Orca/Bambu 3MF requests model and configuration loading explicitly and owns the reader's plate/preset outputs. Slic3r-format project snapshots use the matching upstream reader. Failed model reads preserve the prior plate and preview.

JSON containing a preset type or a single preset identity goes to the official preset catalog importer. `.orca_printer`, `.orca_filament`, `.orca_bundle` and ZIP exports use the official bundle importer. This preserves printer, filament and process inheritance instead of applying every file as a session overlay. Untyped JSON containing all three session identities remains a config overlay. Incomplete preset JSON may use the explicitly selected legacy process/filament import. Parser failures are reported; missing inherited presets are not silently replaced with unrelated profiles.

File associations use the model UTIs and Orca archive extensions with alternate-handler rank. OBJ also advertises its platform geometry UTI. The app offers ZIP/JSON import without claiming default ownership of all such documents.

## Cloud profiles and printer inventory

Orca Cloud sign-in uses the upstream authentication endpoints and native device-only Keychain tokens. Physical printer inventory is fetched from `/api/v1/printers`. Printer, filament and process settings come from the separate `/api/v1/sync/pull` profile endpoint. A pull without a cursor requests a full snapshot, matching desktop startup.

Downloaded profiles retain their cloud identity, owner and update time. The C ABI loads them into the corresponding official preset collection, resolves inherited bases and saves user profiles for later startup. Name conflicts with unrelated local presets and unresolved inheritance are reported. Compatibility filtering still applies to filament/process choices; the account panel can show all presets.

Uploading local presets is an explicit action. The engine exports user presets, including legacy mobile process/filament saves, with their proper type. The host uses `/api/v1/sync/push` and the original update time for existing records. Stable upload identities allow the app to recognize its own uploaded copies. A 409 preserves the conflicting versions; the app does not force-push. Host addresses and `printhost_` credentials are removed from upload content. Saved native LAN connection credentials remain in Keychain.

Cloud registration of physical printers remains on the hosted service. Orca Cloud preset synchronization is separate from vendor cloud authentication and printer transports. Cloud tombstones do not automatically remove local profiles in this implementation.

## Touch interaction

The viewport has explicit Orbit, Pan, Move, Rotate and Select modes, plus Fit. One pan recognizer owns one-finger input; SceneKit's competing default recognizers are disabled. Orbit preserves the current framing target, including after panning. Fit explicitly centers the model. Rotation scales with the available viewport width and height, with pitch clamped to avoid flipping. Changing modes cancels the prior gesture before transferring ownership. Pan unprojects screen displacement at the target depth using the actual SceneKit projection, then translates the camera and its target together. A two-finger pinch changes camera distance in every mode, keeps its centroid anchored at the target depth, and cancels an in-progress object drag.

Move projects screen input onto the bed plane and commits through the translation C API. Rotate previews rotation around the object's center and commits through the engine's axis rotation API. Canceled object gestures restore their preview without committing a transform. Selection does not reframe the camera. Geometry revisions refresh the rendered mesh after edits; Fit and successful model imports explicitly request framing.

## Adaptive workspace and settings

Prepare and Preview reserve the main area for the viewport and a compact action bar. Objects/tools and preview filtering have separate dismissible inspectors. The old controls drawer and manual duplicate setting editor are no longer in the workspace.

A single settings inspector owns Printer, Filament and Process options. Available bounds of at least 860 × 500 points enable a hideable left sidebar; narrower windows use a resizable sheet. This uses actual window bounds, including iPad multitasking, rather than device identity. The app does not require full-screen presentation.

Option ownership and Basic/Advanced/Expert visibility come from the engine's desktop preset lists and ConfigOptionDef. Internal, read-only and developer options are excluded. Desktop Tab.cpp supplies the page, group and row order through scripts/generate_ios_settings.py; unmapped options retain their engine category under Additional settings. Preset selection is searchable. Process and filament preset saves use the existing catalog APIs.

## G-code post-processing

Configured post_process commands are read from the engine after export. The host resolves supported commands to native hooks and runs them before publishing the output URL for sharing or network upload. Unknown commands fail export; they are never silently skipped or passed to a shell. With no commands, exported bytes remain unchanged.

The Zmod native hook implements ghzserg/zmod_preprocess's MD5 header, filament color/type/tool metadata and optional object-outline simplification. It streams lines with Python-compatible universal newline handling, hashes the resulting bytes and atomically replaces the export. The default tolerance is 0.2 mm; --no-simplify-objects and --simplify-objects are supported. Desktop Python and compiled Zmod entrypoint paths resolve to this implementation. Third-party attribution and the Apache 2.0 license accompany the source and app resources.

The macOS host test compares output byte-for-byte with a vendored upstream reference over ordinary G-code, multicolor metadata, polygons, duplicate headers, non-UTF8 comments and CR/LF inputs. It also checks MD5, repeated execution and rejection of unsupported commands. This validates the native port rather than the ability to execute Python on iOS.

General desktop Python plugin packages, their dependencies and wxWidgets host APIs do not have an iOS runtime. The native Zmod post-processing hook does not provide arbitrary Python/plugin binary compatibility.

## Platform flags

The UI target supports iPhone and iPad with separate iPhone and simulator engine paths. An absent device engine never falls back to the simulator archive. `ORCA_LINKED` is SDK-specific and generated only for the corresponding available archive. CI requires a real archive, builds both SDKs and audits each final app's Mach-O platform, dynamic dependencies and bundled resources. About displays the build revision for installation diagnosis.


## Model library and transforms

The Add menu exposes the desktop primitives (cube, cylinder, sphere, cone, torus and disc) and the bundled handy-model catalog. Primitive meshes use the same libslic3r mesh generators and curve tolerance as desktop. Handy models load through the engine with geometry-only flags so a bundled 3MF cannot replace the selected printer or print settings. The Xcode resource generator includes the original handy_models folder, including Draco files; decoding remains in the engine.

Scale supports one-finger vertical dragging, uniform percentages and separate local-axis percentages. Engine transforms retain the selected object's visible center and bed contact; uniform group scaling shares the group's center. The transform inspector accepts relative X/Y/Z moves and axis/angle rotation. Apply dismisses the inspector so the model remains visible. Fit-to-bed and automatic orientation create undo snapshots.

Preset selection uses engine ownership metadata: cloud, local user, and system presets appear in separate sections. My presets is the initial source whenever personal compatible presets exist. System and All remain available explicitly. Filament/process compatibility filtering uses PresetBundle's selected-printer compatibility.

## Processed preview and flush configuration

Preview hides the prepare mesh and renders extrusion width and height reported by GCodeProcessor. Z clipping splits paths at range boundaries instead of joining remaining vertices across clipped sections. Discrete printable layer heights drive the upper/lower layer controls; a compact upper-layer scrubber remains beside the viewport. Camera updates reuse the existing toolpath subtree. Color modes distinguish Z position, processed layer height, line width, feature and speed, with legends in millimeters or millimeters per second. Color ranges stay stable while layers are clipped. An unsliced plate displays an explicit slice action.

Before slicing, the host checks project flush-matrix dimensions against active filament colours and physical nozzles. A staged PresetBundle runs the desktop update_multi_material_filament_presets routine when dimensions differ, preserving existing pair values and per-nozzle multipliers while initializing new pairs from the per-filament purge volumes. Fast-purge multipliers are resized separately to the nozzle count. Valid matrices are retained. This restores a desktop lifecycle step omitted by the headless host without changing desktop behavior.


## Native mesh operations

The Objects and tools inspector exposes repair, triangle-count simplification, axis-aligned plane cutting and two-object boolean operations. Boolean operands and subtract order are explicit; cut controls select the retained halves. These operations share one asynchronous dispatcher that snapshots for undo, transfers exclusive session ownership to a worker, copies errors before returning and refreshes geometry/selection on the main actor. The import session gate also blocks slicing, profile imports and memory-pressure mutation during mesh edits. Controls and interactive dismissal remain disabled until the operation finishes. The panel does not implement desktop cut connectors or text/SVG embossing.
