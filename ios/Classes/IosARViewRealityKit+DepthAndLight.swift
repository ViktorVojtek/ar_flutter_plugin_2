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
    
    // MARK: - Enhanced Lighting Setup (Match Android Filament Quality)
    
    /// Setup enhanced lighting to match Android's Filament/SceneView rendering quality.
    ///
    /// Android uses:
    /// - A custom HDR environment map (`pdp-model-viewer.hdr`) loaded as IBL
    /// - Indirect light intensity reduced to 15,000 lux (from Filament's ~100K default)
    /// - ARCore ENVIRONMENTAL_HDR mode for spherical harmonics + HDR cubemaps
    /// - Filament's default ACES tone mapping
    /// - Automatic shadow casting from the estimated main directional light
    ///
    /// On iOS we replicate this with:
    /// 1. **IBL from custom HDR** via `EnvironmentResource` applied to `arView.environment.lighting`
    /// 2. **DirectionalLight with shadows** for contact shadow / ambient occlusion effect
    /// 3. **Grounding shadows** enabled via `renderOptions` (all iOS versions)
    /// 4. **Environment lighting intensity** tuned to approximate 15K lux equivalent
    /// 5. **ImageBasedLightComponent** on iOS 18+ for per-entity custom IBL
    func setupEnhancedLighting() {
        print("💡 Setting up enhanced lighting to match Android Filament quality...")
        
        // Step 1: Ensure grounding shadows are enabled (all iOS versions)
        // This is already done in setupARView() but reinforce it here
        arView.renderOptions.remove(.disableGroundingShadows)
        arView.renderOptions.remove(.disableAREnvironmentLighting)
        
        // Step 2: Load and apply custom IBL environment from HDR file
        setupCustomIBLEnvironment()
        
        // Step 3: Add directional light with shadow casting for contact shadows
        setupDirectionalLight()
        
        // Step 4: On iOS 18+, set up per-entity ImageBasedLightComponent for richer IBL
        setupPerEntityIBL()

        // Step 5: Metal Screen-Space Ambient Occlusion (iOS 15+)
        // Darkens crevices, contacts, and shadow areas per-pixel every frame,
        // matching Android Filament's built-in SSAO quality.
        setupSSAO()

        enhancedLightingEnabled = true
        print("💡 Enhanced lighting setup complete")
    }
    
    /// Load the custom HDR environment (`pdp-model-viewer.hdr`) as an IBL environment resource.
    /// This provides the same rich image-based lighting that Android gets from Filament,
    /// creating natural lighting gradients in crevices and contact points.
    ///
    /// Uses `EnvironmentResource.load(named:in:)` which is available from iOS 13+.
    /// The bundle is discovered at runtime via `findPluginBundle()` so it works in both
    /// CocoaPods and framework embedding scenarios.
    private func setupCustomIBLEnvironment() {
        print("💡 Loading custom HDR environment for IBL...")
        
        // Find the bundle that actually contains pdp-model-viewer.hdr
        guard let pluginBundle = findPluginBundle() else {
            print("⚠️ pdp-model-viewer.hdr not found in any bundle — using ARKit auto-lighting")
            return
        }
        print("💡 Loading HDR from bundle: \(pluginBundle.bundlePath)")
        
        do {
            let resource = try EnvironmentResource.load(named: "pdp-model-viewer", in: pluginBundle)
            
            arView.environment.lighting.resource = resource
            // intensityExponent uses a 2^n scale; 1.0 = 2^1 = balanced IBL illumination.
            // Crevice darkening is now handled by the Metal SSAO post-process (SSAO.metal).
            arView.environment.lighting.intensityExponent = 1.0
            
            print("✅ HDR IBL loaded (intensityExponent: 1.0 — SSAO handles crevice darkening)")
        } catch {
            print("⚠️ Sync HDR load failed: \(error.localizedDescription)")
            print("💡 Trying async load...")
            
            // Async fallback
            EnvironmentResource.loadAsync(named: "pdp-model-viewer", in: pluginBundle)
                .receive(on: DispatchQueue.main)
                .sink(
                    receiveCompletion: { completion in
                        if case .failure(let err) = completion {
                            print("⚠️ Async HDR load also failed: \(err.localizedDescription)")
                            print("💡 IBL unavailable — scene uses ARKit auto-lighting only")
                        }
                    },
                    receiveValue: { [weak self] environmentResource in
                        guard let self = self else { return }
                        self.arView.environment.lighting.resource = environmentResource
                        self.arView.environment.lighting.intensityExponent = 1.0
                        print("✅ HDR IBL loaded async (intensityExponent: 1.0 — SSAO handles crevice darkening)")
                    }
                )
                .store(in: &cancellableCollection)
        }
    }
    
    /// Set up per-entity ImageBasedLightComponent on iOS 18+ for richer IBL
    /// On iOS 18+, ImageBasedLightComponent allows applying custom HDR-based
    /// image-based lighting directly to entities for more pronounced IBL effects.
    private func setupPerEntityIBL() {
        if #available(iOS 18.0, *) {
            guard findPluginBundle() != nil else {
                print("⚠️ iOS 18+ per-entity IBL: HDR bundle not found")
                return
            }
            
            do {
                let resource = try EnvironmentResource.load(named: "pdp-model-viewer", in: findPluginBundle())
                
                // Create a dedicated entity for the IBL
                let iblEntity = Entity()
                iblEntity.name = "__enhanced_ibl__"
                
                // Apply ImageBasedLightComponent with the HDR resource
                let iblComponent = ImageBasedLightComponent(source: .single(resource), intensityExponent: 1.0)
                iblEntity.components.set(iblComponent)
                
                // Create an anchor for the IBL entity (or reuse existing light anchor)
                let lightAnchor: AnchorEntity
                if let existing = lightAnchorEntity {
                    lightAnchor = existing
                } else {
                    lightAnchor = AnchorEntity(world: .zero)
                    lightAnchor.name = "__enhanced_light_anchor__"
                    arView.scene.addAnchor(lightAnchor)
                    lightAnchorEntity = lightAnchor
                }
                lightAnchor.addChild(iblEntity)
                
                print("✅ iOS 18+: Per-entity ImageBasedLightComponent set up")
            } catch {
                print("⚠️ Failed to load HDR for per-entity IBL (URL): \(error.localizedDescription)")
            }
        }
    }
    
    /// Add a directional light with shadow casting for contact shadow effect,
    /// plus a soft overhead spot light for SSAO-like contact darkening.
    ///
    /// Android's Filament automatically derives a main directional light from ARCore's
    /// ENVIRONMENTAL_HDR and uses it for shadow mapping AND screen-space ambient occlusion.
    /// RealityKit doesn't expose SSAO directly, so we approximate it with:
    ///   1. A directional light with aggressive, soft shadows (contact shadow effect)
    ///   2. A wide-cone spot light pointing straight down (darkens crevices and undersides)
    ///   3. Grounding shadows (already enabled via renderOptions)
    ///
    /// Uses `DirectionalLight` class (available iOS 13.0+) which conforms to `HasDirectionalLight`
    /// and supports `.shadow` property for shadow casting.
    private func setupDirectionalLight() {
        print("💡 Adding directional light with shadows + SSAO-like spot light...")
        
        // Create a dedicated anchor entity for lighting
        let lightAnchor: AnchorEntity
        if let existing = lightAnchorEntity {
            lightAnchor = existing
        } else {
            lightAnchor = AnchorEntity(world: .zero)
            lightAnchor.name = "__enhanced_light_anchor__"
            arView.scene.addAnchor(lightAnchor)
            lightAnchorEntity = lightAnchor
        }
        
        // --- Primary Directional Light (shadow-casting, simulates sun/main light) ---
        // Kept at a moderate intensity so it works WITH IBL, not against it.
        // When IBL is loaded, it provides soft omnidirectional lighting that naturally
        // darkens crevices (irradiance falloff). The directional light adds cast shadows
        // for contact shadows and shape definition.
        let directionalLightEntity = DirectionalLight()
        directionalLightEntity.name = "__directional_light__"
        directionalLightEntity.position = SIMD3<Float>(0, 5, 0)
        directionalLightEntity.look(at: SIMD3<Float>(0, 0, 0), from: SIMD3<Float>(0, 5, 2), relativeTo: nil)
        directionalLightEntity.light.color = .white
        directionalLightEntity.light.intensity = 500  // Balanced key light; SSAO darkens contacts
        directionalLightEntity.light.isRealWorldProxy = false
        directionalLightEntity.shadow = DirectionalLightComponent.Shadow(
            maximumDistance: 10,
            depthBias: 0.5
        )
        lightAnchor.addChild(directionalLightEntity)

        // Soft fill light: prevents pure black shadows on the non-lit side of models.
        // IBL provides the main indirect contribution; this is just a gentle lift.
        let fillLightEntity = PointLight()
        fillLightEntity.name = "__fill_light__"
        fillLightEntity.position = SIMD3<Float>(0, 3, 0)
        fillLightEntity.light.color = .white
        fillLightEntity.light.intensity = 100  // gentle — 100 lm
        fillLightEntity.light.attenuationRadius = 15
        lightAnchor.addChild(fillLightEntity)

        print("✅ Enhanced lighting added:")
        print("   ✓ Directional light (500 lux) with shadow casting")
        print("   ✓ Fill light (100 lm point light) to lift dark sides")
        print("   ✓ IBL intensityExponent 1.0 — balanced ambient")
        print("   ✓ SSAO post-process handles crevice darkening (iOS 15+)")
    }
    
    /// Apply ImageBasedLightReceiverComponent to an entity so it receives custom per-entity IBL lighting.
    /// Only available on iOS 18+. Call this after adding a new entity to the scene.
    /// On iOS <18, entities still benefit from the scene-level `arView.environment.lighting.resource`.
    func applyIBLReceiverIfNeeded(_ entity: Entity) {
        if #available(iOS 18.0, *) {
            // Apply GroundingShadowComponent (iOS 18.0+ only)
            applyGroundingShadowIfAvailable(entity)
            
            // Apply ImageBasedLightReceiverComponent if we have a custom IBL entity
            guard let iblAnchor = lightAnchorEntity,
                  let iblEntity = iblAnchor.children.first(where: { $0.name == "__enhanced_ibl__" }) else {
                print("💡 iOS 18+: Applied grounding shadow to entity")
                return
            }
            
            entity.visit { child in
                if child.components[ModelComponent.self] != nil {
                    child.components.set(ImageBasedLightReceiverComponent(imageBasedLight: iblEntity))
                }
            }
            
            print("💡 iOS 18+: Applied IBL receiver + grounding shadow to entity")
        }
    }
    
    /// Apply GroundingShadowComponent to all model entities in the hierarchy.
    /// GroundingShadowComponent requires iOS 18.0+.
    @available(iOS 18.0, *)
    private func applyGroundingShadowIfAvailable(_ entity: Entity) {
        entity.visit { child in
            if child.components[ModelComponent.self] != nil {
                child.components.set(GroundingShadowComponent(castsShadow: true))
            }
        }
    }
    
    /// Clean up enhanced lighting entities on dispose
    func cleanupEnhancedLighting() {
        // Tear down Metal SSAO callbacks and GPU resources first
        cleanupSSAO()

        if let anchor = lightAnchorEntity {
            arView.scene.removeAnchor(anchor)
            lightAnchorEntity = nil
        }
        enhancedLightingEnabled = false
        print("🧹 Enhanced lighting cleaned up")
    }
    
    /// Locate the `pdp-model-viewer.hdr` file and return its URL.
    /// Use this URL with `EnvironmentResource.load(contentsOf:)` — the only API that
    /// can load raw Radiance `.hdr` files. `load(named:in:)` only handles compiled .skybox.
    private func findHDRFileURL() -> URL? {
        // Try the main bundle first
        if let url = Bundle.main.url(forResource: "pdp-model-viewer", withExtension: "hdr") {
            return url
        }
        
        // Try CocoaPods-created resource bundles
        let bundleNames = [
            "ar_flutter_plugin_2",
            "ar_flutter_plugin_2_ar_flutter_plugin_2",
            "ArFlutterPlugin"
        ]
        for bundleName in bundleNames {
            if let bundlePath = Bundle.main.path(forResource: bundleName, ofType: "bundle"),
               let bundle = Bundle(path: bundlePath),
               let url = bundle.url(forResource: "pdp-model-viewer", withExtension: "hdr") {
                print("💡 Found HDR in bundle: \(bundleName)")
                return url
            }
        }
        
        // Search all loaded bundles
        for bundle in Bundle.allBundles {
            if let url = bundle.url(forResource: "pdp-model-viewer", withExtension: "hdr") {
                return url
            }
        }
        
        // Try via plugin class bundle
        let pluginClass: AnyClass? = NSClassFromString("ArFlutterPlugin") ??
                                    NSClassFromString("ar_flutter_plugin_2.ArFlutterPlugin")
        if let cls = pluginClass,
           let url = Bundle(for: cls).url(forResource: "pdp-model-viewer", withExtension: "hdr") {
            return url
        }
        
        return nil
    }
    
    /// Find the plugin's resource bundle (handles CocoaPods bundle structure).
    /// Returns the bundle containing 'pdp-model-viewer.hdr', or nil if not found.
    private func findPluginBundle() -> Bundle? {
        // Try the main bundle first (for development/debug builds)
        if Bundle.main.url(forResource: "pdp-model-viewer", withExtension: "hdr") != nil {
            return Bundle.main
        }
        
        // Try the plugin's resource bundle (CocoaPods bundles resources separately)
        // CocoaPods creates a bundle named after the pod: ar_flutter_plugin_2.bundle
        let bundleNames = [
            "ar_flutter_plugin_2",
            "ar_flutter_plugin_2_ar_flutter_plugin_2",
            "ArFlutterPlugin"
        ]
        
        for bundleName in bundleNames {
            if let bundlePath = Bundle.main.path(forResource: bundleName, ofType: "bundle"),
               let bundle = Bundle(path: bundlePath),
               bundle.url(forResource: "pdp-model-viewer", withExtension: "hdr") != nil {
                print("💡 Found HDR asset in bundle: \(bundleName)")
                return bundle
            }
        }
        
        // Try finding in all registered bundles
        for bundle in Bundle.allBundles {
            if bundle.url(forResource: "pdp-model-viewer", withExtension: "hdr") != nil {
                print("💡 Found HDR asset in bundle: \(bundle.bundlePath)")
                return bundle
            }
        }
        
        // Try finding via framework bundle (plugin class lookup)
        let pluginClass: AnyClass? = NSClassFromString("ArFlutterPlugin") ?? NSClassFromString("ar_flutter_plugin_2.ArFlutterPlugin")
        if let cls = pluginClass {
            let bundle = Bundle(for: cls)
            if bundle.url(forResource: "pdp-model-viewer", withExtension: "hdr") != nil {
                print("💡 Found HDR asset via plugin class bundle")
                return bundle
            }
        }
        
        print("⚠️ Could not find pdp-model-viewer.hdr in any bundle")
        return nil
    }
}
