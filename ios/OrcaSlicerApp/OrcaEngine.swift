// Bridges SwiftUI to official orca_ios_api (libslic3r).

import Foundation
import Combine
import SceneKit
import Darwin
#if canImport(UIKit)
import UIKit
#endif

/// Thin ObservableObject around C ABI in `src/ios/orca_slice_c_api.h`.
final class OrcaEngine: ObservableObject {
    @Published var modelName: String?
    @Published var hasModel = false
    @Published private(set) var lastModelImportSucceeded = false
    @Published private(set) var sessionBusy = false
    @Published private(set) var sessionBusyMessage = "Importing…"
    @Published var gcodeURL: URL?
    @Published var lastMessage = ""
    @Published var lastSliceTimeSec: Float = 0
    @Published var lastSliceFilamentMm3: Float = 0
    @Published var lastSliceLayers: Int = 0
    @Published var lastSliceStatsText: String = ""
    /// Extended analysis (G15)
    @Published var lastInitialLayerTimeSec: Float = 0
    @Published var lastAvgLayerTimeSec: Float = 0
    @Published var lastSupportMm3: Float = 0
    @Published var lastWipeTowerMm3: Float = 0
    @Published var lastAvgLayerTimeText: String = ""
    /// Filament by feature/role: (name, meters, grams)
    @Published var filamentByRole: [(name: String, meters: Float, grams: Float)] = []
    @Published var mesh: MeshGeometry?
    /// Per-object meshes for plate hit-test / selection (same order as objectNames)
    @Published var objectMeshes: [MeshGeometry] = []
    @Published private(set) var paintedFilaments: [PaintedFilamentRegion] = []
    @Published private(set) var filamentPaintRevision = 0
    @Published var gcodePathNode: SCNNode?
    @Published var gcodeGeometry: GCodePathGeometry? {
        didSet { resetPreviewSequence() }
    }
    @Published var previewIsReduced = false
    @Published private(set) var previewFromFile = false
    @Published private(set) var previewBedSize: SIMD2<Float>?
    var previewBounds: (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard let low = gcodeGeometry?.boundsMin, let high = gcodeGeometry?.boundsMax else { return nil }
        return (low, high)
    }
    @Published var objectCount: Int = 0
    @Published var objectNames: [String] = []
    @Published var selectedObjectIndex: Int = -1 // -1 = all / none
    @Published var boundsText: String = ""
    /// Model AABB Z (mm) for cut mid-height default
    @Published var modelMinZ: Float = 0
    @Published var modelMaxZ: Float = 0
    @Published var bedSize: SIMD2<Float> = SIMD2(220, 220)
    @Published var bedHeight: Float = 250
    /// Active process profile display name (system preset or bundled JSON id)
    @Published var activeProcessProfile: String = "process_0.20mm_Standard"
    /// Approximate solid volume from orca_session_model_info (mm³); 0 if unknown
    @Published var modelVolumeMm3: Float = 0
    /// Layer scrubber: max/min Z shown in Preview (mm) — horizontal clip plane
    @Published var previewMaxZ: Float = 100
    @Published var previewMinZ: Float = 0
    @Published var previewLayerHeights: [Float] = []
    @Published var gcodeZMin: Float = 0
    @Published var gcodeZMax: Float = 20
    /// Assembly explode factor (0 = collapsed layout)
    @Published var explodeFactor: Float = 0
    @Published var previewShowShell = false
    @Published var previewShowToolMarker = false {
        didSet { if !previewShowToolMarker { pauseToolheadPlayback(refresh: false) } }
    }
    @Published var previewShowCenterOfGravity = false
    @Published var previewHiddenTools: Set<Int> = []
    @Published var previewHiddenFilaments: Set<Int> = []
    @Published var previewHiddenFeatures: Set<String> = []
    @Published var previewEnabledMoves: Set<GCodePathGeometry.MoveKind> = [.extrude]
    @Published var previewColorMode: GCodePathGeometry.ColorMode = .filament
    @Published var previewThroughMove = Int.max
    @Published private(set) var previewBuilding = false
    @Published private(set) var previewLightweight = false

    // MARK: System presets (all vendors / printers / process / filament)
    @Published private(set) var startupFinished = false
    @Published var presetsLoaded = false
    @Published var presetsLoading = false
    @Published var presetOrigins: [Int: [String: Int]] = [:]
    @Published var printerNames: [String] = []
    @Published var processNames: [String] = []
    @Published var filamentNames: [String] = []
    /// Parallel to printerNames
    @Published var printerVendors: [String] = []
    @Published var selectedPrinter: String = ""
    @Published var selectedProcess: String = ""
    @Published var selectedFilament: String = ""
    /// Only list process/filament marked compatible with the selected printer
    @Published var compatibleOnly: Bool = true
    /// User-saved process preset names (also in processNames after save)
    @Published var userProcessNames: [String] = []
    /// User-saved filament preset names
    @Published var userFilamentNames: [String] = []
    /// File path to machine cover / bed texture for plate logo
    @Published var bedTexturePath: String?
    @Published var printerCoverPath: String?
    /// Active calibration mode (Slic3r::CalibMode raw int); 0 = none
    @Published var calibMode: Int = 0
    @Published var calibSummary: String = ""
    /// Last mesh health report (open edges / manifold)
    @Published var meshHealthText: String = ""
    /// Painted facet overlay (support/seam/mmu/fuzzy) for SceneKit
    @Published var paintOverlayMesh: MeshGeometry?
    /// Facets painted in last brush stroke / fill
    @Published var lastPaintCount: Int = 0
    /// Running total for active paint kind (any non-NONE)
    @Published var paintStatsText: String = ""
    /// Brim ear count for active object (W1)
    @Published var brimEarCount: Int = 0
    /// Second object index for mesh boolean (W2); -1 = auto next/prev
    @Published var booleanOtherObjectIndex: Int = -1

    private let prefsPrinterKey = "orca.lastPrinter"
    private let prefsProcessKey = "orca.lastProcess"
    private let prefsFilamentKey = "orca.lastFilament"
    private let prefsCompatKey = "orca.compatibleOnly"
    static let prefsWizardDoneKey = "orca.configWizardDone"
    static let prefsPreferredVendorsKey = "orca.preferredVendors"
    static let prefsRegionKey = "orca.region"
    static let prefsLanguageKey = "orca.language"
    static let prefsJobHistoryKey = "orca.printHostJobHistory"

    /// Print host job history entries (host + filename + date ISO8601)
    struct JobHistoryEntry: Identifiable, Codable, Equatable {
        var id: String { "\(date)|\(host)|\(filename)" }
        var host: String
        var filename: String
        var date: String // ISO8601
        var hostType: String
    }
    @Published var jobHistory: [JobHistoryEntry] = OrcaEngine.loadJobHistory()

    // MARK: Multi-plate (slot-based; each plate stores model+config as 3MF)
    @Published var plateCount: Int = 1
    @Published var currentPlateIndex: Int = 0
    /// Per-plate snapshot paths under Documents/OrcaSlicer/plates/
    private var platePaths: [URL] = []

    /// Fallback bundled process JSONs if system presets fail to load
    static let bundledProcessProfiles: [(id: String, title: String)] = [
        ("process_0.20mm_Standard", "0.20 mm Standard"),
        ("process_0.16mm_Fine", "0.16 mm Fine"),
    ]

    /// Unique vendor labels (sorted) from loaded printers
    var vendorList: [String] {
        Array(Set(printerVendors.filter { !$0.isEmpty })).sorted()
    }

    private var session: OpaquePointer?

    var version: String {
        #if ORCA_LINKED
        if let c = orca_version_string() {
            return String(cString: c)
        }
        #endif
        return "OrcaSlicer host (engine not linked)"
    }

    var isLinked: Bool {
        #if ORCA_LINKED
        return session != nil
        #else
        return false
        #endif
    }

    let automaticProfileLoading: Bool

    init(loadSystemProfiles: Bool = true) {
        automaticProfileLoading = loadSystemProfiles
        #if ORCA_LINKED
        let res = Bundle.main.resourcePath
        session = orca_session_create(res)
        if session == nil {
            startupFinished = true
            lastMessage = "orca_session_create failed"
            StartupRecovery().finish()
        } else {
            lastMessage = "Engine ready (official libslic3r)"
            applyDefaultFFF()
            // Writable data dir for installed system vendor trees
            guard configureDataDir() else {
                startupFinished = true
                StartupRecovery().finish()
                return
            }
            if loadSystemProfiles {
                Task {
                    await loadAllSystemPresets()
                    await MainActor.run { self.startupFinished = true }
                }
            } else {
                startupFinished = true
                lastMessage = "Recovery mode: engine ready without system profiles"
                StartupRecovery().finish()
            }
        }
        // Free heavy preview caches under OS memory pressure (full profile tree is large).
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMemoryWarning()
        }
        #else
        startupFinished = true
        lastMessage = "Build with ORCA_LINKED + liborca_engine.a"
        StartupRecovery().finish()
        #endif
    }

    /// Results belong to one exact model/configuration and cannot survive an edit.
    private func invalidateSlice() {
        previewRefreshTask?.cancel()
        previewBuildTask?.cancel()
        previewGeneration = UUID()
        previewBuilding = false
        gcodeURL = nil
        gcodeGeometry = nil
        previewLayerHeights = []
        gcodePathNode = nil
        previewIsReduced = false
        previewFromFile = false
        previewBedSize = nil
        lastSliceStatsText = ""
        lastAvgLayerTimeText = ""
        lastSliceTimeSec = 0
        lastSliceFilamentMm3 = 0
        lastSliceLayers = 0
        filamentByRole = []
    }

    /// A memory warning must not turn a successful slice into an unsliced plate.
    /// Retain paths/file/statistics; rebuild compact lines with every move intact.
    func handleMemoryWarning() {
        pauseToolheadPlayback(refresh: false)
        #if ORCA_LINKED
        if let s = session, !presetsLoading, !sliceRunning, !sessionBusy {
            orca_session_purge_option_caches(s)
        }
        #endif
        let wasLightweight = previewLightweight
        previewLightweight = true
        if !wasLightweight && gcodeGeometry != nil { applyPreviewLayer() }
        lastMessage = "Memory-saving preview: all toolpaths retained"
    }

    /// Approximate app footprint (MB) for status after profile load.
    func reportMemoryMB() -> Double {
        #if canImport(UIKit)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / (1024.0 * 1024.0)
        #else
        return 0
        #endif
    }

    #if ORCA_LINKED
    private func configureDataDir() -> Bool {
        guard let s = session else { return false }
        let data = StartupRecovery().dataDirectory
        do {
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            guard data.path.withCString({ orca_session_set_data_dir(s, $0) }) == 0 else {
                lastMessage = "Could not configure writable engine storage"
                return false
            }
            return true
        } catch {
            lastMessage = "Could not create engine storage: \(error.localizedDescription)"
            return false
        }
    }
    #endif

    /// Install + load every vendor under Bundle/profiles via official PresetBundle.
    @MainActor
    func loadAllSystemPresets() async {
        #if ORCA_LINKED
        guard let s = session else { return }
        if presetsLoaded || presetsLoading { return }
        presetsLoading = true
        let recovery = StartupRecovery()
        recovery.begin()
        defer {
            if presetsLoaded {
                do { try recovery.profilesLoaded() }
                catch { lastMessage = "Profiles loaded, but cache metadata could not be saved: \(error.localizedDescription)" }
            }
            recovery.finish()
        }
        lastMessage = "Loading all system profiles…"
        let sessionBits = UInt(bitPattern: s)
        let rc = await Task.detached(priority: .userInitiated) {
            let sess = OpaquePointer(bitPattern: sessionBits)!
            return orca_session_load_all_presets(sess)
        }.value
        if rc != 0 {
            let err = orca_session_last_error(s).map { String(cString: $0) } ?? "load failed"
            lastMessage = "System profiles rc=\(rc): \(err) — using bundled process"
            presetsLoading = false
            loadBundledProfileIfAvailable()
            return
        }
        refreshPresetLists()
        presetsLoaded = orca_session_presets_loaded(s) != 0
        presetsLoading = false
        // Restore compatible-only filter preference
        if UserDefaults.standard.object(forKey: prefsCompatKey) != nil {
            compatibleOnly = UserDefaults.standard.bool(forKey: prefsCompatKey)
            setCompatibleOnly(compatibleOnly)
        }
        // Restore last selection if still present; else prefer known printers
        let savedPrinter = UserDefaults.standard.string(forKey: prefsPrinterKey) ?? ""
        let savedProcess = UserDefaults.standard.string(forKey: prefsProcessKey)
        let savedFilament = UserDefaults.standard.string(forKey: prefsFilamentKey)
        var picked = false
        if !savedPrinter.isEmpty, printerNames.contains(savedPrinter) {
            picked = selectPrinter(savedPrinter)
        }
        if !picked {
            let preferred = [
                "Voron 2.4 300 0.4 nozzle",
                "Voron 2.4 250 0.4 nozzle",
                "Bambu Lab X1 Carbon 0.4 nozzle",
                "Generic Klipper Printer 0.4 nozzle",
            ]
            for name in preferred where printerNames.contains(name) {
                if selectPrinter(name) { picked = true; break }
            }
        }
        if !picked, let first = printerNames.first {
            _ = selectPrinter(first)
        }
        // Restore process/filament if still in (filtered) lists
        if let sp = savedProcess,
           !sp.isEmpty, processNames.contains(sp) || userProcessNames.contains(sp) {
            _ = selectProcess(sp)
        }
        if let sf = savedFilament,
           !sf.isEmpty, filamentNames.contains(sf) || userFilamentNames.contains(sf) {
            _ = selectFilament(sf)
        }
        let mem = reportMemoryMB()
        lastMessage = String(
            format: "Loaded %d printers · %d process · %d filament (compat %@) · ~%.0f MB",
            printerNames.count, processNames.count, filamentNames.count,
            compatibleOnly ? "on" : "off",
            mem
        )
        #endif
    }

    #if ORCA_LINKED
    private func refreshPresetLists() {
        guard let s = session else { return }
        let pc = Int(orca_session_printer_count(s))
        var printers: [String] = []
        var vendors: [String] = []
        printers.reserveCapacity(pc)
        vendors.reserveCapacity(pc)
        for i in 0..<pc {
            if let c = orca_session_printer_name(s, Int32(i)) {
                printers.append(String(cString: c))
            }
            if let v = orca_session_printer_vendor(s, Int32(i)) {
                vendors.append(String(cString: v))
            } else {
                vendors.append("")
            }
        }
        printerNames = printers
        printerVendors = vendors

        let prc = Int(orca_session_process_count(s))
        var procs: [String] = []
        procs.reserveCapacity(prc)
        for i in 0..<prc {
            if let c = orca_session_process_name(s, Int32(i)) {
                procs.append(String(cString: c))
            }
        }
        processNames = procs

        let fc = Int(orca_session_filament_count(s))
        var fils: [String] = []
        fils.reserveCapacity(fc)
        for i in 0..<fc {
            if let c = orca_session_filament_name(s, Int32(i)) {
                fils.append(String(cString: c))
            }
        }
        filamentNames = fils

        if let c = orca_session_selected_printer(s) {
            selectedPrinter = String(cString: c)
        }
        if let c = orca_session_selected_process(s) {
            selectedProcess = String(cString: c)
            if !selectedProcess.isEmpty { activeProcessProfile = selectedProcess }
        }
        if let c = orca_session_selected_filament(s) {
            selectedFilament = String(cString: c)
        }

        let uc = Int(orca_session_user_process_count(s))
        var users: [String] = []
        users.reserveCapacity(uc)
        for i in 0..<uc {
            if let c = orca_session_user_process_name(s, Int32(i)) {
                users.append(String(cString: c))
            }
        }
        userProcessNames = users
        let ufc = Int(orca_session_user_filament_count(s))
        var ufils: [String] = []
        ufils.reserveCapacity(ufc)
        for i in 0..<ufc {
            if let c = orca_session_user_filament_name(s, Int32(i)) {
                ufils.append(String(cString: c))
            }
        }
        userFilamentNames = ufils
        var origins: [Int: [String: Int]] = [:]
        for (scope, names) in [0: procs, 1: fils, 2: printers] {
            origins[scope] = Dictionary(uniqueKeysWithValues: names.map { name in
                (name, Int(name.withCString { orca_session_preset_origin(s, Int32(scope), $0) }))
            })
        }
        presetOrigins = origins
        compatibleOnly = orca_session_get_compatible_only(s) != 0
        refreshObjectFilamentColors()
    }

    private func refreshCoverAndBedTexture() {
        guard let s = session else { return }
        var buf = [CChar](repeating: 0, count: 2048)
        if orca_session_printer_cover_path(s, &buf, buf.count) == 0 {
            printerCoverPath = String(cString: buf)
        } else {
            printerCoverPath = nil
        }
        buf = [CChar](repeating: 0, count: 2048)
        if orca_session_printer_bed_texture_path(s, &buf, buf.count) == 0 {
            bedTexturePath = String(cString: buf)
        } else {
            bedTexturePath = printerCoverPath
        }
    }
    #endif

    @discardableResult
    func selectPrinter(_ name: String) -> Bool {
        #if ORCA_LINKED
        guard let s = session, presetsLoaded else { return false }
        let rc = name.withCString { orca_session_select_printer(s, $0) }
        if rc != 0 {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "select_printer failed"
            return false
        }
        // Apply machine+process+filament → session config + bed size
        let arc = orca_session_apply_presets(s)
        if arc != 0 {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "apply_presets failed"
            return false
        }
        // Compatible process/filament lists rebuilt in C after update_compatible
        refreshPresetLists()
        selectedPrinter = name
        if let c = orca_session_selected_process(s) {
            selectedProcess = String(cString: c)
            activeProcessProfile = selectedProcess
        }
        if let c = orca_session_selected_filament(s) {
            selectedFilament = String(cString: c)
        }
        refreshBedSize()
        refreshCoverAndBedTexture()
        persistSelection()
        lastMessage = String(
            format: "Printer: %@ · bed %d×%d · %d process · %d filament",
            name, Int(bedSize.x), Int(bedSize.y), processNames.count, filamentNames.count
        )
        return true
        #else
        return false
        #endif
    }

    @discardableResult
    func selectProcess(_ name: String) -> Bool {
        #if ORCA_LINKED
        guard let s = session, presetsLoaded else { return false }
        let rc = name.withCString { orca_session_select_process(s, $0) }
        if rc != 0 {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "select_process failed"
            return false
        }
        _ = orca_session_apply_presets(s)
        invalidateSlice()
        selectedProcess = name
        activeProcessProfile = name
        refreshPresetLists()
        refreshBedSize()
        persistSelection()
        lastMessage = "Process: \(name)"
        return true
        #else
        return false
        #endif
    }

    @discardableResult
    func selectFilament(_ name: String) -> Bool {
        #if ORCA_LINKED
        guard let s = session, presetsLoaded else { return false }
        let rc = name.withCString { orca_session_select_filament(s, $0) }
        if rc != 0 {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "select_filament failed"
            return false
        }
        _ = orca_session_apply_presets(s)
        invalidateSlice()
        selectedFilament = name
        refreshObjectFilamentColors()
        persistSelection()
        lastMessage = "Filament: \(name)"
        return true
        #else
        return false
        #endif
    }

    func setCompatibleOnly(_ on: Bool) {
        #if ORCA_LINKED
        guard let s = session else { return }
        compatibleOnly = on
        orca_session_set_compatible_only(s, on ? 1 : 0)
        UserDefaults.standard.set(on, forKey: prefsCompatKey)
        refreshPresetLists()
        lastMessage = on
            ? "Compatible process/filament only"
            : "Showing all process/filament profiles"
        #endif
    }

    /// Persist current process settings as a user preset (Documents/…/user_presets/process).
    @discardableResult
    func saveUserProcess(name: String) -> Bool {
        #if ORCA_LINKED
        guard let s = session else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastMessage = "Enter a name for the user process"
            return false
        }
        let rc = trimmed.withCString { orca_session_save_user_process(s, $0) }
        if rc != 0 {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "save user process failed"
            return false
        }
        refreshPresetLists()
        activeProcessProfile = selectedProcess
        persistSelection()
        lastMessage = "Saved user process “\(trimmed)”"
        return true
        #else
        return false
        #endif
    }

    /// Persist current filament settings as user preset (Documents/…/user_presets/filament).
    @discardableResult
    func saveUserFilament(name: String) -> Bool {
        #if ORCA_LINKED
        guard let s = session else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastMessage = "Enter a name for the user filament"
            return false
        }
        let rc = trimmed.withCString { orca_session_save_user_filament(s, $0) }
        if rc != 0 {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "save user filament failed"
            return false
        }
        refreshPresetLists()
        persistSelection()
        lastMessage = "Saved user filament “\(trimmed)”"
        return true
        #else
        return false
        #endif
    }

    /// Export current DynamicPrintConfig to Documents (or given URL) as JSON.
    @discardableResult
    func exportConfigJSON(to url: URL? = nil) -> URL? {
        #if ORCA_LINKED
        guard let s = session else {
            lastMessage = "No session"
            return nil
        }
        let dest: URL
        if let url {
            dest = url
        } else {
            let name = selectedProcess.isEmpty ? "OrcaConfig" : selectedProcess
                .replacingOccurrences(of: "/", with: "-")
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            dest = docs.appendingPathComponent("OrcaSlicer/exports/\(name).json")
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let rc = dest.path.withCString { orca_session_export_config(s, $0) }
        if rc != 0 {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "export config failed"
            return nil
        }
        lastMessage = "Exported config → \(dest.lastPathComponent)"
        return dest
        #else
        lastMessage = "Not linked"
        return nil
        #endif
    }

    @MainActor
    func importCloudProfiles(_ profiles: [OrcaCloudProfile], owner: String, adoptedIDs: Set<String> = []) async -> Bool {
        guard !sessionBusy, !presetsLoading, !sliceRunning, startupFinished else { return false }
        #if ORCA_LINKED
        guard let session else { return false }
        sessionBusyMessage = "Importing…"
        sessionBusy = true
        defer { sessionBusy = false }
        do {
            let records = try profiles.map { profile -> [String: Any] in
                var record = try profile.record()
                record["adopt_local"] = adoptedIDs.contains(profile.id)
                return record
            }
            let data = try JSONSerialization.data(withJSONObject: records)
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
            try data.write(to: path, options: .atomic)
            defer { try? FileManager.default.removeItem(at: path) }
            let bits = UInt(bitPattern: session)
            let result = await Task.detached(priority: .userInitiated) {
                path.path.withCString { path in owner.withCString { owner in
                    orca_session_import_cloud_presets(OpaquePointer(bitPattern: bits)!, path, owner)
                } }
            }.value
            guard result >= 0 else {
                lastMessage = orca_session_last_error(session).map { String(cString: $0) } ?? "Cloud preset import failed"
                return false
            }
            refreshPresetLists()
            lastMessage = String(localized: "Imported \(result) cloud printer, filament and process presets.")
            return true
        } catch { lastMessage = error.localizedDescription; return false }
        #else
        return false
        #endif
    }

    func exportLocalCloudProfiles() throws -> [OrcaCloudProfile] {
        #if ORCA_LINKED
        guard let session, !sessionBusy, !presetsLoading, !sliceRunning else { throw OrcaCloudError.unavailable }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: path) }
        guard path.path.withCString({ orca_session_export_user_profiles(session, $0) }) >= 0,
              let records = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [[String: Any]] else {
            throw OrcaCloudError.invalidResponse
        }
        return try records.map(OrcaCloudProfile.init(record:))
        #else
        throw OrcaCloudError.unavailable
        #endif
    }

    /// Catalog imports preserve preset type/inheritance. Untyped session JSON is
    /// a settings overlay; it must not become a printer merely because it has IDs.
    @MainActor
    @discardableResult
    func importConfigJSON(url: URL, asUserPreset kind: Int? = nil) async -> Bool {
        guard !sessionBusy, !presetsLoading, !sliceRunning else { return false }
        #if ORCA_LINKED
        guard let s = session else { return false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let dest = copyToTemp(url) else { return false }
        sessionBusyMessage = "Importing…"
        sessionBusy = true
        defer { sessionBusy = false }
        let bits = UInt(bitPattern: s)
        do {
            let (result, catalog) = try await Task.detached(priority: .userInitiated) { () throws -> (Int32, Bool) in
                let session = OpaquePointer(bitPattern: bits)!
                let catalog = try DocumentImportStore.isPresetCatalog(dest)
                let result = dest.path.withCString { path -> Int32 in
                    if catalog { return orca_session_import_preset_catalog(session, path) }
                    if let kind { return orca_session_import_user_preset(session, path, Int32(kind)) }
                    return orca_session_import_config(session, path)
                }
                return (result, catalog)
            }.value
            guard catalog ? result > 0 : result == 0 else {
                lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "Settings import failed"
                return false
            }
            refreshPresetLists()
            if catalog {
                lastMessage = String(localized: "Imported \(result) presets. Select them in Process settings.")
            } else if let kind {
                if kind == 0, let selected = orca_session_selected_process(s) {
                    selectedProcess = String(cString: selected)
                    activeProcessProfile = selectedProcess
                } else if let selected = orca_session_selected_filament(s) {
                    selectedFilament = String(cString: selected)
                }
                persistSelection()
                lastMessage = String(localized: "Imported user preset from \(url.lastPathComponent).")
            } else {
                invalidateSlice()
                refreshBedSize()
                lastMessage = String(localized: "Imported settings from \(url.lastPathComponent).")
            }
            return true
        } catch { lastMessage = error.localizedDescription; return false }
        #else
        return false
        #endif
    }

    // MARK: - Mesh / object ops (G14)

    @discardableResult
    func cloneGrid(nx: Int, ny: Int, spacingMm: Float = 15) -> Bool {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return false }
        let idx = selectedObjectIndex >= 0 ? selectedObjectIndex : 0
        let rc = orca_session_clone_grid(s, Int32(idx), Int32(nx), Int32(ny), spacingMm)
        if rc < 0 {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "clone_grid failed"
            return false
        }
        refreshObjectList()
        refreshMesh()
        refreshBounds()
        refreshModelInfo()
        lastMessage = "Clone grid \(nx)×\(ny) → \(objectCount) objects"
        return true
        #else
        return false
        #endif
    }

    @discardableResult
    func refreshMeshHealth() -> Bool {
        #if ORCA_LINKED
        guard let s = session, hasModel else {
            meshHealthText = ""
            return false
        }
        let idx = selectedObjectIndex >= 0 ? Int32(selectedObjectIndex) : Int32(-1)
        var facets: Int32 = 0, openEdges: Int32 = 0, parts: Int32 = 0
        var vol: Float = 0
        let rc = orca_session_mesh_stats(s, idx, &facets, &openEdges, &parts, &vol)
        if rc != 0 {
            meshHealthText = orca_session_last_error(s).map { String(cString: $0) } ?? "stats failed"
            return false
        }
        if openEdges == 0 {
            meshHealthText = "Manifold · \(facets) facets · \(parts) part(s)"
        } else {
            meshHealthText = "Non-manifold · \(openEdges) open edges · \(facets) facets"
        }
        lastMessage = meshHealthText
        return true
        #else
        return false
        #endif
    }

    private func persistSelection() {
        UserDefaults.standard.set(selectedPrinter, forKey: prefsPrinterKey)
        UserDefaults.standard.set(selectedProcess, forKey: prefsProcessKey)
        UserDefaults.standard.set(selectedFilament, forKey: prefsFilamentKey)
    }

    /// Printers for a vendor (empty vendor = all). Optional search filter.
    func filteredPrinters(vendor: String?, search: String) -> [String] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return printerNames.enumerated().compactMap { idx, name in
            if let vendor, !vendor.isEmpty {
                let v = idx < printerVendors.count ? printerVendors[idx] : ""
                if v.caseInsensitiveCompare(vendor) != .orderedSame { return nil }
            }
            if !q.isEmpty && !name.lowercased().contains(q) { return nil }
            return name
        }
    }

    func filteredProcesses(search: String) -> [String] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return processNames }
        return processNames.filter { $0.lowercased().contains(q) }
    }

    func filteredFilaments(search: String) -> [String] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return filamentNames }
        return filamentNames.filter { $0.lowercased().contains(q) }
    }

    deinit {
        previewPlaybackTask?.cancel()
        #if ORCA_LINKED
        if let s = session { orca_session_destroy(s) }
        #endif
    }

    #if ORCA_LINKED
    @discardableResult
    private func setOptionRaw(_ key: String, _ value: String) -> Int32 {
        guard let s = session else { return -1 }
        let rc = key.withCString { k in
            value.withCString { v in
                orca_session_set_option(s, k, v)
            }
        }
        if rc == 0 { invalidateSlice() }
        return rc
    }
    #endif

    private func applyDefaultFFF() {
        #if ORCA_LINKED
        // Minimal printer defaults must agree with upstream's extrusion-mode validation.
        _ = setOptionRaw("use_relative_e_distances", "1")
        _ = setOptionRaw("layer_change_gcode", "G92 E0")
        _ = setOptionRaw("layer_height", "0.2")
        _ = setOptionRaw("wall_loops", "2")
        _ = setOptionRaw("sparse_infill_density", "15%")
        _ = setOptionRaw("filament_diameter", "1.75")
        _ = setOptionRaw("nozzle_diameter", "0.4")
        _ = setOptionRaw("printable_area", "0x0,220x0,220x220,0x220")
        _ = setOptionRaw("printable_height", "250")
        bedSize = SIMD2(220, 220)
        bedHeight = 250
        refreshBedSize()
        #endif
    }

    func refreshBedSize() {
        #if ORCA_LINKED
        guard let s = session else { return }
        var w: Float = 220, d: Float = 220, h: Float = 250
        if orca_session_bed_size(s, &w, &d, &h) == 0 {
            bedSize = SIMD2(w, d)
            bedHeight = h
        }
        #endif
    }

    func refreshObjectList() {
        #if ORCA_LINKED
        guard let s = session, hasModel else {
            objectNames = []
            objectCount = 0
            return
        }
        let n = Int(orca_session_object_count(s))
        objectCount = n
        var names: [String] = []
        for i in 0..<n {
            if let c = orca_session_object_name(s, Int32(i)) {
                let name = String(cString: c)
                names.append(name.isEmpty ? "Object \(i + 1)" : name)
            } else {
                names.append("Object \(i + 1)")
            }
        }
        objectNames = names
        if selectedObjectIndex >= n {
            selectedObjectIndex = n > 0 ? 0 : -1
        }
        #endif
    }

    /// Load first available bundled process profile (Standard preferred, then Fine).
    func loadBundledProfileIfAvailable() {
        let candidates = Self.bundledProcessProfiles.map(\.id) + [
            "0.20mm Standard",
            "0.16mm Fine",
        ]
        for name in candidates {
            if loadProcessProfile(name) {
                return
            }
        }
    }

    /// Load a bundled process JSON by resource name (no extension).
    /// Re-applies bed defaults after load because process profiles omit printable_area.
    @discardableResult
    func loadProcessProfile(_ resourceName: String) -> Bool {
        #if ORCA_LINKED
        guard let s = session else { return false }
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "json") else {
            return false
        }
        let rc = url.path.withCString { orca_session_load_config(s, $0) }
        if rc == 0 {
            // Preserve current bed if already set; otherwise apply FFF defaults including bed
            let w = bedSize.x, d = bedSize.y, h = bedHeight
            // Process profiles may wipe unrelated keys — reassert nozzle/filament + bed
            _ = setOptionRaw("filament_diameter", "1.75")
            _ = setOptionRaw("nozzle_diameter", "0.4")
            setBedSize(width: w, depth: d, height: h)
            activeProcessProfile = resourceName
            // setBedSize updates lastMessage — restore profile load status
            lastMessage = "Loaded process profile: \(resourceName)"
            return true
        } else {
            let err = orca_session_last_error(s).map { String(cString: $0) } ?? "?"
            lastMessage = "Profile \(resourceName) rc=\(rc): \(err)"
            return false
        }
        #else
        return false
        #endif
    }

    func loadConfig(url: URL) -> String {
        #if ORCA_LINKED
        guard let s = session else { return "No session" }
        let rc = url.path.withCString { orca_session_load_config(s, $0) }
        if rc != 0 {
            let err = orca_session_last_error(s).map { String(cString: $0) } ?? "error"
            lastMessage = "load_config rc=\(rc): \(err)"
            return lastMessage
        }
        refreshBedSize()
        lastMessage = "Loaded config \(url.lastPathComponent)"
        return lastMessage
        #else
        return "Not linked"
        #endif
    }

    /// Copy security-scoped URL into temp for the C engine.
    private func copyToTemp(_ url: URL) -> URL? {
        do {
            if DocumentImportStore.models.owns(url) { return url }
            return try DocumentImportStore.temporary.copy(url)
        } catch {
            lastMessage = "Copy failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Load model, replacing the plate (default).
    func loadModel(url: URL) -> String {
        loadModel(url: url, append: false)
    }

    /// Add model onto the plate without clearing existing objects.
    func addModel(url: URL) -> String {
        loadModel(url: url, append: true)
    }

    func loadModel(url: URL, append: Bool) -> String {
        lastModelImportSucceeded = false
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard let dest = copyToTemp(url) else { return lastMessage }

        #if ORCA_LINKED
        guard let s = session else {
            lastMessage = "No session"
            return lastMessage
        }
        let rc: Int32 = dest.path.withCString { path in
            if append {
                return orca_session_add_model(s, path)
            } else {
                return orca_session_load_model(s, path)
            }
        }
        return finishModelImport(url: url, append: append, rc: rc)
        #else
        modelName = url.lastPathComponent + " (engine not linked)"
        hasModel = false
        lastMessage = "Engine not linked"
        return lastMessage
        #endif
    }

    /// The document inbox owns these files, so native parsing can run off the UI
    /// thread while controls and memory-pressure native cache mutation are paused.
    @MainActor
    func loadDocumentModel(url: URL, append: Bool, includeSettings: Bool = true) async -> Bool {
        guard !sessionBusy, !presetsLoading, !sliceRunning else { return false }
        sessionBusyMessage = "Importing…"
        sessionBusy = true
        lastModelImportSucceeded = false
        defer { sessionBusy = false }
        #if ORCA_LINKED
        guard let session else { lastMessage = "No session"; return false }
        let bits = UInt(bitPattern: session)
        let rc = await Task.detached(priority: .userInitiated) {
            let session = OpaquePointer(bitPattern: bits)!
            return url.path.withCString {
                if append && !includeSettings { return orca_session_add_model_geometry(session, $0) }
                return append ? orca_session_add_model(session, $0) : orca_session_load_model(session, $0)
            }
        }.value
        _ = finishModelImport(url: url, append: append, rc: rc)
        return lastModelImportSucceeded
        #else
        lastMessage = "Engine not linked"
        return false
        #endif
    }

    #if ORCA_LINKED
    private func finishModelImport(url: URL, append: Bool, rc: Int32) -> String {
        guard let s = session else { return "No session" }
        if rc != 0 {
            let err = orca_session_last_error(s).map { String(cString: $0) } ?? "error"
            lastMessage = "\(append ? "add" : "load")_model rc=\(rc): \(err)"
            return lastMessage
        }
        lastModelImportSucceeded = true
        modelName = append
            ? "\(objectCount + 1) objects · last \(url.lastPathComponent)"
            : url.lastPathComponent
        hasModel = true
        let is3MF = url.pathExtension.lowercased() == "3mf"
        // 3MF projects already store world transforms + print config — do not re-center.
        if append {
            _ = orca_session_arrange(s)
        } else if !is3MF {
            _ = orca_session_center_on_bed(s)
        }
        refreshObjectList()
        refreshMesh()
        refreshBounds()
        refreshModelInfo()
        refreshBedSize()
        gcodeURL = nil
        gcodePathNode = nil
        gcodeGeometry = nil
        previewLayerHeights = []
        if is3MF && !append {
            lastMessage = "Opened project \(url.lastPathComponent) · \(objectCount) object(s) · config restored"
        } else {
            lastMessage = "Loaded \(url.lastPathComponent) · \(objectCount) object(s) · mesh ready"
        }
        return lastMessage
    }
    #endif

    @Published var previewToolheadPosition: SCNVector3?
    @Published var smoothToolheadMovement = true
    @Published private(set) var previewToolheadMove: Double?
    @Published private(set) var previewPlaybackRunning = false
    private var previewManualScrubbing = false
    @Published var previewPlaybackRate = 1.0
    private var previewPlaybackTask: Task<Void, Never>?

    func resetPreviewSequence() {
        pauseToolheadPlayback(refresh: false)
        previewManualScrubbing = false
        previewThroughMove = .max
        previewToolheadMove = nil
        previewToolheadPosition = nil
    }

    func pauseToolheadPlayback(refresh: Bool = true) {
        previewPlaybackTask?.cancel()
        previewPlaybackTask = nil
        let wasPlaying = previewPlaybackRunning
        previewPlaybackRunning = false
        if refresh && wasPlaying { requestPreviewLayer() }
    }

    func playToolhead() {
        guard let geometry = gcodeGeometry, geometry.moveCount > 0 else { return }
        pauseToolheadPlayback(refresh: false)
        // Restrict playback to the selected layer range; feature filters affect
        // visibility, while physical nozzle travel still belongs to the route.
        var first: Int?, last: Int?
        for segment in geometry.segments {
            guard let a = segment.points.first, let b = segment.points.last,
                  max(a.z, b.z) >= previewMinZ - 0.001,
                  min(a.z, b.z) <= previewMaxZ + 0.001 else { continue }
            first = first ?? segment.firstMove
            last = segment.lastMove
        }
        guard let first, let last else { return }
        let start = Double(first - 1), end = Double(last)
        let cursor = previewToolheadMove ?? start
        let needsFullPath = previewThroughMove != .max || previewBuilding
        updateToolhead(to: cursor < start || cursor >= end ? start : cursor)
        // Show the selected range during motion; rebuild the clipped beads
        // once paused, rather than rebuilding a large mesh on every tick.
        previewThroughMove = .max
        if needsFullPath { applyPreviewLayer() }
        previewPlaybackRunning = true
        previewPlaybackTask = Task { @MainActor [weak self] in
            var timestamp = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
                guard let self, self.previewPlaybackRunning, let geometry = self.gcodeGeometry else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if self.previewBuilding { timestamp = now; continue }
                let elapsed = min(0.25, max(0, now - timestamp))
                timestamp = now
                let next = min(end, geometry.advanceToolhead(from: self.previewToolheadMove ?? start,
                    seconds: elapsed * self.previewPlaybackRate))
                self.updateToolhead(to: next)
                if next >= end { self.pauseToolheadPlayback(); return }
            }
        }
    }

    private func updateToolhead(to value: Double) {
        guard let geometry = gcodeGeometry, value.isFinite else { return }
        let cursor = max(-1, min(value, Double(max(0, geometry.moveCount - 1))))
        previewThroughMove = max(0, Int(cursor))
        previewToolheadMove = cursor
        previewShowToolMarker = true
        previewToolheadPosition = geometry.position(atMove: cursor)
    }

    func scrubToolhead(to value: Double) {
        pauseToolheadPlayback(refresh: false)
        updateToolhead(to: value)
    }

    func setToolheadScrubbing(_ editing: Bool) {
        pauseToolheadPlayback(refresh: false)
        let needsFullPath = previewThroughMove != .max
        previewManualScrubbing = editing
        if editing {
            if needsFullPath { applyPreviewLayer() }
        } else { requestPreviewLayer() }
    }

    func stepToolhead(_ direction: Int) {
        guard let geometry = gcodeGeometry, geometry.moveCount > 0 else { return }
        previewManualScrubbing = false
        let cursor = previewToolheadMove ?? Double(min(previewThroughMove, geometry.moveCount - 1))
        scrubToolhead(to: max(0, direction > 0 ? floor(cursor) + 1 : ceil(cursor) - 1))
        requestPreviewLayer()
    }

    private var previewRefreshTask: Task<Void, Never>?

    func requestPreviewLayer() {
        previewRefreshTask?.cancel()
        previewRefreshTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 60_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            self?.applyPreviewLayer()
        }
    }

    private var previewBuildTask: Task<SCNNode, Never>?
    private var previewGeneration = UUID()

    /// Build CPU geometry away from UIKit's event/termination thread. A cancelled
    /// slider build must never replace a newer result or a different project's slice.
    func applyPreviewLayer() {
        previewBuildTask?.cancel()
        let generation = UUID()
        previewGeneration = generation
        guard let geo = gcodeGeometry else {
            gcodePathNode = nil
            previewBuilding = false
            return
        }
        let lo = min(previewMinZ, previewMaxZ), hi = max(previewMinZ, previewMaxZ)
        let hidden = previewHiddenFeatures, moves = previewEnabledMoves
        let tools = previewHiddenTools, filaments = previewHiddenFilaments
        let moving = previewPlaybackRunning || previewManualScrubbing
        let through = moving || previewToolheadMove != nil ? Int.max : previewThroughMove
        let fractionalThrough = moving ? nil : previewToolheadMove, mode = previewColorMode
        let toolMarker = previewShowToolMarker, cog = previewShowCenterOfGravity
        let lightweight = previewLightweight || geo.moveCount > 250_000
        previewBuilding = true
        let work = Task.detached(priority: .userInitiated) {
            let filtered = geo.filtered(minZ: lo, maxZ: hi, hiddenFeatures: hidden,
                enabledMoves: moves, hiddenTools: tools, hiddenFilaments: filaments, throughMove: through, throughPosition: fractionalThrough, cancelled: { Task.isCancelled })
            return filtered.makeNode(color: .white, colorMode: mode, showToolMarker: toolMarker, showCenterOfGravity: cog, lightweight: lightweight, cancelled: { Task.isCancelled })
        }
        previewBuildTask = work
        Task { @MainActor [weak self] in
            let node = await work.value
            guard let self, self.previewGeneration == generation, !work.isCancelled else { return }
            self.gcodePathNode = node
            self.previewBuilding = false
        }
    }

    @Published private(set) var meshRevision = 0

    func refreshMesh() {
        meshRevision += 1
        invalidateSlice()
        // Imported projects, undo, mesh edits and instance transforms can all
        // change the world-space annotation geometry.
        defer { refreshFilamentPaint() }
        #if ORCA_LINKED
        guard let s = session, hasModel else {
            mesh = nil
            objectMeshes = []
            return
        }
        // Combined mesh (framing + single-object fallback)
        var posPtr: UnsafeMutablePointer<Float>?
        var idxPtr: UnsafeMutablePointer<UInt32>?
        var vcount: Int = 0
        var icount: Int = 0
        let rc = orca_session_export_mesh(s, &posPtr, &vcount, &idxPtr, &icount)
        defer {
            if let p = posPtr { orca_free(p) }
            if let i = idxPtr { orca_free(i) }
        }
        guard rc == 0, let posPtr, let idxPtr, vcount > 0, icount > 0 else {
            mesh = nil
            objectMeshes = []
            return
        }
        let positions = Array(UnsafeBufferPointer(start: posPtr, count: vcount * 3))
        let indices = Array(UnsafeBufferPointer(start: idxPtr, count: icount))
        var bmin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var bmax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for i in 0..<vcount {
            let p = SIMD3(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2])
            bmin = min(bmin, p)
            bmax = max(bmax, p)
        }
        mesh = MeshGeometry(positions: positions, indices: indices, min: bmin, max: bmax)

        // Per-object meshes so the user can tap/select on the plate
        let n = Int(orca_session_object_count(s))
        var per: [MeshGeometry] = []
        per.reserveCapacity(max(n, 0))
        for oi in 0..<n {
            var oPos: UnsafeMutablePointer<Float>?
            var oIdx: UnsafeMutablePointer<UInt32>?
            var ov: Int = 0, oiCount: Int = 0
            let orc = orca_session_export_object_mesh(s, Int32(oi), &oPos, &ov, &oIdx, &oiCount)
            defer {
                if let p = oPos { orca_free(p) }
                if let i = oIdx { orca_free(i) }
            }
            guard orc == 0, let oPos, let oIdx, ov > 0, oiCount > 0 else {
                per.append(MeshGeometry(positions: [], indices: [], min: .zero, max: .zero))
                continue
            }
            let pos = Array(UnsafeBufferPointer(start: oPos, count: ov * 3))
            let ind = Array(UnsafeBufferPointer(start: oIdx, count: oiCount))
            var omin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var omax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for i in 0..<ov {
                let p = SIMD3(pos[i * 3], pos[i * 3 + 1], pos[i * 3 + 2])
                omin = min(omin, p)
                omax = max(omax, p)
            }
            per.append(MeshGeometry(positions: pos, indices: ind, min: omin, max: omax))
        }
        objectMeshes = per
        refreshObjectFilamentColors()
        #endif
    }

    func selectObject(at index: Int) {
        let count = max(objectCount, objectMeshes.count)
        guard index >= 0, index < count else {
            clearSelection()
            return
        }
        // Keep selection if already selected (re-tap empty bed or Deselect chip to clear).
        // Do NOT toggle-off on re-tap — iOS fires a tap after drag and was wiping selection.
        selectedObjectIndex = index
        let name = objectNames.indices.contains(index) ? objectNames[index] : "Object \(index + 1)"
        lastMessage = "Selected \(name) · tap empty plate or Deselect to clear"
    }

    func clearSelection() {
        selectedObjectIndex = -1
        lastMessage = "Nothing selected · tap an object to select"
    }

    func refreshBounds() {
        #if ORCA_LINKED
        guard let s = session, hasModel else {
            boundsText = ""
            modelMinZ = 0
            modelMaxZ = 0
            return
        }
        var minx: Float = 0, miny: Float = 0, minz: Float = 0
        var maxx: Float = 0, maxy: Float = 0, maxz: Float = 0
        if orca_session_model_bounds(s, &minx, &miny, &minz, &maxx, &maxy, &maxz) == 0 {
            modelMinZ = minz
            modelMaxZ = maxz
            boundsText = String(
                format: "BB %.1f×%.1f×%.1f mm",
                maxx - minx, maxy - miny, maxz - minz
            )
        }
        #endif
    }

    /// object count + optional volume via orca_session_model_info
    func refreshModelInfo() {
        #if ORCA_LINKED
        guard let s = session, hasModel else {
            modelVolumeMm3 = 0
            return
        }
        var count: Int32 = 0
        var vol: Float = 0
        if orca_session_model_info(s, &count, &vol) == 0 {
            objectCount = Int(count)
            modelVolumeMm3 = vol
        } else {
            modelVolumeMm3 = 0
        }
        #endif
    }

    func setOption(_ key: String, value: String) {
        #if ORCA_LINKED
        guard let s = session else { return }
        let rc = key.withCString { k in
            value.withCString { v in
                orca_session_set_option(s, k, v)
            }
        }
        if rc == 0 {
            lastMessage = "set \(key)=\(value)"
        } else {
            let err = orca_session_last_error(s).map { String(cString: $0) } ?? "unknown"
            lastMessage = "Failed to set \(key)=\(value): \(err)"
        }
        #else
        lastMessage = "Not linked"
        #endif
    }

    /// Uses selectedObjectIndex when index omitted (-1 = all, or selection)
    private var transformIndex: Int32 {
        Int32(selectedObjectIndex)
    }

    /// index -1 = all objects; default uses selectedObjectIndex
    func translate(dx: Float, dy: Float, dz: Float = 0, index: Int? = nil, recordUndo: Bool = true) {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return }
        // Prefer explicit index from drag; fall back to selection. Never silently no-op on bad index.
        var idx = index ?? selectedObjectIndex
        if idx < 0 {
            // No selection: move all objects (same delta)
            idx = -1
        } else if idx >= objectCount && objectCount > 0 {
            idx = 0
        }
        if recordUndo { pushUndoSnapshot(label: "move") }
        let rc = orca_session_translate_object(s, Int32(idx), dx, dy, dz)
        if rc == 0 {
            // Keep selection on the moved object
            if idx >= 0 { selectedObjectIndex = idx }
            refreshMesh()
            refreshBounds()
            refreshModelInfo()
            lastMessage = String(format: "Moved Δ(%.1f, %.1f) mm · obj %@", dx, dy,
                                 idx < 0 ? "all" : "\(idx + 1)")
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "translate failed"
        }
        #endif
    }

    func rotateZ(degrees: Float, index: Int? = nil) {
        rotate(axis: 2, degrees: degrees, index: index)
    }

    /// axis: 0=X, 1=Y, 2=Z
    func rotate(axis: Int, degrees: Float, index: Int? = nil) {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return }
        pushUndoSnapshot(label: "rotate")
        let idx = Int32(index ?? selectedObjectIndex)
        let rc = orca_session_rotate_object_axis(s, idx, Int32(axis), degrees)
        if rc == 0 {
            refreshMesh(); refreshBounds(); refreshModelInfo()
            let ax = ["X", "Y", "Z"][max(0, min(2, axis))]
            lastMessage = String(format: "Rotated %@ %.0f°", ax, degrees)
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "rotate failed"
        }
        #endif
    }

    /// axis: 0=X, 1=Y, 2=Z
    func mirror(axis: Int, index: Int? = nil) {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return }
        pushUndoSnapshot(label: "mirror")
        let idx = Int32(index ?? selectedObjectIndex)
        let rc = orca_session_mirror_object(s, idx, Int32(axis))
        if rc == 0 {
            refreshMesh(); refreshBounds(); refreshModelInfo()
            let ax = ["X", "Y", "Z"][max(0, min(2, axis))]
            lastMessage = "Mirrored \(ax)"
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "mirror failed"
        }
        #endif
    }

    func scale(x: Float, y: Float, z: Float, index: Int? = nil) {
        #if ORCA_LINKED
        guard let s = session, hasModel, [x, y, z].allSatisfy({ $0.isFinite && $0 > 0 }) else { return }
        pushUndoSnapshot(label: "scale")
        let rc = orca_session_scale_object_axes(s, Int32(index ?? selectedObjectIndex), x, y, z)
        if rc == 0 {
            refreshMesh(); refreshBounds(); refreshModelInfo()
            lastMessage = "Scaled selection"
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "Scale failed"
        }
        #endif
    }

    @discardableResult
    func addPrimitive(kind: Int, x: Float, y: Float, z: Float) -> Bool {
        #if ORCA_LINKED
        guard let s = session else { return false }
        pushUndoSnapshot(label: "add-primitive")
        let index = orca_session_add_primitive(s, Int32(kind), x, y, z)
        guard index >= 0 else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "Invalid primitive dimensions"
            return false
        }
        hasModel = true
        selectedObjectIndex = Int(index)
        explodeFactor = 0
        refreshObjectList(); refreshMesh(); refreshBounds(); refreshModelInfo()
        lastMessage = "Added primitive"
        return true
        #else
        return false
        #endif
    }

    func scale(factor: Float, index: Int? = nil) {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return }
        pushUndoSnapshot(label: "scale")
        let idx = Int32(index ?? selectedObjectIndex)
        let rc = orca_session_scale_object(s, idx, factor)
        if rc == 0 {
            refreshMesh(); refreshBounds(); refreshModelInfo()
            lastMessage = String(format: "Scaled ×%.2f", factor)
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "scale failed"
        }
        #endif
    }

    func scaleToFit(marginMm: Float = 5, index: Int? = nil) {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return }
        pushUndoSnapshot(label: "scale-to-fit")
        let idx = Int32(index ?? selectedObjectIndex)
        let rc = orca_session_scale_to_fit(s, idx, marginMm)
        if rc == 0 {
            refreshMesh(); refreshBounds(); refreshModelInfo()
            lastMessage = "Scaled to fit bed"
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "scale_to_fit failed"
        }
        #endif
    }

    func autoOrient(index: Int? = nil) {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return }
        pushUndoSnapshot(label: "auto-orient")
        let idx = Int32(index ?? selectedObjectIndex)
        let rc = orca_session_orient_object(s, idx)
        if rc == 0 {
            refreshMesh(); refreshBounds(); refreshModelInfo()
            lastMessage = "Auto-oriented"
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "orient failed"
        }
        #endif
    }

    func centerOnBed() {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return }
        if orca_session_center_on_bed(s) == 0 {
            refreshMesh(); refreshBounds(); refreshModelInfo()
            lastMessage = "Centered on bed"
        }
        #endif
    }

    func arrange() {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return }
        if orca_session_arrange(s) == 0 {
            refreshMesh(); refreshBounds(); refreshModelInfo()
            lastMessage = "Arranged objects on plate"
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "arrange failed"
        }
        #endif
    }

    /// factor 0 = collapse, 1+ = explode (wx assembly explode lite)
    func explode(factor: Float, spacingMm: Float = 25) {
        _ = explodeObjects(factor: factor, spacingMm: spacingMm)
    }

    // MARK: Host job history (wx send queue lite)
    private static let hostHistoryKey = "orca.host.jobHistory"
    @Published var hostJobHistory: [String] = UserDefaults.standard.stringArray(forKey: OrcaEngine.hostHistoryKey) ?? []

    func recordHostJob(host: String, file: String, hostType: String = "") {
        let line = "\(ISO8601DateFormatter().string(from: Date())) · \(host) · \(file)"
        var h = hostJobHistory
        h.insert(line, at: 0)
        if h.count > 40 { h = Array(h.prefix(40)) }
        hostJobHistory = h
        UserDefaults.standard.set(h, forKey: Self.hostHistoryKey)
        // Also structured history for Device tab detail
        appendJobHistory(host: host, filename: file, hostType: hostType)
    }

    func clearHostJobHistory() {
        hostJobHistory = []
        UserDefaults.standard.removeObject(forKey: Self.hostHistoryKey)
        clearJobHistory()
    }

    // MARK: First-run wizard prefs (language / region / vendors / last printer)
    static let wizardDoneKey = "orca.wizard.done"
    static var wizardCompleted: Bool {
        get {
            UserDefaults.standard.bool(forKey: wizardDoneKey)
                || UserDefaults.standard.bool(forKey: prefsWizardDoneKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: wizardDoneKey)
            UserDefaults.standard.set(newValue, forKey: prefsWizardDoneKey)
        }
    }

    static var preferredVendors: [String] {
        get {
            UserDefaults.standard.stringArray(forKey: prefsPreferredVendorsKey)
                ?? UserDefaults.standard.stringArray(forKey: "orca.wizard.vendors")
                ?? []
        }
        set {
            UserDefaults.standard.set(newValue, forKey: prefsPreferredVendorsKey)
            UserDefaults.standard.set(newValue, forKey: "orca.wizard.vendors")
        }
    }

    static var appLanguage: String {
        get { UserDefaults.standard.string(forKey: prefsLanguageKey) ?? "en" }
        set { UserDefaults.standard.set(newValue, forKey: prefsLanguageKey) }
    }

    static var appRegion: String {
        get { UserDefaults.standard.string(forKey: prefsRegionKey) ?? "International" }
        set { UserDefaults.standard.set(newValue, forKey: prefsRegionKey) }
    }

    var maximumProjectFilaments: Int {
        #if ORCA_LINKED
        return Int(orca_max_project_filaments())
        #else
        return 64
        #endif
    }

    var maximumPaintFilaments: Int {
        #if ORCA_LINKED
        return Int(orca_max_paint_filaments())
        #else
        return 32
        #endif
    }

    var projectFilamentColors: [String] {
        let colors = (getOption("filament_colour") ?? "#009688").split(separator: ";").map(String.init)
        return colors.isEmpty ? ["#009688"] : colors
    }

    @discardableResult
    func setProjectFilamentColor(_ index: Int, hex: String) -> Bool {
        var colors = projectFilamentColors
        guard colors.indices.contains(index) else { return false }
        colors[index] = hex
        let ok = applyConfigOption(key: "filament_colour", value: colors.joined(separator: ";"))
        if ok { refreshObjectFilamentColors(); invalidateSlice() }
        return ok
    }

    @discardableResult
    func addProjectFilament() -> Bool {
        #if ORCA_LINKED
        guard let session, !sessionBusy, !sliceRunning, !presetsLoading else { return false }
        let result = orca_session_add_project_filament(session)
        lastMessage = result == 0 ? "Filament added" :
            (orca_session_last_error(session).map { String(cString: $0) } ?? "Cannot add filament")
        if result == 0 { refreshObjectFilamentColors(); invalidateSlice() }
        return result == 0
        #else
        return false
        #endif
    }

    @Published private(set) var objectFilamentColors: [UIColor] = []
    @Published private(set) var projectDisplayColors: [UIColor] = []

    private func refreshObjectFilamentColors() {
        let colors = projectFilamentColors
        projectDisplayColors = colors.map(FilamentColor.uiColor)
        filamentPaintRevision += 1
        objectFilamentColors = objectNames.indices.map { index in
            let slot = max(0, (Int(getObjectOption(index: index, key: "extruder") ?? "1") ?? 1) - 1)
            return FilamentColor.uiColor(colors[min(slot, colors.count - 1)])
        }
    }

    var physicalFilamentIndices: [Int] {
        let flags = (getOption("filament_is_mixed") ?? "").split(separator: ",").map(String.init)
        return projectFilamentColors.indices.filter { $0 >= flags.count || flags[$0] != "1" }
    }

    struct MixedGradientEdit {
        let enabled: Bool
        let range: String
        let curve: String
        let perPart: Bool
    }

    var mixedGradientBounds: ClosedRange<Double> {
        #if ORCA_LINKED
        var lower = 0.1, upper = 0.9
        orca_mixed_gradient_limits(&lower, &upper)
        return lower...upper
        #else
        return 0.1...0.9
        #endif
    }

    func addMixedFilament(components: [Int], ratios: [Int], gradient: Bool, reverse: Bool, perPart: Bool,
                          gradientEdit: MixedGradientEdit? = nil) -> Bool {
        #if ORCA_LINKED
        guard let session, !sessionBusy, !sliceRunning, !presetsLoading, components.count == ratios.count else { return false }
        let ids = components.map { Int32($0 + 1) }, weights = ratios.map(Int32.init)
        let result = ids.withUnsafeBufferPointer { ids in
            weights.withUnsafeBufferPointer { weights in
                if let gradientEdit {
                    return gradientEdit.range.withCString { range in gradientEdit.curve.withCString { curve in
                        orca_session_add_mixed_gradient(session, ids.baseAddress, weights.baseAddress, ids.count,
                            gradientEdit.enabled ? 1 : 0, range, curve, gradientEdit.perPart ? 1 : 0)
                    } }
                }
                return orca_session_add_mixed_filament(session, ids.baseAddress, weights.baseAddress, ids.count,
                    gradient ? 1 : 0, reverse ? 1 : 0, perPart ? 1 : 0)
            }
        }
        lastMessage = result == 0 ? "Mixed filament added" :
            (orca_session_last_error(session).map { String(cString: $0) } ?? "Cannot add mixed filament")
        if result == 0 { refreshObjectFilamentColors(); invalidateSlice() }
        return result == 0
        #else
        return false
        #endif
    }

    struct MixedFilamentInfo: Decodable {
        let components: [Int]
        let ratios: [Double]
        let gradient: Bool
        let range: String
        let curve: String
        let perPart: Bool
    }

    func mixedFilamentInfo(_ slot: Int) -> MixedFilamentInfo? {
        #if ORCA_LINKED
        guard let session, !sessionBusy, !sliceRunning, !presetsLoading else { return nil }
        guard let text = orca_session_mixed_filament_json(session, Int32(slot)) else {
            lastMessage = orca_session_last_error(session).map { String(cString: $0) } ?? "Cannot read mixed filament"
            return nil
        }
        do { return try JSONDecoder().decode(MixedFilamentInfo.self, from: Data(String(cString: text).utf8)) }
        catch { lastMessage = error.localizedDescription; return nil }
        #else
        return nil
        #endif
    }

    func updateMixedFilament(_ slot: Int, components: [Int]? = nil, ratios: [Int], gradientMode: Int, perPart: Bool,
                             gradientEdit: MixedGradientEdit? = nil) -> Bool {
        #if ORCA_LINKED
        guard let session, !sessionBusy, !sliceRunning, !presetsLoading else { return false }
        let weights = ratios.map(Int32.init)
        let result = weights.withUnsafeBufferPointer { weights in
            if let gradientEdit {
                let ids = (components ?? []).map { Int32($0 + 1) }
                return ids.withUnsafeBufferPointer { ids in
                    gradientEdit.range.withCString { range in gradientEdit.curve.withCString { curve in
                        orca_session_edit_mixed_gradient(session, Int32(slot), components == nil ? nil : ids.baseAddress,
                            ids.count, weights.baseAddress, weights.count, gradientEdit.enabled ? 1 : 0,
                            range, curve, gradientEdit.perPart ? 1 : 0)
                    } }
                }
            }
            if let components {
                let ids = components.map { Int32($0 + 1) }
                return ids.withUnsafeBufferPointer {
                    orca_session_replace_mixed_components(session, Int32(slot), $0.baseAddress, $0.count,
                        weights.baseAddress, weights.count, Int32(gradientMode), perPart ? 1 : 0)
                }
            }
            return orca_session_update_mixed_filament(session, Int32(slot), weights.baseAddress, weights.count,
                Int32(gradientMode), perPart ? 1 : 0)
        }
        if result == 0 {
            refreshObjectFilamentColors(); invalidateSlice()
            lastMessage = "Updated mixed filament \(slot + 1)"
        } else { lastMessage = orca_session_last_error(session).map { String(cString: $0) } ?? "Cannot update mixed filament" }
        return result == 0
        #else
        return false
        #endif
    }

    var extruderCount: Int {
        #if ORCA_LINKED
        guard let s = session else { return 1 }
        return max(1, Int(orca_session_extruder_count(s)))
        #else
        return 1
        #endif
    }

    func filamentSlotName(_ slot: Int) -> String {
        #if ORCA_LINKED
        guard let s = session, let c = orca_session_filament_slot_name(s, Int32(slot)) else { return "" }
        return String(cString: c)
        #else
        return ""
        #endif
    }

    @discardableResult
    func setFilamentSlot(_ slot: Int, name: String) -> Bool {
        #if ORCA_LINKED
        guard let s = session, !sessionBusy, !sliceRunning, !presetsLoading else { return false }
        let rc = name.withCString { orca_session_set_filament_slot(s, Int32(slot), $0) }
        if rc == 0 {
            if slot == 0 { selectedFilament = name }
            invalidateSlice()
            refreshPresetLists()
            if slot == 0 { persistSelection() }
            lastMessage = "Slot \(slot + 1): \(name)"
            return true
        }
        lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "set filament slot failed"
        return false
        #else
        return false
        #endif
    }

    // MARK: Recent files
    private static let recentKey = "orca.recent.models"
    @Published var recentModelPaths: [String] = UserDefaults.standard.stringArray(forKey: OrcaEngine.recentKey) ?? []

    func rememberRecent(url: URL) {
        var list = recentModelPaths.filter { $0 != url.path }
        list.insert(url.path, at: 0)
        if list.count > 12 { list = Array(list.prefix(12)) }
        recentModelPaths = list
        UserDefaults.standard.set(list, forKey: Self.recentKey)
    }

    func duplicateObject(at index: Int) {
        #if ORCA_LINKED
        guard let s = session, hasModel, index >= 0 else { return }
        let rc = orca_session_duplicate_object(s, Int32(index))
        if rc >= 0 {
            hasModel = true
            refreshObjectList()
            selectedObjectIndex = Int(rc)
            refreshMesh(); refreshBounds(); refreshModelInfo()
            lastMessage = "Duplicated object → index \(rc)"
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "duplicate failed"
        }
        #endif
    }

    func duplicateSelected() {
        let idx = selectedObjectIndex >= 0 ? selectedObjectIndex : 0
        duplicateObject(at: idx)
    }

    func deleteObject(at index: Int) {
        #if ORCA_LINKED
        guard let s = session, hasModel, index >= 0 else { return }
        let rc = orca_session_delete_object(s, Int32(index))
        if rc == 0 {
            let n = Int(orca_session_object_count(s))
            hasModel = n > 0
            if !hasModel {
                modelName = nil
                objectNames = []
                objectCount = 0
                modelVolumeMm3 = 0
                selectedObjectIndex = -1
                refreshMesh()
                clearPaintOverlay()
                refreshBounds()
                lastMessage = "Plate empty"
            } else {
                if selectedObjectIndex >= n {
                    selectedObjectIndex = n - 1
                }
                refreshObjectList()
                refreshMesh(); refreshBounds(); refreshModelInfo()
                lastMessage = "Deleted object \(index)"
            }
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "delete failed"
        }
        #endif
    }

    func deleteSelected() {
        let idx = selectedObjectIndex >= 0 ? selectedObjectIndex : 0
        deleteObject(at: idx)
    }

    func clearPlate() {
        #if ORCA_LINKED
        guard let s = session else { return }
        _ = orca_session_clear_model(s)
        hasModel = false
        modelName = nil
        objectNames = []
        objectCount = 0
        modelVolumeMm3 = 0
        selectedObjectIndex = -1
        refreshMesh()
        clearPaintOverlay()
        refreshBounds()
        lastMessage = "Plate cleared"
        #endif
    }

    /// Common bed sizes (mm) — prefers orca_session_set_printable_area, falls back to options
    func setBedSize(width: Float, depth: Float, height: Float = 250) {
        #if ORCA_LINKED
        guard let s = session else { return }
        let rc = orca_session_set_printable_area(s, width, depth, height)
        if rc != 0 {
            // Fallback for older engine binaries without set_printable_area
            let area = String(format: "0x0,%.0fx0,%.0fx%.0f,0x%.0f", width, width, depth, depth)
            _ = setOptionRaw("printable_area", area)
            _ = setOptionRaw("printable_height", String(format: "%.0f", height))
        }
        refreshBedSize()
        lastMessage = String(
            format: "Bed %.0f×%.0f×%.0f mm",
            bedSize.x, bedSize.y, bedHeight
        )
        #endif
    }

    func getOption(_ key: String) -> String? {
        #if ORCA_LINKED
        guard let s = session else { return nil }
        var buf = [CChar](repeating: 0, count: 4096)
        let rc = key.withCString { k in
            orca_session_get_option(s, k, &buf, buf.count)
        }
        guard rc == 0 else { return nil }
        return String(cString: buf)
        #else
        return nil
        #endif
    }

    // MARK: - Full settings browser (print_config_def + session values)

    func postProcessingScripts() -> [String] {
        #if ORCA_LINKED
        guard let session else { return [] }
        return (0..<orca_session_post_process_count(session)).compactMap { index in
            orca_session_post_process_script(session, index).map { String(cString: $0) }
        }
        #else
        return []
        #endif
    }

    /// Snapshot of DynamicPrintConfig keys for the searchable browser.
    /// Enum choice lists are loaded lazily via `enumChoices(for:)` to save RAM.
    func allConfigOptions() -> [ConfigOptionEntry] {
        #if ORCA_LINKED
        guard let s = session else { return [] }
        let n = Int(orca_session_option_count(s))
        guard n > 0 else { return [] }
        var out: [ConfigOptionEntry] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            guard let ck = orca_session_option_key(s, Int32(i)) else { continue }
            let key = String(cString: ck)
            var scope: Int32 = -1
            let mode = key.withCString { orca_session_option_presentation($0, &scope) }
            guard mode >= 0, mode <= 2, scope >= 0 else { continue }
            var type: Int32 = 6
            var labelBuf = [CChar](repeating: 0, count: 256)
            var catBuf = [CChar](repeating: 0, count: 128)
            var sideBuf = [CChar](repeating: 0, count: 64)
            _ = key.withCString { k in
                orca_session_option_info(
                    s, k, &type,
                    &labelBuf, labelBuf.count,
                    &catBuf, catBuf.count,
                    &sideBuf, sideBuf.count
                )
            }
            let label = String(cString: labelBuf)
            let category = String(cString: catBuf)
            let sidetext = String(cString: sideBuf)
            let value = getOption(key) ?? ""
            // Defer enum choice materialization — hundreds of keys × N labels was costly
            out.append(ConfigOptionEntry(
                key: key,
                scope: Int(scope),
                mode: Int(mode),
                label: label.isEmpty ? key : label,
                category: category,
                sidetext: sidetext,
                type: ConfigOptionEntry.Kind(rawValue: Int(type)) ?? .other,
                value: value,
                enumChoices: []
            ))
        }
        return out
        #else
        return []
        #endif
    }

    /// Load enum serialize keys for one option (call when user expands an enum row).
    func enumChoices(for key: String) -> [ProcessEnumChoice] {
        #if ORCA_LINKED
        guard let s = session else { return [] }
        let ec = Int(key.withCString { orca_session_option_enum_count(s, $0) })
        guard ec > 0 else { return [] }
        var enums: [ProcessEnumChoice] = []
        enums.reserveCapacity(ec)
        for j in 0..<ec {
            let vk = key.withCString { orca_session_option_enum_value(s, $0, Int32(j)) }
                .map { String(cString: $0) } ?? ""
            let lb = key.withCString { orca_session_option_enum_label(s, $0, Int32(j)) }
                .map { String(cString: $0) } ?? vk
            if !vk.isEmpty {
                enums.append(ProcessEnumChoice(key: vk, label: lb.isEmpty ? vk : lb))
            }
        }
        return enums
        #else
        return []
        #endif
    }

    /// Apply option; returns true on success. Updates lastMessage with engine error text.
    @discardableResult
    func applyConfigOption(key: String, value: String) -> Bool {
        #if ORCA_LINKED
        guard let s = session else {
            lastMessage = "No session"
            return false
        }
        let rc = key.withCString { k in
            value.withCString { v in
                orca_session_set_option(s, k, v)
            }
        }
        if rc == 0 {
            lastMessage = "set \(key)=\(value)"
            return true
        }
        let err = orca_session_last_error(s).map { String(cString: $0) } ?? "unknown"
        lastMessage = "Failed to set \(key)=\(value): \(err)"
        return false
        #else
        lastMessage = "Not linked"
        return false
        #endif
    }

    // MARK: - Calibration (official CalibMode via Print::set_calib_params)

    /// Set calibration sweep for next slice. mode matches CalibMode enum.
    @discardableResult
    func setCalib(mode: Int, start: Double, end: Double, step: Double) -> Bool {
        #if ORCA_LINKED
        guard let s = session else {
            lastMessage = "No session"
            return false
        }
        let rc = orca_session_set_calib(s, Int32(mode), start, end, step)
        if rc != 0 {
            let err = orca_session_last_error(s).map { String(cString: $0) } ?? "error"
            lastMessage = "set_calib rc=\(rc): \(err)"
            return false
        }
        calibMode = mode
        calibSummary = Self.calibLabel(mode: mode, start: start, end: end, step: step)
        lastMessage = "Calibration: \(calibSummary)"
        return true
        #else
        lastMessage = "Not linked"
        return false
        #endif
    }

    @discardableResult
    func clearCalib() -> Bool {
        #if ORCA_LINKED
        guard let s = session else { return false }
        _ = orca_session_clear_calib(s)
        calibMode = 0
        calibSummary = ""
        lastMessage = "Calibration cleared"
        return true
        #else
        return false
        #endif
    }

    private static func calibLabel(mode: Int, start: Double, end: Double, step: Double) -> String {
        let name: String
        switch mode {
        case 1: name = "PA Line"
        case 2: name = "PA Pattern"
        case 3: name = "PA Tower"
        case 5: name = "Flow Rate"
        case 6: name = "Temp Tower"
        case 9: name = "Retraction"
        default: name = "Mode \(mode)"
        }
        if mode == 5 { return name }
        return String(format: "%@ %.3g→%.3g step %.3g", name, start, end, step)
    }

    /// Load official bundled calib mesh under Resources/calib/…
    @discardableResult
    func loadBundledCalib(relativePath: String) -> Bool {
        // Try folder-reference layout (Resources/calib/…) then flat lookup
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("calib").appendingPathComponent(relativePath),
            Bundle.main.url(forResource: (relativePath as NSString).deletingPathExtension,
                            withExtension: (relativePath as NSString).pathExtension,
                            subdirectory: "calib/" + ((relativePath as NSString).deletingLastPathComponent)),
            Bundle.main.url(forResource: (relativePath as NSString).lastPathComponent.replacingOccurrences(of: ".\((relativePath as NSString).pathExtension)", with: ""),
                            withExtension: (relativePath as NSString).pathExtension,
                            subdirectory: "calib"),
        ]
        for case let url? in candidates {
            if FileManager.default.fileExists(atPath: url.path) {
                let msg = loadModel(url: url, append: false)
                lastMessage = "Calib model: \(url.lastPathComponent) · \(msg)"
                return hasModel
            }
        }
        lastMessage = "Bundled calib missing: calib/\(relativePath)"
        return false
    }

    /// Temp tower: load model + set Calib_Temp_Tower (temps change each 5 °C block).
    @discardableResult
    func prepareTempTower(startC: Double = 230, endC: Double = 190) -> Bool {
        guard loadBundledCalib(relativePath: "temperature_tower/temperature_tower.drc") else {
            return false
        }
        // Brim helps adhesion on tall towers
        setOption("brim_type", value: "outer_only")
        setOption("brim_width", value: "5")
        setOption("enable_support", value: "0")
        let start = max(endC + 5, min(500, startC))
        let end = min(start - 5, max(155, endC))
        setOption("nozzle_temperature", value: String(Int(start)))
        setOption("nozzle_temperature_initial_layer", value: String(Int(start)))
        return setCalib(mode: 6, start: start, end: end, step: 5)
    }

    /// Flow rate pass 1 or 2 (official multi-object 3MF with per-object flow modifiers).
    @discardableResult
    func prepareFlowRate(pass: Int = 1, linear: Bool = true) -> Bool {
        let path: String
        if linear {
            path = pass == 2
                ? "filament_flow/Orca-LinearFlow_fine.3mf"
                : "filament_flow/Orca-LinearFlow.3mf"
        } else {
            path = pass == 2
                ? "filament_flow/flowrate-test-pass2.3mf"
                : "filament_flow/flowrate-test-pass1.3mf"
        }
        guard loadBundledCalib(relativePath: path) else { return false }
        setOption("enable_support", value: "0")
        return setCalib(mode: 5, start: 0, end: 0, step: 0)
    }

    /// Pressure advance line test (Klipper/Marlin PA).
    @discardableResult
    func preparePressureAdvance(start: Double = 0, end: Double = 0.1, step: Double = 0.002) -> Bool {
        guard loadBundledCalib(relativePath: "pressure_advance/pressure_advance_test.drc") else {
            return false
        }
        setOption("enable_support", value: "0")
        return setCalib(mode: 1, start: start, end: end, step: max(0.0001, step))
    }

    /// Retraction tower (length increases with Z).
    @discardableResult
    func prepareRetraction(start: Double = 0, end: Double = 2, step: Double = 0.1) -> Bool {
        guard loadBundledCalib(relativePath: "retraction/retraction_tower.drc") else {
            return false
        }
        setOption("enable_support", value: "0")
        return setCalib(mode: 9, start: start, end: end, step: max(0.01, step))
    }

    @Published var slicePercent: Int = 0
    @Published var slicePhase: String = ""

    @MainActor
    func cancelSlice() {
        #if ORCA_LINKED
        guard sliceRunning, let s = session else { return }
        postProcessingTask?.cancel()
        orca_session_cancel_slice(s)
        slicePhase = "Cancelling…"
        #endif
    }

    private var sliceRunning = false
    private var postProcessingTask: Task<Void, Error>?

    @MainActor
    func slice() async -> String {
        #if ORCA_LINKED
        guard let s = session else { return "No session" }
        guard !sliceRunning else { return "A slice is already running" }
        guard !presetsLoading else { return "Wait for printer profiles to finish loading" }
        guard !sessionBusy else { return "Wait for the current model operation to finish" }
        sliceRunning = true
        defer { sliceRunning = false }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("plate_\(UUID().uuidString).gcode")
        // A failed attempt must never expose the previous job as its result.
        invalidateSlice()
        await MainActor.run {
            self.slicePercent = 0
            self.slicePhase = "Starting"
        }
        // Progress bridge: C callback → main-thread published fields
        final class ProgressBox: @unchecked Sendable {
            weak var engine: OrcaEngine?
            init(_ e: OrcaEngine) { engine = e }
        }
        let box = ProgressBox(self)
        let boxPtr = Unmanaged.passRetained(box).toOpaque()
        orca_session_set_progress_callback(s, { pct, msg, user in
            guard let user else { return }
            let b = Unmanaged<ProgressBox>.fromOpaque(user).takeUnretainedValue()
            let phase = msg.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async {
                b.engine?.slicePercent = Int(pct)
                b.engine?.slicePhase = phase
            }
        }, boxPtr)
        defer {
            orca_session_set_progress_callback(s, nil, nil)
            Unmanaged<ProgressBox>.fromOpaque(boxPtr).release()
        }
        // OpaquePointer is not Sendable; pass as bitPattern across Task.detached (Swift 6).
        let sessionBits = UInt(bitPattern: s)
        let outPath = out.path
        let rc = await Task.detached {
            let sess = OpaquePointer(bitPattern: sessionBits)!
            return outPath.withCString { orca_session_slice_to_gcode(sess, $0) }
        }.value
        if rc != 0 {
            try? FileManager.default.removeItem(at: out)
            slicePhase = rc == -7 ? "Cancelled" : "Failed"
            let err = orca_session_last_error(s).map { String(cString: $0) } ?? "slice failed"
            return "slice rc=\(rc): \(err)"
        }
        let commands = (0..<orca_session_post_process_count(s)).compactMap { index in
            orca_session_post_process_script(s, index).map { String(cString: $0) }
        }
        do {
            self.slicePhase = "Post-processing"
            let processing = Task.detached { try NativePostProcessing.run(file: out, commands: commands) }
            postProcessingTask = processing
            defer { postProcessingTask = nil }
            try await processing.value
            if processing.isCancelled { throw CancellationError() }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: out)
            self.slicePhase = "Cancelled"
            return "Cancelled"
        } catch {
            try? FileManager.default.removeItem(at: out)
            self.slicePhase = "Post-processing failed"
            return error.localizedDescription
        }
        let defaultWidth: Float = {
            if let width = getOptionFirst("line_width").flatMap(Float.init), width > 0.05 { return width }
            return (getOptionFirst("nozzle_diameter").flatMap(Float.init) ?? 0.4) * 1.1
        }()
        let densities = (getOption("filament_density") ?? "1.24").split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
        slicePhase = "Preparing preview"
        let preview = await Task.detached(priority: .userInitiated) {
            Self.processedPreview(sessionBits: sessionBits, defaultWidth: defaultWidth, densities: densities)
        }.value
        publishPreview(preview, url: out)

        let stats = await MainActor.run { self.lastSliceStatsText }
        if stats.isEmpty {
            return "G-code written: \(out.lastPathComponent) (Print::export_gcode)"
        }
        return "Sliced \(out.lastPathComponent) · \(stats)"
        #else
        return "Link orca_ios_api + libslic3r to slice"
        #endif
    }

    private typealias ProcessedPreview = (geometry: GCodePathGeometry, layers: [Float], reduced: Bool, bed: SIMD2<Float>?)
    private struct PreviewMetadata: Decodable {
        let bed_width: Float?
        let bed_depth: Float?
        let filament_densities: [Float]
    }

    @MainActor
    func loadGCode(url: URL) async -> Bool {
        guard !sessionBusy, !presetsLoading, !sliceRunning else { return false }
        sessionBusy = true
        sessionBusyMessage = "Reading G-code…"
        defer { sessionBusy = false }
        #if ORCA_LINKED
        guard let session else { lastMessage = "No session"; return false }
        let bits = UInt(bitPattern: session)
        let result = await Task.detached(priority: .userInitiated) {
            let session = OpaquePointer(bitPattern: bits)!
            let rc = url.path.withCString { orca_session_load_gcode(session, $0) }
            let preview = rc == 0 ? Self.processedPreview(sessionBits: bits, defaultWidth: 0.45, densities: []) : nil
            return (rc, preview)
        }.value
        guard result.0 == 0, let preview = result.1 else {
            lastMessage = orca_session_last_error(session).map { String(cString: $0) } ?? "G-code preview could not be loaded"
            return false
        }
        previewFromFile = true
        previewShowShell = false
        previewBedSize = preview.bed
        publishPreview(preview, url: url)
        lastMessage = "Opened G-code \(url.lastPathComponent)"
        return true
        #else
        lastMessage = "Engine not linked"
        return false
        #endif
    }

    #if ORCA_LINKED
    @MainActor
    private func publishPreview(_ preview: ProcessedPreview?, url: URL) {
        guard let sess = session else { return }
        gcodeURL = url
        slicePercent = 100
        slicePhase = "Done"
        var t: Float = 0, fil: Float = 0
        var layers: Int32 = 0
        if orca_session_last_slice_stats(sess, &t, &fil, &layers) == 0 {
            self.lastSliceTimeSec = t
            self.lastSliceFilamentMm3 = fil
            self.lastSliceLayers = Int(layers)
            let mins = Int(t) / 60
            let secs = Int(t) % 60
            let grams = fil * 0.00124 // approx PLA density g/mm³
            self.lastSliceStatsText = String(
                format: "~%dm %02ds · %.1f g filament · %d layers",
                mins, secs, grams, Int(layers)
            )
        } else {
            self.lastSliceStatsText = ""
        }
        // Extended analysis (layer times + role usage)
        var initT: Float = 0, avgT: Float = 0, sup: Float = 0, wipe: Float = 0
        var t2: Float = 0, fil2: Float = 0
        var layers2: Int32 = 0
        if orca_session_last_slice_analysis(sess, &t2, &initT, &avgT, &fil2, &sup, &wipe, &layers2) == 0 {
            self.lastInitialLayerTimeSec = initT
            self.lastAvgLayerTimeSec = avgT
            self.lastSupportMm3 = sup
            self.lastWipeTowerMm3 = wipe
            if avgT > 0 {
                let am = Int(avgT) / 60
                let as_ = Int(avgT) % 60
                let im = Int(initT) / 60
                let is_ = Int(initT) % 60
                self.lastAvgLayerTimeText = String(
                    format: "avg layer ~%dm %02ds · 1st ~%dm %02ds",
                    am, as_, im, is_
                )
            } else {
                self.lastAvgLayerTimeText = ""
            }
        } else {
            self.lastAvgLayerTimeText = ""
        }
        let rc = Int(orca_session_filament_role_count(sess))
        var roles: [(name: String, meters: Float, grams: Float)] = []
        roles.reserveCapacity(rc)
        for i in 0..<rc {
            guard let c = orca_session_filament_role_name(sess, Int32(i)) else { continue }
            let name = String(cString: c)
            let m = orca_session_filament_role_meters(sess, Int32(i))
            let g = orca_session_filament_role_grams(sess, Int32(i))
            roles.append((name, m, g))
        }
        roles.sort { $0.grams > $1.grams }
        self.filamentByRole = roles
        if let preview {
            // Filters belong to this job, not a previously opened project.
            self.previewHiddenFeatures = []
            self.previewHiddenTools = []
            self.previewHiddenFilaments = []
            self.previewEnabledMoves = [.extrude]
            self.previewThroughMove = .max
            self.previewToolheadPosition = nil
            self.previewIsReduced = preview.reduced
            self.previewLayerHeights = preview.layers
            self.gcodeGeometry = preview.geometry
            self.gcodeZMin = preview.geometry.zMin
            self.gcodeZMax = max(preview.geometry.zMax, preview.geometry.zMin)
            self.previewMinZ = self.gcodeZMin
            self.previewMaxZ = self.gcodeZMax
            self.applyPreviewLayer()
            if ProcessInfo.processInfo.arguments.contains("--test-preview-memory-warning") {
                handleMemoryWarning()
                handleMemoryWarning() // Repeated warnings must not restart the build.
            }
        } else {
            self.slicePhase = "G-code exported; preview unavailable"
        }
    }

    private static func processedPreview(sessionBits: UInt, defaultWidth: Float, densities: [Float]) ->
        ProcessedPreview? {
        guard let session = OpaquePointer(bitPattern: sessionBits) else { return nil }
        let metadata = orca_session_preview_metadata_json(session).flatMap { text -> PreviewMetadata? in
            let data = Data(String(cString: text).utf8)
            return try? JSONDecoder().decode(PreviewMetadata.self, from: data)
        }
        let fileDensities = metadata?.filament_densities ?? []
        let filamentDensities = fileDensities.isEmpty ? densities : fileDensities
        var segments: UnsafeMutablePointer<orca_preview_segment_t>?
        var count = 0
        var totalCount = 0
        if orca_session_export_preview(session, &segments, &count, &totalCount) == 0,
           let segments {
            defer { orca_free(segments) }
            let defW = defaultWidth
            let records = UnsafeBufferPointer(start: segments, count: count)
            var paths: [GCodePathGeometry.Segment] = []
            var roleLabels: [Int32: String] = [:]
            var layerZ: [UInt32: Float] = [:]
            var minZ = Float.greatestFiniteMagnitude, maxZ = -Float.greatestFiniteMagnitude
            var minFeed = Float.greatestFiniteMagnitude, maxFeed: Float = 0
            var minWidth = Float.greatestFiniteMagnitude, maxWidth: Float = 0
            var minHeight = Float.greatestFiniteMagnitude, maxHeight: Float = 0
            for (ordinal, move) in records.enumerated() {
                let start = SCNVector3(move.start_x, move.start_y, move.start_z)
                let end = SCNVector3(move.end_x, move.end_y, move.end_z)
                let kind = GCodePathGeometry.MoveKind(rawValue: Int(move.move_type)) ?? .travel
                if kind == .extrude && roleLabels[move.role] == nil {
                    roleLabels[move.role] = String(cString: orca_preview_role_name(move.role))
                }
                let feature = kind == .extrude ? (roleLabels[move.role] ?? "Undefined") : kind.label
                if move.feedrate > 0 { minFeed = min(minFeed, move.feedrate); maxFeed = max(maxFeed, move.feedrate) }
                if kind == .extrude {
                    if move.width > 0 { minWidth = min(minWidth, move.width); maxWidth = max(maxWidth, move.width) }
                    if move.height > 0 { minHeight = min(minHeight, move.height); maxHeight = max(maxHeight, move.height) }
                    // Desktop Layers excludes startup/custom extrusion from layer
                    // stops: a purge at Z=10 must not replace the first layer's Z.
                    if feature != "Custom" {
                        minZ = min(minZ, move.end_z); maxZ = max(maxZ, move.end_z)
                        layerZ[move.layer_id] = max(layerZ[move.layer_id] ?? move.end_z, move.end_z)
                    }
                }
                let tool = Int(move.extruder_id)
                let density = filamentDensities.indices.contains(tool) ? filamentDensities[tool] : (filamentDensities.first ?? 1.24)
                let massPerMM = move.feedrate > 0 ? move.volumetric_flow / (move.feedrate / 60) * density : 0
                let metrics = GCodePathGeometry.Metrics(massPerMM: massPerMM, actualSpeed: move.actual_speed,
                    flow: move.volumetric_flow, actualFlow: move.actual_volumetric_flow,
                    fan: move.fan_speed, temperature: move.temperature, pressureAdvance: move.pressure_advance,
                    acceleration: move.acceleration, jerk: move.jerk, layerTime: move.layer_duration,
                    tool: Int(move.extruder_id), colorID: Int(move.color_id), rgba: move.color_rgba)
                if !kind.isMarker, !paths.isEmpty {
                    let index = paths.count - 1
                    if let previousEnd = paths[index].points.last,
                       paths[index].feature == feature, paths[index].width == move.width, paths[index].height == move.height,
                       paths[index].feedrate == move.feedrate, paths[index].kind == kind,
                       paths[index].metrics == metrics,
                       previousEnd.x == start.x, previousEnd.y == start.y, previousEnd.z == start.z {
                        paths[index].points.append(end)
                        paths[index].lastMove = ordinal
                        continue
                    }
                }
                paths.append(GCodePathGeometry.Segment(points: [start, end],
                    feature: feature, width: move.width, feedrate: move.feedrate, height: move.height,
                    kind: kind, metrics: metrics, firstMove: ordinal, lastMove: ordinal))
            }
            // Accumulate ranges in the conversion pass instead of copying large
            // arrays of bridge records with filter/map for each numeric field.
            var path = GCodePathGeometry(segments: paths,
                zMin: minZ.isFinite && minZ <= maxZ ? minZ : 0, zMax: maxZ >= minZ ? maxZ : 0.2,
                feedMin: minFeed <= maxFeed ? minFeed : 0, feedMax: maxFeed,
                widthRange: (minWidth <= maxWidth ? minWidth : defW)...(maxWidth > 0 ? maxWidth : defW),
                layerHeightRange: (minHeight <= maxHeight ? minHeight : 0.2)...(maxHeight > 0 ? maxHeight : 0.2),
                defaultWidth: defW)
            path.prepareColorRanges()
            var bed: SIMD2<Float>?
            if let width = metadata?.bed_width, let depth = metadata?.bed_depth, width > 0, depth > 0 {
                bed = SIMD2(width, depth)
            }
            return (path, Array(Set(layerZ.values)).sorted(), totalCount > count, bed)
        }
        return nil
    }
    #endif

    /// Save plate + config as 3MF via official store_3mf.
    func saveProject3MF() -> URL? {
        #if ORCA_LINKED
        guard let s = session, hasModel else {
            lastMessage = "Nothing to save"
            return nil
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("orcaslicer_project.3mf")
        let rc = out.path.withCString { orca_session_save_3mf(s, $0) }
        if rc != 0 {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "save_3mf failed"
            return nil
        }
        lastMessage = "Saved \(out.lastPathComponent)"
        return out
        #else
        lastMessage = "Not linked"
        return nil
        #endif
    }

    // MARK: Multi-plate slots

    private var platesDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = docs.appendingPathComponent("OrcaSlicer/plates", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func ensurePlateSlots() {
        while platePaths.count < plateCount {
            let i = platePaths.count
            platePaths.append(platesDir.appendingPathComponent("plate_\(i).3mf"))
        }
        if platePaths.count > plateCount {
            platePaths = Array(platePaths.prefix(plateCount))
        }
    }

    /// Persist current plate to its slot file (no-op if empty).
    @discardableResult
    func saveCurrentPlateSlot() -> Bool {
        #if ORCA_LINKED
        ensurePlateSlots()
        guard currentPlateIndex >= 0, currentPlateIndex < platePaths.count else { return false }
        let dest = platePaths[currentPlateIndex]
        if !hasModel {
            // Empty plate: remove prior snapshot if any
            try? FileManager.default.removeItem(at: dest)
            return true
        }
        guard let s = session else { return false }
        let rc = dest.path.withCString { orca_session_save_3mf(s, $0) }
        return rc == 0
        #else
        return false
        #endif
    }

    /// Switch to plate index (saves current first). Loads slot 3MF or clears if empty.
    func selectPlate(_ index: Int) {
        #if ORCA_LINKED
        guard index >= 0, index < plateCount else { return }
        if index == currentPlateIndex { return }
        _ = saveCurrentPlateSlot()
        currentPlateIndex = index
        ensurePlateSlots()
        let path = platePaths[index]
        if FileManager.default.fileExists(atPath: path.path) {
            _ = loadModel(url: path, append: false)
            lastMessage = "Plate \(index + 1) loaded"
        } else {
            clearPlate()
            lastMessage = "Plate \(index + 1) empty"
        }
        #endif
    }

    /// Add a new empty plate and switch to it.
    func addPlate() {
        #if ORCA_LINKED
        _ = saveCurrentPlateSlot()
        plateCount += 1
        ensurePlateSlots()
        currentPlateIndex = plateCount - 1
        clearPlate()
        lastMessage = "Added plate \(plateCount)"
        #endif
    }

    /// Remove current plate if more than one remain.
    func removeCurrentPlate() {
        #if ORCA_LINKED
        guard plateCount > 1 else {
            lastMessage = "Need at least one plate"
            return
        }
        ensurePlateSlots()
        let removeIdx = currentPlateIndex
        try? FileManager.default.removeItem(at: platePaths[removeIdx])
        platePaths.remove(at: removeIdx)
        plateCount -= 1
        if currentPlateIndex >= plateCount {
            currentPlateIndex = plateCount - 1
        }
        ensurePlateSlots()
        let path = platePaths[currentPlateIndex]
        if FileManager.default.fileExists(atPath: path.path) {
            _ = loadModel(url: path, append: false)
        } else {
            clearPlate()
        }
        lastMessage = "Removed plate · now \(plateCount) plate(s)"
        #endif
    }

    // MARK: - wx-parity: undo stack (3MF snapshots) + per-object settings

    private struct UndoEntry {
        let url: URL
        let label: String
    }
    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []
    private let maxUndo = 40
    @Published var canUndo = false
    @Published var canRedo = false
    /// How many undo steps are available (for UI)
    @Published var undoDepth: Int = 0
    @Published var redoDepth: Int = 0

    private func undoDir() -> URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OrcaUndo", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func refreshUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        undoDepth = undoStack.count
        redoDepth = redoStack.count
    }

    private func writeSnapshotFile(session s: OpaquePointer, prefix: String) -> URL? {
        let url = undoDir().appendingPathComponent("\(prefix)_\(UUID().uuidString).3mf")
        let rc = url.path.withCString { orca_session_snapshot(s, $0) }
        guard rc == 0 else { return nil }
        // Verify non-empty file — empty 3MF means store failed silently
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber, size.intValue > 64
        else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    private func applySnapshotFile(_ url: URL) -> Bool {
        #if ORCA_LINKED
        guard let s = session else { return false }
        let rc = url.path.withCString { orca_session_restore_snapshot(s, $0) }
        guard rc == 0 else { return false }
        let n = Int(orca_session_object_count(s))
        hasModel = n > 0
        if hasModel {
            refreshObjectList()
            refreshMesh()
            refreshBounds()
            refreshModelInfo()
            refreshBedSize()
            // Keep selection if still valid
            if selectedObjectIndex >= n {
                selectedObjectIndex = n > 0 ? 0 : -1
            }
        } else {
            clearPlate()
        }
        return true
        #else
        return false
        #endif
    }

    /// Call before destructive/transform operations (desktop Edit → Undo stack).
    func pushUndoSnapshot(label: String = "edit") {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return }
        guard let url = writeSnapshotFile(session: s, prefix: "undo") else {
            // Don't wipe existing stack if this push fails
            return
        }
        recordUndoSnapshot(url, label: label)
        // Don't stomp lastMessage (caller sets "Moved…" etc.)
        #endif
    }

    private func recordUndoSnapshot(_ url: URL, label: String) {
        undoStack.append(UndoEntry(url: url, label: label))
        while undoStack.count > maxUndo {
            let old = undoStack.removeFirst()
            try? FileManager.default.removeItem(at: old.url)
        }
        // New edit branch invalidates redo
        for e in redoStack { try? FileManager.default.removeItem(at: e.url) }
        redoStack.removeAll()
        refreshUndoFlags()
    }

    func undo() {
        #if ORCA_LINKED
        guard let s = session, let entry = undoStack.popLast() else {
            lastMessage = "Nothing to undo"
            refreshUndoFlags()
            return
        }
        // Save current as redo (post-action state)
        if hasModel, let redoURL = writeSnapshotFile(session: s, prefix: "redo") {
            redoStack.append(UndoEntry(url: redoURL, label: entry.label))
        }
        if applySnapshotFile(entry.url) {
            lastMessage = "Undo · \(entry.label) · \(undoStack.count) left"
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "undo failed"
            // Put entry back if restore failed
            undoStack.append(entry)
        }
        // Drop used undo file only after successful restore
        if lastMessage.hasPrefix("Undo") {
            try? FileManager.default.removeItem(at: entry.url)
        }
        refreshUndoFlags()
        #endif
    }

    func redo() {
        #if ORCA_LINKED
        guard let s = session, let entry = redoStack.popLast() else {
            lastMessage = "Nothing to redo"
            refreshUndoFlags()
            return
        }
        if hasModel, let undoURL = writeSnapshotFile(session: s, prefix: "undo") {
            undoStack.append(UndoEntry(url: undoURL, label: entry.label))
        }
        if applySnapshotFile(entry.url) {
            lastMessage = "Redo · \(entry.label)"
            try? FileManager.default.removeItem(at: entry.url)
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "redo failed"
            redoStack.append(entry)
        }
        refreshUndoFlags()
        #endif
    }

    @discardableResult
    func setObjectOption(index: Int, key: String, value: String) -> Bool {
        #if ORCA_LINKED
        guard let s = session, index >= 0 else { return false }
        pushUndoSnapshot(label: key)
        let rc = key.withCString { k in
            value.withCString { v in
                orca_session_set_object_option(s, Int32(index), k, v)
            }
        }
        if rc == 0 {
            lastMessage = "Object \(index + 1): \(key)=\(value)"
            return true
        }
        lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "object option failed"
        return false
        #else
        return false
        #endif
    }

    func getObjectOption(index: Int, key: String) -> String? {
        #if ORCA_LINKED
        guard let s = session, index >= 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 512)
        let rc = key.withCString { k in
            orca_session_get_object_option(s, Int32(index), k, &buf, buf.count)
        }
        guard rc == 0 else { return nil }
        return String(cString: buf)
        #else
        return nil
        #endif
    }

    func eraseObjectOption(index: Int, key: String) {
        #if ORCA_LINKED
        guard let s = session, index >= 0 else { return }
        _ = key.withCString { orca_session_erase_object_option(s, Int32(index), $0) }
        lastMessage = "Cleared object \(key)"
        #endif
    }

    func setObjectExtruder(index: Int, extruder1Based: Int) {
        #if ORCA_LINKED
        guard let s = session, index >= 0 else { return }
        pushUndoSnapshot(label: "extruder")
        let rc = orca_session_set_object_extruder(s, Int32(index), Int32(extruder1Based))
        if rc == 0 { refreshObjectFilamentColors(); invalidateSlice() }
        lastMessage = rc == 0
            ? "Object \(index + 1) → extruder \(extruder1Based)"
            : (orca_session_last_error(s).map { String(cString: $0) } ?? "extruder failed")
        #endif
    }

    // MARK: - wx-parity W1: facet painting (support / seam / MMU / fuzzy)

    /// paint_kind mirrors C API: 0 support, 1 seam, 2 mmu, 3 fuzzy
    enum PaintKind: Int, CaseIterable {
        case support = 0
        case seam = 1
        case mmu = 2
        case fuzzy = 3

        var label: String {
            switch self {
            case .support: return "Support"
            case .seam: return "Seam"
            case .mmu: return "MMU"
            case .fuzzy: return "Fuzzy"
            }
        }
    }

    /// Brush at world hit (slic3r mm). state: 0 erase, 1 enforce/extruder1/fuzzy, 2 block (support/seam).
    @discardableResult
    func paintAt(
        x: Float, y: Float, z: Float,
        kind: PaintKind,
        state: Int,
        radiusMm: Float,
        recordUndo: Bool = false
    ) -> Int {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return -1 }
        if recordUndo { pushUndoSnapshot(label: "paint-\(kind.label)") }
        let objIdx = selectedObjectIndex >= 0 ? Int32(selectedObjectIndex) : Int32(-1)
        let n = orca_session_paint_at(
            s, objIdx, x, y, z, Int32(kind.rawValue), Int32(state), radiusMm
        )
        lastPaintCount = max(0, Int(n))
        if n >= 0 {
            invalidateSlice()
            refreshPaintOverlay(kind: kind)
            refreshPaintStats(kind: kind)
            lastMessage = n > 0
                ? "Painted \(n) facet(s) · \(kind.label)"
                : "No facet near brush · \(kind.label)"
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "paint failed"
        }
        return Int(n)
        #else
        return -1
        #endif
    }

    @discardableResult
    func paintFill(kind: PaintKind, state: Int) -> Int {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return -1 }
        let idx = selectedObjectIndex >= 0 ? selectedObjectIndex : 0
        pushUndoSnapshot(label: "paint-fill-\(kind.label)")
        let n = orca_session_paint_fill(s, Int32(idx), Int32(kind.rawValue), Int32(state))
        lastPaintCount = max(0, Int(n))
        if n >= 0 {
            invalidateSlice()
            refreshPaintOverlay(kind: kind)
            refreshPaintStats(kind: kind)
            lastMessage = "Fill \(kind.label) · \(n) facets"
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "paint fill failed"
        }
        return Int(n)
        #else
        return -1
        #endif
    }

    @discardableResult
    func paintClear(kind: PaintKind, allObjects: Bool = false) -> Bool {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return false }
        pushUndoSnapshot(label: "paint-clear-\(kind.label)")
        let idx: Int32 = allObjects
            ? -1
            : Int32(selectedObjectIndex >= 0 ? selectedObjectIndex : 0)
        let rc = orca_session_paint_clear(s, idx, Int32(kind.rawValue))
        if rc == 0 {
            invalidateSlice()
            if kind == .mmu && allObjects {
                refreshFilamentPaint()
                paintOverlayMesh = nil
            } else { refreshPaintOverlay(kind: kind) }
            refreshPaintStats(kind: kind)
            lastMessage = "Cleared \(kind.label) paint"
            return true
        }
        lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "paint clear failed"
        return false
        #else
        return false
        #endif
    }

    func refreshPaintStats(kind: PaintKind) {
        #if ORCA_LINKED
        guard let s = session, hasModel else {
            paintStatsText = ""
            return
        }
        let idx = selectedObjectIndex >= 0 ? Int32(selectedObjectIndex) : Int32(-1)
        var count: Int32 = 0
        let rc = orca_session_paint_stats(s, idx, Int32(kind.rawValue), -1, &count)
        if rc == 0 {
            paintStatsText = "\(kind.label) · \(count) painted facet(s)"
        } else {
            paintStatsText = ""
        }
        #endif
    }

    /// Load world-space painted facets for SceneKit overlay (any non-NONE state).
    func refreshPaintOverlay(kind: PaintKind?) {
        if kind == .mmu {
            // MMU paint is persistent material coloring, not a single brush mask.
            refreshFilamentPaint(objectIndex: selectedObjectIndex >= 0 ? selectedObjectIndex : nil)
            paintOverlayMesh = nil
            return
        }
        guard let kind else { paintOverlayMesh = nil; return }
        paintOverlayMesh = exportedPaintMesh(objectIndex: selectedObjectIndex, kind: kind, state: -1)
    }

    private func refreshFilamentPaint(objectIndex: Int? = nil) {
        var regions = objectIndex.map { index in paintedFilaments.filter { $0.objectIndex != index } } ?? []
        if hasModel {
            let objects = objectIndex.map { [$0] } ?? Array(objectMeshes.indices)
            for index in objects {
                for state in 1...maximumPaintFilaments {
                    if let mesh = exportedPaintMesh(objectIndex: index, kind: .mmu, state: state) {
                        regions.append(PaintedFilamentRegion(objectIndex: index, filamentIndex: state - 1, mesh: mesh))
                    }
                }
            }
        }
        paintedFilaments = regions
        filamentPaintRevision += 1
    }

    private func exportedPaintMesh(objectIndex: Int, kind: PaintKind, state: Int) -> MeshGeometry? {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return nil }
        var posPtr: UnsafeMutablePointer<Float>?
        var idxPtr: UnsafeMutablePointer<UInt32>?
        var vcount: Int = 0
        var icount: Int = 0
        let rc = orca_session_export_paint_mesh(
            s, Int32(objectIndex), Int32(kind.rawValue), Int32(state),
            &posPtr, &vcount, &idxPtr, &icount
        )
        defer {
            if let p = posPtr { orca_free(p) }
            if let i = idxPtr { orca_free(i) }
        }
        guard rc == 0, let posPtr, let idxPtr, vcount > 0, icount > 0 else {
            return nil
        }
        let positions = Array(UnsafeBufferPointer(start: posPtr, count: vcount * 3))
        let indices = Array(UnsafeBufferPointer(start: idxPtr, count: icount))
        var bmin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var bmax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for i in 0..<vcount {
            let p = SIMD3(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2])
            bmin = min(bmin, p)
            bmax = max(bmax, p)
        }
        return MeshGeometry(positions: positions, indices: indices, min: bmin, max: bmax)
        #else
        return nil
        #endif
    }

    func clearPaintOverlay() {
        paintOverlayMesh = nil
        paintStatsText = ""
        lastPaintCount = 0
        brimEarCount = 0
    }

    // MARK: - wx-parity W1: brim ears (point markers → ModelObject::brim_points)

    /// Place a brim ear at world XY (desktop GLGizmoBrimEars). radiusMm ≤ 0 → auto.
    @discardableResult
    func brimEarAdd(x: Float, y: Float, radiusMm: Float = 0, recordUndo: Bool = true) -> Int {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return -1 }
        if recordUndo { pushUndoSnapshot(label: "brim-ear-add") }
        let idx = selectedObjectIndex >= 0 ? selectedObjectIndex : 0
        let n = orca_session_brim_ear_add(s, Int32(idx), x, y, radiusMm)
        if n >= 0 {
            brimEarCount = Int(n)
            // Ensure process uses painted ears
            setOption("brim_type", value: "painted")
            refreshBrimEarOverlay()
            lastMessage = "Brim ear #\(n) @ (\(String(format: "%.1f", x)), \(String(format: "%.1f", y)))"
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "brim ear add failed"
        }
        return Int(n)
        #else
        return -1
        #endif
    }

    /// Remove nearest brim ear within maxDistMm of world XY.
    @discardableResult
    func brimEarRemoveNearest(x: Float, y: Float, maxDistMm: Float = 8, recordUndo: Bool = true) -> Int {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return -1 }
        if recordUndo { pushUndoSnapshot(label: "brim-ear-remove") }
        let idx = selectedObjectIndex >= 0 ? selectedObjectIndex : 0
        let n = orca_session_brim_ear_remove_nearest(s, Int32(idx), x, y, maxDistMm)
        if n >= 0 {
            brimEarCount = Int(n)
            refreshBrimEarOverlay()
            lastMessage = "Brim ears remaining: \(n)"
        } else {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "brim ear remove failed"
        }
        return Int(n)
        #else
        return -1
        #endif
    }

    @discardableResult
    func brimEarClear(allObjects: Bool = false) -> Bool {
        #if ORCA_LINKED
        guard let s = session, hasModel else { return false }
        pushUndoSnapshot(label: "brim-ear-clear")
        let idx: Int32 = allObjects ? -1 : Int32(selectedObjectIndex >= 0 ? selectedObjectIndex : 0)
        let rc = orca_session_brim_ear_clear(s, idx)
        if rc == 0 {
            brimEarCount = 0
            paintOverlayMesh = nil
            lastMessage = "Cleared brim ears"
            return true
        }
        lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "brim ear clear failed"
        return false
        #else
        return false
        #endif
    }

    func refreshBrimEarCount() {
        #if ORCA_LINKED
        guard let s = session, hasModel else {
            brimEarCount = 0
            return
        }
        let idx = selectedObjectIndex >= 0 ? Int32(selectedObjectIndex) : Int32(-1)
        var count: Int32 = 0
        if orca_session_brim_ear_count(s, idx, &count) == 0 {
            brimEarCount = Int(count)
            paintStatsText = "Brim ears · \(count) marker(s)"
        }
        #endif
    }

    func refreshBrimEarOverlay() {
        #if ORCA_LINKED
        guard let s = session, hasModel else {
            paintOverlayMesh = nil
            return
        }
        let idx = selectedObjectIndex >= 0 ? Int32(selectedObjectIndex) : Int32(-1)
        var posPtr: UnsafeMutablePointer<Float>?
        var idxPtr: UnsafeMutablePointer<UInt32>?
        var vcount: Int = 0
        var icount: Int = 0
        let rc = orca_session_export_brim_ear_mesh(
            s, idx, &posPtr, &vcount, &idxPtr, &icount
        )
        defer {
            if let p = posPtr { orca_free(p) }
            if let i = idxPtr { orca_free(i) }
        }
        refreshBrimEarCount()
        guard rc == 0, let posPtr, let idxPtr, vcount > 0, icount > 0 else {
            paintOverlayMesh = nil
            return
        }
        var positions = [Float](repeating: 0, count: vcount * 3)
        var indices = [UInt32](repeating: 0, count: icount)
        for i in 0..<(vcount * 3) { positions[i] = posPtr[i] }
        for i in 0..<icount { indices[i] = idxPtr[i] }
        var bmin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var bmax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for i in 0..<vcount {
            let p = SIMD3(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2])
            bmin = min(bmin, p)
            bmax = max(bmax, p)
        }
        paintOverlayMesh = MeshGeometry(positions: positions, indices: indices, min: bmin, max: bmax)
        #else
        paintOverlayMesh = nil
        #endif
    }

    enum MeshEdit: Sendable {
        case repair
        case split(toObjects: Bool, part: Int, dropToBed: Bool)
        case simplify(Int)
        case cut(position: Float, axis: Int, upper: Bool, lower: Bool)
        case boolean(other: Int, operation: Int, removeOther: Bool)
    }

    /// The same session gate used by imports excludes slicing, preset imports
    /// and memory-pressure mutation while a native mesh algorithm is running.
    @MainActor
    @discardableResult
    func editMesh(_ edit: MeshEdit) async -> Bool {
        guard !sessionBusy, !sliceRunning, !presetsLoading, hasModel else { return false }
        #if ORCA_LINKED
        guard let session else { return false }
        let index = selectedObjectIndex
        if case .repair = edit { /* Repair also supports the whole plate. */ }
        else if !objectNames.indices.contains(index) {
            lastMessage = "Select one object first"; return false
        }
        switch edit {
        case .simplify(let target):
            guard target >= 0 && target <= Int(Int32.max) else { lastMessage = "Invalid triangle count"; return false }
        case .cut(let position, let axis, let upper, let lower):
            guard position.isFinite, (0...2).contains(axis), upper || lower else { lastMessage = "Choose a valid cut plane and at least one half"; return false }
        case .boolean(let other, let operation, _):
            guard objectNames.indices.contains(other), other != index, (0...2).contains(operation) else {
                lastMessage = "Choose two different objects and a valid operation"; return false
            }
        case .repair: break
        case .split(_, let part, _):
            guard part >= 0 && part <= Int(Int32.max) else { lastMessage = "Choose a valid part"; return false }
        }
        sessionBusyMessage = "Updating model…"
        sessionBusy = true
        defer { sessionBusy = false }
        let snapshot = undoDir().appendingPathComponent("mesh_\(UUID().uuidString).3mf")
        let bits = UInt(bitPattern: session)
        let result = await Task.detached(priority: .userInitiated) {
            let s = OpaquePointer(bitPattern: bits)!
            let saved = snapshot.path.withCString { orca_session_snapshot(s, $0) }
            let bytes = (try? snapshot.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard saved == 0 && bytes > 64 else {
                return (Int32(-1), "Could not prepare an undo snapshot; the model was not changed.", false)
            }
            let code: Int32
            switch edit {
            case .repair: code = orca_session_repair_mesh(s, Int32(index))
            case .split(let objects, let part, let drop):
                code = orca_session_split_model(s, Int32(index), Int32(part), objects ? 1 : 0, drop ? 1 : 0)
            case .simplify(let target): code = orca_session_simplify_mesh(s, Int32(index), Int32(target))
            case .cut(let position, let axis, let upper, let lower):
                var point = SIMD3<Float>(repeating: 0), normal = SIMD3<Float>(repeating: 0)
                point[axis] = position; normal[axis] = 1
                code = orca_session_cut_object_plane(s, Int32(index), point.x, point.y, point.z,
                    normal.x, normal.y, normal.z, upper ? 1 : 0, lower ? 1 : 0)
            case .boolean(let other, let operation, let removeOther):
                code = orca_session_mesh_boolean(s, Int32(index), Int32(other), Int32(operation), removeOther ? 1 : 0)
            }
            let error = orca_session_last_error(s).map { String(cString: $0) } ?? ""
            var restoreFailed = false
            // Split stages its own model and leaves the original untouched on
            // failure; avoid reimporting it or losing its existing preview.
            if code < 0, case .split = edit { /* No restoration needed. */ }
            else if code < 0 {
                restoreFailed = snapshot.path.withCString { orca_session_restore_snapshot(s, $0) } != 0
            }
            return (code, error.isEmpty ? "Mesh operation failed" : error, restoreFailed)
        }.value
        if result.0 >= 0 || result.2 { recordUndoSnapshot(snapshot, label: "mesh-edit") }
        else { try? FileManager.default.removeItem(at: snapshot) }
        if result.0 < 0, case .split = edit { lastMessage = result.1; return false }
        if result.0 >= 0, case .boolean(let other, _, let removeOther) = edit {
            selectedObjectIndex = index - (removeOther && other < index ? 1 : 0)
        } else if result.0 >= 0, case .cut = edit { selectedObjectIndex = -1 }
        else if result.0 >= 0, case .split(let objects, _, _) = edit, objects { selectedObjectIndex = -1 }
        refreshObjectList()
        hasModel = objectCount > 0
        refreshMesh(); refreshBounds(); refreshModelInfo()
        if result.0 < 0 {
            lastMessage = result.1 + (result.2 ? " The previous model could not be restored; its snapshot is available in Undo." : "")
            return false
        }
        _ = refreshMeshHealth()
        lastMessage = "Updated model · \(objectCount) objects"
        if case .split(let objects, _, _) = edit {
            explodeFactor = 0
            lastMessage = "Split into \(result.0) \(objects ? "objects" : "parts")"
        }
        return true
        #else
        lastMessage = "Engine not linked"; return false
        #endif
    }

    func modelPartNames(object index: Int) -> [String] {
        #if ORCA_LINKED
        guard let session, !sessionBusy, !sliceRunning, !presetsLoading else { return [] }
        let count = Int(orca_session_model_part_count(session, Int32(index)))
        return (0..<count).map { part in
            let name = orca_session_model_part_name(session, Int32(index), Int32(part)).map { String(cString: $0) } ?? ""
            return name.isEmpty ? "Part \(part + 1)" : name
        }
        #else
        return []
        #endif
    }

    // MARK: - wx-parity W2: assembly explode + text plate (box)

    /// Explode objects radially from bed center. factor 0 = collapse to saved layout.
    @discardableResult
    func explodeObjects(factor: Float, spacingMm: Float = 20) -> Bool {
        #if ORCA_LINKED
        guard let s = session, hasModel, objectCount >= 1 else {
            lastMessage = "Explode needs objects on plate"
            return false
        }
        pushUndoSnapshot(label: factor <= 0.001 ? "collapse" : "explode")
        let rc = orca_session_explode_objects(s, factor, spacingMm)
        if rc != 0 {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "explode failed"
            return false
        }
        explodeFactor = max(0, factor)
        refreshMesh()
        refreshBounds()
        refreshModelInfo()
        if factor <= 0.001 {
            lastMessage = "Collapsed assembly"
        } else {
            lastMessage = String(format: "Explode ×%.1f (spacing %.0f mm)", factor, spacingMm)
        }
        return true
        #else
        return false
        #endif
    }

    /// Emboss-lite: add a flat box volume named as a text plate (optional dimensions).
    @discardableResult
    func addTextPlate(
        name: String = "Text plate",
        sizeX: Float = 40,
        sizeY: Float = 10,
        sizeZ: Float = 2
    ) -> Bool {
        #if ORCA_LINKED
        guard let s = session else { return false }
        pushUndoSnapshot(label: "add-text-plate")
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmed.isEmpty ? "Text plate" : trimmed
        let rc = label.withCString {
            orca_session_add_box(s, $0, sizeX, sizeY, sizeZ)
        }
        if rc < 0 {
            lastMessage = orca_session_last_error(s).map { String(cString: $0) } ?? "add_box failed"
            return false
        }
        selectedObjectIndex = Int(rc)
        explodeFactor = 0
        refreshObjectList()
        refreshMesh()
        refreshBounds()
        refreshModelInfo()
        hasModel = objectCount > 0
        lastMessage = "Added text plate \"\(label)\" \(String(format: "%.0f×%.0f×%.0f", sizeX, sizeY, sizeZ)) mm"
        return true
        #else
        lastMessage = "Engine not linked"
        return false
        #endif
    }

    // MARK: - W3: preset bundle zip + job history

    /// Documents/OrcaSlicer root
    var dataDirectoryURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("OrcaSlicer", isDirectory: true)
    }

    var userPresetsDirectoryURL: URL {
        dataDirectoryURL.appendingPathComponent("user_presets", isDirectory: true)
    }

    /// Zip Documents/OrcaSlicer/user_presets into a shareable archive (store-only ZIP).
    func exportPresetBundleZip() -> URL? {
        let src = userPresetsDirectoryURL
        let fm = FileManager.default
        try? fm.createDirectory(at: src, withIntermediateDirectories: true)
        // Collect files under user_presets
        guard let enumerator = fm.enumerator(at: src, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            lastMessage = "Cannot read user_presets"
            return nil
        }
        var files: [(relative: String, url: URL)] = []
        for case let url as URL in enumerator {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                let rel = url.path.replacingOccurrences(of: src.path + "/", with: "")
                if rel != url.path {
                    files.append((rel, url))
                } else {
                    files.append((url.lastPathComponent, url))
                }
            }
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrcaSlicer_user_presets_\(stamp).zip")
        do {
            if fm.fileExists(atPath: out.path) { try fm.removeItem(at: out) }
            try OrcaZipWriter.writeStoreZip(files: files, to: out)
            lastMessage = files.isEmpty
                ? "Exported empty preset bundle (no user presets yet)"
                : "Exported preset bundle · \(files.count) file(s)"
            return out
        } catch {
            lastMessage = "Zip failed: \(error.localizedDescription)"
            return nil
        }
    }

    static func loadJobHistory() -> [JobHistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: prefsJobHistoryKey),
              let list = try? JSONDecoder().decode([JobHistoryEntry].self, from: data) else {
            return []
        }
        return list
    }

    func appendJobHistory(host: String, filename: String, hostType: String) {
        let df = ISO8601DateFormatter()
        let entry = JobHistoryEntry(
            host: host,
            filename: filename,
            date: df.string(from: Date()),
            hostType: hostType
        )
        var list = jobHistory
        list.insert(entry, at: 0)
        if list.count > 50 { list = Array(list.prefix(50)) }
        jobHistory = list
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Self.prefsJobHistoryKey)
        }
    }

    func clearJobHistory() {
        jobHistory = []
        UserDefaults.standard.removeObject(forKey: Self.prefsJobHistoryKey)
    }
}

// MARK: - Minimal store-only ZIP writer (no compression) for preset bundle export

enum OrcaZipWriter {
    static func writeStoreZip(files: [(relative: String, url: URL)], to dest: URL) throws {
        var central: [UInt8] = []
        var local: [UInt8] = []
        var offsets: [UInt32] = []

        for (rel, url) in files {
            let nameData = Array(rel.replacingOccurrences(of: "\\", with: "/").utf8)
            let fileData = try Data(contentsOf: url)
            let crc = crc32(fileData)
            let size = UInt32(fileData.count)
            let localOffset = UInt32(local.count)

            // Local file header
            local += u32(0x04034b50) // signature
            local += u16(20) // version needed
            local += u16(0) // flags
            local += u16(0) // method store
            local += u16(0) // time
            local += u16(0) // date
            local += u32(crc)
            local += u32(size)
            local += u32(size)
            local += u16(UInt16(nameData.count))
            local += u16(0) // extra
            local += nameData
            local += [UInt8](fileData)

            offsets.append(localOffset)

            // Central directory header
            central += u32(0x02014b50)
            central += u16(20) // version made by
            central += u16(20) // version needed
            central += u16(0)
            central += u16(0)
            central += u16(0)
            central += u16(0)
            central += u32(crc)
            central += u32(size)
            central += u32(size)
            central += u16(UInt16(nameData.count))
            central += u16(0)
            central += u16(0) // comment
            central += u16(0) // disk
            central += u16(0) // int attr
            central += u32(0) // ext attr
            central += u32(localOffset)
            central += nameData
        }

        let centralOffset = UInt32(local.count)
        let centralSize = UInt32(central.count)
        var out = local + central
        // End of central directory
        out += u32(0x06054b50)
        out += u16(0)
        out += u16(0)
        out += u16(UInt16(files.count))
        out += u16(UInt16(files.count))
        out += u32(centralSize)
        out += u32(centralOffset)
        out += u16(0)
        try Data(out).write(to: dest)
    }

    private static func u16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]
    }
    private static func u32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }

    /// CRC-32 (ISO 3309 / PNG / ZIP)
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xff)
            crc = (crc >> 8) ^ crcTable[idx]
        }
        return crc ^ 0xffff_ffff
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xedb88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()
}
