import UIKit
import Foundation
import ARKit
import GLTFSceneKit
import Combine

// Responsible for creating Renderables and Nodes
class ArModelBuilder: NSObject {

    func makePlane(anchor: ARPlaneAnchor, flutterAssetFile: String?) -> SCNNode {
        let plane = SCNPlane(width: CGFloat(anchor.extent.x), height: CGFloat(anchor.extent.z))
        //Create material
        let material = SCNMaterial()
        let opacity: CGFloat
        
        if let textureSourcePath = flutterAssetFile {
            // Use given asset as plane texture
            let key = FlutterDartProject.lookupKey(forAsset: textureSourcePath)
            if let image = UIImage(named: key, in: Bundle.main,compatibleWith: nil){
                // Asset was found so we can use it
                material.diffuse.contents = image
                material.diffuse.wrapS = .repeat
                material.diffuse.wrapT = .repeat
                plane.materials = [material]
                opacity = 1.0
            } else {
                // Use standard planes
                opacity = 0.3
            }
        } else {
            // Use standard planes
            opacity = 0.3
        }
        
        let planeNode = SCNNode(geometry: plane)
        planeNode.position = SCNVector3Make(anchor.center.x, 0, anchor.center.z)
        // rotate plane by 90 degrees to match the anchor (planes are vertical by default)
        planeNode.eulerAngles.x = -.pi / 2

        planeNode.opacity = opacity

        return planeNode
    }

    func updatePlaneNode(planeNode: SCNNode, anchor: ARPlaneAnchor){
        if let plane = planeNode.geometry as? SCNPlane {
            // Update plane dimensions
            plane.width = CGFloat(anchor.extent.x)
            plane.height = CGFloat(anchor.extent.z)
            // Update texture of planes
            let imageSize: Float = 65 // in mm
            let repeatAmount: Float = 1000 / imageSize //how often per meter we need to repeat the image
            if let gridMaterial = plane.materials.first {
                gridMaterial.diffuse.contentsTransform = SCNMatrix4MakeScale(anchor.extent.x * repeatAmount, anchor.extent.z * repeatAmount, 1)
            }
        }
       planeNode.position = SCNVector3Make(anchor.center.x, 0, anchor.center.z)
    }

    // Creates a node from a given gltf2 (.gltf) model in the Flutter assets folder
    func makeNodeFromGltf(name: String, modelPath: String, transformation: Array<NSNumber>?) -> SCNNode? {
        
        var scene: SCNScene
        let node: SCNNode = SCNNode()

        do {
            let sceneSource = try GLTFSceneSource(named: modelPath)
            
            // Safely get the scene with proper error handling
            do {
                scene = try sceneSource.scene()
            } catch {
                print("Failed to load scene from GLTF asset \(modelPath): \(error.localizedDescription)")
                return nil
            }

            for child in scene.rootNode.childNodes {
                // Use clone() instead of flattenedClone() to preserve:
                // - Normal maps and their UV coordinate sets
                // - Multi-material assignments per sub-mesh
                // - All PBR texture channels from the glTF model
                // flattenedClone() merges geometry and can strip texture data.
                let cloned = child.clone()
                self.enableShadowsOnNode(cloned)
                node.addChildNode(cloned)
            }

            // CRITICAL FIX: Add "[#" prefix to match gesture detection pattern
            node.name = "[#\(name)"
            if let transform = transformation {
                node.transform = deserializeMatrix4(transform)
            }

            return node
        } catch {
            print("Error creating GLTFSceneSource for \(modelPath): \(error.localizedDescription)")
            return nil
        }
    }

    // Creates a node from a given gltf2 (.gltf) model in the Flutter assets folder
    func makeNodeFromFileSystemGltf(name: String, modelPath: String, transformation: Array<NSNumber>?) -> SCNNode? {
        
        var scene: SCNScene
        let node: SCNNode = SCNNode()

        do {
            let sceneSource = try GLTFSceneSource(path: modelPath)
            
            // Safely get the scene with proper error handling
            do {
                scene = try sceneSource.scene()
            } catch {
                print("Failed to load scene from GLTF file \(modelPath): \(error.localizedDescription)")
                return nil
            }

            for child in scene.rootNode.childNodes {
                let cloned = child.clone()
                self.enableShadowsOnNode(cloned)
                node.addChildNode(cloned)
            }

            // CRITICAL FIX: Add "[#" prefix to match gesture detection pattern
            node.name = "[#\(name)"
            if let transform = transformation {
                node.transform = deserializeMatrix4(transform)
            }

            return node
        } catch {
            print("Error creating GLTFSceneSource for \(modelPath): \(error.localizedDescription)")
            return nil
        }
    }
    
    // Creates a node from a given glb model in the app's documents directory
    func makeNodeFromFileSystemGLB(name: String, modelPath: String, transformation: Array<NSNumber>?) -> SCNNode? {
        
        var scene: SCNScene
        let node: SCNNode = SCNNode()

        do {
            let sceneSource = try GLTFSceneSource(path: modelPath)
            
            // Safely get the scene with proper error handling
            do {
                scene = try sceneSource.scene()
            } catch {
                print("Failed to load scene from GLB file \(modelPath): \(error.localizedDescription)")
                return nil
            }

            for child in scene.rootNode.childNodes {
                let cloned = child.clone()
                self.enableShadowsOnNode(cloned)
                node.addChildNode(cloned)
            }

            // CRITICAL FIX: Add "[#" prefix to match gesture detection pattern
            node.name = "[#\(name)"
            if let transform = transformation {
                node.transform = deserializeMatrix4(transform)
            }

            return node
        } catch {
            print("Error creating GLTFSceneSource for GLB \(modelPath): \(error.localizedDescription)")
            return nil
        }
    }
    
    // Creates a node form a given glb model path
    func makeNodeFromWebGlb(name: String, modelURL: String, transformation: Array<NSNumber>?) -> Future<SCNNode?, Never> {
        
        return Future {promise in
            var node: SCNNode? = SCNNode()
            
            let handler: (URL?, URLResponse?, Error?) -> Void = {(url: URL?, urlResponse: URLResponse?, error: Error?) -> Void in
                // If response code is not 200, link was invalid, so return
                if ((urlResponse as? HTTPURLResponse)?.statusCode != 200) {
                    print("makeNodeFromWebGltf received non-200 response code")
                    node = nil
                    promise(.success(node))
                } else {
                    guard let fileURL = url else { return }
                    do {
                        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
                        let documentsDirectory = paths[0]
                        let targetURL = documentsDirectory.appendingPathComponent(urlResponse!.url!.lastPathComponent)
                        
                        try? FileManager.default.removeItem(at: targetURL) //remove item if it's already there
                        try FileManager.default.copyItem(at: fileURL, to: targetURL)

                        do {
                            let sceneSource = GLTFSceneSource(url: targetURL)
                            
                            // Safely try to get the scene with proper error handling
                            let scene: SCNScene
                            do {
                                scene = try sceneSource.scene()
                            } catch {
                                print("Failed to load scene from GLB file: \(error.localizedDescription)")
                                print("This might be due to corrupted download or invalid GLB format")
                                node = nil
                                promise(.success(node))
                                return
                            }
                            
                            // Ensure scene has content
                            guard !scene.rootNode.childNodes.isEmpty else {
                                print("GLB scene loaded but contains no child nodes")
                                node = nil
                                promise(.success(node))
                                return
                            }

                            for child in scene.rootNode.childNodes {
                                // SCALE FIX: Remove hardcoded 0.01x scale to match Android behavior
                                // Let Flutter handle all scaling for cross-platform consistency
                                //child.scale = SCNVector3(0.01,0.01,0.01) // REMOVED: This caused iOS models to be 100x smaller than Android
                                //child.eulerAngles.z = -.pi // Compensate for the different model coordinate definitions in iOS and Android
                                //child.eulerAngles.y = -.pi // Compensate for the different model coordinate definitions in iOS and Android
                                
                                // AMBIENT OCCLUSION FIX: Enable shadow receiving on all materials
                                self.enableShadowsOnNode(child)
                                
                                node?.addChildNode(child)
                            }

                            // CRITICAL FIX: Add "[#" prefix to match gesture detection pattern
                            node?.name = "[#\(name)"
                            if let transform = transformation {
                                node?.transform = deserializeMatrix4(transform)
                            }
                            /*node?.scale = worldScale
                            node?.position = worldPosition
                            node?.worldOrientation = worldRotation*/

                        } catch {
                            print("Unexpected error during GLB processing: \(error.localizedDescription)")
                            node = nil
                        }
                        
                        // Delete file to avoid cluttering device storage (at some point, caching can be included)
                        try FileManager.default.removeItem(at: targetURL)
                        
                        promise(.success(node))
                    } catch {
                        node = nil
                        promise(.success(node))
                    }
                }
                
            }
            
    
            let downloadTask = URLSession.shared.downloadTask(with: URL(string: modelURL)!, completionHandler: handler)
            
            downloadTask.resume()
            
        }
        
    }
    
    // MARK: - Origin Centering for Stable Rotation
    
    /**
     * Centers the pivot point of a node so rotation happens around the geometric center.
     * This prevents objects from "jumping" during rotation gestures.
     * 
     * - Parameter node: The node to center
     * - Parameter centerX: Whether to center the X axis (default: true)
     * - Parameter centerY: Whether to center the Y axis (default: false - keeps bottom aligned)
     * - Parameter centerZ: Whether to center the Z axis (default: true)
     * 
     * For furniture-style placement, use centerY=false to keep objects floor-aligned.
     */
    func centerOrigin(node: SCNNode, centerX: Bool = true, centerY: Bool = false, centerZ: Bool = true) {
        // Get the bounding box of the node in local coordinates
        let (bbMin, bbMax) = node.boundingBox
        
        // Calculate the pivot offset for each axis
        // -1 on an axis = bottom aligned, 0 = centered
        let pivotX = centerX ? (bbMin.x + bbMax.x) / 2 : 0
        let pivotY = centerY ? (bbMin.y + bbMax.y) / 2 : bbMin.y  // Bottom aligned by default
        let pivotZ = centerZ ? (bbMin.z + bbMax.z) / 2 : 0
        
        // Set the pivot point
        // The pivot is in local coordinates - moving the pivot effectively moves the rotation center
        node.pivot = SCNMatrix4MakeTranslation(pivotX, pivotY, pivotZ)
        
        print("🎯 iOS centerOrigin applied - pivot: (\(pivotX), \(pivotY), \(pivotZ)) | boundingBox: min(\(bbMin.x), \(bbMin.y), \(bbMin.z)) max(\(bbMax.x), \(bbMax.y), \(bbMax.z))")
    }
    
    // MARK: - Ambient Occlusion / Shadow Support
    
    /**
     * Recursively enable shadow casting and receiving on all materials in a node hierarchy
     * This is critical for ambient occlusion to work properly in SceneKit
     */
    private func enableShadowsOnNode(_ node: SCNNode) {
        if let geometry = node.geometry {
            for material in geometry.materials {
                // Ensure PBR lighting model for all materials
                material.lightingModel = .physicallyBased
                material.isDoubleSided = true
                
                // Depth buffer for proper shadow receiving
                material.writesToDepthBuffer = true
                material.readsFromDepthBuffer = true
                
                // Boost normal map intensity for visible surface bumps
                // Android Filament renders normal maps at full intensity;
                // SceneKit sometimes under-renders them.
                if material.normal.contents != nil {
                    material.normal.intensity = max(material.normal.intensity, 1.2)
                    print("📦 SceneKit: Normal map found, intensity=\(material.normal.intensity)")
                }
                
                // DO NOT darken ambient — this was causing all materials to render
                // darker than Android. Let the scene lighting handle shadows naturally.
            }
        }
        
        // Cast shadows from this node
        node.castsShadow = true
        
        // Recursively apply to all child nodes
        for child in node.childNodes {
            enableShadowsOnNode(child)
        }
    }
    
}
