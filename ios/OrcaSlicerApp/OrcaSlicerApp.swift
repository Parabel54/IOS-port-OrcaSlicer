// OrcaSlicer iOS shell — prepare + preview with SceneKit orbit and real mesh.
// Engine: official libslic3r via orca_ios_api (AGPL-3.0).

import SwiftUI
import UniformTypeIdentifiers
import SceneKit
import Network
#if canImport(UIKit)
import UIKit
#endif

@main
struct OrcaSlicerApp: App {
    init() {
        if ProcessInfo.processInfo.arguments.contains("--test-document-import") {
            OrcaEngine.wizardCompleted = true
        }
        if ProcessInfo.processInfo.arguments.contains("--test-view-metadata") {
            let completion = DispatchSemaphore(value: 0)
            let result = FileManager.default.temporaryDirectory.appendingPathComponent("orca-view-metadata-smoke.txt")
            try? FileManager.default.removeItem(at: result)
            let worker = Thread {
                _ = String(reflecting: OrcaRootView.Body.self)
                do { try "PASS: root view metadata resolves on a 1 MB stack".write(to: result, atomically: true, encoding: .utf8) }
                catch { NSLog("Could not write view metadata test result: %@", error.localizedDescription) }
                completion.signal()
            }
            worker.name = "OrcaViewMetadataSmoke"
            worker.stackSize = 1_048_576
            worker.start()
            precondition(completion.wait(timeout: .now() + 15) == .success && FileManager.default.fileExists(atPath: result.path),
                         "Root view metadata test failed")
        }
    }

    var body: some Scene {
        WindowGroup {
            StartupRecoveryView()
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Theme from StateColor.cpp dark map

private enum OrcaTheme {
    static let bg = Color(red: 0x2D / 255.0, green: 0x2D / 255.0, blue: 0x31 / 255.0)
    static let panel = Color(red: 0x36 / 255.0, green: 0x36 / 255.0, blue: 0x3C / 255.0)
    static let elevated = Color(red: 0x3E / 255.0, green: 0x3E / 255.0, blue: 0x45 / 255.0)
    static let field = Color(red: 0x2D / 255.0, green: 0x2D / 255.0, blue: 0x31 / 255.0)
    static let accent = Color(red: 0x00 / 255.0, green: 0x96 / 255.0, blue: 0x88 / 255.0)
    static let accentHover = Color(red: 0x26 / 255.0, green: 0xA6 / 255.0, blue: 0x9A / 255.0)
    static let accentDim = Color(red: 0x00 / 255.0, green: 0x67 / 255.0, blue: 0x5B / 255.0)
    static let muted = Color(red: 0xB3 / 255.0, green: 0xB3 / 255.0, blue: 0xB5 / 255.0)
    static let border = Color(red: 0x4A / 255.0, green: 0x4A / 255.0, blue: 0x51 / 255.0)
    static let success = Color(red: 0x00 / 255.0, green: 0x96 / 255.0, blue: 0x88 / 255.0)
    static let danger = Color(red: 0xBB / 255.0, green: 0x2A / 255.0, blue: 0x3A / 255.0)
    static let text = Color(red: 0xEF / 255.0, green: 0xEF / 255.0, blue: 0xF0 / 255.0)
}

// MARK: - Root

struct OrcaRootView: View {
    @StateObject private var engine: OrcaEngine
    @Environment(\.scenePhase) private var scenePhase

    @ObservedObject private var documents: DocumentInbox

    init(loadSystemProfiles: Bool = true, documents: DocumentInbox? = nil) {
        _documents = ObservedObject(wrappedValue: documents ?? DocumentInbox())
        _engine = StateObject(wrappedValue: OrcaEngine(loadSystemProfiles: loadSystemProfiles))
    }
    @StateObject private var connections = PrinterConnections()
    @StateObject private var cloudAccount = OrcaCloudAccount()
    @State private var documentPicker: DocumentImportRequest?
    @State private var pendingDocumentPicker: DocumentImportRequest?
    @State private var didTestImport = false
    @State private var processingDocument = false
    @State private var cloudPresetRevision: UUID?
    @State private var settingsDetent: PresentationDetent = .large
    @State private var operationError: String?
    @State private var showProcess = false
    @State private var showPlateInspector = false
    @State private var showMeshTools = false
    @State private var showModelLibrary = false
    @State private var primitiveKind = 0
    @State private var primitiveX = "20"
    @State private var primitiveY = "20"
    @State private var primitiveZ = "20"
    @State private var scaleX = "100"
    @State private var scaleY = "100"
    @State private var scaleZ = "100"
    @State private var uniformScale = true
    @State private var moveX = "0"
    @State private var moveY = "0"
    @State private var moveZ = "0"
    @State private var rotateAmount = "45"
    @State private var showPreviewControls = false
    @State private var sidebarVisible = true
    @State private var showCalibration = false
    @State private var exportShareURL: URL?
    @State private var projectURL: URL?
    @State private var layerHeight = "0.20"
    @State private var infill = "15"
    @State private var walls = "2"
    @State private var status = ""
    @State private var isSlicing = false
    @State private var mainTab: MainTab = .prepare
    /// Prepare: pan on plate moves selection (disables camera orbit while on)
    @State private var moveMode = false

    enum MainTab: String, CaseIterable {
        case prepare = "Prepare"
        case preview = "Preview"
        case device = "Device"
    }

    /// Desktop-style gizmo / tool modes (wx GLGizmos subset)
    enum GizmoMode: String, CaseIterable {
        case select = "Select"
        case move = "Move"
        case rotate = "Rotate"
        case scale = "Scale"
        case layOnFace = "Lay on face"
        case measure = "Measure"
        case paintSupport = "Support paint"
        case paintSeam = "Seam paint"
        case paintMMU = "MMU paint"
        case paintFuzzy = "Fuzzy paint"
        case paintBrimEars = "Brim ears"
    }

    @State private var rotationAxis = 2
    @State private var plateTouchMode: PlateTouchMode = .orbit
    @State private var fitCameraRequest = UUID()
    @State private var cameraView: CameraPreset = .home
    @AppStorage("orca.usePerspectiveCamera") private var usePerspectiveCamera = true
    @AppStorage("orca.autoPerspective") private var autoPerspective = false
    @State private var cameraViewPolicy = CameraViewPolicy()
    @State private var gizmoMode: GizmoMode = .select
    @State private var showPreferences = false
    @State private var showAbout = false
    @State private var showShortcuts = false
    @State private var showLayerHeights = false
    @State private var showObjectSettings = false
    @State private var presetBundleShareURL: URL?
    @State private var textPlateName = "Text plate"
    @State private var textPlateX = "40"
    @State private var textPlateY = "10"
    @State private var textPlateZ = "2"
    @State private var explodeSpacing = "20"
    @State private var showWizard = !OrcaEngine.wizardCompleted
    @State private var wizardVendors: Set<String> = Set(OrcaEngine.preferredVendors)
    @State private var wizardLanguage: String = OrcaEngine.appLanguage
    @State private var wizardRegion: String = OrcaEngine.appRegion
    @State private var measurePointA: SIMD3<Float>?
    @State private var measurePointB: SIMD3<Float>?
    @State private var measureDistanceText = ""
    /// Paint tool: 1 = enforcer / extruder / fuzzy, 2 = blocker (support/seam), 0 = erase
    @State private var paintToolState: Int = 1
    @State private var paintBrushRadius: Float = 2.0
    @State private var paintMMUExtruder: Int = 1
    @State private var paintStrokeNeedsUndo = true
    /// Brim ear radius (mm); 0 = engine auto default
    @State private var brimEarRadius: Float = 5.0
    /// Brim ear tool: add vs remove nearest
    @State private var brimEarErase = false

    private var isPaintGizmo: Bool {
        switch gizmoMode {
        case .paintSupport, .paintSeam, .paintMMU, .paintFuzzy, .paintBrimEars: return true
        default: return false
        }
    }

    private var isFacetPaintGizmo: Bool {
        switch gizmoMode {
        case .paintSupport, .paintSeam, .paintMMU, .paintFuzzy: return true
        default: return false
        }
    }

    private var activePaintKind: OrcaEngine.PaintKind? {
        switch gizmoMode {
        case .paintSupport: return .support
        case .paintSeam: return .seam
        case .paintMMU: return .mmu
        case .paintFuzzy: return .fuzzy
        default: return nil
        }
    }

    private var paintOverlayUIColor: UIColor {
        switch gizmoMode {
        case .paintSupport: return UIColor(red: 0.15, green: 0.85, blue: 0.35, alpha: 0.88)
        case .paintSeam: return UIColor(red: 0.95, green: 0.55, blue: 0.15, alpha: 0.88)
        case .paintMMU: return UIColor(red: 0.45, green: 0.45, blue: 1.0, alpha: 0.88)
        case .paintFuzzy: return UIColor(red: 0.85, green: 0.35, blue: 0.85, alpha: 0.88)
        case .paintBrimEars: return UIColor(red: 1.0, green: 0.75, blue: 0.15, alpha: 0.92)
        default: return UIColor(red: 0.2, green: 0.85, blue: 0.35, alpha: 0.85)
        }
    }

    private var currentPaintState: Int {
        switch gizmoMode {
        case .paintMMU:
            return paintToolState == 0 ? 0 : max(1, min(engine.maximumPaintFilaments, paintMMUExtruder))
        case .paintFuzzy:
            return paintToolState == 0 ? 0 : 1
        case .paintSupport, .paintSeam:
            return paintToolState // 0 erase, 1 enforcer, 2 blocker
        default:
            return paintToolState
        }
    }

    // The root previously resolved a single enormous opaque view type and could
    // overflow the main-thread stack while SwiftUI instantiated its metadata.
    // Erase at screen and presentation boundaries, preserving the existing state.
    private var rootLayout: AnyView {
        AnyView(GeometryReader { geo in
            ZStack {
                OrcaTheme.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    headerBar(inlineInspector: geo.size.width >= 860 && geo.size.height >= 500)
                        .fixedSize(horizontal: false, vertical: true).layoutPriority(2)
                    if !engine.automaticProfileLoading {
                        Text("Recovery mode: system profiles are not loaded. Reopen the app to retry startup.")
                            .font(.caption)
                            .padding(8)
                    }
                    tabBar.fixedSize(horizontal: false, vertical: true).layoutPriority(2)
                    if mainTab == .device {
                        NavigationStack { devicePlaceholder }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        HStack(spacing: 0) {
                            // Available bounds also cover iPad split view and Stage Manager.
                            if geo.size.width >= 860 && geo.size.height >= 500 && sidebarVisible {
                                processSheet.frame(width: min(340, geo.size.width * 0.32))
                                Divider()
                            }
                            VStack(spacing: 0) {
                                // Bound the scene and inspector to the space left by the
                                // tabs and footer. Their content must not displace actions
                                // on short phones or in a compact landscape window.
                                GeometryReader { workspace in
                                    VStack(spacing: 0) {
                                        plateStage
                                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity).clipped()
                                            .allowsHitTesting(!isSlicing && !engine.presetsLoading && !engine.sessionBusy)
                                        if mainTab == .preview && !engine.previewLayerHeights.isEmpty {
                                            previewLayerBar.padding(.horizontal, 12).padding(.vertical, 6)
                                                .background(OrcaTheme.panel)
                                        }
                                        if mainTab == .preview && showPreviewControls {
                                            previewControlsPanel.frame(height: min(320, workspace.size.height * 0.4))
                                        }
                                    }.frame(width: workspace.size.width, height: workspace.size.height).clipped()
                                }
                                // Clipping drawing alone does not bound SwiftUI hit testing.
                                .contentShape(Rectangle())
                                compactControls.padding(.vertical, 4).background(OrcaTheme.panel)
                                    .fixedSize(horizontal: false, vertical: true).layoutPriority(2).zIndex(1)
                            }
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height).clipped()
                .onAppear { recordWorkspaceLayout(geo.size) }
                .onChange(of: geo.size) { recordWorkspaceLayout($0) }
            }
        }
        // The C session belongs to the background slice until it finishes.
        .disabled(isSlicing || engine.presetsLoading || engine.sessionBusy)
        .overlay {
            if isSlicing {
                VStack(spacing: 14) {
                    ProgressView().tint(OrcaTheme.accent)
                    Text(engine.slicePhase.isEmpty ? "Starting…" : engine.slicePhase)
                        .foregroundStyle(OrcaTheme.text)
                    Button("Cancel slicing") { engine.cancelSlice() }
                        .foregroundStyle(OrcaTheme.accent)
                        .disabled(engine.slicePercent < 5)
                }
                .padding(24)
                .background(OrcaTheme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            } else if engine.sessionBusy {
                ProgressView(engine.sessionBusyMessage)
                    .padding(24)
                    .background(OrcaTheme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else if documents.receiving > 0 {
                ProgressView("Preparing file…")
                    .padding(20)
                    .background(OrcaTheme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        })
    }

    private func recordWorkspaceLayout(_ size: CGSize) {
        guard ProcessInfo.processInfo.arguments.contains("--test-view-metadata") else { return }
        let data: [String: Any] = ["width": size.width, "height": size.height,
                                  "sidebar": size.width >= 860 && size.height >= 500 && sidebarVisible]
        if let json = try? JSONSerialization.data(withJSONObject: data) {
            try? json.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("orca-workspace-layout.json"))
            if size.width > size.height {
                try? json.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("orca-workspace-landscape.json"))
            }
        }
    }

    private var primaryPresentations: AnyView {
        AnyView(rootLayout
        .sheet(isPresented: $showProcess, onDismiss: presentPendingDocumentPicker) {
            processSheet
                .presentationDetents([.medium, .large], selection: $settingsDetent)
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showPlateInspector, onDismiss: { importPendingDocuments(); importCloudPresetsIfReady() }) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        plateTabsRow
                        objectPickerRow
                        NavigationLink("Mesh tools") {
                            MeshToolsPanel(engine: engine) {
                                status = engine.lastMessage
                                showPlateInspector = false
                            }
                        }.buttonStyle(.bordered).disabled(!engine.hasModel).accessibilityIdentifier("mesh-tools")
                        transformEditor
                        plateToolsRow
                    }.padding()
                }
                .navigationTitle("Objects and tools")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showPlateInspector = false }.disabled(engine.sessionBusy) } }
            }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
                .interactiveDismissDisabled(engine.sessionBusy)
        }
        .sheet(isPresented: $showModelLibrary) { modelLibrary }
        .sheet(isPresented: $showMeshTools) {
            NavigationStack {
                MeshToolsPanel(engine: engine) { status = engine.lastMessage; showMeshTools = false }
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showMeshTools = false }.disabled(engine.sessionBusy)
                    } }
            }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
                .interactiveDismissDisabled(engine.sessionBusy)
        }
        .sheet(isPresented: $showCalibration) {
            calibrationSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showWizard) {
            configWizardSheet
                .presentationDetents([.large])
                .interactiveDismissDisabled(!OrcaEngine.wizardCompleted)
                .preferredColorScheme(.dark)
        }
        )
    }

    private var auxiliaryPresentations: AnyView {
        AnyView(primaryPresentations
        .sheet(isPresented: $showPreferences) {
            preferencesSheet
                .presentationDetents([.medium, .large])
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showAbout) {
            aboutSheet
                .presentationDetents([.medium])
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showShortcuts) {
            NavigationStack {
                List {
                    Section("Prepare") {
                        labeled("Open", "Toolbar Open")
                        labeled("Slice", "Slice plate button")
                        labeled("Undo / Redo", "Header ↩ / ↪")
                        labeled("Gizmos", "Select · Move · Rotate · Scale · Measure")
                        labeled("Explode", "Tool chip Explode / Collapse")
                    }
                    Section("Process") {
                        labeled("Settings", "Slider icon · Process sheet")
                        labeled("All settings", "Search browser in Process")
                    }
                    Section("Device") {
                        labeled("Discover", "mDNS list after Connect")
                        labeled("Upload / Start", "Device tab actions")
                    }
                    Section("Auxiliary") {
                        labeled("User presets", "Files app → On My iPhone → OrcaSlicer")
                        labeled("Export bundle", "Preferences → Export user presets")
                    }
                }
                .scrollContentBackground(.hidden)
                .background(OrcaTheme.bg)
                .navigationTitle("Shortcuts")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { showShortcuts = false }
                            .foregroundStyle(OrcaTheme.accent)
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showLayerHeights, onDismiss: {
            presentPendingDocumentPicker(); importPendingDocuments(); importCloudPresetsIfReady()
        }) {
            NavigationStack {
                LayerHeightPanel(engine: engine, objectIndex: engine.selectedObjectIndex) { status = engine.lastMessage }
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showLayerHeights = false }.disabled(engine.sessionBusy)
                    } }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled(engine.sessionBusy)
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showObjectSettings) {
            objectSettingsSheet
                .presentationDetents([.medium, .large])
                .preferredColorScheme(.dark)
        }
        )
    }

    var body: some View {
        auxiliaryPresentations
        .onAppear {
            if !OrcaEngine.wizardCompleted {
                showWizard = true
            }
            // Restore preferred vendors into wizard multi-select when reopening
            if wizardVendors.isEmpty {
                wizardVendors = Set(OrcaEngine.preferredVendors)
            }
        }
        .sheet(item: $documentPicker) { request in
            NativeDocumentPicker(settingsOnly: request.isSettings, onPick: { url in
                documents.receive(url, kind: request.kind)
            }, onDismiss: {
                if ProcessInfo.processInfo.arguments.contains("--test-native-picker"), documents.receiving == 0, documents.pending.isEmpty {
                    // UI automation cancels through the system button, then
                    // exercises the document inbox with its local fixture.
                    documents.receive(testDocumentFixture, kind: request.kind)
                }
                documentPicker = nil
            })
        }
        .onAppear {
            importPendingDocuments()
            testDocumentPickerWhenReady()
            if ProcessInfo.processInfo.arguments.contains("--test-view-metadata") {
                let result = PlateSceneView.cameraSmokeTest() ? "PASS: one-finger pan/orbit and two-finger zoom camera math" : "FAIL: camera gesture smoke test"
                try? result.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("orca-camera-smoke.txt"), atomically: true, encoding: .utf8)
            }
        }
        .onChange(of: mainTab) { tab in
            if tab != .preview { engine.pauseToolheadPlayback() }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { engine.pauseToolheadPlayback() }
        }
        .onDisappear { engine.pauseToolheadPlayback() }
        .onChange(of: cloudAccount.busy) { busy in if !busy { importCloudPresetsIfReady() } }
        .onChange(of: cloudAccount.profileRevision) { _ in importCloudPresetsIfReady() }
        .onChange(of: engine.sessionBusy) { importing in if !importing { importPendingDocuments(); importCloudPresetsIfReady() } }
        .onChange(of: documents.pending.count) { _ in importPendingDocuments() }
        .onChange(of: engine.presetsLoading) { _ in importPendingDocuments() }
        .onChange(of: engine.startupFinished) { _ in
            importPendingDocuments()
            testDocumentPickerWhenReady()
            importCloudPresetsIfReady()
        }
        .onChange(of: isSlicing) { _ in importPendingDocuments(); importCloudPresetsIfReady() }
        .onChange(of: editingModalPresented) { _ in importPendingDocuments(); importCloudPresetsIfReady() }
        .alert(operationError == nil ? "Import failed" : "Operation failed", isPresented: Binding(
            get: { operationError != nil || !documents.errorMessage.isEmpty },
            set: { if !$0 { operationError = nil; documents.errorMessage = "" } }
        )) {
            Button("OK", role: .cancel) { operationError = nil; documents.errorMessage = "" }
        } message: { Text(operationError ?? documents.errorMessage) }
    }

    private func headerBar(inlineInspector: Bool) -> AnyView {
        AnyView(HStack(spacing: 8) {
            fileProjectMenu
            Text("OrcaSlicer").font(.headline).lineLimit(1).minimumScaleFactor(0.75)
                .foregroundStyle(OrcaTheme.text)
            Spacer(minLength: 8)
            Button {
                engine.undo()
                status = engine.lastMessage
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 15, weight: .semibold))
                    if engine.undoDepth > 0 {
                        Text("\(engine.undoDepth)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                }
                .foregroundStyle(engine.canUndo ? OrcaTheme.text : OrcaTheme.muted)
                .frame(minWidth: 40, minHeight: 44)
            }
            .disabled(!engine.canUndo)
            Button {
                engine.redo()
                status = engine.lastMessage
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 15, weight: .semibold))
                    if engine.redoDepth > 0 {
                        Text("\(engine.redoDepth)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                }
                .foregroundStyle(engine.canRedo ? OrcaTheme.text : OrcaTheme.muted)
                .frame(minWidth: 40, minHeight: 44)
            }
            .disabled(!engine.canRedo)
            Menu {
                cameraViewMenu
                Button("Object settings…") {
                    showObjectSettings = true
                }
                .disabled(!engine.hasModel || engine.selectedObjectIndex < 0)
                Button("Variable layer height…") { showLayerHeights = true }
                    .disabled(!engine.hasModel || engine.selectedObjectIndex < 0)
                Button("Setup wizard…") { showWizard = true }
                Button("Preferences…") { showPreferences = true }
                Button("Keyboard shortcuts…") { showShortcuts = true }
                Button("About OrcaSlicer…") { showAbout = true }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(OrcaTheme.text)
                    .frame(width: 44, height: 44)
                    .background(OrcaTheme.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Button {
                if inlineInspector { sidebarVisible.toggle() } else { showProcess = true }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(OrcaTheme.text)
                    .frame(width: 44, height: 44)
                    .background(OrcaTheme.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(OrcaTheme.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(OrcaTheme.border).frame(height: 1)
        })
    }

    private var tabBar: AnyView {
        AnyView(HStack(spacing: 0) {
            ForEach(MainTab.allCases, id: \.self) { tab in
                Button {
                    mainTab = tab
                    if engine.previewFromFile { fitCameraRequest = UUID() }
                    if tab != .preview { showPreviewControls = false }
                    if tab != .prepare { moveMode = false }
                    if tab == .preview && engine.gcodeURL == nil {
                        status = "Slice to preview toolpaths."
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(mainTab == tab ? OrcaTheme.accent : OrcaTheme.muted)
                        .background(mainTab == tab ? OrcaTheme.accent.opacity(0.12) : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .background(OrcaTheme.panel))
    }

    enum PrinterHostType: String, CaseIterable, Identifiable {
        case moonraker = "Moonraker"
        case octoprint = "OctoPrint"
        case prusalink = "PrusaLink"
        case flashforge = "Flashforge"
        var id: String { rawValue }
    }

    @State private var hostType: PrinterHostType = .moonraker
    @State private var printerHost = "http://192.168.1.100"
    @State private var octoApiKey = ""
    @State private var flashforgeSerial = ""
    @State private var flashforgeStatus: FlashforgeStatus?
    @State private var flashforgeUploadedJob: FlashforgeUploadedJob?
    @State private var flashforgeUseStation = false
    @State private var flashforgeLeveling = true
    @State private var flashforgeToolSlots = [1, 2, 3, 4]
    @State private var printerStatus = "Not connected"
    @State private var isConnecting = false
    @State private var isJobBusy = false
    @State private var lastUploadedFilename: String?
    @State private var jobState = ""
    @State private var jobProgress: Double = 0
    @State private var jobMessage = ""
    @State private var statusPollTask: Task<Void, Never>?
    @State private var nozzleTemp = "210"
    @State private var bedTemp = "60"
    /// Live temps from printer host (when connected)
    @State private var liveNozzleActual: Double?
    @State private var liveNozzleTarget: Double?
    @State private var liveBedActual: Double?
    @State private var liveBedTarget: Double?
    @State private var liveTempText = ""
    /// Bonjour / mDNS discovery
    @State private var discoveredPrinters: [DiscoveredPrinter] = []
    @State private var isDiscovering = false
    @State private var discoveryBrowsers: [NWBrowser] = []
    @State private var discoveryStatus = ""

    struct DiscoveredPrinter: Identifiable, Hashable {
        let id: String
        let name: String
        let host: String
        let port: Int
        let serviceType: String
        var urlString: String {
            let h = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            return "http://\(h):\(port)"
        }
    }

    private var devicePlaceholder: AnyView {
        AnyView(ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "printer.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(OrcaTheme.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Device")
                            .font(.headline)
                            .foregroundStyle(OrcaTheme.text)
                        Text(printerStatus)
                            .font(.subheadline)
                            .foregroundStyle(OrcaTheme.muted)
                    }
                    Spacer()
                    Button {
                        showCalibration = true
                    } label: {
                        Image(systemName: "ruler")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(OrcaTheme.accent)
                            .frame(width: 40, height: 40)
                            .background(OrcaTheme.elevated)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                PrinterConnectionsPanel(account: cloudAccount, engine: engine, connections: connections, address: printerHost,
                                        kind: hostType.rawValue, apiKey: octoApiKey,
                                        serialNumber: hostType == .flashforge ? flashforgeSerial : nil) { printer in
                    selectPrinterConnection(printer)
                }
                .disabled(isConnecting || isJobBusy)

                // Live temps from host
                if !liveTempText.isEmpty || liveNozzleActual != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Live temps")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(OrcaTheme.muted)
                        HStack(spacing: 16) {
                            liveTempBadge(
                                title: "Nozzle",
                                actual: liveNozzleActual,
                                target: liveNozzleTarget
                            )
                            liveTempBadge(
                                title: "Bed",
                                actual: liveBedActual,
                                target: liveBedTarget
                            )
                        }
                        if !liveTempText.isEmpty {
                            Text(liveTempText)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(OrcaTheme.muted)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(OrcaTheme.panel.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                // Bonjour discovery
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Discover printers (mDNS)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(OrcaTheme.muted)
                        Spacer()
                        Button {
                            if isDiscovering { stopPrinterDiscovery() }
                            else { startPrinterDiscovery() }
                        } label: {
                            Text(isDiscovering ? "Stop" : "Scan")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(OrcaTheme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    if !discoveryStatus.isEmpty {
                        Text(discoveryStatus)
                            .font(.system(size: 11))
                            .foregroundStyle(OrcaTheme.muted)
                    }
                    if discoveredPrinters.isEmpty && isDiscovering {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("Browsing LAN…")
                                .font(.system(size: 12))
                                .foregroundStyle(OrcaTheme.muted)
                        }
                    }
                    ForEach(discoveredPrinters) { p in
                        Button {
                            guard !isConnecting, !isJobBusy else { return }
                            resetPrinterConnection()
                            octoApiKey = ""
                            printerHost = p.urlString
                            if p.serviceType.contains("octoprint") {
                                hostType = .octoprint
                            } else if p.serviceType.contains("moonraker") || p.name.lowercased().contains("klipper") {
                                hostType = .moonraker
                            }
                            printerStatus = "Selected \(p.name)"
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(OrcaTheme.text)
                                        .lineLimit(1)
                                    Text("\(p.serviceType) · \(p.urlString)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(OrcaTheme.muted)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(OrcaTheme.muted)
                            }
                            .padding(10)
                            .background(OrcaTheme.elevated)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Picker("Host type", selection: $hostType) {
                    ForEach(PrinterHostType.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isConnecting || isJobBusy)
                .onChange(of: hostType) { _ in resetPrinterConnection() }

                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        hostType == .flashforge ? "Flashforge AD5X / Adventurer 5M host (port 8898)"
                            : hostType == .moonraker ? "Moonraker / Klipper host"
                            : hostType == .prusalink ? "PrusaLink host"
                            : "OctoPrint host"
                    )
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OrcaTheme.muted)
                    TextField(
                        hostType == .flashforge ? "http://192.168.1.100:8898"
                            : hostType == .moonraker ? "http://printer.local"
                            : hostType == .prusalink ? "http://prusa.local"
                            : "http://octopi.local",
                        text: Binding(get: { printerHost }, set: { value in
                            resetPrinterConnection()
                            octoApiKey = ""
                            printerHost = value
                        })
                    )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .disabled(isConnecting || isJobBusy)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(OrcaTheme.text)
                        .padding(12)
                        .background(OrcaTheme.elevated)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    if PrinterConnection.validatedURL(printerHost) != nil {
                        SecureField(
                            hostType == .flashforge ? "Flashforge LAN access code" : "API key (optional)",
                            text: Binding(get: { octoApiKey }, set: { resetPrinterConnection(); octoApiKey = $0 })
                        )
                            .disabled(isConnecting || isJobBusy)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(OrcaTheme.text)
                            .padding(12)
                            .background(OrcaTheme.elevated)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }

                if hostType == .flashforge { flashforgeConnectionOptions }

                HStack(spacing: 10) {
                    Button {
                        Task { await connectPrinterHost() }
                    } label: {
                        HStack {
                            if isConnecting { ProgressView().tint(.white) }
                            Text(isConnecting ? "Connecting…" : "Connect")
                                .fontWeight(.bold)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(OrcaTheme.accent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .disabled(isConnecting)
                    .buttonStyle(.plain)

                    Button {
                        Task { await uploadGCodeToHost() }
                    } label: {
                        Text("Upload G-code")
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(engine.gcodeURL != nil ? OrcaTheme.elevated : OrcaTheme.elevated.opacity(0.5))
                            .foregroundStyle(engine.gcodeURL != nil ? OrcaTheme.accent : OrcaTheme.muted)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .disabled(engine.gcodeURL == nil || isConnecting)
                    .buttonStyle(.plain)
                }

                // Start / status / cancel
                VStack(alignment: .leading, spacing: 10) {
                    Text("Job")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OrcaTheme.muted)
                    if !jobState.isEmpty {
                        HStack {
                            Text(jobState)
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                .foregroundStyle(OrcaTheme.text)
                            Spacer()
                            Text(String(format: "%.0f%%", jobProgress * 100))
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(OrcaTheme.accent)
                        }
                        ProgressView(value: min(max(jobProgress, 0), 1))
                            .tint(OrcaTheme.accent)
                        if !jobMessage.isEmpty {
                            Text(jobMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(OrcaTheme.muted)
                        }
                    } else if let name = lastUploadedFilename {
                        Text("Ready: \(name)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(OrcaTheme.muted)
                    }
                    HStack(spacing: 10) {
                        Button {
                            Task { await startHostPrint() }
                        } label: {
                            HStack {
                                if isJobBusy { ProgressView().tint(.white) }
                                Text("Start print")
                                    .fontWeight(.bold)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(canStartPrint ? OrcaTheme.accent : OrcaTheme.elevated.opacity(0.5))
                            .foregroundStyle(canStartPrint ? .white : OrcaTheme.muted)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .disabled(!canStartPrint || isJobBusy || isConnecting)
                        .buttonStyle(.plain)

                        Button {
                            Task { await cancelHostPrint() }
                        } label: {
                            Text("Cancel")
                                .fontWeight(.bold)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(OrcaTheme.danger.opacity(0.2))
                                .foregroundStyle(OrcaTheme.danger)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .disabled(isJobBusy || isConnecting)
                        .buttonStyle(.plain)

                        Button {
                            Task { await refreshHostJobStatus() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .background(OrcaTheme.elevated)
                                .foregroundStyle(OrcaTheme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Print host job history")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(OrcaTheme.muted)
                        Spacer()
                        if !engine.hostJobHistory.isEmpty {
                            Button("Clear") {
                                engine.clearHostJobHistory()
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(OrcaTheme.danger)
                            .buttonStyle(.plain)
                        }
                    }
                    if engine.hostJobHistory.isEmpty {
                        Text("Uploads and sends appear here (host · file · date).")
                            .font(.system(size: 11))
                            .foregroundStyle(OrcaTheme.muted)
                    } else {
                        ForEach(engine.hostJobHistory.prefix(12), id: \.self) { line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(OrcaTheme.muted)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(OrcaTheme.elevated)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(OrcaTheme.panel.opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Print temps")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OrcaTheme.muted)
                    HStack(spacing: 10) {
                        tempField("Nozzle °C", text: $nozzleTemp) {
                            engine.setOption("nozzle_temperature", value: nozzleTemp)
                            engine.setOption("nozzle_temperature_initial_layer", value: nozzleTemp)
                            status = engine.lastMessage
                        }
                        tempField("Bed °C", text: $bedTemp) {
                            engine.setOption("bed_temperature", value: bedTemp)
                            engine.setOption("bed_temperature_initial_layer", value: bedTemp)
                            status = engine.lastMessage
                        }
                    }
                }


            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OrcaTheme.bg.opacity(0.96)))
    }

    private var canStartPrint: Bool {
        if hostType == .flashforge {
            return flashforgeUploadedJob != nil && engine.gcodeURL == flashforgeUploadedJob?.source
        }
        return lastUploadedFilename != nil || engine.gcodeURL != nil
    }

    private func tempField(_ title: String, text: Binding<String>, apply: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(OrcaTheme.muted)
            HStack {
                TextField(title, text: text)
                    .keyboardType(.numberPad)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(OrcaTheme.text)
                Button("Set", action: apply)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(OrcaTheme.accent)
            }
            .padding(10)
            .background(OrcaTheme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .frame(maxWidth: .infinity)
    }

    private func resetPrinterConnection() {
        statusPollTask?.cancel()
        statusPollTask = nil
        printerStatus = "Not connected"
        lastUploadedFilename = nil
        flashforgeUploadedJob = nil
        flashforgeStatus = nil
        jobState = ""
        jobMessage = ""
        jobProgress = 0
        liveNozzleActual = nil
        liveNozzleTarget = nil
        liveBedActual = nil
        liveBedTarget = nil
        liveTempText = ""
    }

    private func selectPrinterConnection(_ printer: PrinterConnection) {
        guard !isConnecting, !isJobBusy,
              let type = PrinterHostType(rawValue: printer.kind) else { return }
        do {
            let key = try connections.apiKey(for: printer)
            resetPrinterConnection()
            hostType = type
            printerHost = printer.connectionAddress
            octoApiKey = key
            flashforgeSerial = printer.serialNumber ?? ""
            printerStatus = "Selected \(printer.name)"
        } catch { connections.message = error.localizedDescription }
    }

    private func printerBaseURL() -> URL? {
        PrinterConnection.validatedURL(printerHost)
    }

    private func moonrakerBaseURL() -> URL? { printerBaseURL() }

    private func connectPrinterHost() async {
        guard !isConnecting, !isJobBusy else { return }
        switch hostType {
        case .moonraker: await connectMoonraker()
        case .flashforge: await connectFlashforge()
        case .octoprint, .prusalink: await connectOctoPrint() // PrusaLink speaks OctoPrint-compatible API
        }
    }

    private func uploadGCodeToHost() async {
        guard !isConnecting, !isJobBusy else { return }
        switch hostType {
        case .moonraker: await uploadGCodeToMoonraker()
        case .flashforge: await uploadGCodeToFlashforge()
        case .octoprint, .prusalink: await uploadGCodeToOctoPrint()
        }
    }

    private func startHostPrint() async {
        guard !isConnecting, !isJobBusy else { return }
        switch hostType {
        case .moonraker: await startMoonrakerPrint()
        case .flashforge: await startFlashforgePrint()
        case .octoprint, .prusalink: await startOctoPrint()
        }
    }

    private func cancelHostPrint() async {
        guard !isConnecting, !isJobBusy else { return }
        switch hostType {
        case .moonraker: await cancelMoonrakerPrint()
        case .flashforge: await cancelFlashforgePrint()
        case .octoprint, .prusalink: await cancelOctoPrint()
        }
    }

    private func refreshHostJobStatus() async {
        switch hostType {
        case .moonraker: await refreshMoonrakerJobStatus()
        case .flashforge: await refreshFlashforgeStatus()
        case .octoprint, .prusalink: await refreshOctoPrintJobStatus()
        }
    }

    private var flashforgeConnectionOptions: AnyView {
        AnyView(VStack(alignment: .leading, spacing: 10) {
            TextField("Flashforge serial number", text: Binding(get: { flashforgeSerial }, set: {
                resetPrinterConnection()
                flashforgeSerial = $0
            }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            Text("Use the printer’s local IP, serial number, and LAN access code from its network settings. Connect first to read status and AD5X material slots.")
                .font(.caption).foregroundStyle(OrcaTheme.muted)
            Text("Slicing profile: \(engine.selectedPrinter.isEmpty ? "Choose a Flashforge profile in Process" : engine.selectedPrinter)")
                .font(.caption)
            Toggle("Level before printing", isOn: $flashforgeLeveling)
            if let current = flashforgeStatus, current.hasMaterialStation {
                Toggle("Use AD5X material station (IFS)", isOn: $flashforgeUseStation)
                if flashforgeUseStation {
                    ForEach(0..<4, id: \.self) { tool in
                        Picker("Tool \(tool + 1)", selection: $flashforgeToolSlots[tool]) {
                            ForEach(current.slots) { slot in
                                Text("Slot \(slot.id): \(slot.material)\(slot.hasFilament ? "" : " (empty)")").tag(slot.id)
                            }
                        }
                    }
                    Text("Mappings apply to tools present in the generated G-code. Upload does not start a print; Start print is a separate action.")
                        .font(.caption).foregroundStyle(OrcaTheme.muted)
                }
            }
        }
        .disabled(isConnecting || isJobBusy)
        .onChange(of: flashforgeUseStation) { _ in invalidateFlashforgeUpload() }
        .onChange(of: flashforgeLeveling) { _ in invalidateFlashforgeUpload() }
        .onChange(of: flashforgeToolSlots) { _ in invalidateFlashforgeUpload() })
    }

    private func invalidateFlashforgeUpload() {
        flashforgeUploadedJob = nil
        lastUploadedFilename = nil
    }

    private func flashforgeClient() throws -> FlashforgeClient {
        try FlashforgeClient(address: printerHost, serial: flashforgeSerial, code: octoApiKey)
    }

    private func applyFlashforgeStatus(_ current: FlashforgeStatus) {
        flashforgeStatus = current
        jobState = current.state
        jobProgress = current.progress
        jobMessage = current.filename
        liveNozzleActual = current.nozzle
        liveNozzleTarget = current.nozzleTarget
        liveBedActual = current.bed
        liveBedTarget = current.bedTarget
        updateLiveTempText()
        printerStatus = "\(current.name) · \(current.state)"
    }

    private func connectFlashforge() async {
        isConnecting = true
        defer { isConnecting = false }
        do {
            let current = try await flashforgeClient().detail()
            guard !Task.isCancelled else { return }
            applyFlashforgeStatus(current)
            flashforgeUseStation = current.hasMaterialStation
            startLiveTempPolling()
        } catch { printerStatus = error.localizedDescription }
    }

    private func refreshFlashforgeStatus() async {
        do {
            let current = try await flashforgeClient().detail()
            guard !Task.isCancelled else { return }
            applyFlashforgeStatus(current)
        } catch {
            guard !Task.isCancelled else { return }
            jobMessage = error.localizedDescription
        }
    }

    private func uploadGCodeToFlashforge() async {
        guard let source = engine.gcodeURL else { printerStatus = "Slice first to produce G-code"; return }
        guard engine.selectedPrinter.lowercased().hasPrefix("flashforge") else {
            printerStatus = "Select the matching Flashforge slicing profile in Process before uploading"
            return
        }
        isConnecting = true
        invalidateFlashforgeUpload()
        defer { isConnecting = false }
        do {
            let client = try flashforgeClient()
            let current = try await client.detail()
            guard !Task.isCancelled else { return }
            applyFlashforgeStatus(current)
            let selected = engine.selectedPrinter.lowercased()
            if (current.modelID == 38 && !selected.contains("ad5x")) ||
               ([35, 36].contains(current.modelID ?? -1) && !selected.contains("5m")) {
                printerStatus = "The connected printer does not match the selected Flashforge slicing profile"
                return
            }
            let useStation = flashforgeUseStation
            if useStation && !current.hasMaterialStation { throw FlashforgeError.materialMapping }
            let leveling = flashforgeLeveling
            let mapping = flashforgeToolSlots
            let upload = try await Task.detached(priority: .userInitiated) {
                try client.prepareUpload(source: source, leveling: leveling, useStation: useStation,
                                         slots: current.slots, toolSlots: mapping)
            }.value
            let job = try await client.upload(upload)
            flashforgeUploadedJob = job
            lastUploadedFilename = job.filename
            printerStatus = "Uploaded \(job.filename) · ready to start"
            engine.recordHostJob(host: printerHost, file: job.filename, hostType: "Flashforge")
        } catch { printerStatus = error.localizedDescription }
    }

    private func startFlashforgePrint() async {
        guard let job = flashforgeUploadedJob, engine.gcodeURL == job.source else {
            printerStatus = "Upload the current G-code before starting"
            return
        }
        isJobBusy = true
        defer { isJobBusy = false }
        do {
            try await flashforgeClient().start(job)
            printerStatus = "Print start requested"
            startLiveTempPolling()
        } catch { printerStatus = error.localizedDescription }
    }

    private func cancelFlashforgePrint() async {
        isJobBusy = true
        defer { isJobBusy = false }
        do {
            try await flashforgeClient().cancel()
            printerStatus = "Print cancel requested"
        } catch { printerStatus = error.localizedDescription }
    }

    private func printerHeaders(for req: inout URLRequest) {
        let key = octoApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            req.setValue(key, forHTTPHeaderField: "X-Api-Key")
        }
    }

    private func connectMoonraker() async {
        isConnecting = true
        defer { isConnecting = false }
        guard let base = printerBaseURL() else {
            printerStatus = "Invalid URL"
            return
        }
        let info = base.appendingPathComponent("server/info")
        var req = URLRequest(url: info)
        printerHeaders(for: &req)
        req.timeoutInterval = 5
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard !Task.isCancelled else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let result = json["result"] as? [String: Any] {
                    let ver = result["klippy_state"] as? String
                        ?? result["moonraker_version"] as? String
                        ?? "ok"
                    printerStatus = "Moonraker · \(ver)"
                } else {
                    printerStatus = "Moonraker connected (HTTP \(code))"
                }
                await refreshLiveTemps()
                startLiveTempPolling()
            } else {
                printerStatus = "HTTP \(code) from server.info"
            }
        } catch {
            printerStatus = "Unreachable: \(error.localizedDescription)"
        }
    }

    /// GET /api/version — OctoPrint handshake
    private func connectOctoPrint() async {
        isConnecting = true
        defer { isConnecting = false }
        guard let base = printerBaseURL() else {
            printerStatus = "Invalid URL"
            return
        }
        var req = URLRequest(url: base.appendingPathComponent("api/version"))
        req.timeoutInterval = 5
        printerHeaders(for: &req)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard !Task.isCancelled else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let ver = (json["server"] as? String)
                        ?? (json["api"] as? String)
                        ?? "ok"
                    let label = hostType == .prusalink ? "PrusaLink" : "OctoPrint"
                    printerStatus = "\(label) · \(ver)"
                } else {
                    printerStatus = hostType == .prusalink ? "PrusaLink connected" : "OctoPrint connected"
                }
                await refreshLiveTemps()
                startLiveTempPolling()
            } else if code == 403 {
                printerStatus = "HTTP 403 — check API key"
            } else {
                printerStatus = "HTTP \(code)"
            }
        } catch {
            printerStatus = "Unreachable: \(error.localizedDescription)"
        }
    }

    /// Light-weight temp poll while Device tab is connected (independent of job).
    private func startLiveTempPolling() {
        // Reuse statusPollTask only if not already job-polling; spawn dedicated loop via job task
        // when idle so live temps keep updating after Connect.
        if statusPollTask != nil { return }
        statusPollTask = Task {
            for _ in 0..<360 { // ~30 min at 5s
                if Task.isCancelled { return }
                await refreshLiveTemps()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func uploadGCodeToMoonraker() async {
        guard let gcode = engine.gcodeURL else {
            printerStatus = "Slice first to produce G-code"
            return
        }
        guard let base = moonrakerBaseURL() else {
            printerStatus = "Invalid host URL"
            return
        }
        isConnecting = true
        defer { isConnecting = false }
        // Moonraker multipart upload: POST /server/files/upload
        let uploadURL = base.appendingPathComponent("server/files/upload")
        let boundary = "OrcaBoundary\(UUID().uuidString)"
        var req = URLRequest(url: uploadURL)
        printerHeaders(for: &req)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        guard let fileData = try? Data(contentsOf: gcode) else {
            printerStatus = "Could not read G-code file"
            return
        }
        var body = Data()
        let filename = gcode.lastPathComponent
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"root\"\r\n\r\n".data(using: .utf8)!)
        body.append("gcodes\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard !Task.isCancelled else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(code) {
                // Prefer path returned by Moonraker; fall back to filename in gcodes/
                var remoteName = filename
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let result = json["result"] as? [String: Any],
                   let item = result["item"] as? [String: Any],
                   let path = item["path"] as? String, !path.isEmpty {
                    remoteName = path
                }
                lastUploadedFilename = remoteName
                printerStatus = "Uploaded \(remoteName)"
                jobMessage = "Upload OK — Start print when ready"
                engine.recordHostJob(host: self.printerHost, file: remoteName, hostType: "Moonraker")
            } else {
                printerStatus = "Upload failed HTTP \(code)"
            }
        } catch {
            printerStatus = "Upload error: \(error.localizedDescription)"
        }
    }

    /// POST /printer/print/start?filename=
    private func startMoonrakerPrint() async {
        guard let base = moonrakerBaseURL() else {
            printerStatus = "Invalid host URL"
            return
        }
        var filename = lastUploadedFilename
        if filename == nil, let gcode = engine.gcodeURL {
            // Auto-upload then start
            await uploadGCodeToMoonraker()
            filename = lastUploadedFilename ?? gcode.lastPathComponent
        }
        guard let filename, !filename.isEmpty else {
            printerStatus = "Upload G-code first"
            return
        }
        isJobBusy = true
        defer { isJobBusy = false }
        var comps = URLComponents(
            url: base.appendingPathComponent("printer/print/start"),
            resolvingAgainstBaseURL: false
        )
        comps?.queryItems = [URLQueryItem(name: "filename", value: filename)]
        guard let url = comps?.url else {
            printerStatus = "Bad start URL"
            return
        }
        var req = URLRequest(url: url)
        printerHeaders(for: &req)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard !Task.isCancelled else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(code) {
                jobState = "printing"
                jobProgress = 0
                jobMessage = "Started \(filename)"
                printerStatus = "Print started · \(filename)"
                startJobStatusPolling()
            } else {
                let errBody = String(data: data, encoding: .utf8) ?? ""
                printerStatus = "Start failed HTTP \(code)"
                jobMessage = errBody.isEmpty ? "HTTP \(code)" : String(errBody.prefix(160))
            }
        } catch {
            printerStatus = "Start error: \(error.localizedDescription)"
        }
    }

    /// POST /printer/print/cancel
    private func cancelMoonrakerPrint() async {
        guard let base = moonrakerBaseURL() else {
            printerStatus = "Invalid host URL"
            return
        }
        isJobBusy = true
        defer { isJobBusy = false }
        var req = URLRequest(url: base.appendingPathComponent("printer/print/cancel"))
        printerHeaders(for: &req)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(code) {
                jobState = "cancelled"
                jobMessage = "Print cancelled"
                printerStatus = "Print cancelled"
                statusPollTask?.cancel()
                statusPollTask = nil
            } else {
                printerStatus = "Cancel failed HTTP \(code)"
            }
        } catch {
            printerStatus = "Cancel error: \(error.localizedDescription)"
        }
    }

    /// GET /printer/objects/query?print_stats&display_status&extruder&heater_bed
    private func refreshMoonrakerJobStatus() async {
        guard let base = moonrakerBaseURL() else { return }
        var comps = URLComponents(
            url: base.appendingPathComponent("printer/objects/query"),
            resolvingAgainstBaseURL: false
        )
        // Moonraker accepts object names as query keys
        comps?.queryItems = [
            URLQueryItem(name: "print_stats", value: nil),
            URLQueryItem(name: "display_status", value: nil),
            URLQueryItem(name: "extruder", value: nil),
            URLQueryItem(name: "heater_bed", value: nil),
        ]
        guard let url = comps?.url else { return }
        var req = URLRequest(url: url)
        printerHeaders(for: &req)
        req.timeoutInterval = 8
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard !Task.isCancelled else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(code),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let statusObj = result["status"] as? [String: Any]
            else {
                if code != 0 { jobMessage = "Status HTTP \(code)" }
                return
            }
            if let ps = statusObj["print_stats"] as? [String: Any] {
                let state = (ps["state"] as? String) ?? ""
                let fn = (ps["filename"] as? String) ?? ""
                if !state.isEmpty { jobState = state }
                if !fn.isEmpty { jobMessage = fn }
            }
            if let ds = statusObj["display_status"] as? [String: Any] {
                if let p = ds["progress"] as? Double {
                    jobProgress = p
                } else if let p = ds["progress"] as? Int {
                    jobProgress = Double(p)
                }
                if let msg = ds["message"] as? String, !msg.isEmpty {
                    jobMessage = msg
                }
            }
            applyMoonrakerTemps(statusObj)
            if !jobState.isEmpty {
                printerStatus = "Job · \(jobState) · \(String(format: "%.0f%%", jobProgress * 100))"
            }
        } catch {
            guard !Task.isCancelled else { return }
            jobMessage = error.localizedDescription
        }
    }

    private func applyMoonrakerTemps(_ statusObj: [String: Any]) {
        if let ex = statusObj["extruder"] as? [String: Any] {
            liveNozzleActual = Self.jsonDouble(ex["temperature"])
            liveNozzleTarget = Self.jsonDouble(ex["target"])
        }
        if let bed = statusObj["heater_bed"] as? [String: Any] {
            liveBedActual = Self.jsonDouble(bed["temperature"])
            liveBedTarget = Self.jsonDouble(bed["target"])
        }
        updateLiveTempText()
    }

    private static func jsonDouble(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    private func updateLiveTempText() {
        let nA = liveNozzleActual.map { String(format: "%.0f", $0) } ?? "—"
        let nT = liveNozzleTarget.map { String(format: "%.0f", $0) } ?? "—"
        let bA = liveBedActual.map { String(format: "%.0f", $0) } ?? "—"
        let bT = liveBedTarget.map { String(format: "%.0f", $0) } ?? "—"
        liveTempText = "N \(nA)/\(nT) °C · B \(bA)/\(bT) °C"
    }

    private func liveTempBadge(title: String, actual: Double?, target: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(OrcaTheme.muted)
            if let a = actual {
                Text(String(format: "%.0f°", a))
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundStyle(OrcaTheme.accent)
            } else {
                Text("—")
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundStyle(OrcaTheme.muted)
            }
            if let t = target {
                Text(String(format: "→ %.0f°", t))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(OrcaTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func startJobStatusPolling() {
        statusPollTask?.cancel()
        statusPollTask = Task {
            for _ in 0..<120 { // ~10 min at 5s
                if Task.isCancelled { return }
                await refreshHostJobStatus()
                await refreshLiveTemps()
                let s = jobState.lowercased()
                let done = [
                    "complete", "completed", "cancelled", "canceled",
                    "error", "standby", "ready", "operational", "offline"
                ].contains(s)
                if done { return }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// Poll live nozzle/bed temps when host supports it.
    private func refreshLiveTemps() async {
        switch hostType {
        case .flashforge: await refreshFlashforgeStatus()
        case .moonraker:
            // Temps already folded into refreshMoonrakerJobStatus; also allow standalone poll
            await refreshMoonrakerTempsOnly()
        case .octoprint, .prusalink:
            await refreshOctoPrintTemps()
        }
    }

    private func refreshMoonrakerTempsOnly() async {
        guard let base = moonrakerBaseURL() else { return }
        var comps = URLComponents(
            url: base.appendingPathComponent("printer/objects/query"),
            resolvingAgainstBaseURL: false
        )
        comps?.queryItems = [
            URLQueryItem(name: "extruder", value: nil),
            URLQueryItem(name: "heater_bed", value: nil),
        ]
        guard let url = comps?.url else { return }
        var req = URLRequest(url: url)
        printerHeaders(for: &req)
        req.timeoutInterval = 5
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard !Task.isCancelled else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(code),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let statusObj = result["status"] as? [String: Any]
            else { return }
            applyMoonrakerTemps(statusObj)
        } catch {
            // Silent — offline printers are common during discovery
        }
    }

    private func refreshOctoPrintTemps() async {
        guard let base = printerBaseURL() else { return }
        var req = URLRequest(url: base.appendingPathComponent("api/printer"))
        req.timeoutInterval = 5
        printerHeaders(for: &req)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard !Task.isCancelled else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(code),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let temp = json["temperature"] as? [String: Any]
            else { return }
            if let tool = temp["tool0"] as? [String: Any] {
                liveNozzleActual = Self.jsonDouble(tool["actual"])
                liveNozzleTarget = Self.jsonDouble(tool["target"])
            }
            if let bed = temp["bed"] as? [String: Any] {
                liveBedActual = Self.jsonDouble(bed["actual"])
                liveBedTarget = Self.jsonDouble(bed["target"])
            }
            updateLiveTempText()
        } catch {
            // silent
        }
    }

    // MARK: Bonjour / mDNS discovery

    private func startPrinterDiscovery() {
        stopPrinterDiscovery()
        isDiscovering = true
        discoveredPrinters = []
        discoveryStatus = "Scanning local network…"
        // OctoPrint + common HTTP printers; Moonraker often on _http._tcp
        let types = ["_octoprint._tcp", "_moonraker._tcp", "_http._tcp"]
        var browsers: [NWBrowser] = []
        for type in types {
            let descriptor = NWBrowser.Descriptor.bonjour(type: type, domain: nil)
            let browser = NWBrowser(for: descriptor, using: .tcp)
            browser.stateUpdateHandler = { [type] new in
                if case .failed(let err) = new {
                    DispatchQueue.main.async {
                        self.discoveryStatus = "Browse \(type): \(err.localizedDescription)"
                    }
                }
            }
            browser.browseResultsChangedHandler = { results, _ in
                DispatchQueue.main.async {
                    self.mergeDiscoveryResults(results, serviceType: type)
                }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
        discoveryBrowsers = browsers
        // Auto-stop after 30s
        Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            await MainActor.run {
                if isDiscovering {
                    stopPrinterDiscovery()
                    discoveryStatus = discoveredPrinters.isEmpty
                        ? "No printers found (try manual URL)"
                        : "Found \(discoveredPrinters.count) · scan stopped"
                }
            }
        }
    }

    private func stopPrinterDiscovery() {
        for b in discoveryBrowsers { b.cancel() }
        discoveryBrowsers = []
        isDiscovering = false
    }

    private func mergeDiscoveryResults(_ results: Set<NWBrowser.Result>, serviceType: String) {
        for result in results {
            guard case let .service(name: name, type: type, domain: _, interface: _) = result.endpoint
            else { continue }
            let id = "\(type)|\(name)"
            let fallbackPort = type.contains("octoprint") ? 5000
                : type.contains("moonraker") ? 7125
                : 80
            // Placeholder row immediately
            if !discoveredPrinters.contains(where: { $0.id == id }) {
                discoveredPrinters.append(
                    DiscoveredPrinter(id: id, name: name, host: name, port: fallbackPort, serviceType: type)
                )
                discoveredPrinters.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                discoveryStatus = "Found \(discoveredPrinters.count) service(s)"
            }
            resolveService(result: result, name: name, fallbackPort: fallbackPort) { host, port in
                DispatchQueue.main.async {
                    if let idx = self.discoveredPrinters.firstIndex(where: { $0.id == id }) {
                        self.discoveredPrinters[idx] = DiscoveredPrinter(
                            id: id, name: name, host: host, port: port, serviceType: type
                        )
                    } else {
                        self.discoveredPrinters.append(
                            DiscoveredPrinter(id: id, name: name, host: host, port: port, serviceType: type)
                        )
                    }
                    self.discoveredPrinters.sort {
                        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                    self.discoveryStatus = "Found \(self.discoveredPrinters.count) service(s)"
                }
            }
        }
        _ = serviceType
    }

    private func resolveService(
        result: NWBrowser.Result,
        name: String,
        fallbackPort: Int,
        completion: @escaping (_ host: String, _ port: Int) -> Void
    ) {
        let connection = NWConnection(to: result.endpoint, using: .tcp)
        var finished = false
        let finish: (String, Int) -> Void = { host, port in
            guard !finished else { return }
            finished = true
            completion(host, port)
            connection.cancel()
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let path = connection.currentPath,
                   let ep = path.remoteEndpoint,
                   case .hostPort(let h, let p) = ep {
                    let hostStr: String
                    switch h {
                    case .name(let n, _): hostStr = n
                    case .ipv4(let a): hostStr = "\(a)"
                    case .ipv6(let a): hostStr = "\(a)"
                    @unknown default: hostStr = name
                    }
                    finish(hostStr, Int(p.rawValue))
                } else {
                    finish(name, fallbackPort)
                }
            case .failed:
                finish(name, fallbackPort)
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            finish(name, fallbackPort)
        }
    }

    // MARK: OctoPrint REST

    /// POST /api/files/local multipart upload
    private func uploadGCodeToOctoPrint() async {
        guard let gcode = engine.gcodeURL else {
            printerStatus = "Slice first to produce G-code"
            return
        }
        guard let base = printerBaseURL() else {
            printerStatus = "Invalid host URL"
            return
        }
        isConnecting = true
        defer { isConnecting = false }
        let uploadURL = base.appendingPathComponent("api/files/local")
        let boundary = "OrcaBoundary\(UUID().uuidString)"
        var req = URLRequest(url: uploadURL)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        printerHeaders(for: &req)
        req.timeoutInterval = 90
        guard let fileData = try? Data(contentsOf: gcode) else {
            printerStatus = "Could not read G-code file"
            return
        }
        let filename = gcode.lastPathComponent
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
                .data(using: .utf8)!
        )
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"select\"\r\n\r\n".data(using: .utf8)!)
        body.append("true\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard !Task.isCancelled else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(code) {
                var remoteName = filename
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let files = json["files"] as? [String: Any],
                   let local = files["local"] as? [String: Any],
                   let name = local["name"] as? String {
                    remoteName = name
                }
                lastUploadedFilename = remoteName
                printerStatus = "OctoPrint uploaded \(remoteName)"
                jobMessage = "Upload OK — Start print when ready"
                engine.recordHostJob(
                    host: self.printerHost,
                    file: remoteName,
                    hostType: hostType.rawValue
                )
            } else if code == 403 {
                printerStatus = "Upload 403 — check API key"
            } else {
                printerStatus = "OctoPrint upload HTTP \(code)"
            }
        } catch {
            printerStatus = "Upload error: \(error.localizedDescription)"
        }
    }

    /// POST /api/job { "command": "start" } — file must be selected
    private func startOctoPrint() async {
        guard let base = printerBaseURL() else {
            printerStatus = "Invalid host URL"
            return
        }
        if lastUploadedFilename == nil, engine.gcodeURL != nil {
            await uploadGCodeToOctoPrint()
        }
        guard lastUploadedFilename != nil || engine.gcodeURL != nil else {
            printerStatus = "Upload G-code first"
            return
        }
        isJobBusy = true
        defer { isJobBusy = false }
        var req = URLRequest(url: base.appendingPathComponent("api/job"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        printerHeaders(for: &req)
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["command": "start"])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard !Task.isCancelled else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(code) {
                jobState = "Printing"
                jobProgress = 0
                jobMessage = lastUploadedFilename ?? "job"
                printerStatus = "OctoPrint print started"
                startJobStatusPolling()
            } else {
                let errBody = String(data: data, encoding: .utf8) ?? ""
                printerStatus = "Start failed HTTP \(code)"
                jobMessage = errBody.isEmpty ? "HTTP \(code)" : String(errBody.prefix(160))
            }
        } catch {
            printerStatus = "Start error: \(error.localizedDescription)"
        }
    }

    /// POST /api/job { "command": "cancel" }
    private func cancelOctoPrint() async {
        guard let base = printerBaseURL() else {
            printerStatus = "Invalid host URL"
            return
        }
        isJobBusy = true
        defer { isJobBusy = false }
        var req = URLRequest(url: base.appendingPathComponent("api/job"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        printerHeaders(for: &req)
        req.timeoutInterval = 10
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["command": "cancel"])
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(code) {
                jobState = "cancelled"
                jobMessage = "Print cancelled"
                printerStatus = "OctoPrint cancelled"
                statusPollTask?.cancel()
                statusPollTask = nil
            } else {
                printerStatus = "Cancel failed HTTP \(code)"
            }
        } catch {
            printerStatus = "Cancel error: \(error.localizedDescription)"
        }
    }

    /// GET /api/job
    private func refreshOctoPrintJobStatus() async {
        guard let base = printerBaseURL() else { return }
        var req = URLRequest(url: base.appendingPathComponent("api/job"))
        req.timeoutInterval = 8
        printerHeaders(for: &req)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard !Task.isCancelled else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(code),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                if code != 0 { jobMessage = "Status HTTP \(code)" }
                return
            }
            if let state = json["state"] as? String, !state.isEmpty {
                jobState = state
            }
            if let progress = json["progress"] as? [String: Any] {
                if let completion = progress["completion"] as? Double {
                    jobProgress = completion / 100.0
                } else if let completion = progress["completion"] as? Int {
                    jobProgress = Double(completion) / 100.0
                }
            }
            if let job = json["job"] as? [String: Any],
               let file = job["file"] as? [String: Any],
               let name = file["name"] as? String {
                jobMessage = name
            }
            if !jobState.isEmpty {
                printerStatus = "Octo · \(jobState) · \(String(format: "%.0f%%", jobProgress * 100))"
            }
        } catch {
            guard !Task.isCancelled else { return }
            jobMessage = error.localizedDescription
        }
    }

    private var fileProjectMenu: AnyView {
        AnyView(NativeProjectMenu { button in
            let models = UIMenu(options: .displayInline, children: [
                UIAction(title: "Open model…") { _ in requestDocumentPicker(.model(append: false)) },
                UIAction(title: "Add model…") { _ in requestDocumentPicker(.model(append: true)) },
                UIAction(title: "Add primitive or handy model…") { _ in showModelLibrary = true }
            ])
            var presets: [UIMenuElement] = [
                UIAction(title: "Import process preset…") { _ in requestDocumentPicker(.settings(preset: 0)) },
                UIAction(title: "Import filament preset…") { _ in requestDocumentPicker(.settings(preset: 1)) },
                UIAction(title: "Import configuration…") { _ in requestDocumentPicker(.settings(preset: nil)) },
                UIAction(title: "Export user presets…") { [weak button] _ in
                    if let button { exportUserPresetsZip(from: button) }
                },
                UIAction(title: "Export configuration…") { _ in exportShareURL = engine.exportConfigJSON() }
            ]
            if let url = exportShareURL {
                presets.append(UIAction(title: "Share configuration") { [weak button] _ in
                    if let button { NativeProjectMenu.share(url, from: button) }
                })
            }
            var project: [UIMenuElement] = [
                UIAction(title: "Save project…", attributes: engine.hasModel ? [] : .disabled) { _ in
                    projectURL = engine.saveProject3MF(); status = engine.lastMessage
                }
            ]
            if let url = projectURL {
                project.append(UIAction(title: "Share project") { [weak button] _ in
                    if let button { NativeProjectMenu.share(url, from: button) }
                })
            }
            project.append(UIAction(title: "Calibration…") { _ in showCalibration = true })
            return UIMenu(children: [models, UIMenu(options: .displayInline, children: presets),
                                    UIMenu(options: .displayInline, children: project)])
        }.frame(width: 44, height: 44))
    }

    private var compactControls: AnyView {
        AnyView(HStack(spacing: 8) {
            Button {
                if mainTab == .preview { showPreviewControls.toggle() } else { showPlateInspector = true }
            } label: {
                Image(systemName: mainTab == .preview ? "line.3.horizontal.decrease" : "square.3.layers.3d")
                    .frame(width: 44, height: 44)
            }.accessibilityLabel(mainTab == .preview ? Text("Preview controls") : Text("Objects and tools"))
            if mainTab == .preview, let gcode = engine.gcodeURL {
                ShareLink(item: gcode) {
                    Label("Export G-code", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent).tint(OrcaTheme.accent)
            } else {
                Button(action: sliceNow) {
                    Label("Slice plate", systemImage: "square.3.layers.3d.down.right")
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent).tint(OrcaTheme.accent)
                    .disabled(!engine.hasModel || isSlicing || engine.sessionBusy)
                    .accessibilityIdentifier("slice-plate")
            }
        }.padding(.horizontal, 8))
    }

    private let handyModels: [(String, [String])] = [
        ("Orca Cube", ["OrcaCube_v2.drc", "OrcaPlug_v2.drc"]),
        ("OrcaSliced Combo", ["OrcaSliced.3mf", "OrcaCube_v2.drc", "OrcaPlug_v2.drc"]),
        ("Orca Badge", ["OrcaBadge.3mf"]),
        ("Orca Tolerance Test", ["OrcaToleranceTest.drc"]),
        ("3DBenchy", ["3DBenchy.drc"]), ("Cali Cat", ["calicat.drc"]),
        ("Autodesk FDM Test", ["ksr_fdmtest_v4.drc"]),
        ("Voron Cube", ["Voron_Design_Cube_v7.drc"]),
        ("Stanford Bunny", ["Stanford_Bunny.drc"]),
        ("Orca String Hell", ["Orca_stringhell.drc"])
    ]

    private var modelLibrary: AnyView {
        AnyView(NavigationStack {
            Form {
                Section("Primitive") {
                    Picker("Shape", selection: $primitiveKind) {
                        ForEach(Array(["Cube", "Cylinder", "Sphere", "Cone", "Torus", "Disc"].enumerated()), id: \.offset) { i, name in
                            Text(name).tag(i)
                        }
                    }.onChange(of: primitiveKind) { kind in primitiveZ = kind == 5 ? "0.2" : "20" }
                    numericField(primitiveKind == 0 ? "Width X (mm)" : primitiveKind == 4 ? "Inner diameter (mm)" : "Diameter (mm)", text: $primitiveX)
                    if primitiveKind == 0 || primitiveKind == 4 {
                        numericField(primitiveKind == 4 ? "Tube diameter (mm)" : "Depth Y (mm)", text: $primitiveY)
                    }
                    if primitiveKind != 2 && primitiveKind != 4 { numericField("Height Z (mm)", text: $primitiveZ) }
                    Button("Add to plate") {
                        guard let x = Float(primitiveX), let y = Float(primitiveY), let z = Float(primitiveZ),
                              [x, y, z].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 10000 }) else {
                            documents.errorMessage = "Enter dimensions between 0 and 10000 mm."; return
                        }
                        if engine.addPrimitive(kind: primitiveKind, x: x, y: y, z: z) {
                            mainTab = .prepare; fitCameraRequest = UUID(); showModelLibrary = false
                        } else { documents.errorMessage = engine.lastMessage }
                    }.accessibilityIdentifier("add-primitive")
                }
                Section("Handy models") {
                    ForEach(Array(handyModels.enumerated()), id: \.offset) { _, model in
                        Button(model.0) {
                            showModelLibrary = false
                            Task { @MainActor in
                                for file in model.1 {
                                    guard let root = Bundle.main.resourceURL else { return }
                                    let url = root.appendingPathComponent("handy_models").appendingPathComponent(file)
                                    guard await engine.loadDocumentModel(url: url, append: true, includeSettings: false) else {
                                        documents.errorMessage = engine.lastMessage; return
                                    }
                                }
                                engine.arrange()
                                mainTab = .prepare; fitCameraRequest = UUID(); status = engine.lastMessage
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add model").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showModelLibrary = false } } }
        })
    }

    private func numericField(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, text: text).multilineTextAlignment(.trailing)
                .keyboardType(.numbersAndPunctuation).frame(maxWidth: 110)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var transformEditor: AnyView {
        AnyView(VStack(alignment: .leading, spacing: 12) {
            Text("Transform selection").font(.headline)
            Text(engine.selectedObjectIndex < 0 ? "All objects" : engine.objectNames.indices.contains(engine.selectedObjectIndex) ? engine.objectNames[engine.selectedObjectIndex] : "Selection")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Transform", selection: Binding(get: { [.move, .rotate, .scale].contains(gizmoMode) ? gizmoMode : .move }, set: { gizmoMode = $0 })) {
                Text("Move").tag(GizmoMode.move)
                Text("Rotate").tag(GizmoMode.rotate)
                Text("Scale").tag(GizmoMode.scale)
            }.pickerStyle(.segmented)
                .onChange(of: gizmoMode) { mode in
                    if mode == .move { plateTouchMode = .move }
                    if mode == .rotate { plateTouchMode = .rotate }
                    if mode == .scale { plateTouchMode = .scale }
                }
            if gizmoMode == .scale {
                Toggle("Uniform scale", isOn: $uniformScale)
                numericField(uniformScale ? "Scale (%)" : "X scale (%)", text: $scaleX)
                if !uniformScale {
                    numericField("Y scale (%)", text: $scaleY)
                    numericField("Z scale (%)", text: $scaleZ)
                }
                Text("Relative to current size, along the object's local axes.").font(.caption).foregroundStyle(.secondary)
                Button("Apply scale") {
                    let values = uniformScale ? [scaleX, scaleX, scaleX] : [scaleX, scaleY, scaleZ]
                    let factors = values.compactMap { Float($0) }
                    guard factors.count == 3, factors.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 10000 }) else {
                        documents.errorMessage = "Enter scale percentages between 0 and 10000."; return
                    }
                    engine.scale(x: factors[0] / 100, y: factors[1] / 100, z: factors[2] / 100)
                    status = engine.lastMessage; showPlateInspector = false
                }.accessibilityIdentifier("apply-scale")
            } else if gizmoMode == .rotate {
                Picker("Axis", selection: $rotationAxis) { Text("X").tag(0); Text("Y").tag(1); Text("Z").tag(2) }
                    .pickerStyle(.segmented)
                numericField("Rotation (degrees)", text: $rotateAmount)
                Button("Apply rotation") {
                    guard let angle = Float(rotateAmount), angle.isFinite else { documents.errorMessage = "Enter a valid angle."; return }
                    engine.rotate(axis: rotationAxis, degrees: angle)
                    status = engine.lastMessage; showPlateInspector = false
                }
            } else {
                numericField("Move X (mm)", text: $moveX)
                numericField("Move Y (mm)", text: $moveY)
                numericField("Move Z (mm)", text: $moveZ)
                Button("Apply move") {
                    let values = [moveX, moveY, moveZ].compactMap { Float($0) }
                    guard values.count == 3, values.allSatisfy({ $0.isFinite }) else { documents.errorMessage = "Enter valid distances."; return }
                    engine.translate(dx: values[0], dy: values[1], dz: values[2])
                    status = engine.lastMessage; showPlateInspector = false
                }
            }
        }.disabled(!engine.hasModel))
    }

    private var objectPickerRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                objectChip(title: "All", selected: engine.selectedObjectIndex < 0) {
                    engine.selectedObjectIndex = -1
                }
                ForEach(Array(engine.objectNames.enumerated()), id: \.offset) { i, name in
                    objectChip(title: name, selected: engine.selectedObjectIndex == i) {
                        engine.selectedObjectIndex = i
                    }
                }
                toolChip("Duplicate", "plus.square.on.square") {
                    engine.duplicateSelected(); status = engine.lastMessage
                }
                toolChip("Delete", "trash") {
                    engine.deleteSelected(); status = engine.lastMessage
                }
                toolChip("Clear", "xmark.rectangle") {
                    engine.clearPlate(); status = engine.lastMessage
                }
            }
        }
    }

    private func objectChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(selected ? OrcaTheme.accent.opacity(0.25) : OrcaTheme.elevated)
                .foregroundStyle(selected ? OrcaTheme.accent : OrcaTheme.text)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(selected ? OrcaTheme.accent : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var plateTabsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(0..<engine.plateCount, id: \.self) { i in
                    Button {
                        engine.selectPlate(i)
                        status = engine.lastMessage
                        moveMode = false
                    } label: {
                        Text("Plate \(i + 1)")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                engine.currentPlateIndex == i
                                    ? OrcaTheme.accent.opacity(0.25)
                                    : OrcaTheme.elevated
                            )
                            .foregroundStyle(
                                engine.currentPlateIndex == i ? OrcaTheme.accent : OrcaTheme.text
                            )
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().stroke(
                                    engine.currentPlateIndex == i ? OrcaTheme.accent : Color.clear,
                                    lineWidth: 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    engine.addPlate()
                    status = engine.lastMessage
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .padding(8)
                        .background(OrcaTheme.elevated)
                        .foregroundStyle(OrcaTheme.accent)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                if engine.plateCount > 1 {
                    Button {
                        engine.removeCurrentPlate()
                        status = engine.lastMessage
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 12, weight: .bold))
                            .padding(8)
                            .background(OrcaTheme.elevated)
                            .foregroundStyle(OrcaTheme.danger)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var plateToolsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                toolChip(
                    "Drag",
                    "hand.draw",
                    selected: moveMode
                ) {
                    moveMode.toggle()
                    plateTouchMode = moveMode ? .move : .orbit
                    status = moveMode
                        ? "Move mode: drag on plate (orbit off)"
                        : "Orbit camera"
                }
                // Desktop gizmo strip (wx GLGizmos)
                ForEach(GizmoMode.allCases, id: \.self) { mode in
                    toolChip(mode.rawValue, gizmoIcon(mode), selected: gizmoMode == mode) {
                        gizmoMode = mode
                        showPlateInspector = false
                        moveMode = (mode == .move)
                        if mode == .move { plateTouchMode = .move }
                        else if mode == .rotate { plateTouchMode = .rotate }
                        else if mode == .scale { plateTouchMode = .scale }
                        else if mode == .layOnFace { plateTouchMode = .layOnFace }
                        else if mode == .select { plateTouchMode = .select }
                        if mode != .measure {
                            measurePointA = nil
                            measurePointB = nil
                            measureDistanceText = ""
                        }
                        if mode == .paintBrimEars {
                            brimEarErase = false
                            engine.refreshBrimEarOverlay()
                            status = "Brim ears: tap plate to place · r=\(String(format: "%.1f", brimEarRadius)) mm"
                        } else if let kind = paintKind(for: mode) {
                            paintStrokeNeedsUndo = true
                            engine.refreshPaintOverlay(kind: kind)
                            engine.refreshPaintStats(kind: kind)
                            status = "Paint: \(mode.rawValue) · brush \(String(format: "%.1f", paintBrushRadius)) mm"
                        } else {
                            engine.clearPaintOverlay()
                            status = "Gizmo: \(mode.rawValue)"
                        }
                    }
                }
                if gizmoMode == .rotate {
                    toolChip("↺ Z45", "rotate.left") {
                        engine.rotateZ(degrees: -45); status = engine.lastMessage
                    }
                    toolChip("↻ Z45", "rotate.right") {
                        engine.rotateZ(degrees: 45); status = engine.lastMessage
                    }
                }
                if gizmoMode == .scale {
                    toolChip("×0.9", "minus.magnifyingglass") {
                        engine.scale(factor: 0.9); status = engine.lastMessage
                    }
                    toolChip("×1.1", "plus.magnifyingglass") {
                        engine.scale(factor: 1.1); status = engine.lastMessage
                    }
                }
                if isFacetPaintGizmo {
                    paintToolChips
                }
                if gizmoMode == .paintBrimEars {
                    brimEarToolChips
                }
                toolChip("Center", "scope") { engine.centerOnBed(); status = engine.lastMessage }
                toolChip("Arrange", "square.grid.2x2") {
                    engine.pushUndoSnapshot(label: "arrange")
                    engine.arrange(); status = engine.lastMessage
                }
                toolChip("Deselect", "xmark.circle") {
                    engine.clearSelection(); status = engine.lastMessage
                }
                toolChip(
                    engine.explodeFactor > 0.001 ? "Collapse" : "Explode",
                    engine.explodeFactor > 0.001
                        ? "arrow.down.forward.and.arrow.up.backward"
                        : "arrow.up.backward.and.arrow.down.forward",
                    selected: engine.explodeFactor > 0.001
                ) {
                    let sp = Float(explodeSpacing) ?? 20
                    if engine.explodeFactor > 0.001 {
                        engine.explode(factor: 0, spacingMm: sp)
                    } else {
                        engine.explode(factor: 1.2, spacingMm: sp)
                    }
                    status = engine.lastMessage
                }
                if engine.explodeFactor > 0.001 {
                    toolChip("Explode+", "plus.magnifyingglass") {
                        let sp = Float(explodeSpacing) ?? 20
                        engine.explode(factor: engine.explodeFactor + 0.5, spacingMm: sp)
                        status = engine.lastMessage
                    }
                }
                toolChip("Text plate", "textformat") {
                    let sx = Float(textPlateX) ?? 40
                    let sy = Float(textPlateY) ?? 10
                    let sz = Float(textPlateZ) ?? 2
                    _ = engine.addTextPlate(name: textPlateName, sizeX: sx, sizeY: sy, sizeZ: sz)
                    status = engine.lastMessage
                }
                toolChip("Orient", "arrow.up.and.down.and.arrow.left.and.right") {
                    engine.autoOrient(); status = engine.lastMessage
                }
                toolChip("Fit bed", "arrow.down.right.and.arrow.up.left") {
                    engine.scaleToFit(); status = engine.lastMessage
                }
                toolChip("↺ Z", "rotate.left") { engine.rotateZ(degrees: -45); status = engine.lastMessage }
                toolChip("↻ Z", "rotate.right") { engine.rotateZ(degrees: 45); status = engine.lastMessage }
                toolChip("↺ X", "rotate.3d") { engine.rotate(axis: 0, degrees: -45); status = engine.lastMessage }
                toolChip("↻ Y", "rotate.3d") { engine.rotate(axis: 1, degrees: 45); status = engine.lastMessage }
                toolChip("Mirror X", "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                    engine.mirror(axis: 0); status = engine.lastMessage
                }
                toolChip("Mirror Y", "arrow.up.and.down.righttriangle.up.righttriangle.down") {
                    engine.mirror(axis: 1); status = engine.lastMessage
                }
                toolChip("×0.5", "minus.magnifyingglass") { engine.scale(factor: 0.5); status = engine.lastMessage }
                toolChip("×2", "plus.magnifyingglass") { engine.scale(factor: 2); status = engine.lastMessage }
                toolChip("←", "arrow.left") { engine.translate(dx: -10, dy: 0); status = engine.lastMessage }
                toolChip("→", "arrow.right") { engine.translate(dx: 10, dy: 0); status = engine.lastMessage }
                toolChip("↑", "arrow.up") { engine.translate(dx: 0, dy: 10); status = engine.lastMessage }
                toolChip("↓", "arrow.down") { engine.translate(dx: 0, dy: -10); status = engine.lastMessage }
            }
        }
    }

    private var activePlateTouchMode: PlateTouchMode {
        mainTab == .prepare ? plateTouchMode : (plateTouchMode == .pan ? .pan : .orbit)
    }

    private var plateStage: AnyView {
        AnyView(ZStack {
            PlateSceneView(
                mesh: engine.mesh,
                framingBounds: mainTab == .preview ? engine.previewBounds : nil,
                meshRevision: engine.meshRevision,
                objectMeshes: engine.objectMeshes,
                objectColors: engine.objectFilamentColors,
                paintedFilaments: engine.paintedFilaments,
                filamentColors: engine.projectDisplayColors,
                filamentPaintRevision: engine.filamentPaintRevision,
                selectedObjectIndex: engine.selectedObjectIndex,
                gcodeNode: engine.gcodePathNode,
                showGCode: mainTab == .preview,
                toolheadPosition: engine.previewToolheadPosition,
                toolheadMove: engine.previewToolheadMove,
                toolpathGeometry: engine.gcodeGeometry,
                showToolhead: engine.previewShowToolMarker,
                smoothToolhead: engine.smoothToolheadMovement,
                showShell: engine.previewShowShell,
                bedSize: mainTab == .preview && engine.previewFromFile ? (engine.previewBedSize ?? engine.bedSize) : engine.bedSize,
                bedTexturePath: mainTab == .preview && engine.previewFromFile ? nil : engine.bedTexturePath,
                accent: UIColor(red: 0, green: 150 / 255, blue: 136 / 255, alpha: 1),
                touchMode: activePlateTouchMode,
                fitRequest: fitCameraRequest,
                cameraView: cameraView,
                projection: usePerspectiveCamera ? .perspective : .orthographic,
                onCameraView: selectCameraView,
                onOrbitBegin: {
                    usePerspectiveCamera = cameraViewPolicy.orbit(automatic: autoPerspective,
                        current: usePerspectiveCamera ? .perspective : .orthographic) == .perspective
                },
                rotationAxis: rotationAxis,
                onScaleCommit: { factor, index in
                    engine.scale(factor: factor, index: index)
                    status = engine.lastMessage
                },
                onRotateCommit: { degrees, index in
                    engine.rotate(axis: rotationAxis, degrees: degrees, index: index)
                    status = engine.lastMessage
                },
                measureMode: gizmoMode == .measure && mainTab == .prepare,
                paintMode: isPaintGizmo && mainTab == .prepare && engine.hasModel,
                paintOverlay: isPaintGizmo && mainTab == .prepare ? engine.paintOverlayMesh : nil,
                paintOverlayColor: paintOverlayUIColor,
                onDragCommit: { dx, dy, objIdx in
                    // Use index captured at drag start — never rely on post-tap selection
                    let idx = objIdx >= 0 ? objIdx : nil
                    if let idx { engine.selectObject(at: idx) }
                    engine.translate(dx: dx, dy: dy, index: idx, recordUndo: true)
                    status = engine.lastMessage
                },
                onDragLive: { dx, dy in
                    status = String(format: "Drag Δ%.1f, %.1f mm", dx, dy)
                },
                onMeasurePick: { handleMeasurePick($0) },
                onPaintHit: { pt, isBegin in handlePaintHit(pt, isBegin: isBegin) },
                onSelectObject: { idx in
                    if idx < 0 {
                        engine.clearSelection()
                    } else {
                        // Only toggle-deselect on intentional re-tap (not after drag)
                        engine.selectObject(at: idx)
                    }
                    status = engine.lastMessage
                },
                onFacePick: { index, point in
                    engine.selectedObjectIndex = index
                    Task { @MainActor in
                        if await engine.editMesh(.layOnFace(point)) == false { operationError = engine.lastMessage }
                        status = engine.lastMessage
                    }
                }
            )
            .overlay(alignment: .bottom) {
                if mainTab != .device {
                    VStack(spacing: 4) {
                    HStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(PlateTouchMode.allCases) { mode in
                                if mainTab == .prepare || mode == .orbit || mode == .pan {
                                    toolChip(mode.rawValue, mode.icon, selected: activePlateTouchMode == mode) {
                                        plateTouchMode = mode
                                        gizmoMode = mode == .move ? .move : mode == .rotate ? .rotate : mode == .scale ? .scale : mode == .layOnFace ? .layOnFace : .select
                                        moveMode = mode == .move
                                        engine.clearPaintOverlay()
                                    }
                                }
                            }
                            if mainTab == .prepare {
                                toolChip("Add", "plus") { showModelLibrary = true }.accessibilityIdentifier("model-library-shortcut")
                                toolChip("Transform", "slider.horizontal.3") { showPlateInspector = true }
                                toolChip("Mesh tools", "cube.transparent") { showMeshTools = true }
                                toolChip("Layer height", "slider.vertical.3") { showLayerHeights = true }
                                    .disabled(!engine.objectNames.indices.contains(engine.selectedObjectIndex))
                                    .disabled(!engine.hasModel).accessibilityIdentifier("mesh-tools-shortcut")
                            }
                        }.padding(8)
                    }
                    modelInformationMenu
                    toolChip("Home", "house") { selectCameraView(.home) }
                        .accessibilityIdentifier("camera-home").padding(.trailing, 8)
                    }
                    if activePlateTouchMode == .rotate {
                        Picker("Rotation axis", selection: $rotationAxis) {
                            Text("X").tag(0)
                            Text("Y").tag(1)
                            Text("Z").tag(2)
                        }.pickerStyle(.segmented).padding(.horizontal, 8).padding(.bottom, 8)
                    }
                    }.background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 12)).padding(8)
                }
            }
            .overlay {
                if mainTab == .preview && engine.gcodeGeometry == nil {
                    VStack(spacing: 12) {
                        Image(systemName: "square.3.layers.3d").font(.largeTitle)
                        Text("Slice the plate to preview toolpaths")
                        Button("Slice plate", action: sliceNow).buttonStyle(.borderedProminent)
                            .disabled(!engine.hasModel || isSlicing)
                    }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .overlay(alignment: .topTrailing) {
                gizmoStatusBadges.padding(12)
            }
            .overlay {
                if mainTab == .device {
                    devicePlaceholder
                }
            }
        })
    }

    private var modelInformationMenu: some View {
        Menu {
            if mainTab == .preview && engine.previewFromFile {
                if let url = engine.gcodeURL { Text(url.lastPathComponent) }
                Text("G-code preview")
            } else {
                if let name = engine.modelName { Text(name) }
                if !engine.boundsText.isEmpty { Text(engine.boundsText) }
                if !engine.selectedPrinter.isEmpty { Text(engine.selectedPrinter) }
            }
            if !status.isEmpty { Text(status) }
            Text(engine.lastSliceStatsText)
            Button("Fit model") { fitCameraRequest = UUID() }
        } label: {
            Image(systemName: "info.circle").frame(width: 44, height: 44)
        }.accessibilityLabel(Text("Model and slice information"))
    }

    private func selectCameraView(_ view: CameraPreset) {
        usePerspectiveCamera = cameraViewPolicy.select(view, automatic: autoPerspective,
            current: usePerspectiveCamera ? .perspective : .orthographic) == .perspective
        cameraView = view
        fitCameraRequest = UUID()
    }

    private var projectionSelection: Binding<Bool> {
        Binding(get: { usePerspectiveCamera }, set: {
            cameraViewPolicy.reset()
            usePerspectiveCamera = $0
        })
    }

    private var automaticPerspectiveSelection: Binding<Bool> {
        Binding(get: { autoPerspective }, set: {
            cameraViewPolicy.reset()
            autoPerspective = $0
        })
    }

    private var cameraViewMenu: some View {
        Menu("View") {
            Button { selectCameraView(.home) } label: { Label("Home view", systemImage: "house") }
            ForEach(CameraPreset.allCases.filter { $0 != .home }, id: \.rawValue) { view in
                Button("\(view.rawValue) view") { selectCameraView(view) }
            }
            Divider()
            Picker("Projection", selection: projectionSelection) {
                Text("Perspective").tag(true)
                Text("Orthographic").tag(false)
            }
            Toggle("Auto Perspective", isOn: automaticPerspectiveSelection)
        }.accessibilityIdentifier("camera-view-menu")
    }

    @ViewBuilder
    private var paintToolChips: some View {
        Group {
            if gizmoMode == .paintSupport || gizmoMode == .paintSeam {
                toolChip("Enforce", "plus.circle", selected: paintToolState == 1) {
                    paintToolState = 1; status = "Brush: enforcer"
                }
                toolChip("Block", "minus.circle", selected: paintToolState == 2) {
                    paintToolState = 2; status = "Brush: blocker"
                }
            } else if gizmoMode == .paintMMU {
                toolChip("Filament \(paintMMUExtruder)", "paintpalette", selected: paintToolState != 0) {
                    paintToolState = 1
                    paintMMUExtruder = paintMMUExtruder >= min(engine.maximumPaintFilaments, engine.projectFilamentColors.count) ? 1 : paintMMUExtruder + 1
                    status = "MMU extruder \(paintMMUExtruder)"
                }
            } else if gizmoMode == .paintFuzzy {
                toolChip("Fuzzy", "scribble.variable", selected: paintToolState == 1) {
                    paintToolState = 1; status = "Brush: fuzzy skin"
                }
            }
            toolChip("Erase", "eraser", selected: paintToolState == 0) {
                paintToolState = 0; status = "Brush: erase"
            }
            toolChip("R \(String(format: "%.0f", paintBrushRadius))", "circle.dashed") {
                // Cycle brush radius 1 → 2 → 4 → 8 → 1
                if paintBrushRadius < 1.5 { paintBrushRadius = 2 }
                else if paintBrushRadius < 3 { paintBrushRadius = 4 }
                else if paintBrushRadius < 6 { paintBrushRadius = 8 }
                else { paintBrushRadius = 1 }
                status = String(format: "Brush radius %.0f mm", paintBrushRadius)
            }
            toolChip("Fill all", "paintbrush.fill") {
                guard let kind = activePaintKind else { return }
                _ = engine.paintFill(kind: kind, state: currentPaintState)
                status = engine.lastMessage
            }
            toolChip("Clear", "trash") {
                guard let kind = activePaintKind else { return }
                _ = engine.paintClear(kind: kind)
                status = engine.lastMessage
            }
        }
    }

    @ViewBuilder
    private var brimEarToolChips: some View {
        Group {
            toolChip("Add", "plus.circle", selected: !brimEarErase) {
                brimEarErase = false
                status = "Brim ear: tap to place"
            }
            toolChip("Remove", "minus.circle", selected: brimEarErase) {
                brimEarErase = true
                status = "Brim ear: tap near marker to remove"
            }
            toolChip("R \(String(format: "%.0f", brimEarRadius))", "circle.dashed") {
                if brimEarRadius < 3 { brimEarRadius = 5 }
                else if brimEarRadius < 7 { brimEarRadius = 8 }
                else if brimEarRadius < 12 { brimEarRadius = 12 }
                else { brimEarRadius = 3 }
                status = String(format: "Brim ear radius %.0f mm", brimEarRadius)
            }
            toolChip("Clear", "trash") {
                _ = engine.brimEarClear()
                status = engine.lastMessage
            }
        }
    }

    private var gizmoStatusBadges: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if activePlateTouchMode == .layOnFace && mainTab == .prepare {
                Text("Tap a flat outer face · drag to orbit")
                    .font(.caption).padding(8)
                    .background(.regularMaterial, in: Capsule())
            }
            if (moveMode || gizmoMode == .move) && mainTab == .prepare && engine.hasModel {
                Text("Move gizmo · orbit off")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OrcaTheme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(OrcaTheme.panel.opacity(0.95))
                    .clipShape(Capsule())
            }
            if gizmoMode == .measure && !measureDistanceText.isEmpty {
                Text(measureDistanceText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(OrcaTheme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(OrcaTheme.panel.opacity(0.95))
                    .clipShape(Capsule())
            }
            if isPaintGizmo && mainTab == .prepare {
                let fallback: String = {
                    if gizmoMode == .paintBrimEars {
                        return "Brim ears · \(engine.brimEarCount) · r=\(String(format: "%.0f", brimEarRadius)) mm"
                    }
                    return "\(gizmoMode.rawValue) · r=\(String(format: "%.0f", paintBrushRadius)) mm"
                }()
                Text(engine.paintStatsText.isEmpty ? fallback : engine.paintStatsText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OrcaTheme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(OrcaTheme.panel.opacity(0.95))
                    .clipShape(Capsule())
            }
        }
    }

    private func handleMeasurePick(_ pt: SIMD3<Float>) {
        if measurePointA == nil || measurePointB != nil {
            measurePointA = pt
            measurePointB = nil
            measureDistanceText = String(format: "A (%.1f, %.1f, %.1f)", pt.x, pt.y, pt.z)
            return
        }
        measurePointB = pt
        guard let a = measurePointA else { return }
        let dx = pt.x - a.x
        let dy = pt.y - a.y
        let dz = pt.z - a.z
        let d = sqrt(dx * dx + dy * dy + dz * dz)
        measureDistanceText = String(format: "Distance %.2f mm", d)
        status = measureDistanceText
    }

    private func handlePaintHit(_ pt: SIMD3<Float>, isBegin: Bool) {
        if gizmoMode == .paintBrimEars {
            // Point markers: only act on stroke begin (tap), not drag samples
            guard isBegin else { return }
            if brimEarErase {
                _ = engine.brimEarRemoveNearest(x: pt.x, y: pt.y, maxDistMm: max(brimEarRadius * 2, 8))
            } else {
                _ = engine.brimEarAdd(x: pt.x, y: pt.y, radiusMm: brimEarRadius)
            }
            status = engine.lastMessage
            return
        }
        guard let kind = activePaintKind else { return }
        if isBegin { paintStrokeNeedsUndo = true }
        let record = paintStrokeNeedsUndo
        let n = engine.paintAt(
            x: pt.x, y: pt.y, z: pt.z,
            kind: kind,
            state: currentPaintState,
            radiusMm: paintBrushRadius,
            recordUndo: record
        )
        if record && n >= 0 { paintStrokeNeedsUndo = false }
        if n > 0 {
            status = engine.lastMessage
        }
    }

    private func paintKind(for mode: GizmoMode) -> OrcaEngine.PaintKind? {
        switch mode {
        case .paintSupport: return .support
        case .paintSeam: return .seam
        case .paintMMU: return .mmu
        case .paintFuzzy: return .fuzzy
        default: return nil
        }
    }

    private func gizmoIcon(_ mode: GizmoMode) -> String {
        switch mode {
        case .select: return "cursorarrow"
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .rotate: return "rotate.3d"
        case .scale: return "arrow.up.left.and.arrow.down.right"
        case .layOnFace: return "cube.transparent"
        case .measure: return "ruler"
        case .paintSupport: return "paintbrush.pointed"
        case .paintSeam: return "line.diagonal"
        case .paintMMU: return "paintpalette"
        case .paintFuzzy: return "scribble.variable"
        case .paintBrimEars: return "circle.bottomhalf.filled"
        }
    }

    private var configWizardSheet: AnyView {
        AnyView(NavigationStack {
            List {
                Section("Welcome") {
                    Text("First-run setup (desktop ConfigWizard lite). Language, region, preferred vendors, and last printer are stored in UserDefaults.")
                        .font(.footnote)
                        .foregroundStyle(OrcaTheme.muted)
                        .listRowBackground(OrcaTheme.panel)
                }
                Section("Language") {
                    Picker("Language", selection: $wizardLanguage) {
                        Text("English").tag("en")
                        Text("中文").tag("zh")
                        Text("Deutsch").tag("de")
                        Text("Français").tag("fr")
                        Text("Español").tag("es")
                        Text("日本語").tag("ja")
                    }
                    .listRowBackground(OrcaTheme.panel)
                }
                Section("Region") {
                    Picker("Region", selection: $wizardRegion) {
                        Text("International").tag("International")
                        Text("North America").tag("North America")
                        Text("Europe").tag("Europe")
                        Text("China").tag("China")
                        Text("Japan").tag("Japan")
                        Text("Other").tag("Other")
                    }
                    .listRowBackground(OrcaTheme.panel)
                }
                Section("Preferred vendors (multi-select)") {
                    if engine.vendorList.isEmpty {
                        Text(engine.presetsLoading ? "Loading profiles…" : "Profiles load after Continue — you can re-open Setup anytime.")
                            .foregroundStyle(OrcaTheme.muted)
                            .listRowBackground(OrcaTheme.panel)
                    } else {
                        ForEach(engine.vendorList.prefix(60), id: \.self) { v in
                            Button {
                                if wizardVendors.contains(v) { wizardVendors.remove(v) }
                                else { wizardVendors.insert(v) }
                            } label: {
                                HStack {
                                    Text(v).foregroundStyle(OrcaTheme.text)
                                    Spacer()
                                    if wizardVendors.contains(v) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(OrcaTheme.accent)
                                    }
                                }
                            }
                            .listRowBackground(OrcaTheme.panel)
                        }
                    }
                }
                if !engine.selectedPrinter.isEmpty {
                    Section("Last printer") {
                        labeled("Restored", engine.selectedPrinter)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(OrcaTheme.bg)
            .navigationTitle("Setup wizard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Continue") {
                        OrcaEngine.appLanguage = wizardLanguage
                        OrcaEngine.appRegion = wizardRegion
                        OrcaEngine.preferredVendors = Array(wizardVendors).sorted()
                        OrcaEngine.wizardCompleted = true
                        showWizard = false
                        status = "Setup saved · \(wizardVendors.count) vendor(s) preferred"
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(OrcaTheme.accent)
                }
            }
            .task {
                if engine.automaticProfileLoading && engine.vendorList.isEmpty && !engine.presetsLoading {
                    await engine.loadAllSystemPresets()
                }
            }
        })
    }

    private var preferencesSheet: AnyView {
        AnyView(NavigationStack {
            List {
                Section("Appearance") {
                    Toggle("Dark mode (forced)", isOn: .constant(true))
                        .listRowBackground(OrcaTheme.panel)
                    labeled("Theme", "Orca desktop dark")
                }
                Section("3D view") {
                    Picker("Projection", selection: projectionSelection) {
                        Text("Perspective").tag(true)
                        Text("Orthographic").tag(false)
                    }
                    Toggle("Auto Perspective", isOn: automaticPerspectiveSelection)
                }
                Section("Setup") {
                    Button("Show setup wizard again") {
                        OrcaEngine.wizardCompleted = false
                        showPreferences = false
                        showWizard = true
                    }
                    .foregroundStyle(OrcaTheme.accent)
                    .listRowBackground(OrcaTheme.panel)
                    Button("Export user presets (zip)") {
                        if let url = engine.exportPresetBundleZip() {
                            presetBundleShareURL = url
                            status = engine.lastMessage
                            exportUserPresetsZip() // also present system share sheet
                        } else {
                            status = engine.lastMessage
                        }
                    }
                    .foregroundStyle(OrcaTheme.accent)
                    .listRowBackground(OrcaTheme.panel)
                    if let url = presetBundleShareURL {
                        ShareLink(item: url) {
                            Label("Share \(url.lastPathComponent)", systemImage: "square.and.arrow.up")
                                .foregroundStyle(OrcaTheme.accent)
                        }
                        .listRowBackground(OrcaTheme.panel)
                    }
                }
                Section("Slicing defaults") {
                    labeled("Compatible filter", engine.compatibleOnly ? "On" : "Off")
                    Toggle("Compatible process/filament only", isOn: $engine.compatibleOnly)
                        .listRowBackground(OrcaTheme.panel)
                        .onChange(of: engine.compatibleOnly) { on in
                            engine.setCompatibleOnly(on)
                        }
                }
                Section("Paths") {
                    labeled("Data", "Documents/OrcaSlicer")
                    labeled("Profiles", "Bundle · profiles/")
                }
                Section("Engine") {
                    Text(engine.version)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(OrcaTheme.muted)
                        .listRowBackground(OrcaTheme.panel)
                }
            }
            .scrollContentBackground(.hidden)
            .background(OrcaTheme.bg)
            .navigationTitle("Preferences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showPreferences = false }
                        .foregroundStyle(OrcaTheme.accent)
                }
            }
        })
    }

    private var aboutSheet: AnyView {
        AnyView(NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "seal.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(OrcaTheme.accent)
                Text("OrcaSlicer")
                    .font(.title.bold())
                    .foregroundStyle(OrcaTheme.text)
                Text(engine.version)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(OrcaTheme.muted)
                    .multilineTextAlignment(.center)
                Text("Build \(Bundle.main.object(forInfoDictionaryKey: "OrcaBuildRevision") as? String ?? "development")")
                    .font(.caption.monospaced())
                Text("iOS shell (SwiftUI) · official libslic3r engine\nAGPL-3.0 · replaces desktop wxWidgets UI on mobile")
                    .font(.footnote)
                    .foregroundStyle(OrcaTheme.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Spacer()
            }
            .padding(.top, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OrcaTheme.bg)
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showAbout = false }
                        .foregroundStyle(OrcaTheme.accent)
                }
            }
        })
    }

    private var objectSettingsSheet: AnyView {
        AnyView(ProcessSettingsBrowser(engine: engine, objects: true, onClose: { showObjectSettings = false }) {
            status = engine.lastMessage
        })
    }

    private func toolChip(
        _ title: String,
        _ systemImage: String,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selected ? OrcaTheme.accent.opacity(0.25) : OrcaTheme.elevated)
            .foregroundStyle(selected ? OrcaTheme.accent : OrcaTheme.text)
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(selected ? OrcaTheme.accent : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var lowerPreviewLayer: Int {
        engine.previewLayerHeights.firstIndex(where: { $0 >= engine.previewMinZ - 0.001 }) ?? 0
    }
    private var upperPreviewLayer: Int {
        engine.previewLayerHeights.lastIndex(where: { $0 <= engine.previewMaxZ + 0.001 }) ?? 0
    }
    private var upperLayerBinding: Binding<Double> {
        Binding(get: { Double(upperPreviewLayer) }, set: { value in
            let i = Int(value.rounded())
            guard engine.previewLayerHeights.indices.contains(i) else { return }
            let z = engine.previewLayerHeights[i]
            guard z != engine.previewMaxZ else { return }
            engine.previewMaxZ = z
            engine.previewMinZ = min(engine.previewMinZ, z)
            engine.resetPreviewSequence()
            engine.requestPreviewLayer()
        })
    }

    private var previewLayerBar: some View {
        VStack(spacing: 2) {
            HStack {
                Text("Layer \(upperPreviewLayer + 1) / \(engine.previewLayerHeights.count)")
                Spacer()
                Text(String(format: "Z %.2f mm", engine.previewMaxZ))
            }.font(.caption.monospacedDigit())
            Slider(value: upperLayerBinding, in: 0...Double(max(1, engine.previewLayerHeights.count - 1)), step: 1)
                .disabled(engine.previewLayerHeights.count < 2).tint(OrcaTheme.accent)
                .accessibilityLabel("Upper preview layer")
        }
    }

    // An in-workspace panel keeps all three main tabs reachable even at its
    // largest size. A modal large detent covered them on compact devices.
    private var previewControlsPanel: AnyView {
        AnyView(VStack(spacing: 0) {
            HStack {
                Text("Preview controls").font(.subheadline.weight(.semibold))
                Spacer()
                Button { showPreviewControls = false } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }
                    .accessibilityLabel("Hide preview controls")
            }.padding(.horizontal, 16)
                .contentShape(Rectangle())
                .gesture(DragGesture().onEnded { if $0.translation.height > 35 { showPreviewControls = false } })
            ScrollView { layerScrubber }.accessibilityIdentifier("preview-controls-content")
        }.background(OrcaTheme.panel))
    }

    private var toolpathScrubber: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let geometry = engine.gcodeGeometry {
                let cursor = max(-1, engine.previewToolheadMove ?? Double(min(engine.previewThroughMove, max(0, geometry.moveCount - 1))))
                HStack {
                    Text("Toolhead position").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("Move \((cursor + 1).formatted(.number.precision(.fractionLength(0...2)))) / \(geometry.moveCount)")
                        .font(.caption.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                }
                HStack(spacing: 8) {
                    Button { engine.stepToolhead(-1) } label: { Image(systemName: "backward.end.fill").frame(width: 44, height: 44) }
                        .accessibilityLabel("Previous toolpath move").disabled(cursor <= -1)
                    ManualToolpathScrubber(value: Binding(
                        get: { cursor },
                        set: { engine.scrubToolhead(to: $0) }), range: -1...Double(max(0, geometry.moveCount - 1)),
                        onEditingChanged: { engine.setToolheadScrubbing($0) })
                    Button { engine.stepToolhead(1) } label: { Image(systemName: "forward.end.fill").frame(width: 44, height: 44) }
                        .accessibilityLabel("Next toolpath move").disabled(cursor >= Double(geometry.moveCount - 1))
                }
                HStack {
                    Button {
                        if engine.previewPlaybackRunning { engine.pauseToolheadPlayback() }
                        else { engine.playToolhead() }
                    } label: {
                        Label(engine.previewPlaybackRunning ? "Pause" : "Play",
                              systemImage: engine.previewPlaybackRunning ? "pause.fill" : "play.fill")
                    }.accessibilityIdentifier("toolhead-playback")
                    Spacer()
                    Picker("Playback speed", selection: $engine.previewPlaybackRate) {
                        Text("1×").tag(1.0)
                        Text("10×").tag(10.0)
                        Text("100×").tag(100.0)
                    }.pickerStyle(.menu)
                }
                Text("Scrub or play to see each move. Playback uses G-code feedrates.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Smooth toolhead movement", isOn: $engine.smoothToolheadMovement)
                Button("Show complete toolpath") {
                    engine.resetPreviewSequence()
                }
            }
        }
    }

    private var layerScrubber: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Color by").font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Color by", selection: Binding(
                get: { engine.previewColorMode },
                set: { engine.previewColorMode = $0; engine.requestPreviewLayer() }
            )) {
                ForEach(GCodePathGeometry.ColorMode.allCases) { mode in Text(mode.label).tag(mode) }
            }.pickerStyle(.menu).labelsHidden()
            }

            if engine.gcodeGeometry == nil { Text("Slice the plate to preview toolpaths.") }
            else {
                if engine.previewFromFile, let url = engine.gcodeURL { Text(url.lastPathComponent).font(.headline) }
                Text(engine.lastSliceStatsText).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                if engine.previewIsReduced {
                    Text("Toolpaths are reduced to fit available memory.").font(.caption).foregroundStyle(.secondary)
                }
                toolpathScrubber
                Text("Lower layer \(lowerPreviewLayer + 1)").font(.caption)
                Slider(value: Binding(get: { Double(lowerPreviewLayer) }, set: { value in
                    let i = Int(value.rounded())
                    guard engine.previewLayerHeights.indices.contains(i) else { return }
                    let z = engine.previewLayerHeights[i]
                    guard z != engine.previewMinZ else { return }
                    engine.previewMinZ = z
                    engine.previewMaxZ = max(engine.previewMaxZ, z)
                    engine.resetPreviewSequence()
                    engine.requestPreviewLayer()
                }), in: 0...Double(max(1, engine.previewLayerHeights.count - 1)), step: 1)
                    .disabled(engine.previewLayerHeights.count < 2)
                Button("Show all layers") {
                    engine.previewMinZ = engine.gcodeZMin
                    engine.previewMaxZ = engine.gcodeZMax
                    engine.resetPreviewSequence()
                    engine.requestPreviewLayer()
                }
            }
            if engine.previewLightweight || (engine.gcodeGeometry?.moveCount ?? 0) > 250_000 {
                Text("Memory-saving preview · all toolpaths retained").font(.caption).foregroundStyle(.secondary)
            }
            if engine.previewBuilding {
                ProgressView("Updating toolpaths…").accessibilityIdentifier("preview-building")
            }
            if let geometry = engine.gcodeGeometry {
                Button("Show current layer only") {
                    engine.previewMinZ = engine.previewMaxZ
                    engine.resetPreviewSequence()
                    engine.requestPreviewLayer()
                }
                DisclosureGroup("Line types") {
                    HStack {
                        Button("All") { engine.previewHiddenFeatures = []; engine.requestPreviewLayer() }
                        Button("None") { engine.previewHiddenFeatures = Set(geometry.features); engine.requestPreviewLayer() }
                    }.buttonStyle(.bordered)
                    ForEach(geometry.features, id: \.self) { feature in
                        Toggle(isOn: Binding(get: { !engine.previewHiddenFeatures.contains(feature) }, set: { visible in
                            if visible { engine.previewHiddenFeatures.remove(feature) }
                            else { engine.previewHiddenFeatures.insert(feature) }
                            engine.requestPreviewLayer()
                        })) {
                            Label { Text(feature) } icon: {
                                Circle().fill(Color(uiColor: GCodePathGeometry.color(for: feature))).frame(width: 10, height: 10)
                            }
                        }
                    }
                }.accessibilityIdentifier("preview-line-types")
                DisclosureGroup("Options") {
                    if !engine.previewFromFile { Toggle("Model shell", isOn: $engine.previewShowShell) }
                    Toggle("Tool marker", isOn: Binding(get: { engine.previewShowToolMarker }, set: {
                        engine.previewShowToolMarker = $0; engine.requestPreviewLayer()
                    }))
                    Toggle("Center of gravity", isOn: Binding(get: { engine.previewShowCenterOfGravity }, set: {
                        engine.previewShowCenterOfGravity = $0; engine.requestPreviewLayer()
                    }))
                    ForEach(GCodePathGeometry.MoveKind.allCases.filter { $0 != .extrude }) { kind in
                        Toggle(kind.label, isOn: Binding(get: { engine.previewEnabledMoves.contains(kind) }, set: { visible in
                            if visible { engine.previewEnabledMoves.insert(kind) }
                            else { engine.previewEnabledMoves.remove(kind) }
                            engine.requestPreviewLayer()
                        }))
                    }
                }.accessibilityIdentifier("preview-options")
                DisclosureGroup("Filaments and tools") {
                    ForEach(geometry.toolIDs, id: \.self) { tool in
                        Toggle("Tool \(tool + 1)", isOn: Binding(get: { !engine.previewHiddenTools.contains(tool) }, set: { visible in
                            if visible { engine.previewHiddenTools.remove(tool) }
                            else { engine.previewHiddenTools.insert(tool) }
                            engine.requestPreviewLayer()
                        }))
                    }
                    ForEach(geometry.filamentIDs, id: \.self) { filament in
                        Toggle("Filament \(filament + 1)", isOn: Binding(get: { !engine.previewHiddenFilaments.contains(filament) }, set: { visible in
                            if visible { engine.previewHiddenFilaments.remove(filament) }
                            else { engine.previewHiddenFilaments.insert(filament) }
                            engine.requestPreviewLayer()
                        }))
                    }
                }

            }

            if engine.previewColorMode.isNumeric, let geometry = engine.gcodeGeometry {
                let range = geometry.colorRange(for: engine.previewColorMode)
                let unit = engine.previewColorMode.unit
                LinearGradient(colors: [Color(uiColor: GCodePathGeometry.gradientColor(t: 0)),
                    Color(uiColor: GCodePathGeometry.gradientColor(t: 0.25)),
                    Color(uiColor: GCodePathGeometry.gradientColor(t: 0.5)),
                    Color(uiColor: GCodePathGeometry.gradientColor(t: 0.75)),
                    Color(uiColor: GCodePathGeometry.gradientColor(t: 1))], startPoint: .leading, endPoint: .trailing)
                    .frame(height: 8).clipShape(Capsule())
                HStack {
                    Text(String(format: "%.2f %@", range.lowerBound, unit))
                    Spacer()
                    Text(String(format: "%.2f %@", range.upperBound, unit))
                }.font(.caption.monospacedDigit())
            }

            // Analysis strip when stats available
            if !engine.lastAvgLayerTimeText.isEmpty || !engine.filamentByRole.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if !engine.lastAvgLayerTimeText.isEmpty {
                        Text(engine.lastAvgLayerTimeText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(OrcaTheme.muted)
                    }
                    if !engine.filamentByRole.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(engine.filamentByRole.enumerated()), id: \.offset) { _, r in
                                    Text(String(format: "%@: %.1fg", r.name, r.grams))
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(OrcaTheme.elevated)
                                        .foregroundStyle(OrcaTheme.text)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(OrcaTheme.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(OrcaTheme.border).frame(height: 1)
        }
    }

    @State private var topShells = "3"
    @State private var bottomShells = "3"
    @State private var supportOn = false
    @State private var brimType = "auto_brim"
    @State private var brimWidth = "5"
    @State private var supportType = "normal(auto)"
    @State private var wallGenerator = "arachne"
    @State private var seamPosition = "aligned"
    @State private var ironingType = "no ironing"
    @State private var infillPattern = "grid"
    @State private var outerWallSpeed = "60"
    @State private var sparseSpeed = "100"
    @State private var filamentDiameter = "1.75"
    @State private var printerSearch = ""
    @State private var processSearch = ""
    @State private var filamentSearch = ""
    @State private var vendorFilter = ""
    @State private var showPrinterPicker = false
    @State private var showProcessPicker = false
    @State private var showFilamentPicker = false
    @State private var filamentSlotForPicker = 0
    @State private var showAllSettings = false
    @State private var userProcessName = ""
    @State private var userFilamentName = ""
    @State private var cloneNx = "2"
    @State private var cloneNy = "2"
    @State private var cutZText = ""
    @State private var simplifyTargetFaces = ""
    @State private var cutPlaneTilt = "0" // degrees from horizontal about X
    @State private var booleanOtherText = ""
    // Calibration sheet fields
    @State private var calibTempStart = "230"
    @State private var calibTempEnd = "190"
    @State private var calibPAStart = "0"
    @State private var calibPAEnd = "0.1"
    @State private var calibPAStep = "0.002"
    @State private var calibRetractStart = "0"
    @State private var calibRetractEnd = "2"
    @State private var calibRetractStep = "0.1"
    @State private var calibFlowPass = 1
    @State private var calibFlowLinear = true

    private var calibrationSheet: AnyView {
        AnyView(NavigationStack {
            List {
                if engine.calibMode != 0 {
                    Section {
                        Text(engine.calibSummary)
                            .foregroundStyle(OrcaTheme.accent)
                            .listRowBackground(OrcaTheme.panel)
                        Button(role: .destructive) {
                            _ = engine.clearCalib()
                            status = engine.lastMessage
                        } label: {
                            Text("Clear calibration mode")
                        }
                        .listRowBackground(OrcaTheme.panel)
                    } header: {
                        Text("Active")
                    }
                }

                Section {
                    HStack {
                        Text("Start °C").foregroundStyle(OrcaTheme.muted)
                        TextField("230", text: $calibTempStart)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(OrcaTheme.text)
                    }
                    .listRowBackground(OrcaTheme.panel)
                    HStack {
                        Text("End °C").foregroundStyle(OrcaTheme.muted)
                        TextField("190", text: $calibTempEnd)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(OrcaTheme.text)
                    }
                    .listRowBackground(OrcaTheme.panel)
                    Button {
                        let s = Double(calibTempStart) ?? 230
                        let e = Double(calibTempEnd) ?? 190
                        if engine.prepareTempTower(startC: s, endC: e) {
                            status = engine.lastMessage
                            showCalibration = false
                            showProcess = false
                            mainTab = .prepare
                        } else {
                            status = engine.lastMessage
                        }
                    } label: {
                        Text("Load temp tower + set Calib_Temp_Tower")
                            .foregroundStyle(OrcaTheme.accent)
                    }
                    .listRowBackground(OrcaTheme.panel)
                } header: {
                    Text("Temperature tower")
                } footer: {
                    Text("Official temperature_tower.drc · nozzle temp steps −5 °C per block via Print::set_calib_params.")
                        .font(.system(size: 11))
                }

                Section {
                    Toggle("Linear (YOLO) flow", isOn: $calibFlowLinear)
                        .tint(OrcaTheme.accent)
                        .listRowBackground(OrcaTheme.panel)
                    Picker("Pass", selection: $calibFlowPass) {
                        Text("Pass 1").tag(1)
                        Text("Pass 2 (fine)").tag(2)
                    }
                    .listRowBackground(OrcaTheme.panel)
                    Button {
                        if engine.prepareFlowRate(pass: calibFlowPass, linear: calibFlowLinear) {
                            status = engine.lastMessage
                            showCalibration = false
                            showProcess = false
                            mainTab = .prepare
                        } else {
                            status = engine.lastMessage
                        }
                    } label: {
                        Text("Load flow-rate test model")
                            .foregroundStyle(OrcaTheme.accent)
                    }
                    .listRowBackground(OrcaTheme.panel)
                } header: {
                    Text("Flow rate")
                } footer: {
                    Text("Official Orca LinearFlow / flowrate-test 3MF · objects use per-modifier print_flow_ratio.")
                        .font(.system(size: 11))
                }

                Section {
                    HStack {
                        Text("PA start").foregroundStyle(OrcaTheme.muted)
                        TextField("0", text: $calibPAStart)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(OrcaTheme.text)
                    }
                    .listRowBackground(OrcaTheme.panel)
                    HStack {
                        Text("PA end").foregroundStyle(OrcaTheme.muted)
                        TextField("0.1", text: $calibPAEnd)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(OrcaTheme.text)
                    }
                    .listRowBackground(OrcaTheme.panel)
                    HStack {
                        Text("Step").foregroundStyle(OrcaTheme.muted)
                        TextField("0.002", text: $calibPAStep)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(OrcaTheme.text)
                    }
                    .listRowBackground(OrcaTheme.panel)
                    Button {
                        let s = Double(calibPAStart) ?? 0
                        let e = Double(calibPAEnd) ?? 0.1
                        let st = Double(calibPAStep) ?? 0.002
                        if engine.preparePressureAdvance(start: s, end: e, step: st) {
                            status = engine.lastMessage
                            showCalibration = false
                            showProcess = false
                            mainTab = .prepare
                        } else {
                            status = engine.lastMessage
                        }
                    } label: {
                        Text("Load PA line test")
                            .foregroundStyle(OrcaTheme.accent)
                    }
                    .listRowBackground(OrcaTheme.panel)
                } header: {
                    Text("Pressure advance")
                } footer: {
                    Text("Official pressure_advance_test.drc · Calib_PA_Line emits K-factor lines in G-code.")
                        .font(.system(size: 11))
                }

                Section {
                    HStack {
                        Text("Start mm").foregroundStyle(OrcaTheme.muted)
                        TextField("0", text: $calibRetractStart)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(OrcaTheme.text)
                    }
                    .listRowBackground(OrcaTheme.panel)
                    HStack {
                        Text("End mm").foregroundStyle(OrcaTheme.muted)
                        TextField("2", text: $calibRetractEnd)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(OrcaTheme.text)
                    }
                    .listRowBackground(OrcaTheme.panel)
                    HStack {
                        Text("Step mm").foregroundStyle(OrcaTheme.muted)
                        TextField("0.1", text: $calibRetractStep)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(OrcaTheme.text)
                    }
                    .listRowBackground(OrcaTheme.panel)
                    Button {
                        let s = Double(calibRetractStart) ?? 0
                        let e = Double(calibRetractEnd) ?? 2
                        let st = Double(calibRetractStep) ?? 0.1
                        if engine.prepareRetraction(start: s, end: e, step: st) {
                            status = engine.lastMessage
                            showCalibration = false
                            showProcess = false
                            mainTab = .prepare
                        } else {
                            status = engine.lastMessage
                        }
                    } label: {
                        Text("Load retraction tower")
                            .foregroundStyle(OrcaTheme.accent)
                    }
                    .listRowBackground(OrcaTheme.panel)
                } header: {
                    Text("Retraction helper")
                } footer: {
                    Text("Official retraction_tower.drc · retraction length ramps with Z (Calib_Retraction_tower).")
                        .font(.system(size: 11))
                }

                Section {
                    Text("After loading a calibration model: Slice → Preview → Device upload/print. Clear calibration before normal prints.")
                        .font(.system(size: 12))
                        .foregroundStyle(OrcaTheme.muted)
                        .listRowBackground(OrcaTheme.panel)
                }
            }
            .scrollContentBackground(.hidden)
            .background(OrcaTheme.bg)
            .navigationTitle("Calibration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showCalibration = false }
                        .foregroundStyle(OrcaTheme.accent)
                }
            }
        })
    }

    private var processSheet: AnyView {
        AnyView(ProcessSettingsBrowser(engine: engine) {
            syncProcessFieldsFromEngine()
            status = engine.lastMessage
        })
    }

    private func syncProcessFieldsFromEngine() {
        if let v = engine.getOptionFirst("layer_height") { layerHeight = v }
        if let v = engine.getOptionFirst("wall_loops") { walls = v }
        if let v = engine.getOptionPercent("sparse_infill_density") { infill = v }
        if let v = engine.getOptionFirst("top_shell_layers") { topShells = v }
        if let v = engine.getOptionFirst("bottom_shell_layers") { bottomShells = v }
        if let v = engine.getOptionFirst("brim_width") { brimWidth = v }
        if let v = engine.getOptionFirst("outer_wall_speed") { outerWallSpeed = v }
        if let v = engine.getOptionFirst("sparse_infill_speed") { sparseSpeed = v }
        supportOn = engine.getOptionBool("enable_support")
        brimType = ProcessOptionCatalog.match(
            engine.getOptionFirst("brim_type"),
            in: ProcessOptionCatalog.brimType,
            fallback: "auto_brim"
        )
        supportType = ProcessOptionCatalog.match(
            engine.getOptionFirst("support_type"),
            in: ProcessOptionCatalog.supportType,
            fallback: "normal(auto)"
        )
        wallGenerator = ProcessOptionCatalog.match(
            engine.getOptionFirst("wall_generator"),
            in: ProcessOptionCatalog.wallGenerator,
            fallback: "arachne"
        )
        seamPosition = ProcessOptionCatalog.match(
            engine.getOptionFirst("seam_position"),
            in: ProcessOptionCatalog.seamPosition,
            fallback: "aligned"
        )
        ironingType = ProcessOptionCatalog.match(
            engine.getOptionFirst("ironing_type"),
            in: ProcessOptionCatalog.ironingType,
            fallback: "no ironing"
        )
        infillPattern = ProcessOptionCatalog.match(
            engine.getOptionFirst("sparse_infill_pattern"),
            in: ProcessOptionCatalog.infillPattern,
            fallback: "grid"
        )
        if let v = engine.getOptionFirst("nozzle_temperature") { nozzleTemp = v }
        // Bed temp: try both legacy and Bambu-style keys
        if let v = engine.getOptionFirst("bed_temperature") ?? engine.getOptionFirst("hot_plate_temp") {
            bedTemp = v
        }
        if let v = engine.getOptionFirst("filament_diameter") { filamentDiameter = v }
    }

    /// Official enum dropdown (Picker) for process options like brim_type.
    private func enumPicker(
        title: String,
        selection: Binding<String>,
        choices: [ProcessEnumChoice],
        onChange: @escaping (String) -> Void
    ) -> some View {
        // Write-through binding so pickers apply immediately without fragile onChange paths
        let live = Binding<String>(
            get: { selection.wrappedValue },
            set: { newVal in
                selection.wrappedValue = newVal
                onChange(newVal)
            }
        )
        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(OrcaTheme.muted)
            Picker(title, selection: live) {
                ForEach(choices) { c in
                    Text(c.label).tag(c.key)
                }
            }
            .pickerStyle(.menu)
            .tint(OrcaTheme.accent)
        }
        .listRowBackground(OrcaTheme.panel)
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(OrcaTheme.muted)
            Spacer()
            Text(value).foregroundStyle(OrcaTheme.text).multilineTextAlignment(.trailing)
        }
        .listRowBackground(OrcaTheme.panel)
    }

    private func bedPreset(_ title: String, _ w: Float, _ d: Float) -> some View {
        Button {
            engine.setBedSize(width: w, depth: d, height: engine.bedHeight)
            engine.refreshBedSize()
            status = engine.lastMessage
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    abs(engine.bedSize.x - w) < 0.5 && abs(engine.bedSize.y - d) < 0.5
                        ? OrcaTheme.accent.opacity(0.25)
                        : OrcaTheme.elevated
                )
                .foregroundStyle(OrcaTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func sliceNow() {
        guard !isSlicing else { return }
        status = ""
        isSlicing = true
        Task {
            let msg = await engine.slice()
            await MainActor.run {
                status = msg
                isSlicing = false
                if engine.gcodeURL != nil {
                    mainTab = .preview
                } else if engine.slicePhase != "Cancelled" {
                    operationError = msg
                }
            }
        }
    }

    private func exportUserPresetsZip(from source: UIView? = nil) {
        // Prefer store-only ZIP of Documents/OrcaSlicer/user_presets (portable bundle)
        if let zipURL = engine.exportPresetBundleZip() {
            presetBundleShareURL = zipURL
            status = engine.lastMessage
            NativeProjectMenu.share(zipURL, from: source)
            return
        }
        // Fallback: NSFileCoordinator package zip of the directory
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let userPresets = docs.appendingPathComponent("OrcaSlicer/user_presets", isDirectory: true)
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent("orca_user_presets.zip")
        try? FileManager.default.removeItem(at: zipURL)
        let coordinator = NSFileCoordinator()
        var err: NSError?
        coordinator.coordinate(readingItemAt: userPresets, options: .forUploading, error: &err) { temp in
            try? FileManager.default.copyItem(at: temp, to: zipURL)
        }
        if FileManager.default.fileExists(atPath: zipURL.path) {
            presetBundleShareURL = zipURL
            status = "Preset bundle ready: \(zipURL.lastPathComponent)"
            NativeProjectMenu.share(zipURL, from: source)
        } else {
            status = err?.localizedDescription ?? engine.lastMessage
        }
    }

    private func testDocumentPickerWhenReady() {
        guard ProcessInfo.processInfo.arguments.contains("--test-document-import"), !didTestImport,
              engine.startupFinished, !engine.presetsLoading else { return }
        didTestImport = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if ProcessInfo.processInfo.arguments.contains("--test-native-picker") {
                requestDocumentPicker(.model(append: false))
            } else {
                documents.receive(testDocumentFixture, kind: .model(append: false))
            }
        }
    }

    private var testDocumentFixture: URL {
        let name = ProcessInfo.processInfo.arguments.contains("--test-gcode-import") ? "ios-gcode-smoke.gcode" : "ios-import-smoke.3mf"
        return StartupRecovery().dataDirectory.deletingLastPathComponent().appendingPathComponent(name)
    }

    private func requestDocumentPicker(_ kind: DocumentImportKind) {
        showPreviewControls = false
        let request = DocumentImportRequest(kind: kind)
        if showProcess {
            pendingDocumentPicker = request
            showProcess = false
        } else { documentPicker = request }
    }

    private func presentPendingDocumentPicker() {
        documentPicker = pendingDocumentPicker
        pendingDocumentPicker = nil
    }

    private var editingModalPresented: Bool {
        showModelLibrary || showPlateInspector || showProcess || showWizard || showCalibration || showObjectSettings || showLayerHeights || showPreferences || showAbout || showShortcuts
    }

    private func importCloudPresetsIfReady() {
        guard let owner = cloudAccount.ownerID, cloudPresetRevision != cloudAccount.profileRevision,
              !cloudAccount.busy, !processingDocument, !isSlicing, !engine.presetsLoading,
              !engine.sessionBusy, engine.startupFinished, !editingModalPresented else { return }
        let revision = cloudAccount.profileRevision
        let profiles = cloudAccount.profiles
        guard cloudAccount.lastSynced != nil else { return }
        cloudPresetRevision = revision
        Task { @MainActor in
            let success = await engine.importCloudProfiles(profiles, owner: owner, adoptedIDs: cloudAccount.uploadedProfileIDs)
            cloudAccount.profileImportMessage = engine.lastMessage
            if !success { status = engine.lastMessage }
        }
    }

    private func importPendingDocuments() {
        guard !processingDocument, !isSlicing, !engine.presetsLoading, !engine.sessionBusy, engine.startupFinished, !editingModalPresented,
              let document = documents.takeNext() else { return }
        processingDocument = true
        Task { @MainActor in
            var success = false
            switch document.kind {
            case .automatic: break // Resolved before staging.
            case .toolpath:
                success = await engine.loadGCode(url: document.url)
                status = engine.lastMessage
                if success { fitCameraRequest = UUID(); engine.rememberRecent(url: document.url) }
            case .model(let append):
                success = await engine.loadDocumentModel(url: document.url, append: append)
                if success { fitCameraRequest = UUID() }
                status = engine.lastMessage
                if success { engine.rememberRecent(url: document.url) }
            case .settings(let preset):
                success = await engine.importConfigJSON(url: document.url, asUserPreset: preset)
                status = engine.lastMessage
            }
            if !success { documents.errorMessage = status }
            syncProcessFieldsFromEngine()
            if success, case .toolpath = document.kind { mainTab = .preview }
            else { mainTab = .prepare }
            if ProcessInfo.processInfo.arguments.contains("--test-document-import"), success,
               engine.hasModel, engine.objectCount == 1 {
                try? "PASS: app document inbox imported a 3MF model".write(
                    to: FileManager.default.temporaryDirectory.appendingPathComponent("orca-document-import-smoke.txt"),
                    atomically: true, encoding: .utf8)
            }
            if ProcessInfo.processInfo.arguments.contains("--test-show-settings") {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    showProcess = true
                }
            }
            processingDocument = false
            importPendingDocuments()
            importCloudPresetsIfReady()
        }
    }

}

private struct LayerHeightPanel: View {
    @ObservedObject var engine: OrcaEngine
    let objectIndex: Int
    var onChanged: () -> Void
    @State private var profile: OrcaEngine.LayerHeightProfile?
    @State private var quality = 0.5
    @State private var radius = 5
    @State private var keepMinimum = false
    @State private var failure: String?

    var body: some View {
        Form {
            if engine.objectNames.indices.contains(objectIndex) {
                Section("Object") { Text(engine.objectNames[objectIndex]) }
            }
            if let profile {
                Section("Layer height along object") {
                    profileChart(profile)
                    if profile.custom {
                        Text("Custom layer heights").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Using process and object layer heights").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Printer limits: \(profile.minimum.formatted(.number.precision(.fractionLength(2...3))))–\(profile.maximum.formatted(.number.precision(.fractionLength(2...3)))) mm")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Adaptive") {
                Slider(value: $quality, in: 0...1).accessibilityLabel("Quality and speed balance")
                HStack { Text("Finer detail"); Spacer(); Text("Faster print") }.font(.caption)
                Button("Apply adaptive layer heights") { run(.adaptive(Float(quality))) }
                Text("Uses the model's surfaces and your printer's layer-height limits.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(profile == nil)
            Section("Smooth") {
                Stepper("Radius: \(radius)", value: $radius, in: 1...10)
                Toggle("Keep thin layers", isOn: $keepMinimum)
                Button("Smooth layer heights") { run(.smooth(radius: radius, keepMinimum: keepMinimum)) }
            }.disabled(profile == nil)
            Section {
                Button("Reset layer heights", role: .destructive) { run(.reset) }
                Text("Changes affect only this object. Slice again to see the resulting layers. Save 3MF to keep the profile; Undo restores the previous one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let failure {
                Section { Text(failure).foregroundStyle(.red); Button("Reload layer heights") { Task { await reload() } } }
            }
        }
        .disabled(engine.sessionBusy)
        .tint(OrcaTheme.accent)
        .navigationTitle("Variable layer height").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(engine.sessionBusy)
        .overlay {
            if engine.sessionBusy { ProgressView(engine.sessionBusyMessage).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) }
        }
        .task(id: [objectIndex, engine.meshRevision]) { await reload() }
    }

    private func profileChart(_ profile: OrcaEngine.LayerHeightProfile) -> some View {
        let bounds = profile.points.reduce((profile.minimum, profile.maximum)) { (min($0.0, $1.y), max($0.1, $1.y)) }
        let width = max(bounds.1 - bounds.0, 0.001)
        return VStack(spacing: 6) {
            Text("Top · \(profile.objectHeight.formatted(.number.precision(.fractionLength(1...2)))) mm")
                .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            GeometryReader { geometry in
                Path { path in
                    for (index, point) in profile.points.enumerated() {
                        let position = CGPoint(x: CGFloat((point.y - bounds.0) / width) * geometry.size.width,
                            y: (1 - CGFloat(point.x / max(profile.objectHeight, 0.001))) * geometry.size.height)
                        if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
                    }
                }.stroke(OrcaTheme.accent, lineWidth: 2)
            }
            .frame(height: 200).padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text("\(bounds.0.formatted(.number.precision(.fractionLength(2...3)))) mm")
                Spacer()
                Text("\(bounds.1.formatted(.number.precision(.fractionLength(2...3)))) mm")
            }.font(.caption)
            Text("Bottom · 0 mm").font(.caption).frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Layer height profile. Object height: \(profile.objectHeight) mm."))
    }

    @MainActor
    private func reload() async {
        let value = await engine.layerHeightProfile(object: objectIndex)
        profile = value
        failure = value == nil ? engine.lastMessage : nil
    }

    private func run(_ action: OrcaEngine.LayerHeightEdit) {
        Task { @MainActor in
            if await engine.editMesh(.layerHeights(action)) { onChanged(); await reload() }
            else { failure = engine.lastMessage }
        }
    }
}

private struct MeshToolsPanel: View {
    @ObservedObject var engine: OrcaEngine
    var onComplete: () -> Void
    @State private var targetFaces = "0"
    @State private var cutAxis = 2
    @State private var cutPosition = "0"
    @State private var keepUpper = true
    @State private var keepLower = true
    @State private var otherObject = -1
    @State private var booleanOperation = 0
    @State private var removeOther = true
    @State private var failure: String?
    @State private var partNames: [String] = []
    @State private var selectedPart = 0
    @State private var dropSplitObjects = true

    private var hasSelection: Bool { engine.objectNames.indices.contains(engine.selectedObjectIndex) }
    private var secondObject: Int {
        if engine.objectNames.indices.contains(otherObject), otherObject != engine.selectedObjectIndex { return otherObject }
        return engine.objectNames.indices.first(where: { $0 != engine.selectedObjectIndex }) ?? -1
    }

    var body: some View {
        Form {
            Section("Selection") {
                Picker("Object", selection: $engine.selectedObjectIndex) {
                    Text("All objects").tag(-1)
                    ForEach(Array(engine.objectNames.enumerated()), id: \.offset) { i, name in Text(name).tag(i) }
                }
                if !hasSelection { Text("Select one object for split, simplify, cut and boolean operations.").font(.caption) }
            }
            Section("Repair") {
                Button(hasSelection ? "Repair selected object" : "Repair all objects") { run(.repair) }.accessibilityIdentifier("repair-mesh")
                Text("Repair uses the engine's mesh repair tools. It cannot reconstruct every damaged model.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Simplify") {
                TextField("Triangles per part (0 = half)", text: $targetFaces).keyboardType(.numberPad)
                Button("Simplify selected object") {
                    guard let target = Int(targetFaces), target == 0 || (target >= 4 && target <= Int(Int32.max)) else {
                        failure = "Enter 0 or a triangle count of at least 4."; return
                    }
                    run(.simplify(target))
                }
            }.disabled(!hasSelection)
            Section("Split") {
                Toggle("Drop new objects to bed", isOn: $dropSplitObjects)
                Button("Split to objects") { run(.split(toObjects: true, part: 0, dropToBed: dropSplitObjects)) }
                    .accessibilityIdentifier("split-to-objects")
                Text("Creates independent objects. Turn off Drop to keep floating parts at their current height.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Splitting to objects removes modifier volumes. Undo restores the original object.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Model part", selection: $selectedPart) {
                    if partNames.isEmpty { Text("No solid model parts selected").tag(0) }
                    ForEach(Array(partNames.enumerated()), id: \.offset) { index, name in
                        Text("\(index + 1): \(name)").tag(index)
                    }
                }
                Button("Split to parts") { run(.split(toObjects: false, part: selectedPart, dropToBed: false)) }
                    .disabled(partNames.isEmpty).accessibilityIdentifier("split-to-parts")
                Text("Separates disconnected pieces inside the same object, preserving their placement.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(!hasSelection)
            Section("Cut") {
                Picker("Plane axis", selection: $cutAxis) { Text("X").tag(0); Text("Y").tag(1); Text("Z").tag(2) }
                    .pickerStyle(.segmented)
                TextField("Plane position (mm)", text: $cutPosition).keyboardType(.numbersAndPunctuation)
                Toggle("Keep upper half", isOn: $keepUpper)
                Toggle("Keep lower half", isOn: $keepLower)
                Button("Cut selected object") {
                    guard let position = Float(cutPosition), position.isFinite else { failure = "Enter a valid plane position."; return }
                    run(.cut(position: position, axis: cutAxis, upper: keepUpper, lower: keepLower))
                }.disabled(!keepUpper && !keepLower)
            }.disabled(!hasSelection)
            Section("Boolean") {
                Picker("Second object", selection: Binding(get: { secondObject }, set: { otherObject = $0 })) {
                    ForEach(Array(engine.objectNames.enumerated()).filter { $0.offset != engine.selectedObjectIndex }, id: \.offset) { i, name in
                        Text(name).tag(i)
                    }
                }
                Picker("Operation", selection: $booleanOperation) {
                    Text("Union").tag(0); Text("Subtract").tag(1); Text("Intersect").tag(2)
                }.pickerStyle(.segmented)
                Toggle("Remove second object", isOn: $removeOther)
                Button("Apply boolean") { run(.boolean(other: secondObject, operation: booleanOperation, removeOther: removeOther)) }
                Text("Subtract removes the second object's volume from the selected object.").font(.caption).foregroundStyle(.secondary)
            }.disabled(!hasSelection || engine.objectCount < 2)
        }
        .disabled(engine.sessionBusy)
        .navigationTitle("Mesh tools").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(engine.sessionBusy)
        .overlay {
            if engine.sessionBusy {
                ProgressView(engine.sessionBusyMessage).padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .onAppear { setCutMiddle(); refreshParts() }
        .onChange(of: cutAxis) { _ in setCutMiddle() }
        .onChange(of: engine.selectedObjectIndex) { _ in setCutMiddle(); refreshParts() }
        .onChange(of: engine.sessionBusy) { busy in if !busy { refreshParts() } }
        .alert("Mesh operation failed", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(failure ?? "") }
    }

    private func setCutMiddle() {
        guard engine.objectMeshes.indices.contains(engine.selectedObjectIndex) else { return }
        let mesh = engine.objectMeshes[engine.selectedObjectIndex]
        cutPosition = String(format: "%.3f", (mesh.min[cutAxis] + mesh.max[cutAxis]) * 0.5)
    }

    private func run(_ edit: OrcaEngine.MeshEdit) {
        Task { @MainActor in
            if await engine.editMesh(edit) { onComplete() }
            else { failure = engine.lastMessage }
        }
    }

    private func refreshParts() {
        guard !engine.sessionBusy else { return }
        partNames = engine.modelPartNames(object: engine.selectedObjectIndex)
        if !partNames.indices.contains(selectedPart) { selectedPart = 0 }
    }
}

private struct OrcaLogoMark: View {
    var body: some View {
        Group {
            #if canImport(UIKit)
            if let ui = UIImage(named: "OrcaSlicerLogo") {
                Image(uiImage: ui)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "seal.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(OrcaTheme.accent)
            }
            #else
            Image("OrcaSlicerLogo").resizable().scaledToFit()
            #endif
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel("OrcaSlicer")
    }
}

#Preview {
    OrcaRootView().preferredColorScheme(.dark)
}
