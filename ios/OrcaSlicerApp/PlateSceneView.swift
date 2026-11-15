// SceneKit prepare view: build plate + real mesh from libslic3r + G-code paths.
// Coordinate convention:
//   libslic3r is Z-up (XY bed). SceneKit is Y-up.
//   All print geometry lives under "content" node rotated R_x(-90°):
//     (x, y, z)_slic3r  →  (x, z, -y)_scenekit
//   so the bed stays a simple XY plane and the grid always sits under the model.

import SwiftUI
import SceneKit
import UIKit

enum PlateTouchMode: String, CaseIterable, Identifiable {
    case orbit = "Orbit", pan = "Pan", move = "Move", rotate = "Rotate", select = "Select"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .orbit: return "globe"
        case .pan: return "hand.draw"
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .rotate: return "rotate.3d"
        case .select: return "cursorarrow"
        }
    }
}

/// Interactive build plate with official-engine mesh geometry + optional G-code paths.
struct PlateSceneView: UIViewRepresentable {
    var mesh: MeshGeometry?
    var meshRevision: Int = 0
    /// Per-object meshes for tap-to-select (same order as engine.objectNames).
    var objectMeshes: [MeshGeometry] = []
    var selectedObjectIndex: Int = -1
    var gcodeNode: SCNNode? = nil
    var showGCode: Bool = false
    var bedSize: SIMD2<Float> = SIMD2(220, 220)
    /// Optional machine bed texture / cover PNG path (from system profiles)
    var bedTexturePath: String? = nil
    var accent: UIColor = UIColor(red: 0, green: 150 / 255, blue: 136 / 255, alpha: 1)
    /// Prepare tab: pan on bed plane moves selected object(s) in mm (slic3r XY).
    var touchMode: PlateTouchMode = .orbit
    var fitRequest = UUID()
    var rotationAxis: Int = 2
    /// Tap object to select; drag on object to move (without requiring Move gizmo).
    var selectMode: Bool { [.select, .move, .rotate].contains(touchMode) }
    var moveMode: Bool { touchMode == .move }
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

    /// Run on the simulator main thread against a real SceneKit camera.
    static func cameraSmokeTest() -> Bool {
        let view = SCNView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        view.scene = SCNScene()
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
        guard coordinator.panGesture?.maximumNumberOfTouches == 1, coordinator.pinchGesture != nil else { return false }
        let distance = simd_length(SIMD3<Float>(50, 60, 80))
        coordinator.zoom(scale: 2, view: view)
        guard abs(simd_length(SIMD3<Float>(camera.position.x, camera.position.y, camera.position.z)) - distance / 2) < 0.01 else { return false }
        let before = camera.position
        coordinator.cameraDrag(delta: CGPoint(x: 35, y: 25), view: view, mode: .pan)
        let target = view.defaultCameraController.target
        guard abs(camera.position.x - before.x - target.x) < 0.01,
              abs(camera.position.y - before.y - target.y) < 0.01,
              abs(target.x) + abs(target.y) + abs(target.z) > 0.01 else { return false }
        let beforeOrbit = camera.position
        coordinator.cameraDrag(delta: CGPoint(x: 60, y: 20), view: view, mode: .orbit)
        let afterOrbit = camera.position
        let offset = SIMD3<Float>(afterOrbit.x - target.x, afterOrbit.y - target.y, afterOrbit.z - target.z)
        return abs(simd_length(offset) - distance / 2) < 0.1 &&
            abs(afterOrbit.x - beforeOrbit.x) + abs(afterOrbit.z - beforeOrbit.z) > 0.01
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
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
        return view
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
                context.coordinator.frameCamera(view: view, mesh: mesh, bedSize: bedSize)
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
        if !context.coordinator.isDragging, context.coordinator.lastMeshKey != meshKey {
            content.childNode(withName: "model", recursively: false)?.removeFromParentNode()
            let root = SCNNode()
            root.name = "model"
            if !objectMeshes.isEmpty {
                for (i, om) in objectMeshes.enumerated() {
                    guard om.vertexCount > 0 else { continue }
                    let selected = (i == selectedObjectIndex)
                    let color = selected
                        ? UIColor(red: 0.15, green: 0.85, blue: 0.75, alpha: 1)
                        : accent
                    let node = om.makeNode(color: color)
                    node.name = "object_\(i)"
                    if selected {
                        node.geometry?.firstMaterial?.emission.contents = UIColor(
                            red: 0, green: 0.35, blue: 0.3, alpha: 1
                        )
                    }
                    root.addChildNode(node)
                }
                content.addChildNode(root)
            } else if let mesh {
                let node = mesh.makeNode(color: accent)
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
                    child.geometry?.firstMaterial?.diffuse.contents = selected
                        ? UIColor(red: 0.15, green: 0.85, blue: 0.75, alpha: 1)
                        : accent
                    child.geometry?.firstMaterial?.emission.contents = selected
                        ? UIColor(red: 0, green: 0.35, blue: 0.3, alpha: 1)
                        : UIColor.black
                }
            }
        }

        if context.coordinator.lastFitRequest != fitRequest {
            if let mesh { context.coordinator.frameCamera(view: view, mesh: mesh, bedSize: bedSize) }
            else { context.coordinator.frameCameraOnBed(view: view, bedSize: bedSize) }
            context.coordinator.lastFitRequest = fitRequest
        }

        // G-code toolpaths (Preview tab) — also under content (Z-up)
        content.childNode(withName: "gcode", recursively: false)?.removeFromParentNode()
        if showGCode, let gcodeNode {
            let clone = gcodeNode.clone()
            clone.name = "gcode"
            // G-code nodes were previously self-rotated; strip extra rotation if present
            clone.eulerAngles = SCNVector3Zero
            content.addChildNode(clone)
            content.childNode(withName: "model", recursively: false)?.opacity = 0.15
        } else {
            content.childNode(withName: "model", recursively: false)?.opacity = 1.0
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
        var parent: PlateSceneView?
        var lastMeshKey: String = ""
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
            guard let camera = view.pointOfView else { return }
            let controller = view.defaultCameraController
            let target = SIMD3<Float>(controller.target.x, controller.target.y, controller.target.z)
            let distance = simd_length(camera.simdPosition - target)
            guard distance > 0, scale.isFinite, scale > 0 else { return }
            let ratio = min(max(distance / scale, 0.5), 20000) / distance
            // Keep the point under the pinch centroid stationary on screen.
            var focus = target
            if let anchor {
                let depth = view.projectPoint(controller.target).z
                let world = view.unprojectPoint(SCNVector3(Float(anchor.x), Float(anchor.y), depth))
                focus = SIMD3<Float>(world.x, world.y, world.z)
            }
            camera.simdPosition = focus + (camera.simdPosition - focus) * ratio
            let nextTarget = focus + (target - focus) * ratio
            controller.target = SCNVector3(nextTarget.x, nextTarget.y, nextTarget.z)
        }

        private func cameraPan(_ gesture: UIPanGestureRecognizer, view: SCNView, mode: PlateTouchMode) {
            // Consume the recognizer's initial movement too; subsequent changes
            // are incremental so crossing its recognition threshold cannot jump.
            guard gesture.state == .began || gesture.state == .changed else { return }
            let delta = gesture.translation(in: view)
            gesture.setTranslation(.zero, in: view)
            cameraDrag(delta: delta, view: view, mode: mode)
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
                let next = min(max(elevation + requested, -limit), limit)
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

        private func rotateObject(_ gesture: UIPanGestureRecognizer, view: SCNView, parent: PlateSceneView) {
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
                let angle = rotateDegrees * Float.pi / 180
                switch parent.rotationAxis {
                case 0: rotationNode?.eulerAngles.x = angle
                case 1: rotationNode?.eulerAngles.y = angle
                default: rotationNode?.eulerAngles.z = angle
                }
            case .ended, .cancelled, .failed:
                let commit = gesture.state == .ended && isDragging && abs(rotateDegrees) > 0.1
                rotationNode?.transform = SCNMatrix4Identity
                rotationNode?.pivot = SCNMatrix4Identity
                rotationNode = nil
                isDragging = false
                suppressSelectUntil = Date().timeIntervalSince1970 + 0.35
                if commit { parent.onRotateCommit?(rotateDegrees, dragObjectIndex) }
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
                return n == "model" || p == "model" || n == "paintOverlay" || p == "paintOverlay"
            }) {
                return slic3rFromWorld(h.worldCoordinates)
            }
            return nil
        }

        /// Resolve object index from SceneKit hit (node name object_N)
        private func hitObjectIndex(view: SCNView, screen: CGPoint) -> Int? {
            let hits = view.hitTest(screen, options: [
                SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue
            ])
            for h in hits {
                var n: SCNNode? = h.node
                while let node = n {
                    if let name = node.name, name.hasPrefix("object_"),
                       let idx = Int(name.dropFirst("object_".count)) {
                        return idx
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

            if parent.touchMode == .orbit || parent.touchMode == .pan {
                cameraPan(gr, view: view, mode: parent.touchMode)
                return
            }
            if parent.touchMode == .rotate {
                rotateObject(gr, view: view, parent: parent)
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

        /// World-space target of bed center after content R_x(-90): (cx, 0, -cy)
        private func bedCenterWorld(bedSize: SIMD2<Float>) -> SCNVector3 {
            SCNVector3(bedSize.x * 0.5, 0, -bedSize.y * 0.5)
        }

        func frameCameraOnBed(view: SCNView, bedSize: SIMD2<Float>) {
            guard let cam = view.scene?.rootNode.childNode(withName: "camera", recursively: false) else { return }
            let target = bedCenterWorld(bedSize: bedSize)
            let plate = max(bedSize.x, bedSize.y, 100)
            let dist = plate * 1.05
            cam.position = SCNVector3(
                target.x + dist * 0.55,
                dist * 0.72,
                target.z + dist * 0.75
            )
            cam.look(at: target)
            view.pointOfView = cam
            view.defaultCameraController.pointOfView = cam
            view.defaultCameraController.automaticTarget = false
            view.defaultCameraController.target = target
        }

        func frameCamera(view: SCNView, mesh: MeshGeometry, bedSize: SIMD2<Float>) {
            guard let cam = view.scene?.rootNode.childNode(withName: "camera", recursively: false) else { return }

            // Mesh in slic3r Z-up under content; world after R_x(-90): (x, z, -y)
            let mx = (mesh.min.x + mesh.max.x) * 0.5
            let my = (mesh.min.y + mesh.max.y) * 0.5
            let mz = (mesh.min.z + mesh.max.z) * 0.5
            let modelWorld = SCNVector3(mx, mz, -my)

            let target = modelWorld
            let dx = mesh.max.x - mesh.min.x
            let dy = mesh.max.y - mesh.min.y
            let dz = mesh.max.z - mesh.min.z
            let radius = max(sqrtf(dx * dx + dy * dy + dz * dz) * 0.5, 0.5)
            let aspect = max(Float(view.bounds.width / max(view.bounds.height, 1)), 0.2)
            let verticalHalfAngle = Float(42.0 * Double.pi / 360.0)
            let limitingAngle = min(verticalHalfAngle, atanf(tanf(verticalHalfAngle) * aspect))
            let dist = max(radius / sinf(limitingAngle) * 1.15, 3)
            cam.camera?.zNear = max(Double(dist) / 1000, 0.01)

            cam.position = SCNVector3(
                target.x + dist * 0.55,
                dist * 0.65,
                target.z + dist * 0.8
            )
            cam.look(at: target)
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
    /// Preview color mode (feature type / height gradient / speed gradient).
    enum ColorMode: String, CaseIterable, Identifiable {
        case feature
        case height
        case speed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .feature: return "Feature"
            case .height: return "Height"
            case .speed: return "Speed"
            }
        }
    }

    struct Segment {
        var points: [SCNVector3]
        var feature: String
        /// Extrusion width mm from official `;WIDTH:` comments (0 = travel / unknown)
        var width: Float
        /// Feedrate mm/min from last F word on the segment (0 if unknown)
        var feedrate: Float
    }
    var segments: [Segment]
    var zMin: Float = 0
    var zMax: Float = 0
    var feedMin: Float = 0
    var feedMax: Float = 0
    /// Default line width when WIDTH comment missing (from nozzle / line_width)
    var defaultWidth: Float = 0.45

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

    func filtered(minZ: Float = -.greatestFiniteMagnitude, maxZ: Float, enabledGroups: Set<FeatureGroup>? = nil) -> GCodePathGeometry {
        var out: [Segment] = []
        for seg in segments {
            if let enabled = enabledGroups {
                let g = Self.group(for: seg.feature)
                if !enabled.contains(g) { continue }
            }
            let pts = seg.points.filter { $0.z >= minZ - 0.001 && $0.z <= maxZ + 0.001 }
            if pts.count > 1 {
                out.append(Segment(points: pts, feature: seg.feature, width: seg.width, feedrate: seg.feedrate))
            }
        }
        return GCodePathGeometry(
            segments: out, zMin: max(zMin, minZ), zMax: maxZ,
            feedMin: feedMin, feedMax: feedMax, defaultWidth: defaultWidth
        )
    }

    static func color(for feature: String) -> UIColor {
        let f = feature.lowercased()
        if f.contains("outer wall") || f.contains("outer_wall") {
            return UIColor(red: 0.95, green: 0.55, blue: 0.15, alpha: 1)
        }
        if f.contains("inner wall") || f.contains("inner_wall") {
            return UIColor(red: 0.95, green: 0.85, blue: 0.20, alpha: 1)
        }
        if f.contains("top") {
            return UIColor(red: 0.55, green: 0.35, blue: 0.85, alpha: 1)
        }
        if f.contains("bottom") {
            return UIColor(red: 0.30, green: 0.55, blue: 0.95, alpha: 1)
        }
        if f.contains("sparse") || f.contains("internal") || f.contains("infill") {
            return UIColor(red: 0.25, green: 0.75, blue: 0.55, alpha: 1)
        }
        if f.contains("support") {
            return UIColor(red: 0.55, green: 0.55, blue: 0.60, alpha: 1)
        }
        if f.contains("skirt") || f.contains("brim") {
            return UIColor(red: 0.70, green: 0.70, blue: 0.75, alpha: 1)
        }
        if f.contains("bridge") {
            return UIColor(red: 0.20, green: 0.75, blue: 0.85, alpha: 1)
        }
        if f.contains("travel") {
            return UIColor(red: 0.45, green: 0.45, blue: 0.50, alpha: 0.55)
        }
        return UIColor(red: 0, green: 150 / 255, blue: 136 / 255, alpha: 1)
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

    func color(for seg: Segment, mode: ColorMode) -> UIColor {
        switch mode {
        case .feature:
            return Self.color(for: seg.feature)
        case .height:
            let midZ: Float
            if let first = seg.points.first, let last = seg.points.last {
                midZ = (first.z + last.z) * 0.5
            } else {
                midZ = zMin
            }
            let span = max(0.001, zMax - zMin)
            let t = (midZ - zMin) / span
            return Self.gradientColor(t: t)
        case .speed:
            let span = max(1, feedMax - feedMin)
            let t = seg.feedrate > 0 ? (seg.feedrate - feedMin) / span : 0
            return Self.gradientColor(t: t)
        }
    }

    /// Parent "content" applies Z-up → Y-up; do not rotate this node.
    /// Extrusions: ribbon quads at official `;WIDTH:` (fallback defaultWidth).
    /// Travel: thin line.
    func makeNode(color: UIColor, colorMode: ColorMode = .feature) -> SCNNode {
        let root = SCNNode()
        root.name = "gcode"
        for seg in segments {
            guard seg.points.count > 1 else { continue }
            let c = self.color(for: seg, mode: colorMode)
            let isTravel = Self.group(for: seg.feature) == .travel || seg.width <= 0.01
            if isTravel {
                root.addChildNode(makeLineNode(points: seg.points, color: c.withAlphaComponent(0.55)))
            } else {
                let w = seg.width > 0.05 ? seg.width : defaultWidth
                if let ribbon = makeRibbonNode(points: seg.points, width: w, color: c) {
                    root.addChildNode(ribbon)
                } else {
                    root.addChildNode(makeLineNode(points: seg.points, color: c))
                }
            }
        }
        return root
    }

    private func makeLineNode(points: [SCNVector3], color: UIColor) -> SCNNode {
        let src = SCNGeometrySource(vertices: points)
        var indices: [Int32] = []
        for i in 0..<(points.count - 1) {
            indices.append(Int32(i))
            indices.append(Int32(i + 1))
        }
        let data = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
        let elem = SCNGeometryElement(
            data: data,
            primitiveType: .line,
            primitiveCount: indices.count / 2,
            bytesPerIndex: MemoryLayout<Int32>.size
        )
        let geo = SCNGeometry(sources: [src], elements: [elem])
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.lightingModel = .constant
        geo.materials = [mat]
        return SCNNode(geometry: geo)
    }

    /// Flat ribbon in XY (slic3r bed plane) extruded ±half-width perpendicular to path.
    private func makeRibbonNode(points: [SCNVector3], width: Float, color: UIColor) -> SCNNode? {
        let n = points.count
        guard n >= 2 else { return nil }
        let half = max(width, 0.12) * 0.5
        // Cap segment density for large paths
        let stride = max(1, n / 4000)
        var sampled: [SCNVector3] = []
        var i = 0
        while i < n {
            sampled.append(points[i])
            i += stride
        }
        if sampled.last.map({ $0.x != points[n - 1].x || $0.y != points[n - 1].y || $0.z != points[n - 1].z }) ?? true {
            sampled.append(points[n - 1])
        }
        let m = sampled.count
        guard m >= 2 else { return nil }

        var verts: [SCNVector3] = []
        verts.reserveCapacity(m * 2)
        for j in 0..<m {
            let p = sampled[j]
            // Tangent from neighbors
            let prev = sampled[max(0, j - 1)]
            let next = sampled[min(m - 1, j + 1)]
            var tx = next.x - prev.x
            var ty = next.y - prev.y
            let len = max(sqrtf(tx * tx + ty * ty), 1e-4)
            tx /= len; ty /= len
            // Perpendicular in XY
            let px = -ty * half
            let py = tx * half
            verts.append(SCNVector3(p.x + px, p.y + py, p.z + 0.02))
            verts.append(SCNVector3(p.x - px, p.y - py, p.z + 0.02))
        }

        var indices: [UInt32] = []
        indices.reserveCapacity((m - 1) * 6)
        for j in 0..<(m - 1) {
            let a = UInt32(j * 2)
            let b = a + 1
            let c = a + 2
            let d = a + 3
            // two triangles (double-sided via material)
            indices.append(contentsOf: [a, c, b, b, c, d])
        }

        // SCNVector3 may pack as 16 bytes on some platforms — use Float triples explicitly
        var floats: [Float] = []
        floats.reserveCapacity(verts.count * 3)
        for v in verts {
            floats.append(v.x); floats.append(v.y); floats.append(v.z)
        }
        let fData = Data(bytes: floats, count: floats.count * MemoryLayout<Float>.size)
        let src = SCNGeometrySource(
            data: fData,
            semantic: .vertex,
            vectorCount: verts.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 3
        )
        let idxData = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.size)
        let elem = SCNGeometryElement(
            data: idxData,
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let geo = SCNGeometry(sources: [src], elements: [elem])
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        mat.writesToDepthBuffer = true
        mat.readsFromDepthBuffer = true
        geo.materials = [mat]
        return SCNNode(geometry: geo)
    }
}
