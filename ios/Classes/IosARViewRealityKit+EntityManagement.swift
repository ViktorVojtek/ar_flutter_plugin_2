import Foundation
import ARKit
import RealityKit
import Combine
import ModelIO
import SceneKit
import GLTFSceneKit

// MARK: - Entity/Node Management Extension

@available(iOS 13.0, *)
extension IosARViewRealityKit {
    
    // MARK: - Material Configuration
    
    /// Configure entity materials for proper transparency, PBR rendering, and enhanced lighting.
    /// This addresses the GLB→USDZ conversion issues where transparency and PBR properties may be lost
    /// and ensures materials are properly configured for RealityKit's rendering pipeline.
    ///
    /// On Android, Filament preserves all glTF PBR properties natively (metallic, roughness, normal, AO).
    /// On iOS, the GLB→SceneKit→USDZ→RealityKit pipeline can degrade these properties.
    /// This method compensates by verifying and adjusting material properties post-load.
    func configureEntityMaterials(_ entity: Entity) {
        // Visit all entities recursively to configure their materials
        entity.visit { childEntity in
            guard var modelComponent = childEntity.components[ModelComponent.self] else {
                return
            }
            
            var materialsModified = false
            var newMaterials: [Material] = []
            
            for material in modelComponent.materials {
                // For iOS 15+, we can directly modify PhysicallyBasedMaterial
                if #available(iOS 15.0, *) {
                    if var pbrMaterial = material as? PhysicallyBasedMaterial {
                        // Extract alpha from the tint color
                        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1.0
                        pbrMaterial.baseColor.tint.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                        
                        // Check multiple indicators of transparency:
                        // 1. Alpha in base color tint
                        // 2. Opacity threshold set
                        // 3. Any texture (which might have alpha channel)
                        let hasTransparency = alpha < 0.99 || 
                                            pbrMaterial.opacityThreshold != nil ||
                                            pbrMaterial.baseColor.texture != nil
                        
                        if hasTransparency {
                            // Enable transparent blending
                            // Use the alpha from tint, defaulting to 1.0 if texture-based transparency
                            let opacityValue = alpha < 0.99 ? Float(alpha) : 1.0
                            pbrMaterial.blending = .transparent(opacity: .init(floatLiteral: opacityValue))
                            
                            // For textures with alpha, we need to ensure the texture's alpha is used
                            // This is done by setting faceCulling to none for double-sided rendering
                            pbrMaterial.faceCulling = .none
                            
                            print("🔧 Material configured for transparency: tintAlpha=\(alpha), hasTexture=\(pbrMaterial.baseColor.texture != nil)")
                        }
                        
                        // =====================================================
                        // PBR QUALITY CHECKS (match Android Filament quality)
                        // =====================================================
                        
                        // ---- Roughness ----
                        // If roughness defaulted to 1.0 with no texture it was likely lost in
                        // GLB→USDZ conversion (SCNScene.write() does not always preserve it).
                        // 0.7 gives a natural semi-matte look without eliminating specular entirely.
                        if pbrMaterial.roughness.texture == nil {
                            let currentRoughness = pbrMaterial.roughness.scale
                            if currentRoughness >= 0.99 {
                                pbrMaterial.roughness = .init(scale: 0.7)
                                print("🔧 Roughness corrected: 1.0 → 0.7 (likely lost in GLB→USDZ conversion)")
                            }
                        }

                        // ---- Metallic ----
                        // Metal value is frequently dropped to 0 after USDZ export.
                        // We can't recover the original value but a mid-range (0.0) dielectric
                        // default is physically correct for most non-metal products.
                        // Only log when it's suspiciously zero alongside a roughness that also
                        // reset — that pattern indicates a full PBR property loss.
                        if pbrMaterial.metallic.texture == nil {
                            let currentMetallic = pbrMaterial.metallic.scale
                            // Leave metallic as-is; just ensure it's not negative (NaN from conversion)
                            if currentMetallic.isNaN || currentMetallic < 0 {
                                pbrMaterial.metallic = .init(scale: 0.0)
                                print("🔧 Metallic NaN/negative fixed → 0.0")
                            }
                        }

                        // ---- Specular ----
                        // Nudge only if entirely missing; over-boosting causes a rubber look.
                        if pbrMaterial.specular.texture == nil {
                            let currentSpecular = pbrMaterial.specular.scale
                            if currentSpecular < 0.01 {
                                pbrMaterial.specular = .init(scale: 0.2)
                            }
                        }

                        // ---- Clearcoat (iOS 15+) ----
                        // Add a subtle clearcoat layer for non-metallic, non-transparent materials.
                        // This gives plastics and painted surfaces a realistic thin-film specular
                        // highlight that matches Android Filament's second specular lobe.
                        // Only apply when metallic is low (dielectric) and the surface has a
                        // texture (actual product geometry, not a flat colour placeholder).
                        let isOpaque = alpha >= 0.99 && pbrMaterial.opacityThreshold == nil
                        let isDielectric = pbrMaterial.metallic.scale < 0.3
                        let hasBaseTexture = pbrMaterial.baseColor.texture != nil
                        if isOpaque && isDielectric && hasBaseTexture {
                            pbrMaterial.clearcoat = .init(scale: 0.15)
                            pbrMaterial.clearcoatRoughness = .init(scale: 0.25)
                        }

                        newMaterials.append(pbrMaterial)
                        materialsModified = true
                    } else {
                        // Keep non-PBR materials as-is
                        newMaterials.append(material)
                    }
                } else {
                    // iOS 13-14: Limited material modification support
                    // Materials are still rendered but we can't modify them as easily
                    newMaterials.append(material)
                }
            }
            
            if materialsModified {
                modelComponent.materials = newMaterials
                childEntity.components[ModelComponent.self] = modelComponent
            }
        }
    }
    
    /// Configure SceneKit scene materials before USDZ export
    /// This helps preserve transparency AND PBR properties during the GLB→SceneKit→USDZ conversion.
    /// 
    /// On Android, Filament loads GLB models natively and preserves all PBR properties perfectly.
    /// On iOS, we go through GLB→SceneKit→USDZ→RealityKit which can lose PBR data.
    /// This method ensures metalness, roughness, normal maps, and AO maps survive the conversion.
    func configureSceneKitMaterialsForExport(_ scene: SCNScene) {
        scene.rootNode.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            
            for material in geometry.materials {
                // CRITICAL: Enable double-sided rendering for semi-transparent materials
                material.isDoubleSided = true
                
                // Ensure depth buffer handling for proper transparency sorting
                material.writesToDepthBuffer = true
                material.readsFromDepthBuffer = true
                
                // Use alpha blending mode
                material.blendMode = .alpha
                
                // Ensure PBR lighting model for best quality
                material.lightingModel = .physicallyBased
                
                // CRITICAL: Configure transparency mode for textures with alpha
                // dualLayer provides better results for semi-transparent textures
                material.transparencyMode = .dualLayer
                
                // If diffuse has a texture, assume it might have alpha channel
                if material.diffuse.contents is UIImage || 
                   material.diffuse.contents is String ||
                   material.diffuse.contents != nil {
                    // Enable transparency if any texture is present
                    // The texture might have an alpha channel
                    if material.transparency >= 0.99 {
                        // Keep full opacity but enable alpha from texture
                        material.transparencyMode = .dualLayer
                    }
                }
                
                // Also check for explicit transparency
                if material.transparency < 0.99 {
                    material.transparencyMode = .dualLayer
                }
                
                // =====================================================================
                // PBR PROPERTY PRESERVATION (critical for matching Android Filament quality)
                // =====================================================================
                
                // Preserve metalness — if GLTFSceneKit parsed it, ensure it survives export.
                // If metalness is nil/zero but the model should be metallic, this ensures
                // the USDZ export carries the property through.
                if material.metalness.contents == nil {
                    // Default to non-metallic (dielectric) — matches glTF default
                    material.metalness.contents = NSNumber(value: 0.0)
                }
                
                // Preserve roughness — critical for specular highlight quality.
                // Android Filament renders roughness accurately from the glTF model.
                // If roughness is nil, SceneKit defaults to 1.0 (fully rough) which loses
                // all specular highlights and makes the model look flat/matte.
                if material.roughness.contents == nil {
                    // Default to higher roughness for a natural matte look
                    // Lower values cause a shiny/rubber appearance
                    material.roughness.contents = NSNumber(value: 0.75)
                }
                
                // Ambient occlusion map preservation
                // Baked AO texture is the primary source of crevice darkening on iOS.
                // RealityKit has no screen-space AO — the baked map IS the AO.
                // Boost intensity significantly so it shows up prominently.
                if material.ambientOcclusion.contents != nil {
                    // AO map exists — push intensity high so crevices stay very dark
                    material.ambientOcclusion.intensity = 3.0
                    print("📦 PBR: Boosted ambient occlusion map (intensity: 3.0)")
                }
                // DO NOT darken ambient for materials without AO maps.
                // The blanket ambient.intensity = 0.3 was making iOS render darker than Android.
                // Let the scene lighting (IBL + directional light) handle shading naturally.
                
                // Normal map preservation — critical for visible surface bumps
                // Keep at 1.0 (native glTF value). A boost to 1.5 made the surface
                // noisy/plastic under the previous over-bright lighting; with corrected
                // IBL and reduced directional light, 1.0 gives natural bump depth.
                if material.normal.contents != nil {
                    if material.normal.intensity < 0.01 {
                        material.normal.intensity = 1.0
                    } else {
                        // Preserve author-defined intensity; clamp to minimum 1.0
                        material.normal.intensity = max(material.normal.intensity, 1.0)
                    }
                    print("📦 PBR: Normal map preserved (intensity: \(material.normal.intensity))")
                }
                
                // Emissive map/color preservation
                if material.emission.contents != nil {
                    if material.emission.intensity < 0.01 {
                        material.emission.intensity = 1.0
                    }
                }
                
                // Log PBR property state for debugging
                let hasMetalness = material.metalness.contents != nil
                let hasRoughness = material.roughness.contents != nil
                let hasNormal = material.normal.contents != nil
                let hasAO = material.ambientOcclusion.contents != nil
                if hasMetalness || hasNormal || hasAO {
                    print("📦 PBR properties: metal=\(hasMetalness) rough=\(hasRoughness) normal=\(hasNormal) ao=\(hasAO)")
                }
            }
        }
    }
    
    // MARK: - Entity Loading
    
    /// Add a new entity (node) to the AR scene
    /// Supports GLTF, GLB, USDZ, and other Model I/O formats
    func addNode(dict_node: Dictionary<String, Any>, result: @escaping FlutterResult) {
        guard let nodeId = dict_node["name"] as? String else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "Node name required", details: nil))
            return
        }
        
        guard let uri = dict_node["uri"] as? String else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "URI required", details: nil))
            return
        }
        
        print("📦 Adding entity: \(nodeId) from URI: \(uri)")
        
        // Parse transform
        let transformMatrix = dict_node["transformation"] as? [NSNumber]
        let scale = dict_node["scale"] as? Double
        
        // Load model asynchronously
        loadingQueue.async { [weak self] in
            print("🔵 [ASYNC BLOCK] Entered loadingQueue.async block")
            guard let self = self else { 
                print("❌ [ASYNC BLOCK] self is nil, returning")
                return 
            }
            print("🔵 [ASYNC BLOCK] self is valid, about to call loadEntity")
            
            do {
                print("🔵 [ASYNC BLOCK] Inside do block, calling loadEntity now...")
                // Load or get from cache
                let entity = try self.loadEntity(from: uri, nodeId: nodeId)
                print("🔵 [ASYNC BLOCK] loadEntity returned successfully")
                
                // Apply transform on main thread
                DispatchQueue.main.async {
                    self.configureEntity(entity, nodeId: nodeId, transformMatrix: transformMatrix, scale: scale)
                    
                    // Create anchor entity to hold the model
                    let anchorEntity = AnchorEntity()
                    anchorEntity.name = nodeId
                    anchorEntity.addChild(entity)
                    
                    // Add to scene
                    self.arView.scene.addAnchor(anchorEntity)
                    
                    // Add per-model accent lighting for studio-quality rendering
                    self.addAccentLightsToAnchor(anchorEntity)
                    
                    // Apply IBL receiver so the entity receives custom HDR lighting
                    self.applyIBLReceiverIfNeeded(entity)
                    
                    // Store references
                    self.entityCollection[nodeId] = entity
                    self.anchorEntityCollection[nodeId] = anchorEntity
                    
                    print("✅ Entity added successfully: \(nodeId)")
                    result(nodeId)
                }
            } catch {
                DispatchQueue.main.async {
                    print("❌ Failed to load entity: \(error.localizedDescription)")
                    result(FlutterError(
                        code: "LOAD_FAILED",
                        message: "Failed to load model: \(error.localizedDescription)",
                        details: nil
                    ))
                }
            }
        }
    }
    
    /// Load entity asynchronously using callbacks (NO SEMAPHORES!)
    private func loadEntityAsync(from uri: String, nodeId: String, completion: @escaping (Result<Entity, Error>) -> Void) {
        print("🔵 loadEntityAsync called for URI: \(uri)")
        
        // Check cache first
        if let cachedEntity = assetCache[uri] {
            print("♻️ Using cached entity for: \(uri)")
            completion(.success(cachedEntity.clone(recursive: true)))
            return
        }
        
        print("🔵 Not in cache, loading fresh from: \(uri)")
        
        // Determine URL
        let url: URL
        if uri.starts(with: "http://") || uri.starts(with: "https://") {
            url = URL(string: uri)!
        } else if uri.starts(with: "file://") {
            url = URL(string: uri)!
        } else {
            if let assetURL = Bundle.main.url(forResource: uri, withExtension: nil) {
                url = assetURL
            } else {
                completion(.failure(NSError(domain: "IosARView", code: 404, userInfo: [NSLocalizedDescriptionKey: "Asset not found: \(uri)"])))
                return
            }
        }
        
        let fileExtension = url.pathExtension.lowercased()
        print("🔵 File extension: \(fileExtension)")
        
        if fileExtension == "usdz" || fileExtension == "usd" || fileExtension == "usda" || fileExtension == "usdc" || fileExtension == "reality" {
            print("🔵 Loading USDZ directly with RealityKit")
            self.loadUsdzEntityAsync(from: url) { result in
                if case .success(let entity) = result {
                    self.assetCache[uri] = entity
                    completion(.success(entity.clone(recursive: true)))
                } else {
                    completion(result)
                }
            }
        } else if fileExtension == "glb" || fileExtension == "gltf" {
            print("🔵 Converting GLB/GLTF to USDZ then loading")
            self.loadGltfEntityAsync(from: url) { result in
                if case .success(let entity) = result {
                    self.assetCache[uri] = entity
                    completion(.success(entity.clone(recursive: true)))
                } else {
                    completion(result)
                }
            }
        } else {
            completion(.failure(NSError(domain: "IosARView", code: 400, userInfo: [NSLocalizedDescriptionKey: "Unsupported file format: \(fileExtension)"])))
        }
    }
    
    /// Load entity from URI (GLTF, GLB, USDZ, etc.) - DEPRECATED, use loadEntityAsync
    private func loadEntity(from uri: String, nodeId: String) throws -> Entity {
        print("🔵 loadEntity called for URI: \(uri)")
        print("🔵 loadEntity - Thread: \(Thread.current)")
        print("🔵 loadEntity - Is main thread: \(Thread.isMainThread)")
        
        // Check cache first
        if let cachedEntity = assetCache[uri] {
            print("♻️ Using cached entity for: \(uri)")
            return cachedEntity.clone(recursive: true)
        }
        
        print("🔵 Not in cache, loading fresh")
        print("🔵 About to determine URL type...")
        let url: URL
        
        // Determine URL type
        if uri.starts(with: "http://") || uri.starts(with: "https://") {
            // Remote URL
            url = URL(string: uri)!
        } else if uri.starts(with: "file://") {
            // File URL
            url = URL(string: uri)!
        } else {
            // Asset path
            if let assetURL = Bundle.main.url(forResource: uri, withExtension: nil) {
                url = assetURL
            } else {
                throw NSError(domain: "IosARView", code: 404, userInfo: [NSLocalizedDescriptionKey: "Asset not found: \(uri)"])
            }
        }
        
        // Check file extension
        let fileExtension = url.pathExtension.lowercased()
        
        let entity: Entity
        
        print("🔵 File extension detected: \(fileExtension)")
        
        if fileExtension == "usdz" || fileExtension == "usd" || fileExtension == "usda" || fileExtension == "usdc" || fileExtension == "reality" {
            // Load USDZ/USD directly (RealityKit native format)
            print("🔵 Detected USDZ format, calling loadUsdzEntity")
            entity = try loadUsdzEntity(from: url)
        } else if fileExtension == "glb" || fileExtension == "gltf" {
            // Convert GLTF/GLB to USD then load
            print("🔵 Detected GLB/GLTF format, calling loadGltfEntity")
            entity = try loadGltfEntity(from: url)
        } else {
            print("🔵 Unknown format, calling loadGenericEntity")
            // Try loading as generic model via Model I/O
            entity = try loadGenericEntity(from: url)
        }
        
        // Enable interactions
        entity.generateCollisionShapes(recursive: true)
        
        // Cache the entity
        assetCache[uri] = entity
        
        return entity.clone(recursive: true)
    }
    
    /// Load USDZ entity asynchronously (NO SEMAPHORE!)
    private func loadUsdzEntityAsync(from url: URL, completion: @escaping (Result<Entity, Error>) -> Void) {
        print("🔵 [USDZ] Loading asynchronously from: \(url.lastPathComponent)")
        
        // Store cancellable in collection to keep subscription alive
        Entity.loadAsync(contentsOf: url)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] result in
                    if case .failure(let error) = result {
                        print("❌ [USDZ] Load failed: \(error.localizedDescription)")
                        completion(.failure(error))
                    }
                },
                receiveValue: { [weak self] entity in
                    print("✅ [USDZ] Load successful")
                    entity.generateCollisionShapes(recursive: true)
                    // Configure materials for proper transparency and PBR rendering
                    self?.configureEntityMaterials(entity)
                    completion(.success(entity))
                }
            )
            .store(in: &cancellableCollection)
    }
    
    /// Load USDZ entity (RealityKit native) - DEPRECATED
    private func loadUsdzEntity(from url: URL) throws -> Entity {
        var cancellable: AnyCancellable?
        var loadedEntity: Entity?
        var loadError: Error?
        
        let semaphore = DispatchSemaphore(value: 0)
        
        cancellable = Entity.loadAsync(contentsOf: url)
            .sink(receiveCompletion: { completion in
                if case .failure(let error) = completion {
                    loadError = error
                }
                semaphore.signal()
            }, receiveValue: { entity in
                loadedEntity = entity
            })
        
        semaphore.wait()
        cancellable?.cancel()
        
        if let error = loadError {
            throw error
        }
        
        guard let entity = loadedEntity else {
            throw NSError(domain: "IosARView", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to load USDZ"])
        }
        
        return entity
    }
    
    /// Load GLB/GLTF asynchronously by converting to USDZ (NO SEMAPHORE!)
    private func loadGltfEntityAsync(from url: URL, completion: @escaping (Result<Entity, Error>) -> Void) {
        print("🔵 [GLB] Starting async conversion for: \(url.lastPathComponent)")
        
        // Download if remote using URLSession for non-blocking download
        if url.scheme == "http" || url.scheme == "https" {
            print("🔵 [GLB] Downloading from remote URL using URLSession...")
            
            let downloadTask = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
                guard let self = self else {
                    completion(.failure(NSError(domain: "IosARView", code: 500, userInfo: [NSLocalizedDescriptionKey: "View deallocated"])))
                    return
                }
                
                if let error = error {
                    print("❌ [GLB] Download failed: \(error.localizedDescription)")
                    completion(.failure(error))
                    return
                }
                
                guard let data = data else {
                    completion(.failure(NSError(domain: "IosARView", code: 500, userInfo: [NSLocalizedDescriptionKey: "No data received"])))
                    return
                }
                
                print("✅ [GLB] Downloaded \(data.count) bytes")
                
                // Process on background queue
                DispatchQueue.global(qos: .userInitiated).async {
                    self.processGltfData(data: data, originalURL: url, completion: completion)
                }
            }
            downloadTask.resume()
        } else {
            // Local file - process directly on background queue
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
                    completion(.failure(NSError(domain: "IosARView", code: 500, userInfo: [NSLocalizedDescriptionKey: "View deallocated"])))
                    return
                }
                
                do {
                    let data = try Data(contentsOf: url)
                    self.processGltfData(data: data, originalURL: url, completion: completion)
                } catch {
                    print("❌ [GLB] Failed to read local file: \(error.localizedDescription)")
                    completion(.failure(error))
                }
            }
        }
    }
    
    /// Process GLTF/GLB data - called from background queue
    private func processGltfData(data: Data, originalURL: URL, completion: @escaping (Result<Entity, Error>) -> Void) {
        do {
            // Save to temp file
            let tempDir = FileManager.default.temporaryDirectory
            let destURL = tempDir.appendingPathComponent(originalURL.lastPathComponent)
            try? FileManager.default.removeItem(at: destURL)
            try data.write(to: destURL)
            
            print("🔵 [GLB] Creating GLTFSceneSource...")
            let sceneSource = try GLTFSceneSource(url: destURL, options: nil)
            
            print("🔵 [GLB] Loading SceneKit scene...")
            let scnScene = try sceneSource.scene()
            
            // IMPORTANT: Configure materials BEFORE USDZ export to preserve transparency
            print("🔵 [GLB] Configuring materials for transparency preservation...")
            configureSceneKitMaterialsForExport(scnScene)
            
            print("🔵 [GLB] Exporting to USDZ...")
            let usdzURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).usdz")
            try scnScene.write(to: usdzURL, options: nil, delegate: nil, progressHandler: nil)
            
            print("🔵 [GLB] Loading USDZ into RealityKit (dispatching to main thread)...")
            
            // Dispatch to main thread for RealityKit loading (cancellableCollection access must be on main thread)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else {
                    completion(.failure(NSError(domain: "IosARView", code: 500, userInfo: [NSLocalizedDescriptionKey: "View deallocated"])))
                    return
                }
                
                self.loadUsdzEntityAsync(from: usdzURL) { result in
                    // Cleanup (on background queue)
                    DispatchQueue.global(qos: .background).async {
                        try? FileManager.default.removeItem(at: usdzURL)
                        try? FileManager.default.removeItem(at: destURL)
                    }
                    
                    switch result {
                    case .success(let entity):
                        print("✅ [GLB] Conversion complete!")
                        completion(.success(entity))
                    case .failure(let error):
                        print("❌ [GLB] USDZ load failed: \(error.localizedDescription)")
                        completion(.failure(error))
                    }
                }
            }
            
        } catch {
            print("❌ [GLB] Conversion failed: \(error.localizedDescription)")
            completion(.failure(error))
        }
    }
    
    /// Load GLTF/GLB by converting to USD - DEPRECATED
    private func loadGltfEntity(from url: URL) throws -> Entity {
        print("========== ENTERED loadGltfEntity ==========")
        print("🔵 loadGltfEntity called")
        print("� Converting GLTF/GLB to USD: \(url.lastPathComponent)")
        print("🔵 URL: \(url.absoluteString)")
        
        let localURL: URL
        
        // Download remote files first (synchronous - we're already on background queue)
        if url.scheme == "http" || url.scheme == "https" {
            print("🔵 Detected remote URL, downloading synchronously on background queue")
            print("📥 Downloading remote GLTF/GLB: \(url.absoluteString)")
            print("⏱️ About to call Data(contentsOf:) - this may take a while...")
            
            // Use synchronous download since we're already on background queue (loadingQueue)
            let downloadedData: Data
            do {
                let startTime = Date()
                downloadedData = try Data(contentsOf: url)
                let elapsed = Date().timeIntervalSince(startTime)
                print("✅ Download complete: \(downloadedData.count) bytes in \(elapsed) seconds")
                print("✅ Download complete: \(downloadedData.count) bytes")
            } catch {
                throw NSError(domain: "IosARView", code: 500, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to download GLTF/GLB: \(error.localizedDescription)"
                ])
            }
            
            // Save to temp file
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = url.lastPathComponent
            let destURL = tempDir.appendingPathComponent(fileName)
            
            // Remove existing file if present
            try? FileManager.default.removeItem(at: destURL)
            
            do {
                try downloadedData.write(to: destURL)
                localURL = destURL
                print("✅ Saved to temp file: \(destURL.path)")
            } catch {
                throw NSError(domain: "IosARView", code: 500, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to save downloaded file: \(error.localizedDescription)"
                ])
            }
        } else {
            localURL = url
        }
        
        print("🔵 About to load GLB using GLTFSceneKit: \(localURL.lastPathComponent)")
        
        // Load GLTF/GLB using GLTFSceneKit
        let sceneSource: GLTFSceneSource
        do {
            print("🔵 [1/4] Creating GLTFSceneSource...")
            sceneSource = try GLTFSceneSource(url: localURL, options: nil)
            print("✅ [1/4] GLTFSceneSource created successfully")
        } catch {
            print("❌ GLTFSceneSource failed: \(error)")
            throw NSError(domain: "IosARView", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Failed to initialize GLTFSceneSource: \(error.localizedDescription)"
            ])
        }
        
        print("🔵 [2/4] Loading SceneKit scene from GLTF... (this may take a while)")
        
        // Load SceneKit scene from GLTF
        let scnScene: SCNScene
        do {
            scnScene = try sceneSource.scene()
            print("✅ [2/4] SceneKit scene loaded successfully")
        } catch {
            print("❌ SceneKit scene loading failed: \(error)")
            throw NSError(domain: "IosARView", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Failed to load GLB as SceneKit scene: \(error.localizedDescription)"
            ])
        }
        
        // IMPORTANT: Configure materials BEFORE USDZ export to preserve transparency
        print("🔵 [2.5/4] Configuring materials for transparency preservation...")
        configureSceneKitMaterialsForExport(scnScene)
        
        print("🔵 [3/4] Exporting SceneKit scene to USDZ...")
        
        // Create temporary USDZ file
        let tempDir = FileManager.default.temporaryDirectory
        let tempFileName = "\(UUID().uuidString).usdz"
        let tempURL = tempDir.appendingPathComponent(tempFileName)
        
        // Export SceneKit scene to USDZ
        do {
            try scnScene.write(to: tempURL, options: nil, delegate: nil, progressHandler: nil)
            print("✅ [3/4] Export to USDZ successful: \(tempURL.lastPathComponent)")
        } catch {
            print("❌ USDZ export failed: \(error)")
            throw NSError(domain: "IosARView", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Failed to export SceneKit scene to USDZ: \(error.localizedDescription)"
            ])
        }
        
        print("🔵 [4/4] Loading USDZ into RealityKit...")
        
        // Load the converted USDZ
        let entity = try loadUsdzEntity(from: tempURL)
        
        print("✅ [4/4] Entity loaded from USDZ successfully")
        
        // Clean up temporary files
        try? FileManager.default.removeItem(at: tempURL)
        if localURL != url {
            try? FileManager.default.removeItem(at: localURL)
        }
        
        print("✅ GLTF/GLB converted and loaded successfully")
        return entity
    }
    
    /// Load generic model format via Model I/O
    private func loadGenericEntity(from url: URL) throws -> Entity {
        print("🔄 Loading generic model via Model I/O: \(url.lastPathComponent)")
        
        let mdlAsset = MDLAsset(url: url)
        
        // Convert to USDZ via temp file
        let tempDir = FileManager.default.temporaryDirectory
        let tempFileName = "\(UUID().uuidString).usdz"
        let tempURL = tempDir.appendingPathComponent(tempFileName)
        
        try mdlAsset.export(to: tempURL)
        let entity = try loadUsdzEntity(from: tempURL)
        try? FileManager.default.removeItem(at: tempURL)
        
        return entity
    }
    
    /// Configure entity transform and scale
    private func configureEntity(_ entity: Entity, nodeId: String, transformMatrix: [NSNumber]?, scale: Double?) {
        // Apply scale
        if let scaleValue = scale {
            let scaleFloat = Float(scaleValue)
            entity.scale = SIMD3<Float>(scaleFloat, scaleFloat, scaleFloat)
        }
        
        // Apply transform matrix if provided
        if let matrix = transformMatrix, matrix.count == 16 {
            let transform = parseTransform(matrix: matrix)
            entity.transform = transform
        }
        
        // CRITICAL: Adjust Y position so object sits ON the floor, not half-buried
        adjustEntityToFloor(entity)
        
        // Set name
        entity.name = nodeId
    }
    
    /// Adjust entity Y position so its bottom sits on the anchor (floor)
    /// This prevents objects from being half-buried in the floor
    private func adjustEntityToFloor(_ entity: Entity) {
        // Calculate the bounding box in the entity's parent space (anchor space)
        // This gives us the actual position of the bottom relative to the anchor
        guard let parent = entity.parent else {
            print("⚠️ Cannot adjust floor - entity has no parent")
            return
        }
        
        let bounds = entity.visualBounds(relativeTo: parent)
        
        // Get the minimum Y value (bottom of the model in anchor space)
        let minY = bounds.min.y
        
        print("📏 Entity bounds in anchor space - min: \(bounds.min), max: \(bounds.max)")
        
        // If the bottom is below the anchor origin, lift the entity up
        if minY < 0 {
            let offset = -minY // How much to lift to bring bottom to Y=0
            entity.position.y += offset
            
            print("📏 Adjusted entity to floor - lifted by \(offset)m (bounds min.y was \(minY), new position.y: \(entity.position.y))")
        } else {
            print("📏 Entity already above floor - no adjustment needed (bounds min.y: \(minY))")
        }
    }
    
    /// Parse transform matrix from Flutter
    private func parseTransform(matrix: [NSNumber]) -> Transform {
        let m = matrix.map { Float($0.floatValue) }
        
        // Create simd_float4x4 from array
        let mat = simd_float4x4(
            SIMD4<Float>(m[0], m[1], m[2], m[3]),
            SIMD4<Float>(m[4], m[5], m[6], m[7]),
            SIMD4<Float>(m[8], m[9], m[10], m[11]),
            SIMD4<Float>(m[12], m[13], m[14], m[15])
        )
        
        return Transform(matrix: mat)
    }
    
    /// Add node to an existing anchor (for addNodeToPlaneAnchor)
    func addNodeWithAnchor(dict_node: Dictionary<String, Any>, dict_anchor: Dictionary<String, Any>, result: @escaping FlutterResult) {
        print("🔵 [ANCHOR] addNodeWithAnchor method entered")
        
        guard let nodeId = dict_node["name"] as? String else {
            print("❌ [ANCHOR] Node name missing")
            result(FlutterError(code: "INVALID_ARGUMENT", message: "Node name required", details: nil))
            return
        }
        
        guard let uri = dict_node["uri"] as? String else {
            print("❌ [ANCHOR] URI missing")
            result(FlutterError(code: "INVALID_ARGUMENT", message: "URI required", details: nil))
            return
        }
        
        print("✅ [ANCHOR] NodeId: \(nodeId)")
        print("✅ [ANCHOR] URI: \(uri)")
        
        guard let anchorName = dict_anchor["name"] as? String else {
            print("❌ [ANCHOR] Anchor name missing")
            result(FlutterError(code: "INVALID_ARGUMENT", message: "Anchor name required", details: nil))
            return
        }
        
        print("✅ [ANCHOR] Anchor name: \(anchorName)")
        
        // Get or create the anchor entity
        let anchorEntity: AnchorEntity
        if let existingAnchor = anchorEntityCollection[anchorName] {
            print("✅ [ANCHOR] Using existing anchor: \(anchorName)")
            anchorEntity = existingAnchor
        } else {
            print("⚠️ [ANCHOR] Creating new anchor: \(anchorName)")
            
            // Parse anchor transform
            guard let transformMatrix = dict_anchor["transformation"] as? [NSNumber], transformMatrix.count == 16 else {
                print("❌ [ANCHOR] Invalid transformation matrix")
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Valid transformation matrix required", details: nil))
                return
            }
            
            let transform = parseAnchorTransform(matrix: transformMatrix)
            
            // Debug: Log the anchor position
            let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            print("🔵 [ANCHOR] Anchor position: x=\(position.x), y=\(position.y), z=\(position.z)")
            
            // Create AR anchor
            let arAnchor = ARAnchor(name: anchorName, transform: transform)
            arView.session.add(anchor: arAnchor)
            anchorCollection[anchorName] = arAnchor
            
            // Create anchor entity
            anchorEntity = AnchorEntity()
            anchorEntity.name = anchorName
            anchorEntity.transform = Transform(matrix: transform)
            arView.scene.addAnchor(anchorEntity)
            anchorEntityCollection[anchorName] = anchorEntity
            
            print("✅ [ANCHOR] New anchor created: \(anchorName)")
        }
        
        // Parse node transform and scale
        let transformMatrix = dict_node["transformation"] as? [NSNumber]
        let scale = dict_node["scale"] as? Double
        
        print("🔵 [ANCHOR] Starting async model load")
        
        // Load model asynchronously using callback-based approach
        print("🔵 [ANCHOR] Calling loadEntityAsync for: \(nodeId)")
        print("🔵 [ANCHOR] URI: \(uri)")
        
        self.loadEntityAsync(from: uri, nodeId: nodeId) { [weak self] loadResult in
            guard let self = self else { return }
            
            switch loadResult {
            case .success(let entity):
                print("✅ [CALLBACK] Entity loaded successfully")
                
                DispatchQueue.main.async {
                    print("🔵 [MAIN] Configuring and adding entity to anchor")
                    self.configureEntity(entity, nodeId: nodeId, transformMatrix: transformMatrix, scale: scale)
                    
                    // Add entity to the anchor
                    anchorEntity.addChild(entity)
                    
                    // Add per-model accent lighting for studio-quality rendering
                    self.addAccentLightsToAnchor(anchorEntity)
                    
                    // Apply IBL receiver so the entity receives custom HDR lighting
                    self.applyIBLReceiverIfNeeded(entity)
                    
                    // Store reference
                    self.entityCollection[nodeId] = entity
                    
                    print("✅ Entity added to anchor successfully: \(nodeId) → \(anchorName)")
                    result(nodeId)
                }
                
            case .failure(let error):
                print("❌ [CALLBACK] Failed to load entity: \(error.localizedDescription)")
                
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "LOAD_FAILED",
                        message: "Failed to load model: \(error.localizedDescription)",
                        details: nil
                    ))
                }
            }
        }
    }
    
    /// Parse anchor transform from Flutter (helper for addNodeWithAnchor)
    private func parseAnchorTransform(matrix: [NSNumber]) -> simd_float4x4 {
        let m = matrix.map { Float($0.floatValue) }
        
        return simd_float4x4(
            SIMD4<Float>(m[0], m[1], m[2], m[3]),
            SIMD4<Float>(m[4], m[5], m[6], m[7]),
            SIMD4<Float>(m[8], m[9], m[10], m[11]),
            SIMD4<Float>(m[12], m[13], m[14], m[15])
        )
    }
    
    /// Remove entity from scene
    func removeNode(nodeName: String) {
        print("🗑️ Removing entity: \(nodeName)")
        print("🔍 Current entityCollection keys: \(Array(entityCollection.keys))")
        print("🔍 Current anchorEntityCollection keys: \(Array(anchorEntityCollection.keys))")
        
        // Clear selection if this entity was selected
        if let entity = entityCollection[nodeName], selectedEntity === entity {
            selectedEntity = nil
            print("🔄 Cleared selection for removed entity")
        }
        
        // Get the entity first
        guard let entity = entityCollection[nodeName] else {
            print("⚠️ Entity not found in collection: \(nodeName)")
            return
        }
        
        // Find and remove the anchor entity (may be keyed by nodeId OR anchorName)
        // First try nodeId (for addNode without anchor)
        if let anchorEntity = anchorEntityCollection[nodeName] {
            arView.scene.removeAnchor(anchorEntity)
            anchorEntityCollection.removeValue(forKey: nodeName)
            print("✅ Removed anchor by nodeId: \(nodeName)")
        } else {
            // For addNodeWithAnchor, find anchor by traversing up the hierarchy
            var currentEntity: Entity? = entity.parent
            while let parent = currentEntity {
                if let anchorEntity = parent as? AnchorEntity {
                    // Remove just this entity from the anchor
                    entity.removeFromParent()
                    
                    // If anchor has no more children, remove it too
                    if anchorEntity.children.isEmpty {
                        arView.scene.removeAnchor(anchorEntity)
                        // Find and remove from anchorEntityCollection
                        if let anchorKey = anchorEntityCollection.first(where: { $0.value === anchorEntity })?.key {
                            anchorEntityCollection.removeValue(forKey: anchorKey)
                            anchorCollection.removeValue(forKey: anchorKey)
                            print("✅ Removed empty anchor: \(anchorKey)")
                        }
                    }
                    print("✅ Removed entity from anchor hierarchy")
                    break
                }
                currentEntity = parent.parent
            }
        }
        
        // Remove from entity collection
        entityCollection.removeValue(forKey: nodeName)
        
        print("✅ Entity removed: \(nodeName)")
    }
    
    /// Deep removal with resource cleanup
    func removeNodeDeep(nodeId: String) -> Bool {
        print("🗑️ Deep removing entity: \(nodeId)")
        print("🔍 Current entityCollection keys: \(Array(entityCollection.keys))")
        print("🔍 Current anchorEntityCollection keys: \(Array(anchorEntityCollection.keys))")
        
        // Clear selection if this entity was selected
        if let entity = entityCollection[nodeId], selectedEntity === entity {
            selectedEntity = nil
            print("🔄 Cleared selection for deep removed entity")
        }
        
        // Check if entity exists
        guard let entity = entityCollection[nodeId] else {
            print("⚠️ Entity not found for deep removal: \(nodeId)")
            return false
        }
        
        // Remove from parent (handles both anchor and non-anchor cases)
        entity.removeFromParent()
        
        // Try to find and remove the anchor
        // First try nodeId (for addNode without anchor)
        if let anchorEntity = anchorEntityCollection[nodeId] {
            arView.scene.removeAnchor(anchorEntity)
            anchorEntityCollection.removeValue(forKey: nodeId)
            anchorCollection.removeValue(forKey: nodeId)
            print("✅ Removed anchor by nodeId: \(nodeId)")
        }
        // For addNodeWithAnchor case, we already removed from parent above
        // The anchor will remain if it has other children
        
        // Remove from collections
        entityCollection.removeValue(forKey: nodeId)
        
        print("✅ Entity deeply removed: \(nodeId)")
        return true
    }
    
    /// Update entity transform
    func updateEntityTransform(nodeName: String, transform: Transform) {
        guard let entity = entityCollection[nodeName] else {
            print("⚠️ Entity not found for transform update: \(nodeName)")
            return
        }
        
        entity.transform = transform
    }
}

// MARK: - Entity Helper Extension

@available(iOS 13.0, *)
extension Entity {
    /// Recursively visit all entities in the hierarchy
    /// - Parameter closure: Called for each entity (including self)
    func visit(_ closure: (Entity) -> Void) {
        closure(self)
        for child in children {
            child.visit(closure)
        }
    }
}
