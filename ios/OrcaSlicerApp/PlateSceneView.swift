// SceneKit prepare view: build plate + real mesh from libslic3r + G-code paths.
// Coordinate convention:
//   libslic3r is Z-up (XY bed). SceneKit is Y-up.
//   All print geometry lives under "content" node rotated R_x(-90°):
//     (x, y, z)_slic3r  →  (x, z, -y)_scenekit
//   so the bed stays a simple XY plane and the grid always sits under the model.

import SwiftUI
import SceneKit
import ObjectiveC
import Metal
import UIKit

enum FilamentColor {
    static func uiColor(_ hex: String) -> UIColor {
        let text = String(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#\" ")).prefix(6))
        let value = UInt32(text, radix: 16) ?? 0x009688
        return UIColor(red: CGFloat((value >> 16) & 255)/255, green: CGFloat((value >> 8) & 255)/255,
                       blue: CGFloat(value & 255)/255, alpha: 1)
    }
}

/// Native MMU annotations retain their own subdivided topology and filament ID.
/// Keep them under the corresponding object so live transforms move both.
struct PaintedFilamentRegion {
    var objectIndex: Int
    var filamentIndex: Int
    var mesh: MeshGeometry
}


/// Pause display work without tearing down GPU resources during background/exit.
/// The scene is released only when the representable is actually dismantled.
private final class PlateSCNView: SCNView {
    private var observers: [NSObjectProtocol] = []
    override init(frame: CGRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        observeLifecycle()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        observeLifecycle()
    }
    private func observeLifecycle() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.setRenderingActive(false)
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.setRenderingActive(true)
            }
        ]
    }
    func setRenderingActive(_ active: Bool) {
        isPlaying = active
        scene?.isPaused = !active
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

enum PlateTouchMode: String, CaseIterable, Identifiable {
    case orbit = "Orbit", pan = "Pan", move = "Move", rotate = "Rotate", scale = "Scale", layOnFace = "Lay on face", select = "Select"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .orbit: return "globe"
        case .pan: return "hand.draw"
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .rotate: return "rotate.3d"
        case .scale: return "arrow.up.left.and.arrow.down.right"
        case .layOnFace: return "cube.transparent"
        case .select: return "cursorarrow"
        }
    }
}

enum CameraPreset: String, CaseIterable {
    case front = "Front", right = "Right", back = "Back", left = "Left", top = "Top", bottom = "Bottom", home = "Home"
    var direction: SIMD3<Float> {
        switch self {
        case .front: return SIMD3(0, 0, 1)
        case .back: return SIMD3(0, 0, -1)
        case .right: return SIMD3(1, 0, 0)
        case .left: return SIMD3(-1, 0, 0)
        case .top: return SIMD3(0, 1, 0)
        case .bottom: return SIMD3(0, -1, 0)
        case .home: return simd_normalize(SIMD3(0.55, 0.65, 0.8))
        }
    }
}

enum CameraProjection {
    case perspective, orthographic
}

/// Desktop Camera::auto_type only returns to perspective after an automatic
/// face view. A manual projection choice cancels that automatic transition.
struct CameraViewPolicy {
    private var automaticallyAligned = false

    mutating func select(_ view: CameraPreset, automatic: Bool, current: CameraProjection) -> CameraProjection {
        guard automatic else { reset(); return current }
        if view != .home { automaticallyAligned = true; return .orthographic }
        return orbit(automatic: automatic, current: current)
    }

    mutating func orbit(automatic: Bool, current: CameraProjection) -> CameraProjection {
        let next: CameraProjection = automatic && automaticallyAligned ? .perspective : current
        reset()
        return next
    }

    mutating func reset() { automaticallyAligned = false }
}

/// Incremental deltas keep the cursor fixed when changing scrubbing precision.
struct ToolpathScrubGesture {
    enum Precision {
        case normal, fine, veryFine, moveByMove
        var label: String {
            switch self {
            case .normal: return "Drag up/down for finer control"
            case .fine: return "Fine scrubbing"
            case .veryFine: return "Very fine scrubbing"
            case .moveByMove: return "Move by move"
            }
        }
    }
    var value: Double
    let origin: CGPoint
    var previous: CGPoint
    private(set) var precision: Precision = .normal

    mutating func update(to point: CGPoint, width: CGFloat, range: ClosedRange<Double>) -> Double {
        guard point.x.isFinite, point.y.isFinite, width > 0 else { return value }
        let distance = abs(point.y - origin.y)
        precision = distance < 36 ? .normal : distance < 72 ? .fine : distance < 108 ? .veryFine : .moveByMove
        let scale: Double
        switch precision {
        case .normal: scale = (range.upperBound - range.lowerBound) / Double(width)
        case .fine: scale = (range.upperBound - range.lowerBound) / Double(width) * 0.1
        case .veryFine: scale = (range.upperBound - range.lowerBound) / Double(width) * 0.01
        case .moveByMove: scale = 0.125
        }
        value = max(range.lowerBound, min(range.upperBound, value + Double(point.x - previous.x) * scale))
        previous = point
        return value
    }
}

struct ManualToolpathScrubber: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onEditingChanged: (Bool) -> Void
    @State private var precision: ToolpathScrubGesture.Precision = .normal

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            NativeSlider(value: $value, range: range, onEditingChanged: onEditingChanged,
                         onPrecision: { precision = $0 }).frame(height: 44)
            Text(precision.label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private struct NativeSlider: UIViewRepresentable {
        @Binding var value: Double
        let range: ClosedRange<Double>
        var onEditingChanged: (Bool) -> Void
        var onPrecision: (ToolpathScrubGesture.Precision) -> Void

        func makeUIView(context: Context) -> PrecisionSlider {
            let slider = PrecisionSlider()
            slider.minimumValue = 0; slider.maximumValue = 1
            slider.minimumTrackTintColor = UIColor(red: 0, green: 150/255, blue: 136/255, alpha: 1)
            slider.accessibilityLabel = "Toolpath move"
            slider.accessibilityHint = "Drag sideways. Move your finger above or below the slider for finer control. Adjust by one move with VoiceOver."
            return slider
        }
        func updateUIView(_ slider: PrecisionSlider, context: Context) {
            slider.range = range
            slider.cursor = value
            slider.changed = { value = $0 }
            slider.editing = onEditingChanged
            slider.precisionChanged = onPrecision
            slider.refresh()
        }
        static func dismantleUIView(_ slider: PrecisionSlider, coordinator: ()) {
            slider.changed = nil; slider.editing = nil; slider.precisionChanged = nil
        }
    }

    final class PrecisionSlider: UISlider {
        var range: ClosedRange<Double> = 0...1
        var cursor = 0.0
        var changed: ((Double) -> Void)?
        var editing: ((Bool) -> Void)?
        var precisionChanged: ((ToolpathScrubGesture.Precision) -> Void)?
        private var gesture: ToolpathScrubGesture?

        override init(frame: CGRect) {
            super.init(frame: frame)
            addTarget(self, action: #selector(nativeValueChanged), for: .valueChanged)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func refresh() {
            let span = range.upperBound - range.lowerBound
            isEnabled = span > 0
            setValue(span > 0 ? Float((cursor - range.lowerBound) / span) : 0, animated: false)
            accessibilityValue = "Move \((max(0, cursor + 1)).formatted(.number.precision(.fractionLength(0...2)))) of \(Int(range.upperBound) + 1)"
        }
        private func report(_ next: Double) {
            cursor = max(range.lowerBound, min(range.upperBound, next))
            refresh()
            changed?(cursor)
        }
        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            let point = touch.location(in: self)
            gesture = ToolpathScrubGesture(value: cursor, origin: point, previous: point)
            guard super.beginTracking(touch, with: event) else { gesture = nil; return false }
            refresh()
            editing?(true)
            return true
        }
        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            guard var state = gesture else { return false }
            let width = trackRect(forBounds: bounds).width - thumbRect(forBounds: bounds,
                trackRect: trackRect(forBounds: bounds), value: value).width
            let next = state.update(to: touch.location(in: self), width: max(1, width), range: range)
            gesture = state
            precisionChanged?(state.precision)
            report(next)
            return true
        }
        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            super.endTracking(touch, with: event)
            finish()
        }
        override func cancelTracking(with event: UIEvent?) {
            super.cancelTracking(with: event)
            finish()
        }
        private func finish() {
            gesture = nil
            precisionChanged?(.normal)
            editing?(false)
        }
        @objc private func nativeValueChanged() {
            // Retain native accessibility/test adjustments as well as touches.
            guard gesture == nil else { return }
            report(range.lowerBound + Double(value) * (range.upperBound - range.lowerBound))
            editing?(false)
        }
        override func accessibilityIncrement() {
            report(floor(cursor) + 1); editing?(false)
        }
        override func accessibilityDecrement() {
            report(ceil(cursor) - 1); editing?(false)
        }
    }
}

/// Interactive build plate with official-engine mesh geometry + optional G-code paths.
struct PlateSceneView: UIViewRepresentable {
    var mesh: MeshGeometry?
    var framingBounds: (min: SIMD3<Float>, max: SIMD3<Float>)? = nil
    var meshRevision: Int = 0
    /// Per-object meshes for tap-to-select (same order as engine.objectNames).
    var objectMeshes: [MeshGeometry] = []
    var objectColors: [UIColor] = []
    var paintedFilaments: [PaintedFilamentRegion] = []
    var filamentColors: [UIColor] = []
    var filamentPaintRevision: Int = 0
    var selectedObjectIndex: Int = -1
    var gcodeNode: SCNNode? = nil
    var showGCode: Bool = false
    var toolheadPosition: SCNVector3?
    var toolheadMove: Double? = nil
    var toolpathGeometry: GCodePathGeometry? = nil
    var showToolhead = false
    var smoothToolhead = true
    var showShell: Bool = false
    var bedSize: SIMD2<Float> = SIMD2(220, 220)
    /// Optional machine bed texture / cover PNG path (from system profiles)
    var bedTexturePath: String? = nil
    var accent: UIColor = UIColor(red: 0, green: 150 / 255, blue: 136 / 255, alpha: 1)
    /// Prepare tab: pan on bed plane moves selected object(s) in mm (slic3r XY).
    var touchMode: PlateTouchMode = .orbit
    var fitRequest = UUID()
    var cameraView: CameraPreset = .home
    var projection: CameraProjection = .perspective
    var onCameraView: ((CameraPreset) -> Void)? = nil
    var onOrbitBegin: (() -> Void)? = nil
    var rotationAxis: Int = 2
    /// Tap object to select; drag on object to move (without requiring Move gizmo).
    var selectMode: Bool { [.select, .move, .rotate, .scale, .layOnFace].contains(touchMode) }
    var moveMode: Bool { touchMode == .move }
    var onScaleCommit: ((Float, Int) -> Void)? = nil
    var onRotateCommit: ((Float, Int) -> Void)? = nil
    /// Measure gizmo: tap places points in slic3r XYZ (mm).
    var measureMode: Bool = false
    /// Paint gizmo: tap/drag paints facets via libslic3r FacetsAnnotation.
    var paintMode: Bool = false
    /// Painted facet overlay mesh (world slic3r coords)
    var paintOverlay: MeshGeometry? = nil
    /// Overlay color for current paint kind
    var paintOverlayColor: UIColor = UIColor(red: 0.2, green: 0.85, blue: 0.35, alpha: 0.85)
    /// Called when a drag ends: Δx, Δy mm and the object index that was dragged (-1 = all).
    var onDragCommit: ((Float, Float, Int) -> Void)? = nil
    /// Live visual feedback during drag (optional status text).
    var onDragLive: ((Float, Float) -> Void)? = nil
    /// Measure tap in slic3r coordinates (x,y,z mm).
    var onMeasurePick: ((SIMD3<Float>) -> Void)? = nil
    /// Paint hit in slic3r XYZ mm (first stroke of a gesture sets recordUndo via parent).
    var onPaintHit: ((SIMD3<Float>, Bool /*isBegin*/) -> Void)? = nil
    /// User tapped an object on the plate (-1 = empty bed / deselect).
    var onSelectObject: ((Int) -> Void)? = nil
    var onFacePick: ((Int, SIMD3<Float>) -> Void)? = nil

    /// Run on the simulator main thread against a real SceneKit camera.
    static func cameraSmokeTest(includePreview: Bool = true, includePaint: Bool = true, onFailure: ((String) -> Void)? = nil) -> Bool {
        func fail(_ detail: String, line: Int = #line) -> Bool {
            let message = "Camera assertion \(line): " + detail
            onFailure?(message); NSLog("%@", message)
            return false
        }
        var policy = CameraViewPolicy()
        guard policy.select(.top, automatic: false, current: .perspective) == .perspective,
              policy.select(.front, automatic: true, current: .perspective) == .orthographic,
              policy.orbit(automatic: true, current: .orthographic) == .perspective,
              policy.select(.right, automatic: true, current: .perspective) == .orthographic else { return fail("automatic projection policy") }
        policy.reset() // Explicit manual orthographic choice.
        guard policy.orbit(automatic: true, current: .orthographic) == .orthographic,
              policy.select(.home, automatic: true, current: .orthographic) == .orthographic,
              policy.select(.bottom, automatic: true, current: .perspective) == .orthographic,
              policy.select(.home, automatic: true, current: .orthographic) == .perspective else { return fail("manual projection policy") }
        let view = PlateSCNView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        view.scene = SCNScene()
        view.setRenderingActive(false)
        guard view.scene?.isPaused == true, !view.isPlaying else { return fail("render pause state") }
        view.setRenderingActive(true)
        guard view.scene?.isPaused == false else { return fail("render resume state") }
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.position = SCNVector3(50, 60, 80)
        camera.look(at: SCNVector3Zero)
        view.scene?.rootNode.addChildNode(camera)
        view.pointOfView = camera
        view.defaultCameraController.pointOfView = camera
        view.defaultCameraController.automaticTarget = false
        view.defaultCameraController.target = SCNVector3Zero
        view.defaultCameraController.interactionMode = .orbitTurntable
        let coordinator = Coordinator()
        coordinator.installGestures(on: view)
        guard coordinator.panGesture?.maximumNumberOfTouches == 1, coordinator.pinchGesture != nil else { return fail("one-finger pan and pinch recognizers") }
        let distance = simd_length(SIMD3<Float>(50, 60, 80))
        coordinator.zoom(scale: 2, view: view)
        SCNTransaction.flush()
        guard abs(simd_length(SIMD3<Float>(camera.position.x, camera.position.y, camera.position.z)) - distance / 2) < 0.01 else { return fail("pinch distance \(simd_length(camera.simdPosition)) expected \(distance / 2)") }
        let panPoint = view.unprojectPoint(SCNVector3(150, 200, view.projectPoint(SCNVector3Zero).z))
        let before = camera.position
        coordinator.cameraDrag(delta: CGPoint(x: 35, y: 25), view: view, mode: .pan)
        SCNTransaction.flush()
        let panProjected = view.projectPoint(panPoint)
        guard abs(panProjected.x - 185) < 0.5, abs(panProjected.y - 225) < 0.5 else {
            return fail("perspective pan followed \(panProjected), expected (185,225)")
        }
        let target = view.defaultCameraController.target
        guard abs(camera.position.x - before.x - target.x) < 0.01,
              abs(camera.position.y - before.y - target.y) < 0.01,
              abs(target.x) + abs(target.y) + abs(target.z) > 0.01 else { return fail("pan camera \(camera.position) target \(target)") }
        let beforeOrbit = camera.position
        coordinator.cameraDrag(delta: CGPoint(x: 60, y: 20), view: view, mode: .orbit)
        let afterOrbit = camera.position
        let offset = SIMD3<Float>(afterOrbit.x - target.x, afterOrbit.y - target.y, afterOrbit.z - target.z)
        guard abs(simd_length(offset) - distance / 2) < 0.1,
              abs(afterOrbit.x - beforeOrbit.x) + abs(afterOrbit.z - beforeOrbit.z) > 0.01 else { return fail("orbit radius \(simd_length(offset)) expected \(distance / 2)") }
        // A zero-distance touch must preserve both framing and orientation.
        let orientation = camera.simdOrientation
        coordinator.cameraDrag(delta: .zero, view: view, mode: .orbit)
        guard simd_length(camera.simdPosition - SIMD3<Float>(afterOrbit.x, afterOrbit.y, afterOrbit.z)) < 0.001,
              abs(simd_dot(orientation.vector, camera.simdOrientation.vector)) > 0.9999 else { return fail("stationary orbit changed camera position/orientation") }
        let originalSize = view.bounds.size
        let startPosition = camera.simdPosition
        let startOrientation = camera.simdOrientation
        coordinator.cameraDrag(delta: CGPoint(x: originalSize.width * 0.1, y: 0), view: view, mode: .orbit)
        let phonePosition = camera.simdPosition
        camera.simdPosition = startPosition
        camera.simdOrientation = startOrientation
        view.frame.size = CGSize(width: 1024, height: 1366)
        coordinator.cameraDrag(delta: CGPoint(x: 102.4, y: 0), view: view, mode: .orbit)
        guard simd_length(camera.simdPosition - phonePosition) < 0.01 else { return fail("normalized phone/tablet orbit delta \(simd_length(camera.simdPosition - phonePosition))") }
        coordinator.cameraDrag(delta: CGPoint(x: -102.4, y: 0), view: view, mode: .orbit)
        guard simd_length(camera.simdPosition - startPosition) < 0.01 else { return fail("reverse orbit delta \(simd_length(camera.simdPosition - startPosition))") }
        // Projection queries read the presentation tree. Commit synthetic
        // changes just as the real view does between rendered input frames.
        SCNTransaction.flush()
        let anchor = CGPoint(x: 400, y: 500)
        let depth = view.projectPoint(view.defaultCameraController.target).z
        let focus = view.unprojectPoint(SCNVector3(Float(anchor.x), Float(anchor.y), depth))
        coordinator.zoom(scale: 1.5, view: view, anchor: anchor)
        SCNTransaction.flush()
        let projected = view.projectPoint(focus)
        guard abs(projected.x - Float(anchor.x)) < 0.5,
              abs(projected.y - Float(anchor.y)) < 0.5 else { return fail("perspective pinch anchor \(projected) expected \(anchor)") }
        let probe = view.defaultCameraController.target
        let probeOffset = camera.simdWorldRight * 5
        let projectionProbe = SCNVector3(probe.x + probeOffset.x, probe.y + probeOffset.y, probe.z + probeOffset.z)
        let perspectivePoint = view.projectPoint(projectionProbe)
        let beforeProjection = camera.simdPosition
        coordinator.setProjection(.orthographic, view: view)
        SCNTransaction.flush()
        let orthographicPoint = view.projectPoint(projectionProbe)
        guard camera.camera?.usesOrthographicProjection == true,
              simd_length(camera.simdPosition - beforeProjection) < 0.001,
              abs(perspectivePoint.x - orthographicPoint.x) < 0.5,
              abs(perspectivePoint.y - orthographicPoint.y) < 0.5 else { return fail("perspective/orthographic span \(perspectivePoint) -> \(orthographicPoint), FOV \(camera.camera?.fieldOfView ?? 0)") }
        let orthoScale = camera.camera?.orthographicScale ?? 0
        let orthoDepth = view.projectPoint(probe).z
        let orthoFocus = view.unprojectPoint(SCNVector3(Float(anchor.x), Float(anchor.y), orthoDepth))
        coordinator.zoom(scale: 1.5, view: view, anchor: anchor)
        SCNTransaction.flush()
        let zoomedFocus = view.projectPoint(orthoFocus)
        guard abs((camera.camera?.orthographicScale ?? 0) - orthoScale / 1.5) < 0.001,
              abs(zoomedFocus.x - Float(anchor.x)) < 0.5,
              abs(zoomedFocus.y - Float(anchor.y)) < 0.5 else { return fail("orthographic pinch anchor \(zoomedFocus) expected \(anchor), scale \(camera.camera?.orthographicScale ?? 0) expected \(orthoScale / 1.5)") }
        let beforePan = camera.simdPosition
        let oldTarget = view.defaultCameraController.target
        coordinator.cameraDrag(delta: CGPoint(x: 30, y: -15), view: view, mode: .pan)
        let pannedTarget = view.defaultCameraController.target
        let shift = SIMD3<Float>(pannedTarget.x - oldTarget.x, pannedTarget.y - oldTarget.y, pannedTarget.z - oldTarget.z)
        guard simd_length(camera.simdPosition - beforePan - shift) < 0.001, simd_length(shift) > 0.001 else { return fail("orthographic pan shift \(shift)") }
        let center = SIMD3<Float>(pannedTarget.x, pannedTarget.y, pannedTarget.z)
        let side = center + camera.simdWorldRight * 5
        SCNTransaction.flush()
        let beforeSwitch = view.projectPoint(SCNVector3(side.x, side.y, side.z))
        coordinator.setProjection(.perspective, view: view)
        SCNTransaction.flush()
        let afterSwitch = view.projectPoint(SCNVector3(side.x, side.y, side.z))
        guard camera.camera?.usesOrthographicProjection == false,
              abs(beforeSwitch.x - afterSwitch.x) < 0.5,
              abs(beforeSwitch.y - afterSwitch.y) < 0.5 else { return fail("orthographic/perspective span \(beforeSwitch) -> \(afterSwitch)") }
        let finalTarget = view.defaultCameraController.target
        camera.position = SCNVector3(finalTarget.x, finalTarget.y + 100, finalTarget.z + 0.01)
        camera.look(at: finalTarget)
        let top = camera.simdPosition
        coordinator.cameraDrag(delta: .zero, view: view, mode: .orbit)
        coordinator.cameraDrag(delta: CGPoint(x: 10, y: 0), view: view, mode: .orbit)
        guard abs(camera.simdPosition.y - top.y) < 0.001 else { return fail("pole orbit changed Y from \(top.y) to \(camera.simdPosition.y)") }
        camera.name = "camera"
        coordinator.frameCamera(view: view, minimum: SIMD3(0, 0, 990), maximum: SIMD3(10, 10, 1010))
        SCNTransaction.flush()
        let raisedTarget = view.defaultCameraController.target
        guard abs(raisedTarget.y - 1000) < 0.001, camera.position.y > raisedTarget.y else { return fail("raised framing target \(raisedTarget) camera \(camera.position)") }
        for preset in CameraPreset.allCases {
            coordinator.frameCamera(view: view, minimum: SIMD3(0, 0, 990), maximum: SIMD3(10, 10, 1010), preset: preset)
            SCNTransaction.flush()
            let center = SIMD3<Float>(5, 1000, -5)
            let direction = simd_normalize(camera.simdPosition - center)
            guard simd_dot(direction, preset.direction) > 0.999,
                  camera.simdOrientation.vector.x.isFinite else { return fail("preset \(preset) direction \(direction) expected \(preset.direction)") }
        }
        for size in [CGSize(width: 390, height: 600), CGSize(width: 1024, height: 768)] {
            view.frame.size = size
            for projection in [CameraProjection.perspective, .orthographic] {
                coordinator.setProjection(projection, view: view)
                SCNTransaction.flush()
                for preset in CameraPreset.allCases {
                    coordinator.frameCamera(view: view, minimum: SIMD3(0, 0, 990), maximum: SIMD3(10, 10, 1010), preset: preset)
                    SCNTransaction.flush()
                    for x in [Float(0), 10] {
                        for y in [Float(0), 10] {
                            for z in [Float(990), 1010] {
                                let point = view.projectPoint(SCNVector3(x, z, -y))
                                guard point.x >= 0, point.x <= Float(size.width),
                                      point.y >= 0, point.y <= Float(size.height), point.z >= 0, point.z <= 1 else {
                                    let pose = camera.simdTransform
                                    let presented = camera.presentation.simdTransform
                                    let center = view.projectPoint(SCNVector3(5, 1000, -5))
                                    SCNTransaction.flush()
                                    let settled = view.projectPoint(SCNVector3(x, z, -y))
                                    return fail("bounds \(size) \(projection) \(preset), point \(point), settled \(settled), source (\(x),\(y),\(z)), center \(center), pose \(pose), presented \(presented), near/far \(camera.camera?.zNear ?? 0)/\(camera.camera?.zFar ?? 0)")
                                }
                            }
                        }
                    }
                }
            }
        }
        return (!includePaint || filamentPaintSmokeTest()) && (!includePreview || GCodePathGeometry.previewSmokeTest())

    }

    func makeUIView(context: Context) -> SCNView {
        let view = PlateSCNView(frame: .zero)
        view.scene = makeScene()
        view.backgroundColor = UIColor(red: 0x2D / 255, green: 0x2D / 255, blue: 0x31 / 255, alpha: 1)
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.defaultCameraController.maximumVerticalAngle = 89
        view.defaultCameraController.minimumVerticalAngle = 5
        if let cam = view.scene?.rootNode.childNode(withName: "camera", recursively: false) {
            view.pointOfView = cam
        }
        context.coordinator.view = view
        context.coordinator.parent = self
        context.coordinator.lastBed = bedSize
        context.coordinator.lastTexture = bedTexturePath ?? ""
        context.coordinator.installGestures(on: view)
        context.coordinator.installNavigationCube(on: view)
        return view
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.stopToolheadMotion()
        view.isPlaying = false
        view.scene?.isPaused = true
        view.delegate = nil
        view.gestureRecognizers?.forEach { view.removeGestureRecognizer($0) }
        coordinator.parent = nil
        coordinator.view = nil
        view.scene = nil
    }

    func updateUIView(_ view: SCNView, context: Context) {
        if let previous = context.coordinator.parent,
           previous.touchMode != touchMode || previous.rotationAxis != rotationAxis ||
            previous.paintMode != paintMode || previous.measureMode != measureMode {
            // Cancel through the previous mode before switching ownership.
            context.coordinator.panGesture?.isEnabled = false
        }
        context.coordinator.parent = self
        guard let scene = view.scene,
              let content = scene.rootNode.childNode(withName: "content", recursively: false)
        else { return }
        context.coordinator.setProjection(projection, view: view)

        // One recognizer owns one-finger gestures. SceneKit's built-in
        // recognizers otherwise compete with object dragging and pinch zoom.
        view.allowsCameraControl = false
        context.coordinator.panGesture?.isEnabled = true
        context.coordinator.tapGesture?.isEnabled = measureMode || paintMode || selectMode

        // Bed size / texture recreate if missing or changed
        let texKey = bedTexturePath ?? ""
        let bedMissing = content.childNode(withName: "bed", recursively: false) == nil
        if bedMissing
            || context.coordinator.lastBed.x != bedSize.x
            || context.coordinator.lastBed.y != bedSize.y
            || context.coordinator.lastTexture != texKey {
            content.childNode(withName: "bed", recursively: false)?.removeFromParentNode()
            let bed = makeBedNode(size: bedSize, accent: accent, texturePath: bedTexturePath)
            bed.name = "bed"
            content.addChildNode(bed)
            context.coordinator.lastBed = bedSize
            context.coordinator.lastTexture = texKey
            // Re-frame when bed changes so plate stays in view
            if let mesh {
                context.coordinator.frameCamera(view: view, minimum: mesh.min, maximum: mesh.max)
            } else {
                context.coordinator.frameCameraOnBed(view: view, bedSize: bedSize)
            }
        }

        // Mesh model(s) — per-object nodes for hit-test/select; skip rebuild while dragging.
        // Include full AABB so instance translate always invalidates the SceneKit nodes.
        let perKey = objectMeshes.enumerated().map { i, m in
            String(format: "%d:%d:%.3f,%.3f,%.3f,%.3f,%.3f,%.3f",
                   i, m.vertexCount,
                   m.min.x, m.min.y, m.min.z, m.max.x, m.max.y, m.max.z)
        }.joined(separator: "|")
        let meshKey = (mesh.map {
            String(format: "c:%d:%.3f,%.3f,%.3f,%.3f",
                   $0.vertexCount, $0.min.x, $0.min.y, $0.max.x, $0.max.y)
        } ?? "nil") + "|objs=\(perKey)|revision=\(meshRevision)"
        let rebuildModel = !context.coordinator.isDragging && context.coordinator.lastMeshKey != meshKey
        if rebuildModel {
            content.childNode(withName: "model", recursively: false)?.removeFromParentNode()
            let root = SCNNode()
            root.name = "model"
            if !objectMeshes.isEmpty {
                for (i, om) in objectMeshes.enumerated() {
                    guard om.vertexCount > 0 else { continue }
                    let selected = (i == selectedObjectIndex)
                    let color = objectColors.indices.contains(i) ? objectColors[i] : accent
                    let node = om.makeNode(color: color)
                    node.name = "object_\(i)"
                    if selected {
                        node.geometry?.firstMaterial?.emission.contents = UIColor(
                            red: 0.10, green: 0.10, blue: 0.10, alpha: 1
                        )
                    }
                    root.addChildNode(node)
                }
                content.addChildNode(root)
            } else if let mesh {
                let node = mesh.makeNode(color: objectColors.first ?? accent)
                node.name = "object_0"
                root.addChildNode(node)
                content.addChildNode(root)
            }
            context.coordinator.lastMeshKey = meshKey
            context.coordinator.visualOffset = .zero
        } else if !context.coordinator.isDragging {
            // Selection highlight only (no full rebuild)
            if let root = content.childNode(withName: "model", recursively: false) {
                for child in root.childNodes {
                    guard let name = child.name, name.hasPrefix("object_"),
                          let idx = Int(name.dropFirst("object_".count)) else { continue }
                    let selected = idx == selectedObjectIndex
                    child.geometry?.firstMaterial?.diffuse.contents = objectColors.indices.contains(idx) ? objectColors[idx] : accent
                    child.geometry?.firstMaterial?.emission.contents = selected
                        ? UIColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1)
                        : UIColor.black
                }
            }
        }

        if rebuildModel || context.coordinator.lastFilamentPaintRevision != filamentPaintRevision {
            if let model = content.childNode(withName: "model", recursively: false) {
                let grouped = Dictionary(grouping: paintedFilaments, by: \.objectIndex)
                for object in model.childNodes {
                    guard let name = object.name, name.hasPrefix("object_"),
                          let index = Int(name.dropFirst("object_".count)) else { continue }
                    object.childNode(withName: "filamentPaint", recursively: false)?.removeFromParentNode()
                    let colors = Self.makeFilamentPaintNode(regions: grouped[index] ?? [], colors: filamentColors,
                        fallback: objectColors.indices.contains(index) ? objectColors[index] : accent)
                    object.addChildNode(colors)
                }
                context.coordinator.lastFilamentPaintRevision = filamentPaintRevision
            }
        }

        if context.coordinator.lastFitRequest != fitRequest {
            if let bounds = framingBounds {
                context.coordinator.frameCamera(view: view, minimum: bounds.min, maximum: bounds.max, preset: cameraView)
            } else if let mesh { context.coordinator.frameCamera(view: view, minimum: mesh.min, maximum: mesh.max, preset: cameraView) }
            else { context.coordinator.frameCamera(view: view, minimum: .zero, maximum: SIMD3(bedSize.x, bedSize.y, 0), preset: cameraView) }
            context.coordinator.lastFitRequest = fitRequest
        }

        // Reuse the existing scene subtree for camera/selection UI updates.
        let previewID = gcodeNode.map { ObjectIdentifier($0) }
        if context.coordinator.lastPreviewID != previewID || context.coordinator.lastShowGCode != showGCode {
            context.coordinator.stopToolheadMotion()
            content.childNode(withName: "gcode", recursively: false)?.removeFromParentNode()
            if showGCode, let gcodeNode {
                let clone = gcodeNode.clone()
                clone.name = "gcode"
                GCodePathGeometry.copyCursorRenderer(from: gcodeNode, to: clone)
                clone.eulerAngles = SCNVector3Zero
                content.addChildNode(clone)
            }
            context.coordinator.lastPreviewID = previewID
            context.coordinator.lastShowGCode = showGCode
        }
        if let preview = content.childNode(withName: "gcode", recursively: false) {
            let markerPosition = toolheadPosition ?? GCodePathGeometry.endPoint(in: preview)
            var marker = preview.childNode(withName: "scrub-toolhead", recursively: false)
            if marker == nil, showToolhead, let position = markerPosition {
                let sphere = SCNSphere(radius: 1)
                sphere.segmentCount = 12
                let material = SCNMaterial()
                material.diffuse.contents = UIColor.systemYellow
                material.lightingModel = .constant
                sphere.materials = [material]
                let node = SCNNode(geometry: sphere)
                node.name = "scrub-toolhead"
                node.position = position
                marker = node
                preview.addChildNode(node)
            }
            marker?.isHidden = !showToolhead
            if showToolhead, let marker, let position = markerPosition {
                context.coordinator.moveToolhead(marker, position: position, move: toolheadMove,
                    geometry: toolpathGeometry, smooth: smoothToolhead, preview: preview)
            } else {
                context.coordinator.stopToolheadMotion()
                GCodePathGeometry.updateCursor(on: preview, through: toolheadMove)
            }
        } else { context.coordinator.stopToolheadMotion() }
        if let model = content.childNode(withName: "model", recursively: false) {
            model.isHidden = showGCode && !showShell
            model.opacity = showGCode ? 0.15 : 1
        }

        // Paint overlay (support/seam/mmu/fuzzy facets)
        content.childNode(withName: "paintOverlay", recursively: false)?.removeFromParentNode()
        if let paintOverlay, paintOverlay.vertexCount > 0 {
            let node = paintOverlay.makeNode(color: paintOverlayColor)
            node.name = "paintOverlay"
            // Slight inflate so painted faces sit above base mesh
            node.renderingOrder = 10
            if let mats = node.geometry?.materials {
                for m in mats {
                    m.writesToDepthBuffer = false
                    m.transparencyMode = .singleLayer
                }
            }
            content.addChildNode(node)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private static func makeFilamentPaintNode(regions: [PaintedFilamentRegion], colors: [UIColor], fallback: UIColor) -> SCNNode {
        let root = SCNNode()
        root.name = "filamentPaint"
        for region in regions {
            let color = colors.indices.contains(region.filamentIndex) ? colors[region.filamentIndex] : fallback
            let node = region.mesh.makeNode(color: color)
            node.name = "filament_\(region.filamentIndex)"
            node.renderingOrder = 1
            // A small normal offset avoids coplanar flicker while retaining depth
            // testing; rear painted faces must not show through the model.
            node.geometry?.shaderModifiers = [.geometry: "_geometry.position.xyz += _geometry.normal * 0.01;"]
            root.addChildNode(node)
        }
        return root
    }

    static func filamentPaintSmokeTest() -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        let scene = SCNScene()
        scene.background.contents = UIColor.black
        let left = MeshGeometry(positions: [-1.8,-1,0, -0.2,-1,0, -1,1,0], indices: [0,1,2],
            min: SIMD3(-1.8,-1,0), max: SIMD3(-0.2,1,0))
        let right = MeshGeometry(positions: [0.2,-1,0, 1.8,-1,0, 1,1,0], indices: [0,1,2],
            min: SIMD3(0.2,-1,0), max: SIMD3(1.8,1,0))
        var colors = [UIColor](repeating: .blue, count: 32)
        colors[0] = .red; colors[31] = .green
        let object = SCNNode()
        let paint = makeFilamentPaintNode(regions: [
            PaintedFilamentRegion(objectIndex: 0, filamentIndex: 0, mesh: left),
            PaintedFilamentRegion(objectIndex: 0, filamentIndex: 31, mesh: right)
        ], colors: colors, fallback: .white)
        object.addChildNode(paint)
        scene.rootNode.addChildNode(object)
        object.position.x = 7
        guard abs(paint.convertPosition(SCNVector3Zero, to: nil).x - 7) < 0.001 else { return false }
        object.position.x = 0
        // Isolate material/color mapping from lighting; the production geometry
        // and normal-offset shader still run through the real GPU.
        for node in paint.childNodes { node.geometry?.firstMaterial?.lightingModel = .constant }
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = 2
        camera.position.z = 10
        scene.rootNode.addChildNode(camera)
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene; renderer.pointOfView = camera
        guard let image = renderer.snapshot(atTime: 0, with: CGSize(width: 64, height: 64), antialiasingMode: .none).cgImage else { return false }
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 64, height: 64, bitsPerComponent: 8,
                bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            let a = (32 * 64 + 16) * 4, b = (32 * 64 + 48) * 4
            return bytes[a] > 180 && bytes[a+1] < 50 && bytes[a+2] < 50 &&
                bytes[b] < 50 && bytes[b+1] > 180 && bytes[b+2] < 50
        }
    }

    private func makeScene() -> SCNScene {
        let scene = SCNScene()

        // Lights (SceneKit world / Y-up)
        let ambient = SCNNode()
        ambient.light = {
            let l = SCNLight()
            l.type = .ambient
            l.intensity = 500
            l.color = UIColor.white
            return l
        }()
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = {
            let l = SCNLight()
            l.type = .directional
            l.intensity = 900
            l.castsShadow = true
            l.shadowMode = .deferred
            l.shadowColor = UIColor.black.withAlphaComponent(0.35)
            return l
        }()
        key.eulerAngles = SCNVector3(-Float.pi / 3.2, Float.pi / 4.5, 0)
        key.position = SCNVector3(0, 400, 200)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = {
            let l = SCNLight()
            l.type = .directional
            l.intensity = 280
            return l
        }()
        fill.eulerAngles = SCNVector3(-Float.pi / 6, -Float.pi / 3, 0)
        scene.rootNode.addChildNode(fill)

        // Content root: Z-up → Y-up
        let content = SCNNode()
        content.name = "content"
        content.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        scene.rootNode.addChildNode(content)

        // Build plate (XY in slic3r / content space)
        let bed = makeBedNode(size: bedSize, accent: accent, texturePath: bedTexturePath)
        bed.name = "bed"
        content.addChildNode(bed)

        // Camera in SceneKit world space
        let cam = SCNNode()
        cam.name = "camera"
        cam.camera = SCNCamera()
        cam.camera?.zNear = 0.5
        cam.camera?.zFar = 8000
        cam.camera?.fieldOfView = 42
        cam.camera?.projectionDirection = .vertical
        // Default 3/4 view of a 220mm plate (slic3r center 110,110 → world 110, 0, -110)
        let cx = bedSize.x * 0.5
        let cy = bedSize.y * 0.5
        cam.position = SCNVector3(cx + 180, 200, -cy + 220)
        cam.look(at: SCNVector3(cx, 0, -cy))
        scene.rootNode.addChildNode(cam)

        return scene
    }

    /// Bed in content/Z-up space: SCNPlane is already XY, no extra rotation.
    private func makeBedNode(size: SIMD2<Float>, accent: UIColor, texturePath: String? = nil) -> SCNNode {
        let w = CGFloat(size.x)
        let h = CGFloat(size.y)
        let plane = SCNPlane(width: w, height: h)
        plane.widthSegmentCount = 1
        plane.heightSegmentCount = 1

        let mat = SCNMaterial()
        if let texturePath, let img = UIImage(contentsOfFile: texturePath) {
            mat.diffuse.contents = img
            mat.roughness.contents = 0.85
            mat.metalness.contents = 0.05
        } else {
            mat.diffuse.contents = UIColor(red: 0.18, green: 0.19, blue: 0.21, alpha: 1)
            mat.roughness.contents = 0.9
            mat.metalness.contents = 0.08
        }
        mat.isDoubleSided = true
        mat.locksAmbientWithDiffuse = true
        plane.materials = [mat]

        let node = SCNNode(geometry: plane)
        // Center of plate in XY (slic3r printable origin usually 0,0)
        node.position = SCNVector3(size.x * 0.5, size.y * 0.5, -0.02)

        // Grid over plate (lighter when textured so logo stays readable)
        let hasTex = texturePath != nil && !(texturePath ?? "").isEmpty
        let grid = makeGridNode(size: size, accent: accent, muted: hasTex)
        node.addChildNode(grid)

        // Teal rim slightly larger, behind plate surface
        let rim = SCNPlane(width: w + 2.0, height: h + 2.0)
        let rimMat = SCNMaterial()
        rimMat.diffuse.contents = accent.withAlphaComponent(0.45)
        rimMat.isDoubleSided = true
        rimMat.lightingModel = .constant
        rim.materials = [rimMat]
        let rimNode = SCNNode(geometry: rim)
        rimNode.position = SCNVector3(0, 0, -0.08)
        node.addChildNode(rimNode)

        // Origin marker (0,0 corner) — small accent cube
        let origin = SCNBox(width: 4, height: 4, length: 1.5, chamferRadius: 0)
        let oMat = SCNMaterial()
        oMat.diffuse.contents = accent
        oMat.lightingModel = .constant
        origin.materials = [oMat]
        let originNode = SCNNode(geometry: origin)
        // Plane local: (-w/2, -h/2) is bed (0,0)
        originNode.position = SCNVector3(-size.x * 0.5 + 2, -size.y * 0.5 + 2, 0.8)
        node.addChildNode(originNode)

        return node
    }

    private func makeGridNode(size: SIMD2<Float>, accent: UIColor, muted: Bool = false) -> SCNNode {
        let parent = SCNNode()
        let step: Float = 10
        var verts: [SCNVector3] = []
        let x0: Float = -size.x * 0.5
        let y0: Float = -size.y * 0.5
        let x1 = x0 + size.x
        let y1 = y0 + size.y

        var x = x0
        while x <= x1 + 0.01 {
            verts.append(SCNVector3(x, y0, 0.05))
            verts.append(SCNVector3(x, y1, 0.05))
            x += step
        }
        var y = y0
        while y <= y1 + 0.01 {
            verts.append(SCNVector3(x0, y, 0.05))
            verts.append(SCNVector3(x1, y, 0.05))
            y += step
        }

        // Major every 50mm (brighter)
        var majorVerts: [SCNVector3] = []
        x = x0
        while x <= x1 + 0.01 {
            if abs(x.truncatingRemainder(dividingBy: 50)) < 0.01 || abs(x) < 0.01 {
                majorVerts.append(SCNVector3(x, y0, 0.06))
                majorVerts.append(SCNVector3(x, y1, 0.06))
            }
            x += step
        }
        y = y0
        while y <= y1 + 0.01 {
            if abs(y.truncatingRemainder(dividingBy: 50)) < 0.01 || abs(y) < 0.01 {
                majorVerts.append(SCNVector3(x0, y, 0.06))
                majorVerts.append(SCNVector3(x1, y, 0.06))
            }
            y += step
        }

        func lineNode(from verts: [SCNVector3], alpha: CGFloat) -> SCNNode {
            guard verts.count >= 2 else { return SCNNode() }
            let src = SCNGeometrySource(vertices: verts)
            var indices: [Int32] = []
            for i in 0..<(verts.count / 2) {
                indices.append(Int32(i * 2))
                indices.append(Int32(i * 2 + 1))
            }
            let idxData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
            let elem = SCNGeometryElement(
                data: idxData,
                primitiveType: .line,
                primitiveCount: indices.count / 2,
                bytesPerIndex: MemoryLayout<Int32>.size
            )
            let geo = SCNGeometry(sources: [src], elements: [elem])
            let mat = SCNMaterial()
            mat.diffuse.contents = UIColor.white.withAlphaComponent(alpha)
            mat.lightingModel = .constant
            mat.isDoubleSided = true
            geo.materials = [mat]
            return SCNNode(geometry: geo)
        }

        let minorA: CGFloat = muted ? 0.06 : 0.14
        let majorA: CGFloat = muted ? 0.14 : 0.32
        parent.addChildNode(lineNode(from: verts, alpha: minorA))
        parent.addChildNode(lineNode(from: majorVerts, alpha: majorA))
        return parent
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var view: SCNView?
        weak var navigationCube: SCNView?
        var parent: PlateSceneView?
        var lastMeshKey: String = ""
        var lastFilamentPaintRevision = -1
        private var toolheadTimer: Timer?
        private var displayedToolheadMove: Double?
        private var requestedToolheadMove: Double?

        func stopToolheadMotion() {
            toolheadTimer?.invalidate()
            toolheadTimer = nil
            displayedToolheadMove = nil
            requestedToolheadMove = nil
        }

        func moveToolhead(_ marker: SCNNode, position: SCNVector3, move: Double?,
                          geometry: GCodePathGeometry?, smooth: Bool, preview: SCNNode) {
            guard let move, move.isFinite, let geometry, smooth,
                  let start = displayedToolheadMove else {
                stopToolheadMotion()
                marker.position = position
                GCodePathGeometry.updateCursor(on: preview, through: move)
                displayedToolheadMove = move
                requestedToolheadMove = move
                return
            }
            guard requestedToolheadMove != move else { return }
            toolheadTimer?.invalidate()
            requestedToolheadMove = move
            let began = ProcessInfo.processInfo.systemUptime
            // Interpolate the move cursor, then sample the real polyline. A
            // position tween would cut across corners and disconnected paths.
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self, weak marker, weak preview] timer in
                guard let self, let marker, let preview else { timer.invalidate(); return }
                let t = min(1, (ProcessInfo.processInfo.systemUptime - began) / 0.08)
                let cursor = start + (move - start) * t
                if let point = geometry.position(atMove: cursor) { marker.position = point }
                GCodePathGeometry.updateCursor(on: preview, through: cursor)
                self.displayedToolheadMove = cursor
                if t >= 1 { timer.invalidate(); self.toolheadTimer = nil }
            }
            toolheadTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        var lastPreviewID: ObjectIdentifier?
        var lastShowGCode = false
        var lastBed: SIMD2<Float> = SIMD2(0, 0)
        var lastTexture: String = ""
        var lastFitRequest: UUID?
        var pinchGesture: UIPinchGestureRecognizer?
        private var rotateDegrees: Float = 0
        private var rotationNode: SCNNode?
        var panGesture: UIPanGestureRecognizer?
        var tapGesture: UITapGestureRecognizer?
        var isDragging = false
        /// Accumulated visual offset in slic3r XY mm applied to model node while dragging
        var visualOffset: SIMD2<Float> = .zero
        /// Object index captured at drag begin (survives accidental deselect before commit)
        var dragObjectIndex: Int = -1
        /// Ignore bed-tap deselect right after a drag (iOS often delivers a tap after pan end)
        var suppressSelectUntil: TimeInterval = 0
        private var dragStartBedXY: SIMD2<Float>?
        private var lastBedXY: SIMD2<Float>?
        private var paintStrokeActive = false
        private var lastPaintScreen: CGPoint?

        func installGestures(on view: SCNView) {
            if panGesture == nil {
                let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
                pan.maximumNumberOfTouches = 1
                pan.delegate = self
                pan.minimumNumberOfTouches = 1
                pan.isEnabled = true
                view.addGestureRecognizer(pan)
                panGesture = pan
            }
            if pinchGesture == nil {
                let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
                pinch.delegate = self
                view.addGestureRecognizer(pinch)
                pinchGesture = pinch
            }
            if tapGesture == nil {
                let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
                tap.isEnabled = false
                if let panGesture { tap.require(toFail: panGesture) }
                view.addGestureRecognizer(tap)
                tapGesture = tap
            }
        }

        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began {
                panGesture?.isEnabled = false
                panGesture?.isEnabled = true
            }
            guard gesture.numberOfTouches == 2, gesture.state == .changed, let view else { return }
            zoom(scale: Float(gesture.scale), view: view, anchor: gesture.location(in: view))
            gesture.scale = 1
        }

        func zoom(scale: Float, view: SCNView, anchor: CGPoint? = nil) {
            guard let camera = view.pointOfView, let lens = camera.camera else { return }
            let controller = view.defaultCameraController
            let target = SIMD3<Float>(controller.target.x, controller.target.y, controller.target.z)
            let distance = simd_length(camera.simdPosition - target)
            guard distance > 0, scale.isFinite, scale > 0 else { return }
            let ratio: Float
            if lens.usesOrthographicProjection {
                let previous = Float(lens.orthographicScale)
                guard previous > 0 else { return }
                let next = min(max(previous / scale, 0.05), 20000)
                ratio = next / previous
                // Update after unprojecting the original anchor below.
            } else { ratio = min(max(distance / scale, 0.5), 20000) / distance }
            // Keep the point under the pinch centroid stationary on screen.
            var focus = target
            if let anchor {
                let depth = view.projectPoint(controller.target).z
                let world = view.unprojectPoint(SCNVector3(Float(anchor.x), Float(anchor.y), depth))
                focus = SIMD3<Float>(world.x, world.y, world.z)
            }
            let nextTarget = focus + (target - focus) * ratio
            if lens.usesOrthographicProjection {
                lens.orthographicScale *= Double(ratio)
                camera.simdPosition += nextTarget - target
            } else {
                camera.simdPosition = focus + (camera.simdPosition - focus) * ratio
                lens.zNear = min(lens.zNear, Double(distance * ratio) / 100)
                lens.zFar = max(lens.zFar, Double(distance * ratio) * 3)
            }
            controller.target = SCNVector3(nextTarget.x, nextTarget.y, nextTarget.z)
        }

        /// Match the visible span at the current target; changing projection
        /// must preserve the user's pan, zoom and orientation.
        func setProjection(_ projection: CameraProjection, view: SCNView) {
            guard let camera = view.pointOfView, let lens = camera.camera else { return }
            let orthographic = projection == .orthographic
            guard lens.usesOrthographicProjection != orthographic else { return }
            let target = view.defaultCameraController.target
            let center = SIMD3<Float>(target.x, target.y, target.z)
            let offset = camera.simdPosition - center
            let distance = simd_length(offset)
            guard distance > 0 else { return }
            let tangent = tan(Double(lens.fieldOfView) * .pi / 360)
            guard tangent > 0 else { return }
            if orthographic {
                lens.orthographicScale = Double(distance) * tangent
            } else {
                let nextDistance = Float(lens.orthographicScale / tangent)
                camera.simdPosition = center + offset * (nextDistance / distance)
                lens.zNear = min(lens.zNear, Double(nextDistance) / 100)
                lens.zFar = max(lens.zFar, Double(nextDistance) * 3)
            }
            lens.usesOrthographicProjection = orthographic
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let cube = navigationCube, let touched = touch.view else { return true }
            return !touched.isDescendant(of: cube)
        }

        func installNavigationCube(on view: SCNView) {
            let cube = PlateSCNView(frame: .zero)
            cube.scene = SCNScene()
            cube.backgroundColor = .clear
            cube.isPlaying = false
            cube.translatesAutoresizingMaskIntoConstraints = false
            cube.accessibilityLabel = "Navigation cube"
            cube.isAccessibilityElement = true
            let box = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0.025)
            let faces: [CameraPreset] = [.front, .right, .back, .left, .top, .bottom]
            box.materials = faces.map { face in
                let material = SCNMaterial()
                material.lightingModel = .constant
                material.diffuse.contents = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128)).image { context in
                    UIColor(white: 0.24, alpha: 1).setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
                    let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 24), .foregroundColor: UIColor.white]
                    let text = face.rawValue as NSString
                    let size = text.size(withAttributes: attributes)
                    text.draw(at: CGPoint(x: (128-size.width)/2, y: (128-size.height)/2), withAttributes: attributes)
                }
                return material
            }
            cube.scene?.rootNode.addChildNode(SCNNode(geometry: box))
            let camera = SCNNode()
            camera.camera = SCNCamera()
            camera.camera?.usesOrthographicProjection = true
            camera.camera?.orthographicScale = 0.9
            cube.scene?.rootNode.addChildNode(camera)
            cube.pointOfView = camera
            cube.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(cubeTapped(_:))))
            cube.accessibilityCustomActions = CameraPreset.allCases.map { preset in
                UIAccessibilityCustomAction(name: preset.rawValue) { [weak self] _ in
                    self?.selectCamera(preset)
                    return true
                }
            }
            view.addSubview(cube)
            NSLayoutConstraint.activate([
                // Match desktop's lower-left navigator and leave iOS/Metal HUDs clear.
                cube.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
                cube.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -112),
                cube.widthAnchor.constraint(equalToConstant: 84), cube.heightAnchor.constraint(equalToConstant: 84)
            ])
            navigationCube = cube
            updateNavigationCube()
        }

        @objc private func cubeTapped(_ gesture: UITapGestureRecognizer) {
            guard let cube = navigationCube,
                  let hit = cube.hitTest(gesture.location(in: cube), options: nil).first else { return }
            let faces: [CameraPreset] = [.front, .right, .back, .left, .top, .bottom]
            guard faces.indices.contains(hit.geometryIndex) else { return }
            selectCamera(faces[hit.geometryIndex])
        }

        func selectCamera(_ preset: CameraPreset) {
            guard let view, let parent else { return }
            if let select = parent.onCameraView { select(preset); return }
            let low = parent.framingBounds?.min ?? parent.mesh?.min ?? SIMD3<Float>(0, 0, 0)
            let high = parent.framingBounds?.max ?? parent.mesh?.max ?? SIMD3<Float>(parent.bedSize.x, parent.bedSize.y, 0)
            frameCamera(view: view, minimum: low, maximum: high, preset: preset)
        }

        private func updateNavigationCube() {
            guard let source = view?.pointOfView, let camera = navigationCube?.pointOfView else { return }
            camera.simdOrientation = source.simdOrientation
            camera.simdPosition = source.simdOrientation.act(SIMD3<Float>(0, 0, 3))
            navigationCube?.setNeedsDisplay()
        }

        private func cameraPan(_ gesture: UIPanGestureRecognizer, view: SCNView, mode: PlateTouchMode) {
            // Consume the recognizer's initial movement too; subsequent changes
            // are incremental so crossing its recognition threshold cannot jump.
            guard gesture.state == .began || gesture.state == .changed else { return }
            if gesture.state == .began && mode == .orbit { parent?.onOrbitBegin?() }
            let delta = gesture.translation(in: view)
            gesture.setTranslation(.zero, in: view)
            cameraDrag(delta: delta, view: view, mode: mode)
            updateNavigationCube()
        }

        func cameraDrag(delta: CGPoint, view: SCNView, mode: PlateTouchMode) {
            guard let camera = view.pointOfView, delta.x.isFinite, delta.y.isFinite else { return }
            let controller = view.defaultCameraController
            let target = SIMD3<Float>(controller.target.x, controller.target.y, controller.target.z)
            let offset = camera.simdPosition - target
            let distance = simd_length(offset)
            guard distance > 0 else { return }
            if mode == .orbit {
                // One screen width/height is half a turn on every device. Keep
                // the existing target after panning; never reframe on touch-down.
                let yaw = simd_quatf(angle: -Float(delta.x / max(view.bounds.width, 1)) * .pi,
                                     axis: SIMD3<Float>(0, 1, 0))
                let elevation = asinf(min(max(offset.y / distance, -1), 1))
                let requested = Float(delta.y / max(view.bounds.height, 1)) * Float.pi
                let limit = Float.pi * 0.47
                // Preserve an existing top/bottom view: clamping must prevent
                // moving farther past a pole, never snap a valid saved framing.
                let lower = min(-limit, elevation)
                let upper = max(limit, elevation)
                let next = min(max(elevation + requested, lower), upper)
                let right = yaw.act(camera.simdWorldRight)
                let pitch = simd_quatf(angle: -(next - elevation), axis: right)
                let rotation = pitch * yaw
                camera.simdPosition = target + rotation.act(offset)
                camera.simdOrientation = simd_normalize(rotation * camera.simdOrientation)
            } else {
                // Unprojection respects the real projection/FOV and aspect ratio.
                let center = view.projectPoint(controller.target)
                let a = view.unprojectPoint(center)
                let b = view.unprojectPoint(SCNVector3(center.x + Float(delta.x), center.y + Float(delta.y), center.z))
                let shift = SIMD3<Float>(a.x - b.x, a.y - b.y, a.z - b.z)
                camera.simdPosition += shift
                let next = target + shift
                controller.target = SCNVector3(next.x, next.y, next.z)
            }
        }

        private func transformObject(_ gesture: UIPanGestureRecognizer, view: SCNView, parent: PlateSceneView) {
            switch gesture.state {
            case .began:
                dragObjectIndex = hitObjectIndex(view: view, screen: gesture.location(in: view)) ?? parent.selectedObjectIndex
                guard let model = view.scene?.rootNode.childNode(withName: "content", recursively: false)?.childNode(withName: "model", recursively: false) else { return }
                if dragObjectIndex >= 0 { parent.onSelectObject?(dragObjectIndex) }
                rotationNode = dragObjectIndex >= 0 ? model.childNode(withName: "object_\(dragObjectIndex)", recursively: false) : model
                let mesh = dragObjectIndex >= 0 && dragObjectIndex < parent.objectMeshes.count ? parent.objectMeshes[dragObjectIndex] : parent.mesh
                if let mesh {
                    let center = (mesh.min + mesh.max) * 0.5
                    rotationNode?.pivot = SCNMatrix4MakeTranslation(center.x, center.y, center.z)
                    rotationNode?.position = SCNVector3(center.x, center.y, center.z)
                }
                rotateDegrees = 0
                isDragging = true
            case .changed:
                guard isDragging else { return }
                rotateDegrees = Float(gesture.translation(in: view).x / max(view.bounds.width, 1)) * 180
                if parent.touchMode == .scale {
                    let factor = expf(Float(-gesture.translation(in: view).y / max(view.bounds.height, 1)) * logf(4))
                    let clamped = max(0.01, min(100, factor))
                    rotationNode?.scale = SCNVector3(clamped, clamped, clamped)
                    return
                }
                let angle = rotateDegrees * Float.pi / 180
                switch parent.rotationAxis {
                case 0: rotationNode?.eulerAngles.x = angle
                case 1: rotationNode?.eulerAngles.y = angle
                default: rotationNode?.eulerAngles.z = angle
                }
            case .ended, .cancelled, .failed:
                let scale = rotationNode?.scale.x ?? 1
                let scaling = parent.touchMode == .scale
                let commit = gesture.state == .ended && isDragging &&
                    (scaling ? abs(scale - 1) > 0.001 : abs(rotateDegrees) > 0.1)
                rotationNode?.transform = SCNMatrix4Identity
                rotationNode?.pivot = SCNMatrix4Identity
                rotationNode = nil
                isDragging = false
                suppressSelectUntil = Date().timeIntervalSince1970 + 0.35
                if commit {
                    if scaling { parent.onScaleCommit?(scale, dragObjectIndex) }
                    else { parent.onRotateCommit?(rotateDegrees, dragObjectIndex) }
                }
                dragObjectIndex = -1
            default: break
            }
        }

        /// SceneKit world → slic3r XYZ under content R_x(-90°)
        private func slic3rFromWorld(_ w: SCNVector3) -> SIMD3<Float> {
            SIMD3<Float>(w.x, -w.z, w.y)
        }

        private func hitModelSlic3r(view: SCNView, screen: CGPoint) -> SIMD3<Float>? {
            let hits = view.hitTest(screen, options: [
                SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue
            ])
            if let h = hits.first(where: {
                let n = $0.node.name
                let p = $0.node.parent?.name
                return n == "model" || p == "model" || n == "paintOverlay" || p == "paintOverlay" || p == "filamentPaint"
            }) {
                return slic3rFromWorld(h.worldCoordinates)
            }
            return nil
        }

        /// Resolve object index from SceneKit hit (node name object_N)
        private func hitObjectIndex(view: SCNView, screen: CGPoint) -> Int? {
            hitObject(view: view, screen: screen)?.index
        }

        private func hitObject(view: SCNView, screen: CGPoint) -> (index: Int, point: SIMD3<Float>)? {
            let hits = view.hitTest(screen, options: [
                SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue
            ])
            for h in hits {
                var n: SCNNode? = h.node
                while let node = n {
                    if let name = node.name, name.hasPrefix("object_"),
                       let idx = Int(name.dropFirst("object_".count)) {
                        return (idx, slic3rFromWorld(h.worldCoordinates))
                    }
                    if node.name == "model" { break }
                    n = node.parent
                }
            }
            return nil
        }

        @objc private func handleTap(_ gr: UITapGestureRecognizer) {
            guard let view = view, let parent = parent else { return }
            // After a drag, iOS often synthesizes a tap — ignore briefly so we don't deselect
            if Date().timeIntervalSince1970 < suppressSelectUntil {
                return
            }
            let screen = gr.location(in: view)
            if parent.touchMode == .layOnFace {
                if let hit = hitObject(view: view, screen: screen) { parent.onFacePick?(hit.index, hit.point) }
                return
            }
            if parent.paintMode {
                if let p = hitModelSlic3r(view: view, screen: screen) {
                    parent.onPaintHit?(p, true)
                }
                return
            }
            if parent.measureMode {
                if let p = hitModelSlic3r(view: view, screen: screen) {
                    parent.onMeasurePick?(p)
                    return
                }
                if let bedXY = projectToBedXY(view: view, screen: screen) {
                    parent.onMeasurePick?(SIMD3(bedXY.x, bedXY.y, 0))
                }
                return
            }
            // Tap object on plate → select; tap empty bed → deselect
            if parent.selectMode {
                if let idx = hitObjectIndex(view: view, screen: screen) {
                    parent.onSelectObject?(idx)
                } else {
                    parent.onSelectObject?(-1)
                }
            }
        }

        @objc private func handlePan(_ gr: UIPanGestureRecognizer) {
            guard let view = view, let parent = parent else { return }
            let pt = gr.location(in: view)

            // Paint brush stroke
            if parent.paintMode {
                switch gr.state {
                case .began:
                    isDragging = true
                    paintStrokeActive = true
                    view.allowsCameraControl = false
                    lastPaintScreen = pt
                    if let p = hitModelSlic3r(view: view, screen: pt) {
                        parent.onPaintHit?(p, true)
                    }
                case .changed:
                    if let last = lastPaintScreen {
                        let dx = pt.x - last.x, dy = pt.y - last.y
                        if dx * dx + dy * dy < 36 { return }
                    }
                    lastPaintScreen = pt
                    if let p = hitModelSlic3r(view: view, screen: pt) {
                        parent.onPaintHit?(p, false)
                    }
                case .ended, .cancelled, .failed:
                    isDragging = false
                    paintStrokeActive = false
                    lastPaintScreen = nil
                    view.allowsCameraControl = false
                default:
                    break
                }
                return
            }

            if parent.touchMode == .orbit || parent.touchMode == .pan || parent.touchMode == .layOnFace {
                cameraPan(gr, view: view, mode: parent.touchMode == .layOnFace ? .orbit : parent.touchMode)
                return
            }
            if parent.touchMode == .rotate || parent.touchMode == .scale {
                transformObject(gr, view: view, parent: parent)
                return
            }
            guard parent.moveMode else { return }

            switch gr.state {
            case .began:
                // Prefer hit on object — select it, then drag. Move gizmo also allows bed drag.
                if let idx = hitObjectIndex(view: view, screen: pt) {
                    dragObjectIndex = idx
                    parent.onSelectObject?(idx)
                } else if parent.moveMode {
                    // Move gizmo: drag selected (or all if none)
                    dragObjectIndex = parent.selectedObjectIndex
                } else {
                    // Select mode on empty bed: fail this pan so SceneKit orbit can run
                    gr.state = .failed
                    return
                }
                guard let bedXY = projectToBedXY(view: view, screen: pt) else {
                    gr.state = .failed
                    return
                }
                isDragging = true
                view.allowsCameraControl = false
                dragStartBedXY = bedXY
                lastBedXY = bedXY
                visualOffset = .zero

            case .changed:
                guard isDragging,
                      let start = dragStartBedXY,
                      let bedXY = projectToBedXY(view: view, screen: pt)
                else { return }
                let total = SIMD2(bedXY.x - start.x, bedXY.y - start.y)
                visualOffset = total
                applyVisualOffset(total, selectedIndex: dragObjectIndex)
                lastBedXY = bedXY
                parent.onDragLive?(total.x, total.y)

            case .ended, .cancelled, .failed:
                let total = visualOffset
                let wasDragging = isDragging
                let objIdx = dragObjectIndex
                isDragging = false
                dragStartBedXY = nil
                lastBedXY = nil
                // Keep visual offset until engine commits + mesh rebuild (avoids snap-to-old-pose)
                if gr.state == .ended, wasDragging, abs(total.x) > 0.05 || abs(total.y) > 0.05 {
                    // Suppress synthetic tap that would deselect right after drag
                    suppressSelectUntil = Date().timeIntervalSince1970 + 0.35
                    parent.onDragCommit?(total.x, total.y, objIdx)
                    // Clear visual offset after a tick — mesh should already include the move
                    DispatchQueue.main.async {
                        self.applyVisualOffset(.zero, selectedIndex: objIdx)
                        self.visualOffset = .zero
                        self.dragObjectIndex = -1
                    }
                } else {
                    applyVisualOffset(.zero, selectedIndex: objIdx)
                    visualOffset = .zero
                    dragObjectIndex = -1
                }
                view.allowsCameraControl = false

            default:
                break
            }
        }

        /// Ray → world Y=0 (bed) → slic3r XY under content R_x(-90).
        private func projectToBedXY(view: SCNView, screen: CGPoint) -> SIMD2<Float>? {
            // Unproject near/far along the view ray
            let near = view.unprojectPoint(SCNVector3(Float(screen.x), Float(screen.y), 0))
            let far = view.unprojectPoint(SCNVector3(Float(screen.x), Float(screen.y), 1))
            let dx = far.x - near.x
            let dy = far.y - near.y
            let dz = far.z - near.z
            // Intersect ray with world Y = 0 (content bed after R_x(-90))
            if abs(dy) < 1e-6 { return nil }
            let t = -near.y / dy
            if t < 0 || t > 1.5 { return nil } // slightly allow beyond far
            let wx = near.x + dx * t
            let wz = near.z + dz * t
            // World (x, 0, z) ← content (x, y, 0) with content R_x(-90): (x,z,-y) ⇒ y = -z
            let slic3rX = wx
            let slic3rY = -wz
            return SIMD2(slic3rX, slic3rY)
        }

        private func applyVisualOffset(_ offset: SIMD2<Float>, selectedIndex: Int = -1) {
            guard let content = view?.scene?.rootNode.childNode(withName: "content", recursively: false),
                  let model = content.childNode(withName: "model", recursively: false)
            else { return }
            // Offset only the selected object node when possible; else whole group
            if selectedIndex >= 0,
               let obj = model.childNode(withName: "object_\(selectedIndex)", recursively: false) {
                obj.position = SCNVector3(offset.x, offset.y, 0)
                // Reset siblings
                for child in model.childNodes where child.name != "object_\(selectedIndex)" {
                    child.position = SCNVector3Zero
                }
            } else {
                model.position = SCNVector3(offset.x, offset.y, 0)
            }
        }

        func frameCameraOnBed(view: SCNView, bedSize: SIMD2<Float>) {
            frameCamera(view: view, minimum: .zero, maximum: SIMD3(bedSize.x, bedSize.y, 0))
        }

        func frameCamera(view: SCNView, minimum: SIMD3<Float>, maximum: SIMD3<Float>, preset: CameraPreset = .home) {
            guard let cam = view.scene?.rootNode.childNode(withName: "camera", recursively: false) else { return }

            // Mesh in slic3r Z-up under content; world after R_x(-90): (x, z, -y)
            let mx = (minimum.x + maximum.x) * 0.5
            let my = (minimum.y + maximum.y) * 0.5
            let mz = (minimum.z + maximum.z) * 0.5
            let modelWorld = SCNVector3(mx, mz, -my)

            let target = modelWorld
            let dx = maximum.x - minimum.x
            let dy = maximum.y - minimum.y
            let dz = maximum.z - minimum.z
            let radius = max(sqrtf(dx * dx + dy * dy + dz * dz) * 0.5, 0.5)
            let aspect = max(Float(view.bounds.width / max(view.bounds.height, 1)), 0.2)
            let verticalHalfAngle = Float((cam.camera?.fieldOfView ?? 42) * Double.pi / 360.0)
            let limitingAngle = min(verticalHalfAngle, atanf(tanf(verticalHalfAngle) * aspect))
            let dist = max(radius / sinf(limitingAngle) * 1.15, 3)
            cam.camera?.zNear = max(Double(dist) / 1000, 0.01)
            cam.camera?.zFar = max(Double(dist + radius * 3), 100)
            cam.camera?.orthographicScale = Double(radius * 1.15 / min(aspect, 1))

            let direction = preset.direction
            cam.simdPosition = SIMD3(target.x, target.y, target.z) + direction * dist
            let up = preset == .top ? SCNVector3(0, 0, -1) : preset == .bottom ? SCNVector3(0, 0, 1) : SCNVector3(0, 1, 0)
            cam.look(at: target, up: up, localFront: SCNVector3(0, 0, -1))
            updateNavigationCube()
            view.pointOfView = cam
            view.defaultCameraController.pointOfView = cam
            view.defaultCameraController.automaticTarget = false
            view.defaultCameraController.target = target
        }
    }
}

// MARK: - Mesh from C API

struct MeshGeometry {
    var positions: [Float] // xyz * n  (slic3r Z-up)
    var indices: [UInt32]
    var min: SIMD3<Float>
    var max: SIMD3<Float>

    var vertexCount: Int { positions.count / 3 }

    /// Node lives under "content" (Z-up) — no extra euler rotation.
    func makeNode(color: UIColor) -> SCNNode {
        let vcount = vertexCount
        guard vcount > 0, !indices.isEmpty else { return SCNNode() }

        let posData = Data(bytes: positions, count: positions.count * MemoryLayout<Float>.size)
        let source = SCNGeometrySource(
            data: posData,
            semantic: .vertex,
            vectorCount: vcount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 3
        )

        var normals = [Float](repeating: 0, count: positions.count)
        let triCount = indices.count / 3
        for t in 0..<triCount {
            let i0 = Int(indices[t * 3])
            let i1 = Int(indices[t * 3 + 1])
            let i2 = Int(indices[t * 3 + 2])
            guard i0 < vcount, i1 < vcount, i2 < vcount else { continue }
            let ax = positions[i0 * 3], ay = positions[i0 * 3 + 1], az = positions[i0 * 3 + 2]
            let bx = positions[i1 * 3], by = positions[i1 * 3 + 1], bz = positions[i1 * 3 + 2]
            let cx = positions[i2 * 3], cy = positions[i2 * 3 + 1], cz = positions[i2 * 3 + 2]
            let ux = bx - ax, uy = by - ay, uz = bz - az
            let vx = cx - ax, vy = cy - ay, vz = cz - az
            var nx: Float = uy * vz - uz * vy
            var ny: Float = uz * vx - ux * vz
            var nz: Float = ux * vy - uy * vx
            let lenSq: Float = nx * nx + ny * ny + nz * nz
            let len: Float = lenSq > 0.0000001 ? sqrtf(lenSq) : 0.0001
            nx /= len; ny /= len; nz /= len
            for i in [i0, i1, i2] {
                normals[i * 3] += nx
                normals[i * 3 + 1] += ny
                normals[i * 3 + 2] += nz
            }
        }
        for i in 0..<vcount {
            let nx: Float = normals[i * 3]
            let ny: Float = normals[i * 3 + 1]
            let nz: Float = normals[i * 3 + 2]
            let lenSq: Float = nx * nx + ny * ny + nz * nz
            let len: Float = lenSq > 0.0000001 ? sqrtf(lenSq) : 0.0001
            normals[i * 3] = nx / len
            normals[i * 3 + 1] = ny / len
            normals[i * 3 + 2] = nz / len
        }
        let nData = Data(bytes: normals, count: normals.count * MemoryLayout<Float>.size)
        let nSource = SCNGeometrySource(
            data: nData,
            semantic: .normal,
            vectorCount: vcount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 3
        )

        let idxData = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.size)
        let element = SCNGeometryElement(
            data: idxData,
            primitiveType: .triangles,
            primitiveCount: triCount,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geo = SCNGeometry(sources: [source, nSource], elements: [element])
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.metalness.contents = 0.12
        mat.roughness.contents = 0.48
        mat.isDoubleSided = false
        geo.materials = [mat]

        // No eulerAngles — parent "content" already converts Z-up → Y-up
        return SCNNode(geometry: geo)
    }
}

// MARK: - G-code path preview (slic3r Z-up; parent content rotates)

struct GCodePathGeometry {
    // Names and metrics follow libvgcode::EViewType; Z height is an extra mobile view.
    enum ColorMode: String, CaseIterable, Identifiable {
        case summary, feature, filament, speed, actualSpeed, acceleration, jerk
        case layerHeight, lineWidth, flow, actualFlow, layerTime, layerTimeLog
        case fan, temperature, pressureAdvance, tool, height
        var id: String { rawValue }
        var label: String {
            switch self {
            case .summary: return "Summary"
            case .feature: return "Line type"
            case .filament: return "Filament"
            case .height: return "Z height"
            case .layerHeight: return "Layer height"
            case .lineWidth: return "Line width"
            case .speed: return "Speed"
            case .actualSpeed: return "Actual speed"
            case .acceleration: return "Acceleration"
            case .jerk: return "Jerk"
            case .flow: return "Flow"
            case .actualFlow: return "Actual flow"
            case .layerTime: return "Layer time"
            case .layerTimeLog: return "Layer time (log)"
            case .fan: return "Fan speed"
            case .temperature: return "Temperature"
            case .pressureAdvance: return "Pressure advance"
            case .tool: return "Tool"
            }
        }
        var unit: String {
            switch self {
            case .speed, .actualSpeed, .jerk: return "mm/s"
            case .acceleration: return "mm/s²"
            case .flow, .actualFlow: return "mm³/s"
            case .layerTime, .layerTimeLog, .pressureAdvance: return "s"
            case .fan: return "%"
            case .temperature: return "°C"
            case .height, .layerHeight, .lineWidth: return "mm"
            default: return ""
            }
        }
        var isNumeric: Bool { ![.summary, .feature, .filament, .tool].contains(self) }
    }

    // Stable values exported by GCodeProcessor (not inferred from feature names).
    enum MoveKind: Int, CaseIterable, Identifiable {
        case retract = 1, unretract, seam, toolChange, colorChange, pause, custom, travel, wipe, extrude
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .retract: return "Retractions"
            case .unretract: return "Unretractions"
            case .seam: return "Seams"
            case .toolChange: return "Tool changes"
            case .colorChange: return "Color changes"
            case .pause: return "Pause prints"
            case .custom: return "Custom G-code"
            case .travel: return "Travels"
            case .wipe: return "Wipes"
            case .extrude: return "Extrusions"
            }
        }
        var isMarker: Bool { rawValue < Self.travel.rawValue }
    }

    struct Metrics: Equatable {
        var massPerMM: Float = 0
        var actualSpeed: Float = 0
        var flow: Float = 0
        var actualFlow: Float = 0
        var fan: Float = 0
        var temperature: Float = 0
        var pressureAdvance: Float = 0
        var acceleration: Float = 0
        var jerk: Float = 0
        var layerTime: Float = 0
        var tool: Int = 0
        var colorID: Int = 0
        var rgba: UInt32 = 0x009688ff
    }

    struct Segment {
        var points: [SCNVector3]
        var feature: String
        /// Extrusion width mm from official `;WIDTH:` comments (0 = travel / unknown)
        var width: Float
        /// Feedrate mm/min from last F word on the segment (0 if unknown)
        var feedrate: Float
        var height: Float = 0.2
        var kind: MoveKind = .extrude
        var metrics = Metrics()
        var firstMove: Int = 0
        var lastMove: Int = 0
        // Cursor positions of Z/sequence-clipped endpoints. Interior vertices
        // still correspond to consecutive original moves.
        var startPosition: Double? = nil
        var endPosition: Double? = nil

        func cursor(at point: Int) -> Double {
            if point == 0, let startPosition { return startPosition }
            if point == points.count - 1, let endPosition { return endPosition }
            return Double(firstMove + point - 1)
        }

        func edge(at value: Double) -> Int {
            var low = 1, high = points.count
            while low < high {
                let middle = (low + high) / 2
                if cursor(at: middle) <= value { low = middle + 1 } else { high = middle }
            }
            return max(0, min(points.count - 2, low - 1))
        }
    }
    var segments: [Segment]
    var zMin: Float = 0
    var zMax: Float = 0
    var feedMin: Float = 0
    var feedMax: Float = 0
    var widthRange: ClosedRange<Float> = 0...1
    var layerHeightRange: ClosedRange<Float> = 0...1
    /// Default line width when WIDTH comment missing (from nozzle / line_width)
    var defaultWidth: Float = 0.45
    var metricRanges: [ColorMode: ClosedRange<Float>] = [:]
    var featureNames: [String] = []
    var toolIDs: [Int] = []
    var filamentIDs: [Int] = []
    var centerOfGravity: SCNVector3?
    var boundsMin: SIMD3<Float>?
    var boundsMax: SIMD3<Float>?
    var features: [String] { featureNames }
    var moveCount: Int { (segments.last?.lastMove ?? -1) + 1 }

    /// Feature group used by preview toggles (wall / infill / support / travel / other).
    enum FeatureGroup: String, CaseIterable, Identifiable {
        case wall
        case infill
        case support
        case travel
        case other
        var id: String { rawValue }
        var label: String {
            switch self {
            case .wall: return "Wall"
            case .infill: return "Infill"
            case .support: return "Support"
            case .travel: return "Travel"
            case .other: return "Other"
            }
        }
    }

    static func group(for feature: String) -> FeatureGroup {
        let f = feature.lowercased()
        if f.contains("travel") || f.contains("move") || f.contains("wipe") {
            return .travel
        }
        if f.contains("support") {
            return .support
        }
        if f.contains("wall") || f.contains("perimeter") || f.contains("external") {
            return .wall
        }
        if f.contains("infill") || f.contains("sparse") || f.contains("internal")
            || f.contains("solid") || f.contains("top") || f.contains("bottom")
            || f.contains("bridge") || f.contains("skin") {
            return .infill
        }
        if f.contains("skirt") || f.contains("brim") || f.contains("ironing") {
            return .other
        }
        return .other
    }

    func position(atMove value: Double) -> SCNVector3? {
        guard !segments.isEmpty, value.isFinite else { return nil }
        var low = 0, high = segments.count
        while low < high {
            let mid = (low + high) / 2
            if Double(segments[mid].lastMove) < value { low = mid + 1 } else { high = mid }
        }
        let segment = segments[min(low, segments.count - 1)]
        guard let last = segment.points.last else { return nil }
        let offset = max(0, min(Double(segment.points.count - 1), value - Double(segment.firstMove) + 1))
        let index = Int(offset)
        guard index + 1 < segment.points.count else { return last }
        let a = segment.points[index], b = segment.points[index + 1], t = Float(offset - Double(index))
        return SCNVector3(a.x + (b.x-a.x)*t, a.y + (b.y-a.y)*t, a.z + (b.z-a.z)*t)
    }

    /// Advance along commanded feedrates without building a second per-move
    /// timeline. Cursor -1 is the start of the first move; integers are ends.
    /// Dwell/acceleration are not simulated. Bound zero-length marker work.
    func advanceToolhead(from value: Double, seconds: Double) -> Double {
        guard value.isFinite, seconds.isFinite, seconds > 0, !segments.isEmpty else { return value }
        let end = Double(moveCount - 1)
        var cursor = max(-1, min(value, end)), remaining = seconds
        var low = 0, high = segments.count
        while low < high {
            let mid = (low + high) / 2
            if Double(segments[mid].lastMove) <= cursor { low = mid + 1 } else { high = mid }
        }
        var steps = 0
        for segment in segments.dropFirst(low) {
            guard segment.points.count > 1 else { continue }
            cursor = max(cursor, Double(segment.firstMove - 1))
            let offset = max(0, cursor - Double(segment.firstMove) + 1)
            let edge = min(segment.points.count - 1, Int(offset))
            for index in edge..<(segment.points.count - 1) {
                if steps >= 4096 { return cursor }
                steps += 1
                let a = segment.points[index], b = segment.points[index + 1]
                let dx = Double(b.x - a.x), dy = Double(b.y - a.y), dz = Double(b.z - a.z)
                let speed = Double(segment.feedrate) / 60
                let duration = speed.isFinite && speed > 0 ? sqrt(dx*dx + dy*dy + dz*dz) / speed : 0
                let move = Double(segment.firstMove + index)
                let fraction = max(0, min(1, cursor - move + 1))
                let needed = duration * (1 - fraction)
                if needed > remaining {
                    return min(end, move - 1 + fraction + remaining / duration)
                }
                remaining -= needed
                cursor = move
                if remaining <= 0 { return min(end, cursor) }
            }
        }
        return end
    }

    func filtered(minZ: Float = -.greatestFiniteMagnitude, maxZ: Float, enabledGroups: Set<FeatureGroup>? = nil, hiddenFeatures: Set<String> = [],
                  enabledMoves: Set<MoveKind>? = nil, hiddenTools: Set<Int> = [], hiddenFilaments: Set<Int> = [], throughMove: Int = .max, throughPosition: Double? = nil, cancelled: () -> Bool = { false }) -> GCodePathGeometry {
        var out: [Segment] = []
        let limit = throughPosition.map { $0.isFinite ? min($0, Double(throughMove)) : Double(throughMove) } ?? Double(throughMove)
        for source in segments {
            if cancelled() { break }
            if Double(source.firstMove) - 1 >= limit { break }
            if source.kind == .extrude && (hiddenFeatures.contains(source.feature) ||
                hiddenTools.contains(source.metrics.tool) || hiddenFilaments.contains(source.metrics.colorID)) { continue }
            if let enabledMoves, !enabledMoves.contains(source.kind) { continue }
            var seg = source
            if Double(source.lastMove) > limit, !source.points.isEmpty {
                let offset = max(0, min(Double(source.points.count - 1), limit - Double(source.firstMove) + 1))
                let whole = Int(offset), fraction = Float(offset - Double(whole))
                seg.points = Array(source.points.prefix(whole + 1))
                if fraction > 0, whole + 1 < source.points.count {
                    let a = source.points[whole], b = source.points[whole + 1]
                    seg.points.append(SCNVector3(a.x + (b.x-a.x)*fraction,
                        a.y + (b.y-a.y)*fraction, a.z + (b.z-a.z)*fraction))
                }
                seg.lastMove = Int(ceil(limit))
                seg.endPosition = limit
            }
            if let enabled = enabledGroups {
                let g = Self.group(for: seg.feature)
                if !enabled.contains(g) { continue }
            }
            // Keep separate runs when a path exits/re-enters the Z range;
            // filtering vertices alone would draw a false connecting extrusion.
            var run: [SCNVector3] = []
            var runStart = 0.0, runEnd = 0.0
            func flush() {
                if run.count > 1 {
                    var clipped = seg
                    clipped.points = run
                    clipped.firstMove = Int(floor(runStart)) + 1
                    clipped.lastMove = Int(ceil(runEnd))
                    clipped.startPosition = runStart
                    clipped.endPosition = runEnd
                    out.append(clipped)
                }
                run.removeAll(keepingCapacity: true)
            }
            for (edge, pair) in zip(seg.points, seg.points.dropFirst()).enumerated() {
                let (a, b) = pair
                let dz = b.z - a.z
                var lo: Float = 0, hi: Float = 1
                if abs(dz) < 0.000001 {
                    if a.z < minZ - 0.001 || a.z > maxZ + 0.001 { flush(); continue }
                } else {
                    let t0 = (minZ - a.z) / dz, t1 = (maxZ - a.z) / dz
                    lo = max(0, min(t0, t1)); hi = min(1, max(t0, t1))
                    if lo > hi { flush(); continue }
                }
                let start = SCNVector3(a.x + (b.x - a.x) * lo, a.y + (b.y - a.y) * lo, a.z + dz * lo)
                let end = SCNVector3(a.x + (b.x - a.x) * hi, a.y + (b.y - a.y) * hi, a.z + dz * hi)
                if let last = run.last, abs(last.x - start.x) + abs(last.y - start.y) + abs(last.z - start.z) > 0.001 { flush() }
                let edgeStart = seg.cursor(at: edge), span = seg.cursor(at: edge + 1) - edgeStart
                if run.isEmpty { run.append(start); runStart = edgeStart + span * Double(lo) }
                run.append(end)
                runEnd = edgeStart + span * Double(hi)
                if hi < 1 { flush() }
            }
            flush()
        }
        return GCodePathGeometry(
            segments: out, zMin: zMin, zMax: zMax,
            feedMin: feedMin, feedMax: feedMax, widthRange: widthRange, layerHeightRange: layerHeightRange, defaultWidth: defaultWidth, metricRanges: metricRanges, featureNames: featureNames, toolIDs: toolIDs, filamentIDs: filamentIDs, centerOfGravity: centerOfGravity, boundsMin: boundsMin, boundsMax: boundsMax
        )
    }

    /// Check actual GPU color conversion: raw byte attributes previously rendered
    /// a white model despite passing all topology and buffer-layout assertions.
    private static func compactColorSmokeTest() -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        let scene = SCNScene()
        scene.background.contents = UIColor.black
        let path = Segment(points: [SCNVector3(-1, 0, 0), SCNVector3(1, 0, 0)],
            feature: "Outer wall", width: 1, feedrate: 1200)
        scene.rootNode.addChildNode(GCodePathGeometry(segments: [path]).makeNode(color: .white, lightweight: true))
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = 1
        camera.position = SCNVector3(0, 0, 4)
        scene.rootNode.addChildNode(camera)
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        guard let image = renderer.snapshot(atTime: 0, with: CGSize(width: 32, height: 32), antialiasingMode: .none).cgImage else { return false }
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 32, height: 32, bitsPerComponent: 8,
                bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            let offset = (16 * 32 + 16) * 4
            let r = Int(bytes[offset]), g = Int(bytes[offset+1]), b = Int(bytes[offset+2]), a = Int(bytes[offset+3])
            // Allow color-management differences, while rejecting white, black
            // and swapped channels for the desktop orange outer-wall palette.
            return r > 150 && r > g + 10 && g > b + 10 && a > 200
        }
    }

    static func progressiveCursorSmokeTest() -> Bool {
        let wall = Segment(points: [SCNVector3Zero, SCNVector3(10,0,0), SCNVector3(10,10,0)],
            feature: "Outer wall", width: 0.4, feedrate: 600, firstMove: 0, lastMove: 1)
        let travel = Segment(points: [SCNVector3(20,10,0), SCNVector3(40,10,0)],
            feature: "Travel", width: 0, feedrate: 1200, kind: .travel, firstMove: 2, lastMove: 2)
        let source = GCodePathGeometry(segments: [wall, travel]).filtered(maxZ: 1)
        let node = source.makeNode(color: .white, trackCursor: true)
        guard let renderer = cursorRenderer(for: node),
              renderer.batches.count == 2,
              renderer.visibleRanges == [-1.0...2.0],
              let partial = node.childNode(withName: "partial-toolpath", recursively: false) else { return false }
        let original = node.childNodes.compactMap(\.geometry).map { ObjectIdentifier($0) }
        updateCursor(on: node, through: -1)
        guard renderer.batches.allSatisfy({ $0.element.primitiveRange.length == 0 }), partial.geometry == nil else { return false }
        updateCursor(on: node, through: 0.5)
        guard renderer.batches[0].element.primitiveRange.length == 10,
              renderer.batches[1].element.primitiveRange.length == 0,
              let bead = partial.geometry, bead.elements.first?.primitiveType == .triangles,
              abs(bead.boundingBox.max.y - 5) < 0.001 else { return false }
        updateCursor(on: node, through: 1.5)
        guard renderer.batches[0].element.primitiveRange.length == renderer.batches[0].element.primitiveCount,
              renderer.batches[1].element.primitiveRange.length == 0,
              partial.geometry?.elements.first?.primitiveType == .line,
              abs((partial.geometry?.boundingBox.max.x ?? -1) - 30) < 0.001 else { return false }
        updateCursor(on: node, through: 0)
        guard renderer.batches[0].element.primitiveRange.length == 10, partial.geometry == nil else { return false }
        updateCursor(on: node, through: nil)
        guard renderer.batches.allSatisfy({ $0.element.primitiveRange.length == $0.element.primitiveCount }),
              node.childNodes.compactMap(\.geometry).map({ ObjectIdentifier($0) }) == original,
              partial.geometry == nil else { return false }
        let rise = Segment(points: [SCNVector3Zero, SCNVector3(10,0,2)],
            feature: "Support", width: 0.4, feedrate: 600, firstMove: 20, lastMove: 20)
        let originalRise = GCodePathGeometry(segments: [rise])
        let selected = originalRise.filtered(minZ: 0.5, maxZ: 1.5)
        guard selected.segments.first?.startPosition == 19.25, selected.segments.first?.endPosition == 19.75 else { return false }
        let clipped = selected.makeNode(color: .white, trackCursor: true, cursorSource: originalRise)
        updateCursor(on: clipped, through: 19.5)
        guard let tip = clipped.childNode(withName: "partial-toolpath", recursively: false)?.geometry,
              abs(tip.boundingBox.max.z - 1) < 0.001 else { return false }
        updateCursor(on: clipped, through: 19.2)
        guard clipped.childNode(withName: "partial-toolpath", recursively: false)?.geometry == nil else { return false }
        let originalTimeline = GCodePathGeometry(segments: [wall, travel])
        let travelOnly = originalTimeline.filtered(maxZ: 1, enabledMoves: [.travel])
            .makeNode(color: .white, trackCursor: true, cursorSource: originalTimeline)
        updateCursor(on: travelOnly, through: 0.5)
        guard travelOnly.childNode(withName: "partial-toolpath", recursively: false)?.geometry == nil else { return false }
        updateCursor(on: travelOnly, through: 1.5)
        return abs((travelOnly.childNode(withName: "partial-toolpath", recursively: false)?.geometry?.boundingBox.max.x ?? -1) - 30) < 0.001
    }

    static func progressiveGPUSmokeTest() -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        let scene = SCNScene(); scene.background.contents = UIColor.black
        let path = Segment(points: [SCNVector3(-1,0,0), SCNVector3(1,0,0)],
            feature: "Outer wall", width: 1, feedrate: 1200)
        let source = GCodePathGeometry(segments: [path]).makeNode(color: .white, lightweight: true, trackCursor: true)
        let node = source.clone(); copyCursorRenderer(from: source, to: node)
        scene.rootNode.addChildNode(node)
        let camera = SCNNode(); camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true; camera.camera?.orthographicScale = 1
        camera.position = SCNVector3(0,0,4)
        scene.rootNode.addChildNode(camera)
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene; renderer.pointOfView = camera
        func intensity(_ x: Int) -> Int {
            SCNTransaction.flush()
            guard let image = renderer.snapshot(atTime: 0, with: CGSize(width: 32, height: 32), antialiasingMode: .none).cgImage else { return -1 }
            var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
            return bytes.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: 32, height: 32, bitsPerComponent: 8,
                    bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return -1 }
                context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
                return Int(buffer[(16 * 32 + x) * 4])
            }
        }
        updateCursor(on: node, through: -1)
        let before = intensity(8)
        NSLog("Progressive GPU before: %ld", before)
        guard (0..<30).contains(before) else { return false }
        updateCursor(on: node, through: -0.5)
        let left = intensity(8), right = intensity(24)
        NSLog("Progressive GPU half edge: left %ld right %ld", left, right)
        guard left > 150, (0..<30).contains(right) else { return false }
        updateCursor(on: node, through: nil)
        guard intensity(24) > 150 else { return false }
        node.removeFromParentNode()
        let two = Segment(points: [SCNVector3(-1,0,0), SCNVector3Zero, SCNVector3(1,0,0)],
            feature: "Outer wall", width: 1, feedrate: 1200, firstMove: 0, lastMove: 1)
        let prefix = GCodePathGeometry(segments: [two]).makeNode(color: .white, lightweight: true, trackCursor: true)
        scene.rootNode.addChildNode(prefix)
        updateCursor(on: prefix, through: 0.25)
        let completed = intensity(8), future = intensity(28)
        NSLog("Progressive GPU nonempty prefix: completed %ld future %ld", completed, future)
        return completed > 150 && (0..<30).contains(future)
    }

    static func previewSmokeTest(includeProgressive: Bool = true) -> Bool {
        let motion = Segment(points: [SCNVector3(0,0,0), SCNVector3(10,0,0), SCNVector3(20,0,0)],
                             feature: "Outer wall", width: 0.4, feedrate: 600, firstMove: 0, lastMove: 1)
        guard let halfway = GCodePathGeometry(segments: [motion]).position(atMove: 0.5),
              abs(halfway.x - 15) < 0.001 else { return false }

        let motionCorner = Segment(points: [SCNVector3(0,0,0), SCNVector3(10,0,0), SCNVector3(10,10,0)],
                             feature: "Outer wall", width: 0.4, feedrate: 600, firstMove: 0, lastMove: 1)
        let travel = Segment(points: [SCNVector3(20,10,0), SCNVector3(40,10,0)],
                             feature: "Travel", width: 0, feedrate: 1200, firstMove: 2, lastMove: 2)
        let timeline = GCodePathGeometry(segments: [motionCorner, travel])
        let cursor = timeline.advanceToolhead(from: -1, seconds: 1.5)
        guard abs(cursor - 0.5) < 0.0001, let motionPoint = timeline.position(atMove: cursor),
              abs(motionPoint.x - 10) < 0.001, abs(motionPoint.y - 5) < 0.001,
              abs(timeline.advanceToolhead(from: cursor, seconds: 1) - 1.5) < 0.0001,
              timeline.advanceToolhead(from: 2, seconds: 1) == 2,
              timeline.advanceToolhead(from: -1, seconds: 100) == 2,
              timeline.advanceToolhead(from: cursor, seconds: 0) == cursor,
              timeline.position(atMove: .nan) == nil else { return false }
        var zero = travel
        zero.points = [SCNVector3Zero, SCNVector3Zero]
        zero.firstMove = 0; zero.lastMove = 0; zero.feedrate = 0
        guard GCodePathGeometry(segments: [zero]).advanceToolhead(from: -1, seconds: 1) == 0 else { return false }

        let partial = timeline.filtered(maxZ: 1, throughPosition: cursor)
        guard let tip = partial.segments.last?.points.last,
              abs(tip.x - 10) < 0.001, abs(tip.y - 5) < 0.001,
              timeline.filtered(maxZ: 1, throughPosition: -1).segments.isEmpty,
              timeline.filtered(maxZ: 1, throughMove: 0).segments.last?.points.count == 2 else { return false }
        let gestureOrigin = CGPoint(x: 150, y: 20)
        var scrub = ToolpathScrubGesture(value: 500_000, origin: gestureOrigin, previous: gestureOrigin)
        let fullRange = 0.0...1_000_000.0
        guard abs(scrub.update(to: CGPoint(x: 180, y: 20), width: 300, range: fullRange) - 600_000) < 0.001,
              scrub.update(to: CGPoint(x: 180, y: 140), width: 300, range: fullRange) == 600_000,
              scrub.update(to: CGPoint(x: 188, y: 140), width: 300, range: fullRange) == 600_001,
              scrub.update(to: CGPoint(x: 180, y: 140), width: 300, range: fullRange) == 600_000,
              scrub.update(to: CGPoint(x: 180, y: 20), width: 300, range: fullRange) == 600_000,
              scrub.update(to: CGPoint(x: 900, y: 20), width: 300, range: fullRange) == 1_000_000 else { return false }
        let accessibleScrubber = ManualToolpathScrubber.PrecisionSlider()
        accessibleScrubber.range = fullRange; accessibleScrubber.cursor = 600_000
        accessibleScrubber.accessibilityIncrement()
        guard accessibleScrubber.cursor == 600_001 else { return false }
        accessibleScrubber.accessibilityDecrement()
        guard accessibleScrubber.cursor == 600_000 else { return false }
        accessibleScrubber.range = -1...1; accessibleScrubber.cursor = 0
        accessibleScrubber.accessibilityDecrement()
        guard accessibleScrubber.cursor == -1 else { return false }
        accessibleScrubber.accessibilityIncrement()
        guard accessibleScrubber.cursor == 0 else { return false }

        let path = Segment(points: [SCNVector3(0, 0, 0), SCNVector3(1, 0, 2), SCNVector3(2, 0, 0)],
                           feature: "Outer wall", width: 0.45, feedrate: 1200, height: 0.3)
        let clipped = GCodePathGeometry(segments: [path]).filtered(minZ: 1, maxZ: 1.5)
        guard clipped.segments.count == 2,
              clipped.segments.allSatisfy({ $0.points.allSatisfy({ $0.z >= 1 && $0.z <= 1.5 }) }) else { return false }
        let bead = Segment(points: [SCNVector3(0, 0, 1), SCNVector3(10, 0, 1)],
                           feature: "Outer wall", width: 0.45, feedrate: 1200, height: 0.3)
        let support = Segment(points: [SCNVector3(0, 0, 0.2), SCNVector3(10, 0, 0.2)], feature: "Support", width: 0.4, feedrate: 1200, height: 0.2)
        let supportPaths = GCodePathGeometry(segments: [support]).filtered(maxZ: 0.2, enabledMoves: [.extrude])
        guard supportPaths.segments.count == 1,
              !supportPaths.makeNode(color: .white).childNodes.isEmpty,
              !supportPaths.makeNode(color: .white, lightweight: true).childNodes.isEmpty else { return false }
        let compact = GCodePathGeometry(segments: [bead]).makeNode(color: .white, lightweight: true)
        guard let compactMesh = compact.childNodes.first?.geometry,
              compactMesh.elements.first?.primitiveType == .triangles,
              compactMesh.elements.first?.bytesPerIndex == 2,
              compactMesh.sources(for: .normal).isEmpty,
              compactMesh.sources(for: .color).count == 1,
              compactMesh.sources(for: .vertex).first?.vectorCount == 8,
              compactColorSmokeTest(),
              !includeProgressive || (progressiveCursorSmokeTest() && progressiveGPUSmokeTest()) else { return false }
        let node = GCodePathGeometry(segments: [bead]).makeNode(color: .white)
        guard let geometry = node.childNodes.first else { return false }
        let bounds = geometry.boundingBox
        guard bounds.max.z - bounds.min.z >= 0.29 && bounds.max.y - bounds.min.y >= 0.44 else { return false }
        guard let mesh = geometry.geometry, let source = mesh.sources(for: .vertex).first,
              let element = mesh.elements.first else { return false }
        let topIndices = element.data.withUnsafeBytes { bytes in
            // The two start-cap triangles precede the first top surface.
            (6..<9).map { Int(bytes.loadUnaligned(fromByteOffset: $0 * element.bytesPerIndex, as: UInt16.self)) }
        }
        func point(_ index: Int) -> SIMD3<Float> {
            source.data.withUnsafeBytes { bytes in
                let offset = source.dataOffset + index * source.dataStride
                return SIMD3<Float>(bytes.loadUnaligned(fromByteOffset: offset, as: Float.self),
                    bytes.loadUnaligned(fromByteOffset: offset + 4, as: Float.self),
                    bytes.loadUnaligned(fromByteOffset: offset + 8, as: Float.self))
            }
        }
        let topNormal = simd_cross(point(topIndices[1]) - point(topIndices[0]), point(topIndices[2]) - point(topIndices[0]))
        guard topNormal.z > 0 else { return false }
        // A corner between sampled vertices must survive a long toolpath.
        let corner = Segment(points: (0..<8002).map {
            SCNVector3(Float($0) * 0.01, $0 == 1 ? 100 : 0, 1)
        }, feature: "Outer wall", width: 0.45, feedrate: 1200)
        let longPath = GCodePathGeometry(segments: [corner]).makeNode(color: .white)
        guard (longPath.childNodes.first?.boundingBox.max.y ?? 0) >= 99 else { return false }
        var thick = bead
        thick.width = 0.8; thick.height = 0.4
        let colors = GCodePathGeometry(segments: [bead, thick], zMin: 0, zMax: 2, widthRange: 0.45...0.8, layerHeightRange: 0.3...0.4)
        guard !colors.color(for: bead, mode: .layerHeight).isEqual(colors.color(for: thick, mode: .layerHeight)),
              !colors.color(for: bead, mode: .lineWidth).isEqual(colors.color(for: thick, mode: .lineWidth)),
              colors.filtered(minZ: 1, maxZ: 1).widthRange == colors.widthRange,
              colors.filtered(minZ: 1, maxZ: 1).colorRange(for: .height) == colors.colorRange(for: .height) else { return false }
        // Reproduces the resource explosion without requiring a private project:
        // the old renderer creates 20,000 nodes/materials for this fixture.
        let many = GCodePathGeometry(segments: Array(repeating: bead, count: 20_000)).makeNode(color: .white)
        let materials = Set(many.childNodes.flatMap { $0.geometry?.materials ?? [] }.map { ObjectIdentifier($0) })
        guard many.childNodes.count < 20, materials.count == 1 else { return false }
        let vertices = many.childNodes.reduce(0) { $0 + ($1.geometry?.sources(for: .vertex).first?.vectorCount ?? 0) }
        guard vertices == 20_000 * 8 else { return false }
        var detailed = bead
        detailed.metrics = Metrics(massPerMM: 1, actualSpeed: 12, flow: 5, actualFlow: 3, fan: 50, temperature: 215,
                                   pressureAdvance: 0.04, acceleration: 1000, jerk: 8, layerTime: 30, tool: 1, colorID: 2)
        detailed.firstMove = 0; detailed.lastMove = 1
        detailed.points.append(SCNVector3(10, 10, 1))
        var data = GCodePathGeometry(segments: [detailed])
        data.prepareColorRanges()
        guard data.colorRange(for: .actualSpeed) == 12...12,
              data.colorRange(for: .layerTime) == 30...30,
              abs((data.centerOfGravity?.x ?? -1) - 7.5) < 0.001,
              abs((data.centerOfGravity?.y ?? -1) - 2.5) < 0.001,
              data.makeNode(color: .white, showToolMarker: true, showCenterOfGravity: true).childNodes.count == 3,
              data.filtered(maxZ: 1, hiddenFeatures: ["Outer wall"]).segments.isEmpty,
              data.filtered(maxZ: 1, hiddenTools: [1]).segments.isEmpty,
              data.filtered(maxZ: 1, hiddenFilaments: [2]).segments.isEmpty,
              data.filtered(maxZ: 1, throughMove: 0).segments.first?.points.count == 2,
              data.makeNode(color: .white, cancelled: { true }).childNodes.isEmpty else { return false }
        var marker = bead
        marker.kind = .seam; marker.points = [SCNVector3(1, 1, 1), SCNVector3(1, 1, 1)]
        let markers = GCodePathGeometry(segments: [marker])
        return markers.filtered(maxZ: 1, enabledMoves: [.extrude]).segments.isEmpty &&
            markers.filtered(maxZ: 1, enabledMoves: [.seam]).makeNode(color: .white).childNodes.count == 1

    }

    // Desktop libvgcode default palette, keyed by the processor's role labels.
    private static let featurePalette: [String: UInt32] = [
            "undefined": 0xe6b3b3, "inner wall": 0xffe64d, "outer wall": 0xff7d38,
            "overhang wall": 0x1f1fff, "sparse infill": 0xb03029,
            "internal solid infill": 0x9654cc, "top surface": 0xf04040,
            "ironing": 0xff8c69, "bridge": 0x4d80ba, "internal bridge": 0x4d80ba,
            "gap infill": 0xffffff, "skirt": 0x00876e, "support": 0x00ff00,
            "support interface": 0x008000, "prime tower": 0xb3e3ab, "custom": 0x5ed194,
            "bottom surface": 0x665cc7, "brim": 0x003b6e, "support transition": 0x004000,
            "multiple": 0x808080, "travels": 0x38489b, "travel": 0x38489b, "wipes": 0xffff00,
            "retractions": 0xcd22d6, "unretractions": 0x49adcf, "seams": 0xe6e6e6,
            "tool changes": 0xc1be63, "color changes": 0xda948b,
            "pause prints": 0x52f083, "custom g-code": 0xe2d243
    ]
    static func color(for feature: String) -> UIColor {
        let rgb = featurePalette[feature.lowercased()] ?? 0x009688
        return UIColor(red: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    /// Heatmap blue→cyan→green→yellow→red for t in 0…1.
    static func gradientColor(t: Float, alpha: CGFloat = 1) -> UIColor {
        let x = max(0, min(1, CGFloat(t)))
        let r: CGFloat, g: CGFloat, b: CGFloat
        if x < 0.25 {
            let u = x / 0.25
            r = 0.15; g = 0.35 + 0.45 * u; b = 0.95
        } else if x < 0.5 {
            let u = (x - 0.25) / 0.25
            r = 0.15 + 0.1 * u; g = 0.80; b = 0.95 - 0.55 * u
        } else if x < 0.75 {
            let u = (x - 0.5) / 0.25
            r = 0.25 + 0.70 * u; g = 0.80; b = 0.40 - 0.25 * u
        } else {
            let u = (x - 0.75) / 0.25
            r = 0.95; g = 0.80 - 0.55 * u; b = 0.15
        }
        return UIColor(red: r, green: g, blue: b, alpha: alpha)
    }

    func value(for seg: Segment, mode: ColorMode) -> Float {
        switch mode {
        case .height: return ((seg.points.first?.z ?? zMin) + (seg.points.last?.z ?? zMin)) * 0.5
        case .layerHeight: return seg.height
        case .lineWidth: return seg.width
        case .speed: return seg.feedrate / 60
        case .actualSpeed: return seg.metrics.actualSpeed
        case .flow: return seg.metrics.flow
        case .actualFlow: return seg.metrics.actualFlow
        case .fan: return seg.metrics.fan
        case .temperature: return seg.metrics.temperature
        case .pressureAdvance: return seg.metrics.pressureAdvance
        case .acceleration: return seg.metrics.acceleration
        case .jerk: return seg.metrics.jerk
        case .layerTime, .layerTimeLog: return seg.metrics.layerTime
        default: return 0
        }
    }

    mutating func prepareColorRanges() {
        var features = Set<String>(), tools = Set<Int>(), filaments = Set<Int>()
        var weighted = SIMD3<Double>.zero, mass = 0.0
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        // Same model-only exclusions as libvgcode's center-of-gravity marker.
        let excluded: Set<String> = ["Skirt", "Brim", "Support", "Support interface", "Support transition", "Prime tower", "Custom"]
        for seg in segments where seg.kind == .extrude {
            features.insert(seg.feature); tools.insert(seg.metrics.tool); filaments.insert(seg.metrics.colorID)
            for p in seg.points {
                let value = SIMD3<Float>(p.x, p.y, p.z)
                low = simd_min(low, value); high = simd_max(high, value)
            }
            if excluded.contains(seg.feature) { continue }
            for (a, b) in zip(seg.points, seg.points.dropFirst()) {
                let delta = SIMD3<Double>(Double(b.x-a.x), Double(b.y-a.y), Double(b.z-a.z))
                let weight = simd_length(delta) * Double(seg.metrics.massPerMM)
                weighted += SIMD3<Double>(Double(a.x+b.x), Double(a.y+b.y), Double(a.z+b.z)) * (0.5 * weight)
                mass += weight
            }
        }
        featureNames = features.sorted(); toolIDs = tools.sorted(); filamentIDs = filaments.sorted()
        boundsMin = low.x <= high.x ? low : nil
        boundsMax = low.x <= high.x ? high : nil
        if mass > 0 {
            let p = weighted / mass
            centerOfGravity = SCNVector3(Float(p.x), Float(p.y), Float(p.z))
        }

        for mode in ColorMode.allCases where mode.isNumeric {
            var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
            for seg in segments where seg.kind == .extrude {
                let v = value(for: seg, mode: mode)
                if v.isFinite { lo = min(lo, v); hi = max(hi, v) }
            }
            metricRanges[mode] = lo <= hi ? lo...hi : 0...0
        }
    }

    func colorRange(for mode: ColorMode) -> ClosedRange<Float> {
        if let range = metricRanges[mode] { return range }
        switch mode {
        case .height: return min(zMin, zMax)...max(zMin, zMax)
        case .layerHeight: return layerHeightRange
        case .lineWidth: return widthRange
        case .speed: return (min(feedMin, feedMax) / 60)...(max(feedMin, feedMax) / 60)
        default: return 0...1
        }
    }

    func color(for seg: Segment, mode: ColorMode) -> UIColor {
        if seg.kind != .extrude { return Self.color(for: seg.feature) }
        switch mode {
        case .feature, .summary: return Self.color(for: seg.feature)
        case .filament:
            let rgba = seg.metrics.rgba
            return UIColor(red: CGFloat((rgba >> 24) & 255) / 255,
                green: CGFloat((rgba >> 16) & 255) / 255,
                blue: CGFloat((rgba >> 8) & 255) / 255, alpha: 1)
        case .tool:
            return Self.gradientColor(t: Float(seg.metrics.tool % 8) / 7)
        default: break
        }
        let range = colorRange(for: mode)
        let v = value(for: seg, mode: mode)
        if mode == .layerTimeLog {
            let lo = log1pf(max(0, range.lowerBound)), hi = log1pf(max(0, range.upperBound))
            return Self.gradientColor(t: (log1pf(max(0, v)) - lo) / max(0.001, hi - lo))
        }
        return Self.gradientColor(t: (v - range.lowerBound) / max(0.001, range.upperBound - range.lowerBound))
    }

    /// A bounded number of geometry buffers share TWO materials for the entire job.
    /// Per-path materials caused quadratic SceneKit resource-manager cleanup on
    /// device (exit watchdog in SCNMTLResourceManager::_materialWillDie).
    func makeNode(color: UIColor, colorMode: ColorMode = .feature, showToolMarker: Bool = false, showCenterOfGravity: Bool = false, lightweight: Bool = false, trackCursor: Bool = false, cursorSource: GCodePathGeometry? = nil, cancelled: () -> Bool = { false }) -> SCNNode {
        let root = SCNNode()
        root.name = "gcode"
        let solid = SCNMaterial()
        solid.diffuse.contents = UIColor.white
        solid.lightingModel = lightweight ? .constant : .lambert
        solid.isDoubleSided = true
        let lines = SCNMaterial()
        lines.diffuse.contents = UIColor.white
        lines.lightingModel = .constant
        var beads = Batch(material: solid, primitive: .triangles, includeNormals: !lightweight)
        var travels = Batch(material: lines, primitive: .line, includeNormals: false)
        let cursorRenderer = trackCursor ? CursorRenderer(geometry: cursorSource ?? self, visible: segments,
            mode: colorMode, solid: solid, lines: lines, lightweight: lightweight) : nil
        for seg in segments {
            if cancelled() { return SCNNode() }
            guard seg.points.count > 1 else { continue }
            let rgba = self.color(for: seg, mode: colorMode)
            if seg.kind != .extrude || seg.width <= 0.01 {
                if seg.kind.isMarker, let p = seg.points.last {
                    // Batched cross markers, never one sphere/material per event.
                    let r: Float = seg.kind == .seam ? 0.35 : 0.65
                    let ends = [SCNVector3(p.x-r,p.y,p.z), SCNVector3(p.x+r,p.y,p.z),
                                SCNVector3(p.x,p.y-r,p.z), SCNVector3(p.x,p.y+r,p.z),
                                SCNVector3(p.x,p.y,p.z-r), SCNVector3(p.x,p.y,p.z+r)]
                    travels.appendLines(ends, color: rgba)
                    if trackCursor { travels.recordCut(at: seg.cursor(at: seg.points.count - 1)) }
                } else {
                    for (edge, pair) in zip(seg.points, seg.points.dropFirst()).enumerated() {
                        let (a, b) = pair
                        travels.appendLines([a, b], color: rgba.withAlphaComponent(seg.kind == .extrude ? 1 : 0.65))
                        if trackCursor { travels.recordCut(at: seg.cursor(at: edge + 1)) }
                        if travels.vertexCount >= 32768 { travels.flush(into: root, cursorRenderer: cursorRenderer) }
                    }
                }
                if travels.vertexCount >= 32768 { travels.flush(into: root, cursorRenderer: cursorRenderer) }
            } else {
                // Split only at a shared endpoint; every original corner survives.
                var offset = 0
                while offset < seg.points.count - 1 {
                    if cancelled() { return SCNNode() }
                    let end = min(offset + 4095, seg.points.count - 1)
                    beads.appendBead(Array(seg.points[offset...end]), width: seg.width,
                                     height: seg.height, color: rgba,
                                     cursors: trackCursor ? (offset...end).map { seg.cursor(at: $0) } : nil)
                    if beads.vertexCount >= 32768 { beads.flush(into: root, cursorRenderer: cursorRenderer) }
                    offset = end
                }
            }
        }
        if showToolMarker, let p = segments.last?.points.last {
            let marker = SCNNode()
            marker.name = "scrub-toolhead"
            marker.position = p
            var cross = Batch(material: lines, primitive: .line, includeNormals: false)
            cross.appendMarker(SCNVector3Zero, radius: 3, color: .systemYellow)
            cross.flush(into: marker)
            root.addChildNode(marker)
        }
        beads.flush(into: root, cursorRenderer: cursorRenderer)
        travels.flush(into: root, cursorRenderer: cursorRenderer)
        if showCenterOfGravity, let p = centerOfGravity {
            travels.appendMarker(p, radius: 4, color: .systemPink)
            travels.flush(into: root) // Job annotation, independent of move cursor.
        }
        if let cursorRenderer {
            objc_setAssociatedObject(root, &Self.cursorRendererKey, cursorRenderer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            let partial = SCNNode(); partial.name = "partial-toolpath"
            root.addChildNode(partial)
        }
        return root
    }

    static func updateCursor(on root: SCNNode, through position: Double?) {
        cursorRenderer(for: root)?.update(root, through: position)
    }

    static func endPoint(in root: SCNNode) -> SCNVector3? {
        cursorRenderer(for: root)?.endPoint
    }

    private static var cursorRendererKey: UInt8 = 0

    private static func cursorRenderer(for root: SCNNode) -> CursorRenderer? {
        objc_getAssociatedObject(root, &cursorRendererKey) as? CursorRenderer
    }

    static func copyCursorRenderer(from source: SCNNode, to destination: SCNNode) {
        objc_setAssociatedObject(destination, &cursorRendererKey, cursorRenderer(for: source), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Cached batches keep their GPU buffers. Each frame changes only primitive
    /// ranges and a single partial edge, sharing the job's existing materials.
    private final class CursorRenderer: NSObject {
        struct Cut { let position: Double; var primitives: Int }
        struct DrawBatch { let element: SCNGeometryElement; let cuts: [Cut] }
        var batches: [DrawBatch] = []
        let geometry: GCodePathGeometry
        let visibleRanges: [ClosedRange<Double>]
        let endPoint: SCNVector3?
        let mode: ColorMode
        let solid: SCNMaterial
        let lines: SCNMaterial
        let lightweight: Bool
        private var lastRoot: ObjectIdentifier?
        private var lastPosition: Double?

        init(geometry: GCodePathGeometry, visible: [Segment], mode: ColorMode, solid: SCNMaterial, lines: SCNMaterial, lightweight: Bool) {
            self.geometry = geometry; self.mode = mode
            self.solid = solid; self.lines = lines; self.lightweight = lightweight
            endPoint = visible.last?.points.last
            // Retain the original job's COW arrays, not a second filtered path
            // tree. Adjacent visible runs need only one cursor interval.
            var ranges: [ClosedRange<Double>] = []
            for segment in visible where segment.points.count > 1 {
                let start = segment.cursor(at: 0), end = segment.cursor(at: segment.points.count - 1)
                if let previous = ranges.last, start <= previous.upperBound {
                    ranges[ranges.count - 1] = previous.lowerBound...max(previous.upperBound, end)
                } else { ranges.append(start...end) }
            }
            visibleRanges = ranges
        }

        func update(_ root: SCNNode, through position: Double?) {
            if let position, !position.isFinite { return }
            guard lastRoot != ObjectIdentifier(root) || lastPosition != position else { return }
            lastRoot = ObjectIdentifier(root); lastPosition = position
            SCNTransaction.begin(); SCNTransaction.animationDuration = 0
            defer { SCNTransaction.commit() }
            let nodes = root.childNodes.filter { $0.name == "toolpath-batch" }
            for (batch, node) in zip(batches, nodes) {
                var low = 0, high = batch.cuts.count
                if let position {
                    while low < high {
                        let middle = (low + high) / 2
                        if batch.cuts[middle].position <= position { low = middle + 1 } else { high = middle }
                    }
                } else { low = high }
                let count = low > 0 ? batch.cuts[low - 1].primitives : 0
                node.isHidden = count == 0
                if batch.element.primitiveRange.length != count {
                    batch.element.primitiveRange = NSRange(location: 0, length: count)
                }
            }
            guard let partial = root.childNode(withName: "partial-toolpath", recursively: false) else { return }
            partial.geometry = nil
            guard let position else { return }
            var rangeIndex = 0, rangeEnd = visibleRanges.count
            while rangeIndex < rangeEnd {
                let middle = (rangeIndex + rangeEnd) / 2
                if visibleRanges[middle].upperBound < position { rangeIndex = middle + 1 } else { rangeEnd = middle }
            }
            guard rangeIndex < visibleRanges.count, visibleRanges[rangeIndex].contains(position) else { return }
            let visible = visibleRanges[rangeIndex]
            let segments = geometry.segments
            var low = 0, high = segments.count
            while low < high {
                let middle = (low + high) / 2
                if segments[middle].cursor(at: segments[middle].points.count - 1) <= position { low = middle + 1 }
                else { high = middle }
            }
            guard low < segments.count else { return }
            let segment = segments[low]
            guard segment.points.count > 1, !segment.kind.isMarker else { return }
            let edge = segment.edge(at: position)
            let edgeStart = segment.cursor(at: edge), edgeEnd = segment.cursor(at: edge + 1)
            let start = max(edgeStart, visible.lowerBound), end = min(edgeEnd, visible.upperBound)
            guard position > start, position < end else { return }
            let from = segment.points[edge], to = segment.points[edge + 1]
            func point(_ cursor: Double) -> SCNVector3 {
                let fraction = Float((cursor - edgeStart) / (edgeEnd - edgeStart))
                return SCNVector3(from.x + (to.x - from.x) * fraction, from.y + (to.y - from.y) * fraction, from.z + (to.z - from.z) * fraction)
            }
            let a = point(start), tip = point(position)
            let color = geometry.color(for: segment, mode: mode)
            let bead = segment.kind == .extrude && segment.width > 0.01
            var batch = Batch(material: bead ? solid : lines, primitive: bead ? .triangles : .line,
                              includeNormals: bead && !lightweight)
            if bead { batch.appendBead([a, tip], width: segment.width, height: segment.height, color: color) }
            else { batch.appendLines([a, tip], color: color.withAlphaComponent(segment.kind == .extrude ? 1 : 0.65)) }
            let holder = SCNNode()
            batch.flush(into: holder)
            partial.geometry = holder.childNodes.first?.geometry
        }
    }

    private struct Batch {
        let material: SCNMaterial
        let primitive: SCNGeometryPrimitiveType
        let includeNormals: Bool
        var positions: [Float] = []
        var normals: [Float] = []
        var colors: [UInt8] = []
        var indices: [UInt16] = []
        var cuts: [CursorRenderer.Cut] = []
        var vertexCount: Int { positions.count / 3 }

        mutating func vertex(_ p: SCNVector3, normal: SCNVector3, color: UIColor) {
            positions.append(contentsOf: [p.x, p.y, p.z])
            if includeNormals { normals.append(contentsOf: [normal.x, normal.y, normal.z]) }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            colors.append(contentsOf: [r, g, b, a].map { UInt8((min(max($0, 0), 1) * 255).rounded()) })
        }

        mutating func appendMarker(_ p: SCNVector3, radius r: Float, color: UIColor) {
            appendLines([SCNVector3(p.x-r,p.y,p.z), SCNVector3(p.x+r,p.y,p.z),
                         SCNVector3(p.x,p.y-r,p.z), SCNVector3(p.x,p.y+r,p.z),
                         SCNVector3(p.x,p.y,p.z-r), SCNVector3(p.x,p.y,p.z+r)], color: color)
        }

        mutating func appendLines(_ points: [SCNVector3], color: UIColor) {
            for p in points {
                indices.append(UInt16(vertexCount))
                vertex(p, normal: SCNVector3(0, 0, 1), color: color)
            }
        }

        mutating func recordCut(at position: Double) {
            let count = indices.count / (primitive == .line ? 2 : 3)
            if cuts.last?.position == position { cuts[cuts.count - 1].primitives = count }
            else { cuts.append(.init(position: position, primitives: count)) }
        }

        mutating func appendBead(_ points: [SCNVector3], width: Float, height: Float, color: UIColor, cursors: [Double]? = nil) {
            let base = UInt16(vertexCount)
            let half = max(0.01, width) * 0.5
            for j in points.indices {
                let p = points[j], prev = points[max(0,j-1)], next = points[min(points.count-1,j+1)]
                let dx = next.x-prev.x, dy = next.y-prev.y
                let length = max(0.0001, sqrtf(dx*dx+dy*dy))
                let nx = -dy/length, ny = dx/length
                let bottom = p.z - max(0.01, height)
                vertex(SCNVector3(p.x+nx*half,p.y+ny*half,p.z), normal: SCNVector3(nx,ny,1), color: color)
                vertex(SCNVector3(p.x-nx*half,p.y-ny*half,p.z), normal: SCNVector3(-nx,-ny,1), color: color)
                vertex(SCNVector3(p.x+nx*half,p.y+ny*half,bottom), normal: SCNVector3(nx,ny,-1), color: color)
                vertex(SCNVector3(p.x-nx*half,p.y-ny*half,bottom), normal: SCNVector3(-nx,-ny,-1), color: color)
            }
            // Keep primitives in move order so visibility can advance without
            // rebuilding or adding a per-vertex cursor attribute.
            indices.append(contentsOf: [base,base+2,base+1,base+2,base+3,base+1])
            for j in 0..<(points.count-1) {
                let a = base+UInt16(j*4), b = a+4
                // Outward winding matters now that beads use lit materials.
                indices.append(contentsOf: [a,a+1,b,a+1,b+1,b,
                    a,b,a+2,b,b+2,a+2, a+1,a+3,b+1,a+3,b+3,b+1,
                    a+2,b+2,a+3,b+2,b+3,a+3])
                if let cursors { recordCut(at: cursors[j + 1]) }
            }
            let last = base+UInt16((points.count-1)*4)
            indices.append(contentsOf: [last,last+1,last+2,last+1,last+3,last+2])
            if let end = cursors?.last { recordCut(at: end) }
        }

        mutating func flush(into root: SCNNode, cursorRenderer: CursorRenderer? = nil) {
            guard !indices.isEmpty else { return }
            func source(_ values: [Float], _ semantic: SCNGeometrySource.Semantic, _ components: Int) -> SCNGeometrySource {
                let data = values.withUnsafeBytes { Data($0) }
                return SCNGeometrySource(data: data, semantic: semantic, vectorCount: vertexCount,
                    usesFloatComponents: true, componentsPerVector: components,
                    bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                    dataStride: components * MemoryLayout<Float>.size)
            }
            let element = SCNGeometryElement(data: indices.withUnsafeBytes { Data($0) },
                primitiveType: primitive, primitiveCount: indices.count / (primitive == .line ? 2 : 3),
                bytesPerIndex: MemoryLayout<UInt16>.size)
            // Color components are normalized bytes; chunks remain below 65,536
            // vertices so 16-bit indices retain every corner without sampling.
            let colorSource: SCNGeometrySource
            if let device = MTLCreateSystemDefaultDevice(),
               let buffer = colors.withUnsafeBytes({ bytes in
                   device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
               }) {
                // The Data initializer describes raw integers and clamps colors
                // above 1 to white. Request normalized GPU input explicitly.
                colorSource = SCNGeometrySource(buffer: buffer, vertexFormat: .uchar4Normalized,
                    semantic: .color, vertexCount: vertexCount, dataOffset: 0, dataStride: 4)
            } else {
                colorSource = source(colors.map { Float($0) / 255 }, .color, 4)
            }
            var sources = [source(positions, .vertex, 3), colorSource]
            if includeNormals { sources.append(source(normals, .normal, 3)) }
            let geometry = SCNGeometry(sources: sources, elements: [element])
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry)
            if let cursorRenderer, !cuts.isEmpty {
                node.name = "toolpath-batch"
                cursorRenderer.batches.append(.init(element: element, cuts: cuts))
            }
            root.addChildNode(node)
            cuts.removeAll(keepingCapacity: true)
            positions.removeAll(keepingCapacity: true)
            normals.removeAll(keepingCapacity: true)
            colors.removeAll(keepingCapacity: true)
            indices.removeAll(keepingCapacity: true)
        }
    }
}
