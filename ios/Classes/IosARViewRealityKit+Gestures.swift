import Foundation
import UIKit
import ARKit
import RealityKit

// MARK: - Gesture Management Extension

@available(iOS 13.0, *)
extension IosARViewRealityKit: UIGestureRecognizerDelegate {
    
    // MARK: - Helper Methods
    
    /// Find the root entity that we manage (has a name in entityCollection)
    private func findManagedEntity(from entity: Entity) -> Entity {
        // First check if this entity itself is managed
        if entityCollection[entity.name] != nil {
            return entity
        }
        
        // Traverse up to find a managed entity
        var current: Entity? = entity
        while let parent = current?.parent, !(parent is Scene), !(parent is AnchorEntity) {
            if let parentEntity = parent as? Entity {
                if entityCollection[parentEntity.name] != nil {
                    return parentEntity
                }
                current = parentEntity
            } else {
                break
            }
        }
        
        // Traverse down to find a managed entity (in case we hit a wrapper)
        var managed = entity
        entity.children.forEach { child in
            if let childEntity = child as? Entity, entityCollection[childEntity.name] != nil {
                managed = childEntity
            }
        }
        
        return managed
    }
    
    // MARK: - Gesture Setup
    
    func setupTapGesture() {
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tapGesture.delegate = self
        arView.addGestureRecognizer(tapGesture)
        print("✅ Tap gesture enabled")
    }
    
    func setupPanGesture() {
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.maximumNumberOfTouches = 1
        panGesture.delegate = self
        arView.addGestureRecognizer(panGesture)
        self.panGesture = panGesture
        print("✅ Pan gesture enabled")
    }
    
    func setupRotationGesture() {
        let rotationGesture = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
        rotationGesture.delegate = self
        arView.addGestureRecognizer(rotationGesture)
        self.rotationGesture = rotationGesture
        print("✅ Rotation gesture enabled")
    }
    
    func setupPinchGesture() {
        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinchGesture.delegate = self
        arView.addGestureRecognizer(pinchGesture)
        self.pinchGesture = pinchGesture
        print("✅ Pinch gesture enabled")
    }
    
    // MARK: - Gesture Handlers
    
    @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
        let location = recognizer.location(in: arView)
        
        // First, check if user tapped on an entity (for selection)
        if let entity = arView.entity(at: location) {
            let rootEntity = findManagedEntity(from: entity)
            
            // Update selection state
            selectedEntity = rootEntity
            
            // Notify Flutter about entity tap
            DispatchQueue.main.async {
                self.objectManagerChannel.invokeMethod("onNodeTap", arguments: [rootEntity.name])
                // Also send selection changed event (like Android does)
                self.objectManagerChannel.invokeMethod("onSelectionChanged", arguments: rootEntity.name)
            }
            
            if debugGesturesEnabled {
                print("👆 Tapped entity: \(rootEntity.name) - selected")
            }
            return
        }
        
        // No entity hit - deselect current entity and check for plane/point (for placement)
        let wasSelected = selectedEntity != nil
        if wasSelected {
            selectedEntity = nil
            // Notify Flutter about deselection
            DispatchQueue.main.async {
                self.objectManagerChannel.invokeMethod("onSelectionChanged", arguments: nil)
            }
            if debugGesturesEnabled {
                print("👆 Tapped empty space - deselected")
            }
        }
        
        // Check for plane/point hit (for placement)
        if let result = arView.raycast(from: location, allowing: .estimatedPlane, alignment: .any).first {
            // Convert to anchor transform
            let transform = result.worldTransform
            let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            
            // Notify Flutter about plane/point tap
            let tapData: [String: Any] = [
                "x": position.x,
                "y": position.y,
                "z": position.z,
                "transform": serializeMatrix(transform)
            ]
            
            DispatchQueue.main.async {
                self.sessionManagerChannel.invokeMethod("onTap", arguments: tapData)
            }
            
            if debugGesturesEnabled {
                print("👆 Tap at plane/point: \(position)")
            }
        } else if wasSelected {
            // No plane hit but we did deselect - send empty space tap event
            DispatchQueue.main.async {
                self.objectManagerChannel.invokeMethod("onEmptySpaceTap", arguments: nil)
            }
        }
    }
    
    @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let location = recognizer.location(in: arView)
        
        switch recognizer.state {
        case .began:
            // Find entity at touch location
            if let entity = arView.entity(at: location) {
                let rootEntity = findManagedEntity(from: entity)
                selectedEntity = rootEntity
                
                let translation = recognizer.translation(in: arView)
                let velocity = recognizer.velocity(in: arView)
                
                let panData: [String: Any] = [
                    "entityName": rootEntity.name,
                    "translationX": translation.x,
                    "translationY": translation.y,
                    "velocityX": velocity.x,
                    "velocityY": velocity.y
                ]
                
                DispatchQueue.main.async {
                    self.objectManagerChannel.invokeMethod("onPanStart", arguments: panData)
                }
                
                if debugGesturesEnabled {
                    print("🖐️ Pan started on: \(rootEntity.name) (root entity)")
                }
            }
            
        case .changed:
            guard let entity = selectedEntity else { return }
            
            // Get translation and velocity BEFORE we reset it
            let translation = recognizer.translation(in: arView)
            let velocity = recognizer.velocity(in: arView)
            
            // Convert 2D pan to 3D movement on the horizontal (XZ) plane
            if let camera = arView.session.currentFrame?.camera {
                let cameraTransform = camera.transform
                
                // Get camera's forward direction projected onto horizontal plane
                // Column 2 is backward, so we negate it to get forward
                var cameraForward = SIMD3<Float>(-cameraTransform.columns.2.x, 0, -cameraTransform.columns.2.z)
                if simd_length(cameraForward) > 0.001 {
                    cameraForward = simd_normalize(cameraForward)
                } else {
                    cameraForward = SIMD3<Float>(0, 0, -1)
                }
                
                // Compute right vector as cross product of forward and world-up
                // This ensures right is truly perpendicular to forward on the horizontal plane
                let worldUp = SIMD3<Float>(0, 1, 0)
                let cameraRight = simd_normalize(simd_cross(cameraForward, worldUp))
                
                let panScale: Float = 0.004
                let deltaX = Float(translation.x) * panScale
                let deltaY = Float(translation.y) * panScale
                
                // Save original position for distance check
                let originalPosition = entity.position(relativeTo: nil)
                
                // Calculate world-space movement:
                // - Swipe right on screen (positive deltaX) = move right in world
                // - Swipe up on screen (negative deltaY) = move forward in world
                let worldMovement = cameraRight * deltaX - cameraForward * deltaY
                
                // Apply movement in world space
                entity.setPosition(originalPosition + worldMovement, relativeTo: nil)
                
                // Check distance from camera - clamp if too far
                let cameraPosition = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
                let newPosition = entity.position(relativeTo: nil)
                let distanceFromCamera = simd_distance(newPosition, cameraPosition)
                
                if distanceFromCamera > maxPanDistanceMeters {
                    // Revert to original position - object too far
                    entity.setPosition(originalPosition, relativeTo: nil)
                    if debugGesturesEnabled {
                        print("⚠️ Pan limited: distance \(distanceFromCamera)m exceeds max \(maxPanDistanceMeters)m")
                    }
                }
                
                // Reset translation AFTER we've used it
                recognizer.setTranslation(.zero, in: arView)
            }
            
            // Send notification to Flutter with the translation we just processed
            let panData: [String: Any] = [
                "entityName": entity.name,
                "translationX": translation.x,
                "translationY": translation.y,
                "velocityX": velocity.x,
                "velocityY": velocity.y,
                "positionX": entity.position.x,
                "positionY": entity.position.y,
                "positionZ": entity.position.z
            ]
            
            DispatchQueue.main.async {
                self.objectManagerChannel.invokeMethod("onPanChange", arguments: panData)
            }
            
        case .ended, .cancelled:
            if let entity = selectedEntity {
                let velocity = recognizer.velocity(in: arView)
                
                let panData: [String: Any] = [
                    "entityName": entity.name,
                    "velocityX": velocity.x,
                    "velocityY": velocity.y,
                    "finalPositionX": entity.position.x,
                    "finalPositionY": entity.position.y,
                    "finalPositionZ": entity.position.z
                ]
                
                DispatchQueue.main.async {
                    self.objectManagerChannel.invokeMethod("onPanEnd", arguments: panData)
                }
                
                if debugGesturesEnabled {
                    print("🖐️ Pan ended on: \(entity.name)")
                }
            }
            selectedEntity = nil
            
        default:
            break
        }
    }
    
    @objc func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
        let location = recognizer.location(in: arView)
        
        switch recognizer.state {
        case .began:
            if let entity = arView.entity(at: location) {
                let rootEntity = findManagedEntity(from: entity)
                selectedEntity = rootEntity
                
                let rotationData: [String: Any] = [
                    "entityName": rootEntity.name,
                    "rotation": recognizer.rotation,
                    "velocity": recognizer.velocity
                ]
                
                DispatchQueue.main.async {
                    self.objectManagerChannel.invokeMethod("onRotationStart", arguments: rotationData)
                }
                
                if debugGesturesEnabled {
                    print("🔄 Rotation started on: \(rootEntity.name) (root entity)")
                }
            }
            
        case .changed:
            guard let entity = selectedEntity else { return }
            
            // Apply rotation around Y axis (vertical/up axis in world space)
            // UIRotationGestureRecognizer: positive = counter-clockwise
            // RealityKit Y-axis rotation: positive = counter-clockwise when looking down
            // We negate to make clockwise finger rotation = clockwise object rotation
            let rotation = -Float(recognizer.rotation)
            
            // Create rotation quaternion around world Y-axis
            let rotationQuat = simd_quatf(angle: rotation, axis: [0, 1, 0])
            
            // Apply rotation in world space by getting world orientation, rotating, and setting back
            let worldOrientation = entity.orientation(relativeTo: nil)
            entity.setOrientation(rotationQuat * worldOrientation, relativeTo: nil)
            
            // Reset rotation
            recognizer.rotation = 0
            
            let rotationData: [String: Any] = [
                "entityName": entity.name,
                "rotation": rotation,
                "velocity": recognizer.velocity
            ]
            
            DispatchQueue.main.async {
                self.objectManagerChannel.invokeMethod("onRotationChange", arguments: rotationData)
            }
            
        case .ended, .cancelled:
            if let entity = selectedEntity {
                let rotationData: [String: Any] = [
                    "entityName": entity.name,
                    "finalRotation": recognizer.rotation,
                    "velocity": recognizer.velocity
                ]
                
                DispatchQueue.main.async {
                    self.objectManagerChannel.invokeMethod("onRotationEnd", arguments: rotationData)
                }
                
                if debugGesturesEnabled {
                    print("🔄 Rotation ended on: \(entity.name)")
                }
            }
            selectedEntity = nil
            
        default:
            break
        }
    }
    
    @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        let location = recognizer.location(in: arView)
        
        switch recognizer.state {
        case .began:
            if let entity = arView.entity(at: location) {
                let rootEntity = findManagedEntity(from: entity)
                selectedEntity = rootEntity
                if debugGesturesEnabled {
                    print("🤏 Pinch started on: \(rootEntity.name) (root entity)")
                }
            }
            
        case .changed:
            guard let entity = selectedEntity else { return }
            
            // Apply scale
            let scale = Float(recognizer.scale)
            entity.scale *= SIMD3<Float>(repeating: scale)
            
            // Reset scale
            recognizer.scale = 1.0
            
        case .ended, .cancelled:
            if let entity = selectedEntity {
                if debugGesturesEnabled {
                    print("🤏 Pinch ended on: \(entity.name)")
                }
            }
            selectedEntity = nil
            
        default:
            break
        }
    }
    
    // MARK: - UIGestureRecognizerDelegate
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Allow pan and rotation to work simultaneously
        return true
    }
}
