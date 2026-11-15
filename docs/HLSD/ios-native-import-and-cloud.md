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

The viewport has explicit Orbit, Pan, Move, Rotate and Select modes, plus Fit. One pan recognizer owns one-finger input; SceneKit's competing default recognizers are disabled. Orbit starts around the selected object or whole-model center, including after model moves. Changing modes cancels the prior gesture before transferring ownership. Pan translates the camera and its target in camera space. A two-finger pinch changes camera distance in every mode and cancels an in-progress object drag.

Move projects screen input onto the bed plane and commits through the translation C API. Rotate previews rotation around the object's center and commits through the engine's axis rotation API. Canceled object gestures restore their preview without committing a transform. Selection does not reframe the camera. Geometry revisions refresh the rendered mesh after edits; Fit and successful model imports explicitly request framing.

The controls drawer remains independent of the gesture-mode strip. Its handle can hide, compact or expand the scrollable controls.

## Platform flags

The UI target supports iPhone and iPad with separate iPhone and simulator engine paths. An absent device engine never falls back to the simulator archive. `ORCA_LINKED` is SDK-specific and generated only for the corresponding available archive. CI requires a real archive, builds both SDKs and audits each final app's Mach-O platform, dynamic dependencies and bundled resources. About displays the build revision for installation diagnosis.
