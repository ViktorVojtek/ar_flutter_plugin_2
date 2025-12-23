import Foundation
import ARKit
import RealityKit

// MARK: - Depth API & Light Estimation Extension

@available(iOS 13.0, *)
extension IosARViewRealityKit {
    
    // MARK: - Depth API Methods
    
    /// Check if depth occlusion is supported on this device
    /// Prefers scene reconstruction (LiDAR mesh) for best quality occlusion
    func isDepthSupported(result: FlutterResult) {
        if #available(iOS 14.0, *) {
            // Prefer scene reconstruction (requires LiDAR) for best occlusion
            let meshSupported = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
            let depthSupported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
            let supported = meshSupported || depthSupported
            print("📏 Depth API support check - Mesh: \(meshSupported), SceneDepth: \(depthSupported)")
            result(supported)
        } else {
            print("📏 Depth API requires iOS 14.0+")
            result(false)
        }
    }
    
    /// Enable or disable depth occlusion
    /// RealityKit makes this MUCH simpler than SceneKit!
    /// Uses Scene Reconstruction for automatic mesh-based occlusion on LiDAR devices
    func enableDepthOcclusion(enable: Bool, result: FlutterResult) {
        if #available(iOS 14.0, *) {
            // Check for scene reconstruction support (requires LiDAR)
            // Prefer meshWithClassification for better accuracy and fewer artifacts
            let supportsClassification = ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
            let supportsMesh = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
            
            if supportsClassification || supportsMesh {
                if enable {
                    // Use meshWithClassification if available (more accurate, fewer artifacts)
                    if supportsClassification {
                        configuration.sceneReconstruction = .meshWithClassification
                        print("✅ Using mesh WITH classification for better accuracy")
                    } else {
                        configuration.sceneReconstruction = .mesh
                        print("✅ Using basic mesh reconstruction")
                    }
                    
                    // Enable automatic occlusion in RealityKit scene understanding
                    arView.environment.sceneUnderstanding.options.insert(.occlusion)
                    arView.environment.sceneUnderstanding.options.insert(.receivesLighting)
                    
                    // Also enable scene depth for additional accuracy
                    if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                        configuration.frameSemantics.insert(.sceneDepth)
                    }
                    
                    arView.session.run(configuration, options: [])
                    
                    print("✅ Depth occlusion ENABLED (LiDAR mesh-based reconstruction)")
                } else {
                    // Disable scene reconstruction
                    configuration.sceneReconstruction = []
                    
                    // Only remove occlusion if people occlusion is also disabled
                    if !ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) || 
                       !configuration.frameSemantics.contains(.personSegmentationWithDepth) {
                        arView.environment.sceneUnderstanding.options.remove(.occlusion)
                    }
                    
                    configuration.frameSemantics.remove(.sceneDepth)
                    arView.session.run(configuration, options: [])
                    
                    print("❌ Depth occlusion DISABLED")
                }
                
                depthOcclusionEnabled = enable
                result(true)
            } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                // Fallback: Device has depth sensor but no scene reconstruction (unlikely)
                print("⚠️ Scene reconstruction not supported, using basic depth")
                if enable {
                    configuration.frameSemantics.insert(.sceneDepth)
                    arView.environment.sceneUnderstanding.options.insert(.occlusion)
                    arView.session.run(configuration, options: [])
                } else {
                    configuration.frameSemantics.remove(.sceneDepth)
                    arView.environment.sceneUnderstanding.options.remove(.occlusion)
                    arView.session.run(configuration, options: [])
                }
                depthOcclusionEnabled = enable
                result(true)
            } else {
                print("⚠️ Depth occlusion not supported on this device (requires LiDAR)")
                result(false)
            }
        } else {
            print("⚠️ Depth occlusion requires iOS 14.0+")
            result(false)
        }
    }
    
    /// Show or hide the debug mesh visualization
    /// This helps you see exactly what the LiDAR is reconstructing
    func showDebugMesh(show: Bool, result: FlutterResult) {
        if #available(iOS 13.4, *) {
            if show {
                // Show the reconstructed mesh for debugging
                arView.debugOptions.insert(.showSceneUnderstanding)
                print("🔍 Debug mesh visualization ENABLED - you can see the LiDAR mesh")
            } else {
                arView.debugOptions.remove(.showSceneUnderstanding)
                print("🔍 Debug mesh visualization DISABLED")
            }
            result(true)
        } else {
            print("⚠️ Debug mesh requires iOS 13.4+")
            result(false)
        }
    }
    
    // MARK: - People Occlusion Methods
    
    /// Check if people occlusion is supported on this device
    /// Requires A12 chip or later (iPhone XS/XR or newer)
    func isPeopleOcclusionSupported(result: FlutterResult) {
        if #available(iOS 13.0, *) {
            let supported = ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth)
            print("👤 People occlusion support check: \(supported)")
            result(supported)
        } else {
            print("👤 People occlusion requires iOS 13.0+")
            result(false)
        }
    }
    
    /// Enable or disable people occlusion
    /// This uses machine learning to segment people and render them in front of AR objects
    /// Works on devices WITHOUT LiDAR (A12 chip or later)
    func enablePeopleOcclusion(enable: Bool, result: FlutterResult) {
        if #available(iOS 13.0, *) {
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
                if enable {
                    // Enable person segmentation with depth
                    configuration.frameSemantics.insert(.personSegmentationWithDepth)
                    arView.session.run(configuration, options: [])
                    
                    // Enable occlusion in RealityKit (requires iOS 13.4+)
                    if #available(iOS 13.4, *) {
                        arView.environment.sceneUnderstanding.options.insert(.occlusion)
                    }
                    
                    print("✅ People occlusion ENABLED (machine learning segmentation)")
                } else {
                    // Disable person segmentation
                    configuration.frameSemantics.remove(.personSegmentationWithDepth)
                    
                    // Only remove occlusion option if depth occlusion is also disabled
                    if !depthOcclusionEnabled {
                        if #available(iOS 13.4, *) {
                            arView.environment.sceneUnderstanding.options.remove(.occlusion)
                        }
                    }
                    
                    arView.session.run(configuration, options: [])
                    
                    print("❌ People occlusion DISABLED")
                }
                
                result(true)
            } else {
                print("⚠️ People occlusion not supported on this device (requires A12 chip or later)")
                result(false)
            }
        } else {
            print("⚠️ People occlusion requires iOS 13.0+")
            result(false)
        }
    }
    
    /// Check if people occlusion is currently enabled
    func isPeopleOcclusionEnabled(result: FlutterResult) {
        if #available(iOS 13.0, *) {
            let enabled = configuration.frameSemantics.contains(.personSegmentationWithDepth)
            result(enabled)
        } else {
            result(false)
        }
    }
    
    /// Acquire depth image data from current AR frame
    func acquireDepthImage(result: FlutterResult) {
        if #available(iOS 14.0, *) {
            guard let frame = arView.session.currentFrame else {
                result(FlutterError(code: "NO_FRAME", message: "AR frame not available", details: nil))
                return
            }
            
            guard let sceneDepth = frame.sceneDepth else {
                result(FlutterError(code: "NO_DEPTH", message: "Scene depth not available", details: nil))
                return
            }
            
            let depthMap = sceneDepth.depthMap
            let width = CVPixelBufferGetWidth(depthMap)
            let height = CVPixelBufferGetHeight(depthMap)
            
            CVPixelBufferLockBaseAddress(depthMap, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
            
            guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
                result(FlutterError(code: "NO_DATA", message: "Failed to get depth data", details: nil))
                return
            }
            
            // ARKit provides depth as 32-bit float (kCVPixelFormatType_DepthFloat32)
            let depthData = Data(bytes: baseAddress, count: width * height * MemoryLayout<Float32>.size)
            
            let depthInfo: [String: Any] = [
                "width": width,
                "height": height,
                "depthData": FlutterStandardTypedData(bytes: depthData),
                "format": "DEPTH_FLOAT32", // ARKit uses 32-bit float
                "confidenceAvailable": frame.sceneDepth?.confidenceMap != nil
            ]
            
            print("📏 Acquired depth image: \(width)x\(height), \(depthData.count) bytes")
            result(depthInfo)
        } else {
            result(FlutterError(code: "NOT_SUPPORTED", message: "Depth API requires iOS 14.0+", details: nil))
        }
    }
    
    // MARK: - Light Estimation Methods
    
    /// Get current light estimate from ARKit
    func getLightEstimate(result: FlutterResult) {
        guard let frame = arView.session.currentFrame else {
            result(FlutterError(code: "NO_FRAME", message: "AR frame not available", details: nil))
            return
        }
        
        guard let lightEstimate = frame.lightEstimate else {
            result(FlutterError(code: "NO_ESTIMATE", message: "Light estimate not available", details: nil))
            return
        }
        
        let ambientIntensity = lightEstimate.ambientIntensity
        let ambientColorTemperature = lightEstimate.ambientColorTemperature
        
        // Normalize ambient intensity (typical range: 0-2000 lumens, normalize to 0-1)
        let normalizedIntensity = Float(ambientIntensity / 2000.0)
        let isLowLight = normalizedIntensity < 0.3
        let isVeryLowLight = normalizedIntensity < 0.15
        
        let lightData: [String: Any] = [
            "ambientIntensity": ambientIntensity,
            "normalizedIntensity": normalizedIntensity,
            "ambientColorTemperature": ambientColorTemperature,
            "isLowLight": isLowLight,
            "isVeryLowLight": isVeryLowLight,
            "timestamp": Date().timeIntervalSince1970 * 1000
        ]
        
        print("💡 Light estimate - Intensity: \(normalizedIntensity), Low light: \(isLowLight)")
        result(lightData)
    }
    
    /// Enable or disable automatic lighting condition monitoring
    func enableLightingMonitoring(arguments: Dictionary<String, Any>?, result: FlutterResult) {
        let enable = arguments?["enable"] as? Bool ?? true
        
        if let intervalMs = arguments?["intervalMs"] as? Int {
            lightingCheckInterval = TimeInterval(intervalMs) / 1000.0
        }
        
        isMonitoringLighting = enable
        
        if enable {
            print("💡 Starting lighting monitoring (interval: \(lightingCheckInterval)s)")
            startLightingMonitoring()
        } else {
            print("💡 Stopping lighting monitoring")
            stopLightingMonitoring()
        }
        
        result(true)
    }
    
    /// Start the lighting monitoring timer
    func startLightingMonitoring() {
        stopLightingMonitoring() // Clear any existing timer
        
        lightingCheckTimer = Timer.scheduledTimer(withTimeInterval: lightingCheckInterval, repeats: true) { [weak self] _ in
            self?.checkLightingConditions()
        }
    }
    
    /// Stop the lighting monitoring timer
    func stopLightingMonitoring() {
        lightingCheckTimer?.invalidate()
        lightingCheckTimer = nil
    }
    
    /// Check lighting conditions and notify Flutter
    private func checkLightingConditions() {
        guard let frame = arView.session.currentFrame,
              let lightEstimate = frame.lightEstimate else {
            return
        }
        
        let ambientIntensity = lightEstimate.ambientIntensity
        let normalizedIntensity = Float(ambientIntensity / 2000.0)
        let isLowLight = normalizedIntensity < 0.3
        let isVeryLowLight = normalizedIntensity < 0.15
        
        let lightData: [String: Any] = [
            "ambientIntensity": ambientIntensity,
            "normalizedIntensity": normalizedIntensity,
            "isLowLight": isLowLight,
            "isVeryLowLight": isVeryLowLight,
            "timestamp": Date().timeIntervalSince1970 * 1000
        ]
        
        sessionManagerChannel.invokeMethod("onLightingConditionChanged", arguments: lightData)
    }
}
