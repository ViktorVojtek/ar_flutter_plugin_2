import Foundation
import ARKit
import RealityKit

// MARK: - Depth API & Light Estimation Extension

@available(iOS 13.0, *)
extension IosARViewRealityKit {
    
    // MARK: - Depth API Methods
    
    /// Check if depth API is supported on this device
    func isDepthSupported(result: FlutterResult) {
        if #available(iOS 14.0, *) {
            let supported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
            print("📏 Depth API support check: \(supported)")
            result(supported)
        } else {
            print("📏 Depth API requires iOS 14.0+")
            result(false)
        }
    }
    
    /// Enable or disable depth occlusion
    /// RealityKit makes this MUCH simpler than SceneKit!
    func enableDepthOcclusion(enable: Bool, result: FlutterResult) {
        if #available(iOS 14.0, *) {
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                if enable {
                    // ✅ Enable automatic depth occlusion (RealityKit magic!)
                    arView.environment.sceneUnderstanding.options = [.occlusion, .receivesLighting]
                    
                    // Also enable in configuration
                    configuration.frameSemantics.insert(ARWorldTrackingConfiguration.FrameSemantics.sceneDepth)
                    arView.session.run(configuration, options: [])
                    
                    print("✅ Depth occlusion ENABLED (automatic)")
                } else {
                    // Disable occlusion
                    arView.environment.sceneUnderstanding.options = [.receivesLighting]
                    
                    configuration.frameSemantics.remove(ARWorldTrackingConfiguration.FrameSemantics.sceneDepth)
                    arView.session.run(configuration, options: [])
                    
                    print("❌ Depth occlusion DISABLED")
                }
                
                depthOcclusionEnabled = enable
                result(true)
            } else {
                print("⚠️ Depth occlusion not supported on this device")
                result(false)
            }
        } else {
            print("⚠️ Depth occlusion requires iOS 14.0+")
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
