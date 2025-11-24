import Foundation
import ARKit
import RealityKit

// MARK: - Anchor Management Extension

@available(iOS 13.0, *)
extension IosARViewRealityKit {
    
    /// Add anchor to AR session
    func addAnchor(arguments: Dictionary<String, Any>, result: @escaping FlutterResult) {
        guard let anchorName = arguments["name"] as? String else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "Anchor name required", details: nil))
            return
        }
        
        print("⚓ Adding anchor: \(anchorName)")
        
        // Parse transform
        guard let transformMatrix = arguments["transformation"] as? [NSNumber], transformMatrix.count == 16 else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "Valid transformation matrix required", details: nil))
            return
        }
        
        let transform = parseAnchorTransform(matrix: transformMatrix)
        
        // Create AR anchor
        let arAnchor = ARAnchor(name: anchorName, transform: transform)
        
        // Add to session
        arView.session.add(anchor: arAnchor)
        
        // Store reference
        anchorCollection[anchorName] = arAnchor
        
        // Create anchor entity for scene
        let anchorEntity = AnchorEntity()
        anchorEntity.name = anchorName
        anchorEntity.transform = Transform(matrix: transform)
        arView.scene.addAnchor(anchorEntity)
        anchorEntityCollection[anchorName] = anchorEntity
        
        print("✅ Anchor added: \(anchorName)")
        result(true) // Return bool as expected by Dart side
    }
    
    /// Remove anchor from AR session
    func removeAnchor(anchorName: String) {
        print("🗑️ Removing anchor: \(anchorName)")
        
        // Remove AR anchor
        if let arAnchor = anchorCollection[anchorName] {
            arView.session.remove(anchor: arAnchor)
            anchorCollection.removeValue(forKey: anchorName)
        }
        
        // Remove anchor entity
        if let anchorEntity = anchorEntityCollection[anchorName] {
            arView.scene.removeAnchor(anchorEntity)
            anchorEntityCollection.removeValue(forKey: anchorName)
        }
        
        print("✅ Anchor removed: \(anchorName)")
    }
    
    /// Parse anchor transform from Flutter
    private func parseAnchorTransform(matrix: [NSNumber]) -> simd_float4x4 {
        let m = matrix.map { Float($0.floatValue) }
        
        return simd_float4x4(
            SIMD4<Float>(m[0], m[1], m[2], m[3]),
            SIMD4<Float>(m[4], m[5], m[6], m[7]),
            SIMD4<Float>(m[8], m[9], m[10], m[11]),
            SIMD4<Float>(m[12], m[13], m[14], m[15])
        )
    }
}

// MARK: - ARSessionDelegate for Anchors

@available(iOS 13.0, *)
extension IosARViewRealityKit {
    
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        for anchor in anchors {
            if let planeAnchor = anchor as? ARPlaneAnchor {
                handlePlaneDetected(planeAnchor: planeAnchor)
            }
        }
    }
    
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        for anchor in anchors {
            if let planeAnchor = anchor as? ARPlaneAnchor {
                handlePlaneUpdated(planeAnchor: planeAnchor)
            }
        }
    }
    
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for anchor in anchors {
            if let planeAnchor = anchor as? ARPlaneAnchor {
                handlePlaneRemoved(planeAnchor: planeAnchor)
            }
        }
    }
    
    // MARK: - Plane Detection Handlers
    
    private func handlePlaneDetected(planeAnchor: ARPlaneAnchor) {
        print("✈️ Plane detected: \(planeAnchor.identifier)")
        planeCount += 1
        
        // Create plane visualization entity
        let planeEntity = createPlaneEntity(for: planeAnchor)
        
        // Create anchor entity for the plane
        let anchorEntity = AnchorEntity(anchor: planeAnchor)
        anchorEntity.addChild(planeEntity)
        
        // Store reference
        trackedPlanes[planeAnchor.identifier] = (anchorEntity, planeEntity)
        
        // Add to scene if showing planes
        if showPlanes {
            arView.scene.addAnchor(anchorEntity)
        }
        
        // Notify Flutter
        let planeData = serializePlaneData(planeAnchor: planeAnchor)
        DispatchQueue.main.async {
            self.sessionManagerChannel.invokeMethod("onPlaneDetected", arguments: planeData)
        }
    }
    
    private func handlePlaneUpdated(planeAnchor: ARPlaneAnchor) {
        guard let (anchorEntity, planeEntity) = trackedPlanes[planeAnchor.identifier] else {
            return
        }
        
        // Update plane geometry
        updatePlaneEntity(planeEntity, for: planeAnchor)
    }
    
    private func handlePlaneRemoved(planeAnchor: ARPlaneAnchor) {
        print("🗑️ Plane removed: \(planeAnchor.identifier)")
        
        if let (anchorEntity, _) = trackedPlanes.removeValue(forKey: planeAnchor.identifier) {
            arView.scene.removeAnchor(anchorEntity)
        }
        
        planeCount -= 1
    }
    
    // MARK: - Plane Visualization
    
    private func createPlaneEntity(for planeAnchor: ARPlaneAnchor) -> ModelEntity {
        // Create mesh for plane - use extent property (iOS 11.3+) instead of planeExtent (iOS 16+)
        let width = planeAnchor.extent.x
        let height = planeAnchor.extent.z
        
        let mesh = MeshResource.generatePlane(width: width, depth: height)
        
        // Create material - compatible with iOS 13+
        var material = SimpleMaterial()
        if #available(iOS 15.0, *) {
            material.color = .init(tint: UIColor.blue.withAlphaComponent(0.5))
        } else {
            // Fallback for iOS 13-14
            material.baseColor = MaterialColorParameter.color(UIColor.blue.withAlphaComponent(0.5))
        }
        
        // Create entity
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = "plane_\(planeAnchor.identifier)"
        
        // Rotate to align with plane
        entity.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        
        // Set visibility based on showPlanes
        entity.isEnabled = showPlanes
        
        return entity
    }
    
    private func updatePlaneEntity(_ entity: ModelEntity, for planeAnchor: ARPlaneAnchor) {
        // Update mesh size - use extent property (iOS 11.3+)
        let width = planeAnchor.extent.x
        let height = planeAnchor.extent.z
        
        let mesh = MeshResource.generatePlane(width: width, depth: height)
        entity.model?.mesh = mesh
    }
    
    private func serializePlaneData(planeAnchor: ARPlaneAnchor) -> [String: Any] {
        // Use extent property (iOS 11.3+) instead of planeExtent (iOS 16+)
        let extent = planeAnchor.extent
        let center = planeAnchor.center
        
        return [
            "identifier": planeAnchor.identifier.uuidString,
            "type": planeAnchor.alignment == .horizontal ? "horizontal" : "vertical",
            "extentX": extent.x,      // Use .x instead of .width
            "extentZ": extent.z,      // Use .z instead of .height
            "centerX": center.x,
            "centerY": center.y,
            "centerZ": center.z,
            "transform": serializeMatrix(planeAnchor.transform)
        ]
    }
}
