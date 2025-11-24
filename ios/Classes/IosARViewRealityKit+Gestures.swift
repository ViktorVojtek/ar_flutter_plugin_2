import Foundation
import UIKit
import ARKit
import RealityKit

// MARK: - Gesture Management Extension

@available(iOS 13.0, *)
extension IosARViewRealityKit: UIGestureRecognizerDelegate {
    
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
        
        // Perform raycast to find AR plane
        if let result = arView.raycast(from: location, allowing: .estimatedPlane, alignment: .any).first {
            // Convert to anchor transform
            let transform = result.worldTransform
            let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            
            // Notify Flutter
            let tapData: [String: Any] = [
                "x": position.x,
                "y": position.y,
                "z": position.z,
                "transform": serializeMatrix(transform)
            ]
            
            DispatchQueue.main.async {
                self.sessionManagerChannel.invokeMethod("onTap", arguments: tapData)
            }
            
            print("👆 Tap at: \(position)")
        }
    }
    
    @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let location = recognizer.location(in: arView)
        
        switch recognizer.state {
        case .began:
            // Find entity at touch location
            if let entity = arView.entity(at: location) {
                selectedEntity = entity
                
                let translation = recognizer.translation(in: arView)
                let velocity = recognizer.velocity(in: arView)
                
                let panData: [String: Any] = [
                    "entityName": entity.name,
                    "translationX": translation.x,
                    "translationY": translation.y,
                    "velocityX": velocity.x,
                    "velocityY": velocity.y
                ]
                
                DispatchQueue.main.async {
                    self.objectManagerChannel.invokeMethod("onPanStart", arguments: panData)
                }
                
                print("🖐️ Pan started on: \(entity.name)")
            }
            
        case .changed:
            guard let entity = selectedEntity else { return }
            
            let translation = recognizer.translation(in: arView)
            let velocity = recognizer.velocity(in: arView)
            
            // Convert 2D pan to 3D movement
            // Move entity in camera's XY plane
            if let camera = arView.session.currentFrame?.camera {
                let cameraTransform = camera.transform
                let right = SIMD3<Float>(cameraTransform.columns.0.x, cameraTransform.columns.0.y, cameraTransform.columns.0.z)
                let up = SIMD3<Float>(cameraTransform.columns.1.x, cameraTransform.columns.1.y, cameraTransform.columns.1.z)
                
                let panScale: Float = 0.001
                let deltaX = Float(translation.x) * panScale
                let deltaY = Float(translation.y) * panScale
                
                entity.position += right * deltaX
                entity.position += up * (-deltaY)
                
                // Reset translation
                recognizer.setTranslation(.zero, in: arView)
            }
            
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
                
                print("🖐️ Pan ended on: \(entity.name)")
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
                selectedEntity = entity
                
                let rotationData: [String: Any] = [
                    "entityName": entity.name,
                    "rotation": recognizer.rotation,
                    "velocity": recognizer.velocity
                ]
                
                DispatchQueue.main.async {
                    self.objectManagerChannel.invokeMethod("onRotationStart", arguments: rotationData)
                }
                
                print("🔄 Rotation started on: \(entity.name)")
            }
            
        case .changed:
            guard let entity = selectedEntity else { return }
            
            // Apply rotation around Y axis (vertical)
            let rotation = Float(recognizer.rotation)
            entity.orientation *= simd_quatf(angle: rotation, axis: [0, 1, 0])
            
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
                
                print("🔄 Rotation ended on: \(entity.name)")
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
                selectedEntity = entity
                print("🤏 Pinch started on: \(entity.name)")
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
                print("🤏 Pinch ended on: \(entity.name)")
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
