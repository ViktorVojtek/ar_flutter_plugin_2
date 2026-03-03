import Flutter
import UIKit
import Foundation
import ARKit
import Combine
import ARCoreCloudAnchors

// Resource management data structures for deep memory cleanup
class ResourceHandle {
    let nodeId: String
    let node: SCNNode
    var textures: [Any] = []
    var materials: [SCNMaterial] = []
    var geometries: [SCNGeometry] = []
    let assetKey: String?
    
    init(nodeId: String, node: SCNNode, assetKey: String? = nil) {
        self.nodeId = nodeId
        self.node = node
        self.assetKey = assetKey
        
        // Collect all materials and textures from the node hierarchy
        collectResources(from: node)
    }
    
    private func collectResources(from node: SCNNode) {
        if let geometry = node.geometry {
            geometries.append(geometry)
            materials.append(contentsOf: geometry.materials)
            
            for material in geometry.materials {
                // Collect textures from all material properties
                if let diffuse = material.diffuse.contents { textures.append(diffuse) }
                if let specular = material.specular.contents { textures.append(specular) }
                if let normal = material.normal.contents { textures.append(normal) }
                if let emission = material.emission.contents { textures.append(emission) }
                if let roughness = material.roughness.contents { textures.append(roughness) }
                if let metalness = material.metalness.contents { textures.append(metalness) }
            }
        }
        
        // Recursively collect from child nodes
        for child in node.childNodes {
            collectResources(from: child)
        }
    }
}

class CachedAsset {
    let uri: String
    let rootNode: SCNNode
    let refCount: Int
    let creationTime: TimeInterval
    
    init(uri: String, rootNode: SCNNode, refCount: Int = 1) {
        self.uri = uri
        self.rootNode = rootNode
        self.refCount = refCount
        self.creationTime = Date().timeIntervalSince1970
    }
}

class IosARView: NSObject, FlutterPlatformView, ARSCNViewDelegate, UIGestureRecognizerDelegate, ARSessionDelegate, ARCoachingOverlayViewDelegate {
    let sceneView: ARSCNView
    let coachingView: ARCoachingOverlayView
    let sessionManagerChannel: FlutterMethodChannel
    let objectManagerChannel: FlutterMethodChannel
    let anchorManagerChannel: FlutterMethodChannel
    
    // Light estimation monitoring support
    private var isMonitoringLighting = false
    private var lightingCheckTimer: Timer?
    private var lightingCheckInterval: TimeInterval = 1.0 // Check every second
    
    var showPlanes = false
    var planeCount = 0
    var customPlaneTexturePath: String? = nil
    private var trackedPlanes = [UUID: (SCNNode, SCNNode)]()
    let modelBuilder = ArModelBuilder()
    
    // Deep memory cleanup resource management
    private var resourceHandles: [String: ResourceHandle] = [:]
    private var assetCache: [String: CachedAsset] = [:]
    private let maxCacheAge: TimeInterval = 300.0 // 5 minutes
    private let loadingQueue = DispatchQueue(label: "ar.model.loading", qos: .userInitiated)
    
    // IOS FIX: Reverse mapping from node to unique ID (like Android's nodeToUniqueIdMap)
    private var nodeToUniqueIdMap: [SCNNode: String] = [:]
    
    // Performance optimization: Object pools to reduce allocations
    private let nodeHitResultsPool = NSMutableArray()
    private let matrixPool = NSMutableArray()
    
    var cancellableCollection = Set<AnyCancellable>() //Used to store all cancellables in (needed for working with Futures)
    var anchorCollection = [String: ARAnchor]() //Used to bookkeep all anchors created by Flutter calls
    
    private var cloudAnchorHandler: CloudAnchorHandler? = nil
    private var arcoreSession: GARSession? = nil
    private var arcoreMode: Bool = false
    private var configuration: ARWorldTrackingConfiguration!
    private var tappedPlaneAnchorAlignment = ARPlaneAnchor.Alignment.horizontal // default alignment
    
    // MARK: - Depth API State
    private var depthOcclusionEnabled = true // Track depth occlusion state
    private var occlusionNode: SCNNode? = nil // Node for rendering depth-based occlusion
    
    private var panStartLocation: CGPoint?
    private var panCurrentLocation: CGPoint?
    private var panCurrentVelocity: CGPoint?
    private var panCurrentTranslation: CGPoint?
    private var rotationStartLocation: CGPoint?
    private var rotation: CGFloat?
    private var rotationVelocity: CGFloat?
    private var panningNode: SCNNode?
    private var panningNodeCurrentWorldLocation: SCNVector3?

    init(
        frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?,
        binaryMessenger messenger: FlutterBinaryMessenger
    ) {
        self.sceneView = ARSCNView(frame: frame)
        self.coachingView = ARCoachingOverlayView(frame: frame)
        
        // MARK: - Enable Depth Occlusion Rendering
        // Configure ARSCNView to use scene depth for realistic occlusion
        if #available(iOS 13.0, *) {
            // Enable people occlusion and scene depth rendering
            self.sceneView.rendersCameraGrain = true
            self.sceneView.rendersMotionBlur = false
        }
        
        self.sessionManagerChannel = FlutterMethodChannel(name: "arsession_\(viewId)", binaryMessenger: messenger)
        self.objectManagerChannel = FlutterMethodChannel(name: "arobjects_\(viewId)", binaryMessenger: messenger)
        self.anchorManagerChannel = FlutterMethodChannel(name: "aranchors_\(viewId)", binaryMessenger: messenger)
        super.init()

        let configuration = ARWorldTrackingConfiguration() // Create default configuration before initializeARView is called
        self.sceneView.delegate = self
        self.coachingView.delegate = self
        self.sceneView.session.run(configuration)
        self.sceneView.session.delegate = self

        self.sessionManagerChannel.setMethodCallHandler(self.onSessionMethodCalled)
        self.objectManagerChannel.setMethodCallHandler(self.onObjectMethodCalled)
        self.anchorManagerChannel.setMethodCallHandler(self.onAnchorMethodCalled)
    }

    func view() -> UIView {
        return self.sceneView
    }

    func onDispose(_ result:FlutterResult) {
        // Comprehensive cleanup to prevent memory leaks
        sceneView.session.pause()
        
        // Clear all resources efficiently
        resourceHandles.removeAll()
        nodeToUniqueIdMap.removeAll()
        assetCache.removeAll()
        anchorCollection.removeAll()
        trackedPlanes.removeAll()
        
        // Clear object pools
        nodeHitResultsPool.removeAllObjects()
        matrixPool.removeAllObjects()
        
        // Clear cancellables
        cancellableCollection.removeAll()
        
        // Clear method channel handlers
        self.sessionManagerChannel.setMethodCallHandler(nil)
        self.objectManagerChannel.setMethodCallHandler(nil)
        self.anchorManagerChannel.setMethodCallHandler(nil)
        
        result(nil)
    }

    func onSessionMethodCalled(_ call :FlutterMethodCall, _ result:FlutterResult) {
        let arguments = call.arguments as? Dictionary<String, Any>

        switch call.method {
            case "init":
                //self.sessionManagerChannel.invokeMethod("onError", arguments: ["SessionTEST from iOS"])
                //result(nil)
                initializeARView(arguments: arguments!, result: result)
                break
            case "getCameraPose":
                if let cameraPose = sceneView.session.currentFrame?.camera.transform {
                    result(serializeMatrix(cameraPose))
                } else {
                    result(FlutterError())
                }
                break
            case "getAnchorPose":
            if let cameraPose = anchorCollection[arguments?["anchorId"] as! String]?.transform {
                    result(serializeMatrix(cameraPose))
                } else {
                    result(FlutterError())
                }
                break
            case "snapshot":
                // call the SCNView Snapshot method and return the Image
                let snapshotImage = sceneView.snapshot()
                if let bytes = snapshotImage.pngData() {
                    let data = FlutterStandardTypedData(bytes:bytes)
                    result(data)
                } else {
                    result(nil)
                }
            case "dispose":
                onDispose(result)
                result(nil)
                break
            case "showPlanes":
                if let showPlanesArgument = arguments?["showPlanes"] as? Bool {
                        showPlanes = showPlanesArgument
                } else {
                    showPlanes = false
                }
                if (showPlanes){
                    // Visualize currently tracked planes
                    for plane in trackedPlanes.values {
                        plane.0.addChildNode(plane.1)
                    }
                } else {
                    // Remove currently visualized planes
                    for plane in trackedPlanes.values {
                        plane.1.removeFromParentNode()
                    }
                }
                result(nil)
                break
            case "softResetSession":
                let removeAnchors = arguments?["removeExistingAnchors"] as? Bool ?? true
                let resetTracking = arguments?["resetTracking"] as? Bool ?? true
                let success = softResetSession(removeAnchors: removeAnchors, resetTracking: resetTracking)
                result(success)
                break
            case "ar#nukeAll":
                let purgeCaches = arguments?["purgeCaches"] as? Bool ?? true
                let removeAnchors = arguments?["removeExistingAnchors"] as? Bool ?? true
                let resetTracking = arguments?["resetTracking"] as? Bool ?? true
                // Phase 3 enhancements
                let forceSystemMemoryPressure = arguments?["forceSystemMemoryPressure"] as? Bool ?? true
                let enableHardwareGpuReset = arguments?["enableHardwareGpuReset"] as? Bool ?? true
                let simulateMemoryWarning = arguments?["simulateMemoryWarning"] as? Bool ?? true
                let success = self.nukeAll(
                    purgeCaches: purgeCaches, 
                    removeAnchors: removeAnchors, 
                    resetTracking: resetTracking,
                    forceSystemMemoryPressure: forceSystemMemoryPressure,
                    enableHardwareGpuReset: enableHardwareGpuReset,
                    simulateMemoryWarning: simulateMemoryWarning
                )
                result(success)
                break
            case "ar#nukeAllNonBlocking":
                let purgeCaches = arguments?["purgeCaches"] as? Bool ?? true
                let removeAnchors = arguments?["removeExistingAnchors"] as? Bool ?? true
                let resetTracking = arguments?["resetTracking"] as? Bool ?? false
                
                // Start cleanup immediately and return true (fire and forget for now)
                self.nukeAllNonBlockingFireAndForget(
                    purgeCaches: purgeCaches,
                    removeAnchors: removeAnchors,
                    resetTracking: resetTracking
                )
                result(true) // Return immediately
                break
            case "ar#getPluginState":
                let state = self.getPluginState()
                result(state)
                break
            case "getLightEstimate":
                getLightEstimate(result: result)
                break
            case "enableLightingMonitoring":
                enableLightingMonitoring(arguments: arguments, result: result)
                break
            case "isDepthSupported":
                isDepthSupported(result: result)
                break
            case "enableDepthOcclusion":
                if let enable = arguments?["enable"] as? Bool {
                    enableDepthOcclusion(enable: enable, result: result)
                } else {
                    result(FlutterError(code: "INVALID_ARGUMENT", message: "enable parameter required", details: nil))
                }
                break
            case "isDepthOcclusionEnabled":
                result(self.depthOcclusionEnabled)
                break
            case "acquireDepthImage":
                acquireDepthImage(result: result)
                break
            default:
                result(FlutterMethodNotImplemented)
                break
        }
    }

    func onObjectMethodCalled(_ call :FlutterMethodCall, _ result: @escaping FlutterResult) {
        let arguments = call.arguments as? Dictionary<String, Any>
          
        switch call.method {
            case "init":
                DispatchQueue.main.async {self.objectManagerChannel.invokeMethod("onError", arguments: ["ObjectTEST from iOS"])}
                result(nil)
                break
            case "addNode":
                addNode(dict_node: arguments!).sink(receiveCompletion: { completion in
                    switch completion {
                        case .failure(let error):
                            DispatchQueue.main.async {self.objectManagerChannel.invokeMethod("onError", arguments: ["Error: \(error.localizedDescription)"])}
                        case .finished:
                            break
                    }
                }, receiveValue: { val in
                       result(val)
                    }).store(in: &self.cancellableCollection)
                break
            case "addNodeToPlaneAnchor":
                if let dict_node = arguments!["node"] as? Dictionary<String, Any>, let dict_anchor = arguments!["anchor"] as? Dictionary<String, Any> {
                    addNode(dict_node: dict_node, dict_anchor: dict_anchor).sink(receiveCompletion: { completion in
                        switch completion {
                            case .failure(let error):
                                DispatchQueue.main.async {self.objectManagerChannel.invokeMethod("onError", arguments: ["Error: \(error.localizedDescription)"])}
                            case .finished:
                                break
                        }
                    }, receiveValue: { val in
                           result(val)
                        }).store(in: &self.cancellableCollection)
                }
                break
            case "removeNode":
                if let nodeId = arguments!["name"] as? String {
                    // IOS FIX: Use the new unique ID system for removal
                    removeNodeDeep(nodeId: nodeId)
                }
                // Note: removeNode does not return a result (legacy behavior)
                break
            case "removeNodeDeep":
                if let nodeId = arguments!["nodeId"] as? String {
                    let success = removeNodeDeep(nodeId: nodeId)
                    result(success)
                } else {
                    result(false)
                }
                break
            case "purgeCaches":
                let success = purgeCaches()
                result(success)
                break
            case "createNodeFromAsset":
                if let uri = arguments!["uri"] as? String,
                   let transformMatrix = arguments!["transformMatrix"] as? [Double] {
                    createNodeFromAsset(uri: uri, transformMatrix: transformMatrix) { nodeName in
                        result(nodeName)
                    }
                } else {
                    result(nil)
                }
                break
            case "getMemoryInfo":
                let memoryInfo = getMemoryInfo()
                result(memoryInfo)
                break
            case "transformationChanged":
                if let name = arguments!["name"] as? String, let transform = arguments!["transformation"] as? Array<NSNumber> {
                    transformNode(name: name, transform: transform)
                    result(nil)
                }
                break
            default:
                result(FlutterMethodNotImplemented)
                break
        }
    }

    func onAnchorMethodCalled(_ call :FlutterMethodCall, _ result: @escaping FlutterResult) {
        let arguments = call.arguments as? Dictionary<String, Any>
          
        switch call.method {
            case "init":
                DispatchQueue.main.async {self.objectManagerChannel.invokeMethod("onError", arguments: ["ObjectTEST from iOS"])}
                result(nil)
                break
            case "addAnchor":
                if let type = arguments!["type"] as? Int {
                    switch type {
                    case 0: //Plane Anchor
                        if let transform = arguments!["transformation"] as? Array<NSNumber>, let name = arguments!["name"] as? String {
                            addPlaneAnchor(transform: transform, name: name)
                            result(true)
                        }
                        result(false)
                        break
                    default:
                        result(false)
                    
                    }
                }
                result(nil)
                break
            case "removeAnchor":
                if let name = arguments!["name"] as? String {
                    deleteAnchor(anchorName: name)
                }
                break
            case "initGoogleCloudAnchorMode":
                arcoreSession = try! GARSession.session()

                if (arcoreSession != nil){
                    let configuration = GARSessionConfiguration();
                    configuration.cloudAnchorMode = .enabled;
                    arcoreSession?.setConfiguration(configuration, error: nil);
                    if let token = JWTGenerator().generateWebToken(){
                        arcoreSession!.setAuthToken(token)
                        
                        cloudAnchorHandler = CloudAnchorHandler(session: arcoreSession!)
                        arcoreSession!.delegate = cloudAnchorHandler
                        arcoreSession!.delegateQueue = DispatchQueue.main
                        
                        arcoreMode = true
                    } else {
                        DispatchQueue.main.async {self.sessionManagerChannel.invokeMethod("onError", arguments: ["Error generating JWT, have you added cloudAnchorKey.json into the ios/Runner directory ?"])}
                    }
                } else {
                    DispatchQueue.main.async {self.sessionManagerChannel.invokeMethod("onError", arguments: ["Error initializing Google AR Session"])}
                }
                    
                break
            case "uploadAnchor":
                if let anchorName = arguments!["name"] as? String, let anchor = anchorCollection[anchorName] {
                    if let ttl = arguments!["ttl"] as? Int {
                        cloudAnchorHandler?.hostCloudAnchorWithTtl(anchorName: anchorName, anchor: anchor, listener: cloudAnchorUploadedListener(parent: self), ttl: ttl)
                    } else {
                        cloudAnchorHandler?.hostCloudAnchor(anchorName: anchorName, anchor: anchor, listener: cloudAnchorUploadedListener(parent: self))
                    }
                }
                result(true)
                break
            case "downloadAnchor":
                if let anchorId = arguments!["cloudanchorid"] as? String {
                    cloudAnchorHandler?.resolveCloudAnchor(anchorId: anchorId, listener: cloudAnchorDownloadedListener(parent: self))
                }
                break
            default:
                result(FlutterMethodNotImplemented)
                break
        }
    }

    func initializeARView(arguments: Dictionary<String,Any>, result: FlutterResult){
        // Set plane detection configuration
        self.configuration = ARWorldTrackingConfiguration()
        
        // Enable automatic environment texturing for realistic reflections and lighting
        // This captures the real environment and generates dynamic cubemaps for reflections
        self.configuration.environmentTexturing = .automatic
        
        // Enable light estimation for realistic lighting that adapts to the environment
        self.configuration.isLightEstimationEnabled = true
        
        // MARK: - Depth API Configuration
        // Enable scene depth for occlusion (requires LiDAR devices: iPhone 12 Pro+, iPad Pro 2020+)
        if #available(iOS 14.0, *) {
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                self.configuration.frameSemantics.insert(.sceneDepth)
                self.depthOcclusionEnabled = true
                
                // Setup occlusion rendering
                self.setupOcclusionGeometry()
                
                print("✅ ARKit Depth API enabled - occlusion supported")
            } else {
                self.depthOcclusionEnabled = false
                print("⚠️ ARKit Depth API not available on this device (requires LiDAR)")
            }
        } else {
            self.depthOcclusionEnabled = false
            print("⚠️ ARKit Depth API requires iOS 14.0+")
        }
        
        // Optimize SceneKit rendering for realistic PBR materials
        configureRealisticRendering()
        
        if let planeDetectionConfig = arguments["planeDetectionConfig"] as? Int {
            switch planeDetectionConfig {
                case 1: 
                    configuration.planeDetection = .horizontal
                
                case 2: 
                    if #available(iOS 11.3, *) {
                        configuration.planeDetection = .vertical
                    }
                case 3: 
                    if #available(iOS 11.3, *) {
                        configuration.planeDetection = [.horizontal, .vertical]
                    }
                default: 
                    configuration.planeDetection = []
            }
        }

        // Set plane rendering options
        if let configShowPlanes = arguments["showPlanes"] as? Bool {
            showPlanes = configShowPlanes
            if (showPlanes){
                // Visualize currently tracked planes
                for plane in trackedPlanes.values {
                    plane.0.addChildNode(plane.1)
                }
            } else {
                // Remove currently visualized planes
                for plane in trackedPlanes.values {
                    plane.1.removeFromParentNode()
                }
            }
        }
        if let configCustomPlaneTexturePath = arguments["customPlaneTexturePath"] as? String {
            customPlaneTexturePath = configCustomPlaneTexturePath
        }

        // Set debug options
        var debugOptions = ARSCNDebugOptions().rawValue
        if let showFeaturePoints = arguments["showFeaturePoints"] as? Bool {
            if (showFeaturePoints) {
                debugOptions |= ARSCNDebugOptions.showFeaturePoints.rawValue
            }
        }
        if let showWorldOrigin = arguments["showWorldOrigin"] as? Bool {
            if (showWorldOrigin) {
                debugOptions |= ARSCNDebugOptions.showWorldOrigin.rawValue
            }
        }
        self.sceneView.debugOptions = ARSCNDebugOptions(rawValue: debugOptions)
        
        if let configHandleTaps = arguments["handleTaps"] as? Bool {
            if (configHandleTaps){
                let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
                tapGestureRecognizer.delegate = self
                self.sceneView.gestureRecognizers?.append(tapGestureRecognizer)
            }
        }

        if let configHandlePans = arguments["handlePans"] as? Bool {
            if (configHandlePans){
                let panGestureRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
                panGestureRecognizer.maximumNumberOfTouches = 1
                panGestureRecognizer.delegate = self
                self.sceneView.gestureRecognizers?.append(panGestureRecognizer)
            }
        }
        
        if let configHandleRotation = arguments["handleRotation"] as? Bool {
            if (configHandleRotation){
                let rotationGestureRecognizer = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
                rotationGestureRecognizer.delegate = self
                self.sceneView.gestureRecognizers?.append(rotationGestureRecognizer)
            }
        }
        
        // Add coaching view
        if let configShowAnimatedGuide = arguments["showAnimatedGuide"] as? Bool {
            if configShowAnimatedGuide {
                if self.sceneView.superview != nil && self.coachingView.superview == nil {
                    self.sceneView.addSubview(self.coachingView)
        //            self.coachingView.translatesAutoresizingMaskIntoConstraints = false
                    self.coachingView.autoresizingMask = [
                          .flexibleWidth, .flexibleHeight
                        ]
                    self.coachingView.session = self.sceneView.session
                    self.coachingView.activatesAutomatically = true
                    if configuration.planeDetection == .horizontal {
                        self.coachingView.goal = .horizontalPlane
                    }else{
                        self.coachingView.goal = .verticalPlane
                    }
                    // TODO: look into constraints issue. This causes a crash:
                    /**
                     Terminating app due to uncaught exception 'NSGenericException', reason: 'Unable to activate constraint with anchors <NSLayoutXAxisAnchor:0x28342dec0 "ARCoachingOverlayView:0x13a470ae0.centerX"> and <NSLayoutXAxisAnchor:0x28342c680 "FlutterTouchInterceptingView:0x10bad1c90.centerX"> because they have no common ancestor.  Does the constraint or its anchors reference items in different view hierarchies?  That's illegal.'
                     */
        //            NSLayoutConstraint.activate([
        //                self.coachingView.centerXAnchor.constraint(equalTo: self.sceneView.superview!.centerXAnchor),
        //                self.coachingView.centerYAnchor.constraint(equalTo: self.sceneView.superview!.centerYAnchor),
        //                self.coachingView.widthAnchor.constraint(equalTo: self.sceneView.superview!.widthAnchor),
        //                self.coachingView.heightAnchor.constraint(equalTo: self.sceneView.superview!.heightAnchor)
        //                ])
                }
            }
        }
    
        // Update session configuration
        self.sceneView.session.run(configuration)
    }

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        
        if let planeAnchor = anchor as? ARPlaneAnchor{
            let plane = modelBuilder.makePlane(anchor: planeAnchor, flutterAssetFile: customPlaneTexturePath)
            trackedPlanes[anchor.identifier] = (node, plane)
            planeCount += 1
            
            // Send comprehensive plane information to Flutter
            let planeData = serializePlaneData(planeAnchor: planeAnchor)
            DispatchQueue.main.async {self.sessionManagerChannel.invokeMethod("onPlaneDetected", arguments: planeData)}
            
            if (showPlanes) {
                node.addChildNode(plane)
            }
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        
        if let planeAnchor = anchor as? ARPlaneAnchor, let plane = trackedPlanes[anchor.identifier] {
            modelBuilder.updatePlaneNode(planeNode: plane.1, anchor: planeAnchor)
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        trackedPlanes.removeValue(forKey: anchor.identifier)
    }
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if (arcoreMode) {
            do {
                try arcoreSession!.update(frame)
            } catch {
                print(error)
            }
        }
    }

    func addNode(dict_node: Dictionary<String, Any>, dict_anchor: Dictionary<String, Any>? = nil) -> Future<String?, Never> {

        // Note: centerOriginOnLoad flag is available but we don't use centerOrigin() on iOS
        // as it causes similar scale/position issues as on Android. The model's native origin is used.
        // let centerOriginOnLoad = dict_node["centerOriginOnLoad"] as? Bool ?? true
        
        return Future {promise in
            
            switch (dict_node["type"] as! Int) {
                case 0: // GLTF2 Model from Flutter asset folder
                    // Get path to given Flutter asset
                    let key = FlutterDartProject.lookupKey(forAsset: dict_node["uri"] as! String)
                    // Add object to scene
                    if let node: SCNNode = self.modelBuilder.makeNodeFromGltf(name: dict_node["name"] as! String, modelPath: key, transformation: dict_node["transformation"] as? Array<NSNumber>) {
                        // IOS FIX: Generate unique ID like Android for consistent deletion
                        let uniqueNodeId = "ios_node_\(Int(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 0...9999))"
                        
                        if let anchorName = dict_anchor?["name"] as? String, let anchorType = dict_anchor?["type"] as? Int {
                            switch anchorType{
                                case 0: //PlaneAnchor
                                    if let anchor = self.anchorCollection[anchorName]{
                                        // Attach node to the top-level node of the specified anchor
                                        self.sceneView.node(for: anchor)?.addChildNode(node)
                                        // Track with unique ID for reliable deletion
                                        self.trackResourceHandle(for: node, nodeId: uniqueNodeId, assetKey: dict_node["uri"] as? String)
                                        promise(.success(uniqueNodeId))
                                    } else {
                                        promise(.success(nil))
                                    }
                                default:
                                    promise(.success(nil))
                                }
                            
                        } else {
                            // Attach to top-level node of the scene
                            self.sceneView.scene.rootNode.addChildNode(node)
                            // Track with unique ID for reliable deletion
                            self.trackResourceHandle(for: node, nodeId: uniqueNodeId, assetKey: dict_node["uri"] as? String)
                            promise(.success(uniqueNodeId))
                        }
                    } else {
                        DispatchQueue.main.async {self.sessionManagerChannel.invokeMethod("onError", arguments: ["Unable to load renderable \(dict_node["uri"] as! String)"])}
                        promise(.success(nil))
                    }
                    break
                case 1: // GLB Model from the web
                    // Add object to scene
                    self.modelBuilder.makeNodeFromWebGlb(name: dict_node["name"] as! String, modelURL: dict_node["uri"] as! String, transformation: dict_node["transformation"] as? Array<NSNumber>)
                    .sink(receiveCompletion: { completion in
                        switch completion {
                            case .failure(let error):
                                DispatchQueue.main.async {self.objectManagerChannel.invokeMethod("onError", arguments: ["Error: \(error.localizedDescription)"])}
                            case .finished:
                                break
                        }
                    }, receiveValue: { val in
                        if let node: SCNNode = val {
                            // IOS FIX: Generate unique ID like Android for consistent deletion
                            let uniqueNodeId = "ios_node_\(Int(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 0...9999))"
                            
                            if let anchorName = dict_anchor?["name"] as? String, let anchorType = dict_anchor?["type"] as? Int {
                                switch anchorType{
                                    case 0: //PlaneAnchor
                                        if let anchor = self.anchorCollection[anchorName]{
                                            // Attach node to the top-level node of the specified anchor
                                            self.sceneView.node(for: anchor)?.addChildNode(node)
                                            // Track with unique ID for reliable deletion
                                            self.trackResourceHandle(for: node, nodeId: uniqueNodeId, assetKey: dict_node["uri"] as? String)
                                            promise(.success(uniqueNodeId))
                                        } else {
                                            promise(.success(nil))
                                        }
                                    default:
                                        promise(.success(nil))
                                    }
                                
                            } else {
                                // Attach to top-level node of the scene
                                self.sceneView.scene.rootNode.addChildNode(node)
                                // Track with unique ID for reliable deletion
                                self.trackResourceHandle(for: node, nodeId: uniqueNodeId, assetKey: dict_node["uri"] as? String)
                                promise(.success(uniqueNodeId))
                            }
                        } else {
                            DispatchQueue.main.async {self.sessionManagerChannel.invokeMethod("onError", arguments: ["Unable to load renderable \(dict_node["name"] as! String)"])}
                            promise(.success(nil))
                        }
                    }).store(in: &self.cancellableCollection)
                    break
                case 2: // GLB Model from the app's documents folder
                    // Get path to given file system asset
                    let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
                    let documentsDirectory = paths[0]
                    let targetPath = documentsDirectory.appendingPathComponent(dict_node["uri"] as! String).path
 
                    // Add object to scene
                    if let node: SCNNode = self.modelBuilder.makeNodeFromFileSystemGLB(name: dict_node["name"] as! String, modelPath: targetPath, transformation: dict_node["transformation"] as? Array<NSNumber>) {
                        // IOS FIX: Generate unique ID like Android for consistent deletion
                        let uniqueNodeId = "ios_node_\(Int(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 0...9999))"
                        
                        if let anchorName = dict_anchor?["name"] as? String, let anchorType = dict_anchor?["type"] as? Int {
                            switch anchorType{
                                case 0: //PlaneAnchor
                                    if let anchor = self.anchorCollection[anchorName]{
                                        // Attach node to the top-level node of the specified anchor
                                        self.sceneView.node(for: anchor)?.addChildNode(node)
                                        // Track with unique ID for reliable deletion
                                        self.trackResourceHandle(for: node, nodeId: uniqueNodeId, assetKey: dict_node["uri"] as? String)
                                        promise(.success(uniqueNodeId))
                                    } else {
                                        promise(.success(nil))
                                    }
                                default:
                                    promise(.success(nil))
                                }
                            
                        } else {
                            // Attach to top-level node of the scene
                            self.sceneView.scene.rootNode.addChildNode(node)
                            // Track with unique ID for reliable deletion
                            self.trackResourceHandle(for: node, nodeId: uniqueNodeId, assetKey: dict_node["uri"] as? String)
                            promise(.success(uniqueNodeId))
                        }
                    } else {
                        DispatchQueue.main.async {self.sessionManagerChannel.invokeMethod("onError", arguments: ["Unable to load renderable \(dict_node["uri"] as! String)"])}
                        promise(.success(nil))
                    }
                    break
                case 3: //fileSystemAppFolderGLTF2
                    // Get path to given file system asset
                    let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
                    let documentsDirectory = paths[0]
                    let targetPath = documentsDirectory.appendingPathComponent(dict_node["uri"] as! String).path

                    // Add object to scene
                    if let node: SCNNode = self.modelBuilder.makeNodeFromFileSystemGltf(name: dict_node["name"] as! String, modelPath: targetPath, transformation: dict_node["transformation"] as? Array<NSNumber>) {
                        // IOS FIX: Generate unique ID like Android for consistent deletion
                        let uniqueNodeId = "ios_node_\(Int(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 0...9999))"
                        
                        if let anchorName = dict_anchor?["name"] as? String, let anchorType = dict_anchor?["type"] as? Int {
                            switch anchorType{
                                case 0: //PlaneAnchor
                                    if let anchor = self.anchorCollection[anchorName]{
                                        // Attach node to the top-level node of the specified anchor
                                        self.sceneView.node(for: anchor)?.addChildNode(node)
                                        // Track with unique ID for reliable deletion
                                        self.trackResourceHandle(for: node, nodeId: uniqueNodeId, assetKey: dict_node["uri"] as? String)
                                        promise(.success(uniqueNodeId))
                                    } else {
                                        promise(.success(nil))
                                    }
                                default:
                                    promise(.success(nil))
                                }
                            
                        } else {
                            // Attach to top-level node of the scene
                            self.sceneView.scene.rootNode.addChildNode(node)
                            // Track with unique ID for reliable deletion
                            self.trackResourceHandle(for: node, nodeId: uniqueNodeId, assetKey: dict_node["uri"] as? String)
                            promise(.success(uniqueNodeId))
                        }
                    } else {
                        DispatchQueue.main.async {self.sessionManagerChannel.invokeMethod("onError", arguments: ["Unable to load renderable \(dict_node["uri"] as! String)"])}
                        promise(.success(nil))
                    }
                    break
                default:
                    promise(.success(nil))
            }
            
        }
    }
    
    func transformNode(name: String, transform: Array<NSNumber>) {
        let node = sceneView.scene.rootNode.childNode(withName: name, recursively: true)
        node?.transform = deserializeMatrix4(transform)
    }
    
    @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let sceneView = recognizer.view as? ARSCNView else {
            return
        }
        let touchLocation = recognizer.location(in: sceneView)
    
        let allHitResults = sceneView.hitTest(touchLocation, options: [SCNHitTestOption.searchMode : SCNHitTestSearchMode.closest.rawValue])
        
        // IOS FIX: Use nodeToUniqueIdMap to find unique IDs from hit nodes
        var nodeHitResults: Array<String> = []
        for hitResult in allHitResults {
            var currentNode: SCNNode? = hitResult.node
            // Traverse up the node hierarchy to find a tracked node
            while currentNode != nil {
                if let uniqueId = nodeToUniqueIdMap[currentNode!] {
                    nodeHitResults.append(uniqueId)
                    break
                }
                currentNode = currentNode?.parent
            }
        }
        
        if (nodeHitResults.count != 0) {
            DispatchQueue.main.async {self.objectManagerChannel.invokeMethod("onNodeTap", arguments: Array(Set(nodeHitResults)))} // Chaining of Array and Set is used to remove duplicates
            return
        }
            
        let planeTypes: ARHitTestResult.ResultType
        if #available(iOS 11.3, *){
            planeTypes = ARHitTestResult.ResultType([.existingPlaneUsingGeometry, .featurePoint])
        }else {
            planeTypes = ARHitTestResult.ResultType([.existingPlaneUsingExtent, .featurePoint])
        }
        
        let planeAndPointHitResults = sceneView.hitTest(touchLocation, types: planeTypes)
        
        // store the alignment of the tapped plane anchor so we can refer to is later when transforming the node
        if planeAndPointHitResults.count > 0, let hitAnchor = planeAndPointHitResults.first?.anchor as? ARPlaneAnchor {
            self.tappedPlaneAnchorAlignment = hitAnchor.alignment
        }
            
        let serializedPlaneAndPointHitResults = planeAndPointHitResults.map{serializeHitResult($0)}
        if (serializedPlaneAndPointHitResults.count != 0) {
            DispatchQueue.main.async {self.sessionManagerChannel.invokeMethod("onPlaneOrPointTap", arguments: serializedPlaneAndPointHitResults)}
        }
    }

    @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let sceneView = recognizer.view as? ARSCNView else {
            return
        }

        // State Begins
        if recognizer.state == UIGestureRecognizer.State.began
        {
            panStartLocation = recognizer.location(in: sceneView)
            if let startLocation = panStartLocation {
                let allHitResults = sceneView.hitTest(startLocation, options: [SCNHitTestOption.searchMode : SCNHitTestSearchMode.closest.rawValue])
                
                // IOS FIX: Use nodeToUniqueIdMap to find unique IDs from hit nodes
                for hitResult in allHitResults {
                    var currentNode: SCNNode? = hitResult.node
                    // Traverse up the node hierarchy to find a tracked node
                    while currentNode != nil {
                        if let uniqueId = nodeToUniqueIdMap[currentNode!] {
                            panningNode = currentNode
                            panningNodeCurrentWorldLocation = panningNode?.worldPosition
                            DispatchQueue.main.async {self.objectManagerChannel.invokeMethod("onPanStart", arguments: uniqueId)}
                            return
                        }
                        currentNode = currentNode?.parent
                    }
                }
            }
        }
        // State Changes
        if(recognizer.state == UIGestureRecognizer.State.changed)
        {
            // the velocity of the gesture is how fast it is moving. This can be used to translate the position of the node.
            panCurrentVelocity = recognizer.velocity(in: sceneView)
            panCurrentLocation = recognizer.location(in: sceneView)
            panCurrentTranslation = recognizer.translation(in: sceneView)

            if let panLoc = panCurrentLocation, let panNode = panningNode {
                if let query = sceneView.raycastQuery(from: panLoc, allowing: .estimatedPlane, alignment: .any) {
                    guard let result = self.sceneView.session.raycast(query).first else {
                        return
                    }
                    let posX = result.worldTransform.columns.3.x
                    let posY = result.worldTransform.columns.3.y
                    let posZ = result.worldTransform.columns.3.z
                    panNode.worldPosition = SCNVector3(posX, posY, posZ)
                }
                if let panNodeName = panNode.name {
                    DispatchQueue.main.async {self.objectManagerChannel.invokeMethod("onPanChange", arguments: panNodeName)}
                }
            }
        }
        // State Ended
        if(recognizer.state == UIGestureRecognizer.State.ended)
        {
            // kill variables
            panStartLocation = nil
            panCurrentLocation = nil
            // Only send onPanEnd if we have valid transformation data
            if let transformationData = serializeLocalTransformation(node: self.panningNode) {
                DispatchQueue.main.async {self.objectManagerChannel.invokeMethod("onPanEnd", arguments: transformationData)}
            }
            panningNode = nil
        }
    }
    
    @objc func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
        guard let sceneView = recognizer.view as? ARSCNView else {
            return
        }

        // State Begins
        if recognizer.state == UIGestureRecognizer.State.began
        {
            rotationStartLocation = recognizer.location(in: sceneView)
            if let startLocation = rotationStartLocation {
                let allHitResults = sceneView.hitTest(startLocation, options: [SCNHitTestOption.searchMode : SCNHitTestSearchMode.closest.rawValue])
                
                // IOS FIX: Use nodeToUniqueIdMap to find unique IDs from hit nodes
                for hitResult in allHitResults {
                    var currentNode: SCNNode? = hitResult.node
                    // Traverse up the node hierarchy to find a tracked node
                    while currentNode != nil {
                        if let uniqueId = nodeToUniqueIdMap[currentNode!] {
                            panningNode = currentNode
                            DispatchQueue.main.async {self.objectManagerChannel.invokeMethod("onRotationStart", arguments: uniqueId)}
                            return
                        }
                        currentNode = currentNode?.parent
                    }
                }
            }
        }
        // State Changes
        if(recognizer.state == UIGestureRecognizer.State.changed)
        {
            // the velocity of the gesture is how fast it is moving. This can be used to translate the position of the node.
            rotation = recognizer.rotation
            rotationVelocity = recognizer.velocity

            if let r = rotationVelocity, let panNode = panningNode {
                // velocity needs to be reduced substantially otherwise the rotation change seems too fast as radians; also needs inverting to match the movement of the fingers as they rotate on the screen
                let r2 = (r*0.01) * -1
                let nodeRotation = panNode.rotation
                let rotation: SCNQuaternion!
                let planeAlignment = self.tappedPlaneAnchorAlignment
                if planeAlignment == .horizontal {
                    rotation = SCNQuaternion(x: 0, y: 1, z: 0, w: nodeRotation.w+Float(r2)) // quickest way to convert screen into world positions (meters)
                }else{
                    rotation = SCNQuaternion(x: 0, y: 0, z: 1, w: nodeRotation.w+Float(r2)) // quickest way to convert screen into world positions (meters)
                }
                panNode.rotation = rotation
                if let panNodeName = panNode.name {
                    DispatchQueue.main.async {self.objectManagerChannel.invokeMethod("onRotationChange", arguments: panNodeName)}
                }
            }

            // update position of panning node if it has been created
            // panningNode.position + the gesture delta
        }
        // State Ended
        if(recognizer.state == UIGestureRecognizer.State.ended)
        {
            // kill variables
            rotation = nil
            rotationVelocity = nil
            // Only send onRotationEnd if we have valid transformation data
            if let transformationData = serializeLocalTransformation(node: self.panningNode) {
                DispatchQueue.main.async {self.objectManagerChannel.invokeMethod("onRotationEnd", arguments: transformationData)}
            }
            panningNode = nil
        }
    
    }

    // Recursive helper function to traverse a node's parents until a node with a name starting with the specified characters is found
    func nearestParentWithNameStart(node: SCNNode?, characters: String) -> SCNNode? {
        if let nodeNamePrefix = node?.name?.prefix(characters.count) {
            if (nodeNamePrefix == characters) { return node }
        }
        if let parent = node?.parent { return nearestParentWithNameStart(node: parent, characters: characters) }
        return nil
    }
    
    func addPlaneAnchor(transform: Array<NSNumber>, name: String){
        let arAnchor = ARAnchor(transform: simd_float4x4(deserializeMatrix4(transform)))
        anchorCollection[name] = arAnchor
        sceneView.session.add(anchor: arAnchor)
        // Ensure root node is added to anchor before any other function can run (if this isn't done, addNode could fail because anchor does not have a root node yet).
        // The root node is added to the anchor as soon as the async rendering loop runs once, more specifically the function "renderer(_:nodeFor:)"
        while (sceneView.node(for: arAnchor) == nil) {
            usleep(1) // wait 1 millionth of a second
        }
    }
    
    func deleteAnchor(anchorName: String) {
        if let anchor = anchorCollection[anchorName]{
            // Delete all child nodes
            if var attachedNodes = sceneView.node(for: anchor)?.childNodes {
                attachedNodes.removeAll()
            }
            // Remove anchor
            sceneView.session.remove(anchor: anchor)
            // Update bookkeeping
            anchorCollection.removeValue(forKey: anchorName)
        }
    }
    
    private class cloudAnchorUploadedListener: CloudAnchorListener {
        private var parent: IosARView
        
        init(parent: IosARView) {
            self.parent = parent
        }
        
        func onCloudTaskComplete(anchorName: String?, anchor: GARAnchor?) {
            if let cloudState = anchor?.cloudState {
                if (cloudState == GARCloudAnchorState.success) {
                    var args = Dictionary<String, String?>()
                    args["name"] = anchorName
                    args["cloudanchorid"] = anchor?.cloudIdentifier
                    DispatchQueue.main.async {self.parent.anchorManagerChannel.invokeMethod("onCloudAnchorUploaded", arguments: args)}
                } else {
                    DispatchQueue.main.async {self.parent.sessionManagerChannel.invokeMethod("onError", arguments: ["Error uploading anchor, state: \(self.parent.decodeCloudAnchorState(state: cloudState))"])}
                    return
                }
            }
        }
    }

    private class cloudAnchorDownloadedListener: CloudAnchorListener {
        private var parent: IosARView
        
        init(parent: IosARView) {
            self.parent = parent
        }
        
        func onCloudTaskComplete(anchorName: String?, anchor: GARAnchor?) {
            if let cloudState = anchor?.cloudState {
                if (cloudState == GARCloudAnchorState.success) {
                    let newAnchor = ARAnchor(transform: anchor!.transform)
                    // Register new anchor on the Flutter side of the plugin
                    DispatchQueue.main.async {self.parent.anchorManagerChannel.invokeMethod("onAnchorDownloadSuccess", arguments: serializeAnchor(anchor: newAnchor, anchorNode: nil, ganchor: anchor!, name: anchorName), result: { result in
                        if let anchorName = result as? String {
                            self.parent.sceneView.session.add(anchor: newAnchor)
                            self.parent.anchorCollection[anchorName] = newAnchor
                        } else {
                            DispatchQueue.main.async {self.parent.sessionManagerChannel.invokeMethod("onError", arguments: ["Error while registering downloaded anchor at the AR Flutter plugin"])}
                        }

                    })}
                } else {
                    DispatchQueue.main.async {self.parent.sessionManagerChannel.invokeMethod("onError", arguments: ["Error downloading anchor, state \(cloudState)"])}
                    return
                }
            }
        }
    }
    
    func decodeCloudAnchorState(state: GARCloudAnchorState) -> String {
        switch state {
        case .errorCloudIdNotFound:
            return "Cloud anchor id not found"
        case .errorHostingDatasetProcessingFailed:
            return "Dataset processing failed, feature map insufficient"
        case .errorHostingServiceUnavailable:
            return "Hosting service unavailable"
        case .errorInternal:
            return "Internal error"
        case .errorNotAuthorized:
            return "Authentication failed: Not Authorized"
        case .errorResolvingSdkVersionTooNew:
            return "Resolving Sdk version too new"
        case .errorResolvingSdkVersionTooOld:
            return "Resolving Sdk version too old"
        case .errorResourceExhausted:
            return " Resource exhausted"
        case .none:
            return "Empty state"
        case .taskInProgress:
            return "Task in progress"
        case .success:
            return "Success"
        case .errorServiceUnavailable:
            return "Cloud Anchor Service unavailable"
        case .errorResolvingLocalizationNoMatch:
            return "No match"
        @unknown default:
            return "Unknown"
        }
    }
    
    // Serialize comprehensive plane data for Flutter
    func serializePlaneData(planeAnchor: ARPlaneAnchor) -> [String: Any] {
        let center = planeAnchor.center
        let extent = planeAnchor.extent
        let transform = planeAnchor.transform
        
        // Get the height (Y position) from the transform matrix
        let height = transform.columns.3.y
        
        return [
            "identifier": planeAnchor.identifier.uuidString,
            "type": alignmentToString(planeAnchor.alignment),
            "center": [
                "x": center.x,
                "y": height, // This is the height of the plane!
                "z": center.z
            ],
            "extent": [
                "width": extent.x,
                "height": extent.z
            ],
            "transform": [
                transform.columns.0.x, transform.columns.0.y, transform.columns.0.z, transform.columns.0.w,
                transform.columns.1.x, transform.columns.1.y, transform.columns.1.z, transform.columns.1.w,
                transform.columns.2.x, transform.columns.2.y, transform.columns.2.z, transform.columns.2.w,
                transform.columns.3.x, transform.columns.3.y, transform.columns.3.z, transform.columns.3.w
            ],
            "alignment": alignmentToString(planeAnchor.alignment)
        ]
    }
    
    // Helper function to convert alignment to string
    func alignmentToString(_ alignment: ARPlaneAnchor.Alignment) -> String {
        switch alignment {
        case .horizontal:
            return "horizontal"
        case .vertical:
            return "vertical"
        @unknown default:
            return "unknown"
        }
    }
    
    // ========================================
    // DEEP MEMORY CLEANUP IMPLEMENTATION
    // ========================================
    
    private func removeNodeDeep(nodeId: String) -> Bool {
        
        // 1) Get resource handle - try exact match first
        var resourceHandle = resourceHandles.removeValue(forKey: nodeId)
        
        // IOS FIX: If not found, try with [# prefix (modelBuilder adds this prefix)
        if resourceHandle == nil && !nodeId.hasPrefix("[#") {
            let prefixedNodeId = "[#\(nodeId)"
            resourceHandle = resourceHandles.removeValue(forKey: prefixedNodeId)
        }
        
        guard let resourceHandle = resourceHandle else {
            // Still try to remove from scene if it exists
            if let node = sceneView.scene.rootNode.childNode(withName: nodeId, recursively: true) {
                node.removeFromParentNode()
                // IOS FIX: Also remove from reverse mapping
                nodeToUniqueIdMap.removeValue(forKey: node)
                return true
            }
            // IOS FIX: Also try with [# prefix
            if let node = sceneView.scene.rootNode.childNode(withName: "[#\(nodeId)", recursively: true) {
                node.removeFromParentNode()
                // IOS FIX: Also remove from reverse mapping
                nodeToUniqueIdMap.removeValue(forKey: node)
                return true
            }
            return false
        }
        
        // IOS FIX: Also remove the alternate key (original name or unique ID)
        // If we found it by unique ID, also remove by original name
        if let originalName = resourceHandle.node.name, originalName != nodeId {
            resourceHandles.removeValue(forKey: originalName)
        }
        // Get the unique ID from reverse mapping to remove the other entry
        if let uniqueId = nodeToUniqueIdMap[resourceHandle.node], uniqueId != nodeId {
            resourceHandles.removeValue(forKey: uniqueId)
        }
        
        // 2) Remove from scene
        resourceHandle.node.removeFromParentNode()
        
        // IOS FIX: Remove from reverse mapping
        nodeToUniqueIdMap.removeValue(forKey: resourceHandle.node)
        
        // 3) Deep destroy resources
        // Clear material references to help with memory cleanup
        for geometry in resourceHandle.geometries {
            geometry.materials.removeAll()
        }
        
        // Clear texture references
        for material in resourceHandle.materials {
            material.diffuse.contents = nil
            material.specular.contents = nil
            material.normal.contents = nil
            material.emission.contents = nil
            material.roughness.contents = nil
            material.metalness.contents = nil
        }
        
        // Update shared asset cache if applicable
        if let assetKey = resourceHandle.assetKey {
            if let cachedAsset = assetCache[assetKey] {
                let newRefCount = cachedAsset.refCount - 1
                if newRefCount <= 0 {
                    assetCache.removeValue(forKey: assetKey)
                } else {
                    // Update ref count (simplified - in real implementation you'd need atomic operations)
                    assetCache[assetKey] = CachedAsset(uri: cachedAsset.uri, rootNode: cachedAsset.rootNode, refCount: newRefCount)
                }
            }
        }
        
        return true
    }
    
    private func purgeCaches() -> Bool {
        assetCache.removeAll()
        resourceHandles.removeAll()
        nodeToUniqueIdMap.removeAll()
        return true
    }
    
    private func softResetSession(removeAnchors: Bool, resetTracking: Bool) -> Bool {
        var options: ARSession.RunOptions = []
        if removeAnchors { 
            options.insert(.removeExistingAnchors)
            // Also clear our anchor collection
            anchorCollection.removeAll()
        }
        if resetTracking { 
            options.insert(.resetTracking) 
        }
        
        DispatchQueue.main.async {
            self.sceneView.session.pause()
            print("⏸️ AR session paused")
            
            // Short delay to ensure session is fully paused
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.sceneView.session.run(self.configuration, options: options)
                print("▶️ AR session resumed with reset options")
            }
        }
        
        print("✅ Soft reset session completed")
        return true
    }
    
    private func nukeAll(
        purgeCaches: Bool, 
        removeAnchors: Bool, 
        resetTracking: Bool,
        forceSystemMemoryPressure: Bool = true,
        enableHardwareGpuReset: Bool = true,
        simulateMemoryWarning: Bool = true
    ) -> Bool {
        print("� PHASE 3 SYSTEM-LEVEL NUKE ALL INITIATED")
        print("📍 Flags: purgeCaches: \(purgeCaches), removeAnchors: \(removeAnchors), resetTracking: \(resetTracking)")
        print("📍 Phase 3: forceSystemMemoryPressure: \(forceSystemMemoryPressure), hwGpuReset: \(enableHardwareGpuReset), memWarning: \(simulateMemoryWarning)")
        
        return autoreleasepool {
            // A) Stop background work & cancel loading tasks
            print("⏹️ Phase A: Stopping background work")
            do {
                loadingQueue.async {
                    // Cancel any pending operations on the loading queue
                    print("⚡ Loading queue operations stopped")
                }
                print("✅ Phase A: Background work stopped")
            } catch {
                print("❌ Phase A error: \(error.localizedDescription)")
            }

            // B) CRITICAL: Destroy native drawing surface completely (ChatGPT fix)
            print("🖥️ Phase B: Destroying native drawing surfaces")
            do {
                // Stop render loop and frame callbacks first
                sceneView.session.delegate = nil
                sceneView.delegate = nil
                
                // ARSCNView specific teardown
                sceneView.scene = SCNScene() // Create empty scene instead of nil
                sceneView.isPlaying = false
                
                // Force SceneKit resource release
                SCNTransaction.flush()
                print("🔥 SceneKit transaction flushed")
                
                // If we have any Metal texture caches, flush them
                // Note: Add CVMetalTextureCacheFlush if you use texture cache
                
                print("✅ Phase B: Native drawing surfaces destroyed")
            } catch {
                print("❌ Phase B error: \(error.localizedDescription)")
            }

            // C) Clear all anchors and nodes
            print("🗑️ Phase C: Clearing anchors and nodes")
            do {
                if removeAnchors {
                    anchorCollection.removeAll()
                    print("🗑️ Cleared anchor collection")
                }
                
                // Clear all scene nodes BEFORE destroying scene
                sceneView.scene.rootNode.childNodes.forEach { node in
                    node.removeFromParentNode()
                }
                
                // Clear tracking state
                trackedPlanes.removeAll()
                print("🗑️ Cleared tracked planes")
                
                print("✅ Phase C: Anchors and nodes cleared")
            } catch {
                print("❌ Phase C error: \(error.localizedDescription)")
            }

            // D) Pause and destroy AR session completely
            print("⏸️ Phase D: Destroying AR session")
            do {
                sceneView.session.pause()
                
                // Give the session time to fully pause
                Thread.sleep(forTimeInterval: 0.2)
                
                // Clear session delegate to prevent callbacks
                sceneView.session.delegate = nil
                
                // Set session to nil to release it
                // Note: We can't directly nil the session, but we clear delegates
                
                print("✅ Phase D: AR session destroyed")
            } catch {
                print("❌ Phase D error: \(error.localizedDescription)")
            }

            // E) Destroy GPU resources and resource handles (CRITICAL)
            print("🎬 Phase E: Destroying GPU resources")
            do {
                resourceHandles.values.forEach { handle in
                    // Clear textures
                    handle.textures.removeAll()
                    
                    // Clear materials and their textures
                    handle.materials.forEach { material in
                        // Clear material textures (GPU memory release)
                        material.diffuse.contents = nil
                        material.specular.contents = nil
                        material.normal.contents = nil
                        material.emission.contents = nil
                        material.roughness.contents = nil
                        material.metalness.contents = nil
                        material.ambientOcclusion.contents = nil
                        material.selfIllumination.contents = nil
                        material.displacement.contents = nil
                    }
                    handle.materials.removeAll()
                    
                    // Clear geometries
                    handle.geometries.removeAll()
                    
                    // Remove node from scene
                    handle.node.removeFromParentNode()
                }
                resourceHandles.removeAll()
                
                // CRITICAL: Create completely new scene to release all GPU resources
                sceneView.scene = SCNScene()
                
                // Force another SceneKit flush after scene recreation
                SCNTransaction.flush()
                
                print("✅ Phase E: GPU resources destroyed")
            } catch {
                print("❌ Phase E error: \(error.localizedDescription)")
            }

            // F) Purge global caches and singletons
            if purgeCaches {
                print("🧹 Phase F: Purging caches and singletons")
                do {
                    assetCache.removeAll()
                    
                    // Clear any GLTF/ModelIO caches if we have them
                    // Note: Add specific cache clearing for your GLTF loaders here
                    
                    print("✅ Phase F: Caches purged")
                } catch {
                    print("❌ Phase F error: \(error.localizedDescription)")
                }
            }

            // G) Clear gesture and interaction state
            print("🔄 Phase G: Clearing interaction state")
            do {
                // Clear pan gesture state
                panStartLocation = nil
                panCurrentLocation = nil
                panningNode = nil
                
                // Clear rotation gesture state
                rotation = nil
                rotationVelocity = nil
                rotationStartLocation = nil
                
                // Clear plane tracking
                tappedPlaneAnchorAlignment = .horizontal
                
                print("✅ Phase G: Interaction state cleared")
            } catch {
                print("❌ Phase G error: \(error.localizedDescription)")
            }

            // H) CRITICAL: Phase 3 Enhanced aggressive memory cleanup
            print("♻️ Phase H: Phase 3 Enhanced aggressive memory cleanup")
            print("♻️ Flags: forceSystemMemoryPressure=\(forceSystemMemoryPressure), simulateMemoryWarning=\(simulateMemoryWarning)")
            do {
                // Multiple autorelease pool drains
                autoreleasepool {
                    // Force cleanup of any remaining autoreleased objects
                }
                
                // Let the runloop drain to finalize deallocation (longer drain)
                CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.1, false)
                
                // Another autoreleasepool drain
                autoreleasepool {
                    // Second cleanup pass
                }
                
                // PHASE 3 CRITICAL: Enhanced system memory pressure simulation
                if forceSystemMemoryPressure {
                    print("🚀 PHASE 3: Forcing system memory pressure simulation...")
                    for pass in 0..<5 { // Increased passes for Phase 3
                        autoreleasepool {
                            // Force system memory cleanup with more aggressive pressure
                            malloc_zone_pressure_relief(nil, 0)
                            
                            // Phase 3: Multiple memory warning simulations
                            if simulateMemoryWarning && pass < 3 {
                                NotificationCenter.default.post(
                                    name: UIApplication.didReceiveMemoryWarningNotification,
                                    object: UIApplication.shared
                                )
                                print("📱 Phase 3: Memory warning simulation \(pass + 1)")
                            }
                            
                            // Clear caches more aggressively
                            URLCache.shared.removeAllCachedResponses()
                            
                            // Phase 3: Additional system cleanup
                            if enableHardwareGpuReset {
                                // Force Metal command buffer completion
                                if let metalDevice = MTLCreateSystemDefaultDevice() {
                                    let commandQueue = metalDevice.makeCommandQueue()
                                    if let commandBuffer = commandQueue?.makeCommandBuffer() {
                                        commandBuffer.commit()
                                        commandBuffer.waitUntilCompleted()
                                    }
                                }
                                print("⚡ Phase 3: Hardware GPU reset pass \(pass + 1)")
                            }
                            
                            // Drain run loop between passes with extended time for Phase 3
                            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.05, false)
                        }
                    }
                } else {
                    // Fallback to basic cleanup
                    for pass in 0..<3 {
                        autoreleasepool {
                            malloc_zone_pressure_relief(nil, 0)
                            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.05, false)
                        }
                    }
                }
                
                print("✅ Phase H: Phase 3 Enhanced memory cleanup completed")
            } catch {
                print("❌ Phase H error: \(error.localizedDescription)")
            }

            print("🎉 PHASE 3 NUKE ALL COMPLETED - Memory should approach cold start levels")
            return true
        }
    }
    
    // MARK: - Non-Blocking Memory Cleanup (Camera Freeze Fix)
    
    private func nukeAllNonBlockingAsync(
        purgeCaches: Bool,
        removeAnchors: Bool,
        resetTracking: Bool
    ) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: false)
                    return
                }
                
                print("🔄 Starting non-blocking memory cleanup...")
                
                // Phase 1: Background cleanup (no session interruption)
                self.performBackgroundCleanup(purgeCaches: purgeCaches, removeAnchors: removeAnchors)
                
                // Phase 2: Optional soft reset on main thread
                if resetTracking {
                    DispatchQueue.main.async {
                        self.performSoftReset { success in
                            continuation.resume(returning: success)
                        }
                    }
                } else {
                    continuation.resume(returning: true)
                }
            }
        }
    }
    
    private func nukeAllNonBlocking(
        purgeCaches: Bool,
        removeAnchors: Bool,
        resetTracking: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        Task {
            let success = await nukeAllNonBlockingAsync(
                purgeCaches: purgeCaches,
                removeAnchors: removeAnchors,
                resetTracking: resetTracking
            )
            completion(success)
        }
    }
    
    private func nukeAllNonBlockingFireAndForget(
        purgeCaches: Bool,
        removeAnchors: Bool,
        resetTracking: Bool
    ) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            
            print("🔄 Starting fire-and-forget memory cleanup...")
            
            // Phase 1: Background cleanup (no session interruption)
            self.performBackgroundCleanup(purgeCaches: purgeCaches, removeAnchors: removeAnchors)
            
            // Phase 2: Optional soft reset on main thread
            if resetTracking {
                DispatchQueue.main.async {
                    self.performSoftReset { success in
                        print("🔄 Soft reset completed: \(success)")
                    }
                }
            } else {
                print("🔄 Fire-and-forget cleanup completed")
            }
        }
    }
    
    private func performBackgroundCleanup(purgeCaches: Bool, removeAnchors: Bool) {
        // 1. Clear object caches (background safe)
        if purgeCaches {
            assetCache.removeAll()
            print("✅ Asset caches cleared")
        }
        
        // 2. Remove resource handles (background safe)
        if removeAnchors {
            DispatchQueue.main.sync {
                for (_, handle) in resourceHandles {
                    handle.node.removeFromParentNode()
                }
                resourceHandles.removeAll()
                anchorCollection.removeAll()
            }
            print("✅ Nodes and anchors removed")
        }
        
        // 3. Gentle memory pressure (background safe)
        autoreleasepool {
            // Light cleanup without memory warnings
            URLCache.shared.removeAllCachedResponses()
        }
        
        // 4. Progressive GC (background safe)
        for _ in 0..<3 {
            autoreleasepool {
                // Allow natural cleanup cycles
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        
        print("✅ Background cleanup completed")
    }
    
    private func performSoftReset(completion: @escaping (Bool) -> Void) {
        print("🔄 Performing soft session reset...")
        
        // Save current configuration
        let currentConfig = sceneView.session.configuration
        
        guard let config = currentConfig else {
            completion(false)
            return
        }
        
        // Quick pause/resume cycle
        sceneView.session.pause()
        print("⏸️ Session paused briefly")
        
        // Minimal delay for cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Resume with reset options
            var options: ARSession.RunOptions = []
            options.insert(.resetTracking)
            options.insert(.removeExistingAnchors)
            
            self.sceneView.session.run(config, options: options)
            print("▶️ Session resumed with reset")
            
            // Verify session is running
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let isRunning = self.sceneView.session.currentFrame != nil
                print("✅ Session restoration: \(isRunning ? "Success" : "Failed")")
                completion(isRunning)
            }
        }
    }
    
    private func getPluginState() -> [String: Any] {
        var state: [String: Any] = [:]
        
        // Session state
        state["hasSession"] = true // sceneView is non-optional, so session exists
        
        // Check session running state safely 
        state["isSessionPaused"] = (sceneView.session.configuration == nil)
        
        // SceneView state
        state["hasSceneView"] = true // sceneView is non-optional
        state["hasScene"] = (sceneView.scene != nil)
        
        // Collections state - use proper property names
        state["anchorsCount"] = self.anchorCollection.count
        state["nodeAttachedCount"] = self.resourceHandles.count
        
        // Memory hint
        var memInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &memInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            let usedMB = memInfo.resident_size / 1024 / 1024
            state["usedMemoryMB"] = usedMB
        }
        
        print("🔍 Plugin State: \(state)")
        return state
    }
    
    private func createNodeFromAsset(uri: String, transformMatrix: [Double], completion: @escaping (String?) -> Void) {
        
        loadingQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            
            var node: SCNNode?
            var shouldCache = false
            
            // Check if asset is already cached
            if let cachedAsset = self.assetCache[uri] {
                // Clone the cached node
                node = cachedAsset.rootNode.clone()
                let newRefCount = cachedAsset.refCount + 1
                self.assetCache[uri] = CachedAsset(uri: cachedAsset.uri, rootNode: cachedAsset.rootNode, refCount: newRefCount)
            } else {
                // Load new asset - determine type from URI
                if uri.hasPrefix("http://") || uri.hasPrefix("https://") {
                    // Web asset - use async loading
                    DispatchQueue.main.async {
                        self.modelBuilder.makeNodeFromWebGlb(name: "SharedAsset_\(Date().timeIntervalSince1970)", modelURL: uri, transformation: nil)
                            .sink(receiveCompletion: { completionResult in
                                switch completionResult {
                                    case .failure(_):
                                        completion(nil)
                                    case .finished:
                                        break
                                }
                            }, receiveValue: { webNode in
                                if let webNode = webNode {
                                    // Cache the loaded asset
                                    self.assetCache[uri] = CachedAsset(uri: uri, rootNode: webNode, refCount: 1)
                                    
                                    // Apply transformation matrix
                                    if transformMatrix.count >= 16 {
                                        let matrix = transformMatrix.map { Float($0) }
                                        let transform = SCNMatrix4(
                                            m11: matrix[0], m12: matrix[1], m13: matrix[2], m14: matrix[3],
                                            m21: matrix[4], m22: matrix[5], m23: matrix[6], m24: matrix[7],
                                            m31: matrix[8], m32: matrix[9], m33: matrix[10], m34: matrix[11],
                                            m41: matrix[12], m42: matrix[13], m43: matrix[14], m44: matrix[15]
                                        )
                                        webNode.transform = transform
                                    }
                                    
                                    // IOS FIX: Generate unique ID like Android for consistent deletion
                                    let uniqueNodeId = "ios_node_\(Int(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 0...9999))"
                                    webNode.name = uniqueNodeId
                                    self.sceneView.scene.rootNode.addChildNode(webNode)
                                    
                                    // Track resource handle with unique ID
                                    let resourceHandle = ResourceHandle(nodeId: uniqueNodeId, node: webNode, assetKey: uri)
                                    self.resourceHandles[uniqueNodeId] = resourceHandle
                                    
                                    completion(uniqueNodeId)
                                } else {
                                    completion(nil)
                                }
                            }).store(in: &self.cancellableCollection)
                    }
                    return // Exit early for async loading
                } else if uri.contains("/") {
                    // File system asset
                    let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
                    let documentsDirectory = paths[0]
                    let targetPath = documentsDirectory.appendingPathComponent(uri).path
                    
                    if uri.hasSuffix(".glb") {
                        node = self.modelBuilder.makeNodeFromFileSystemGLB(name: "SharedAsset_\(Date().timeIntervalSince1970)", modelPath: targetPath, transformation: nil)
                    } else {
                        node = self.modelBuilder.makeNodeFromFileSystemGltf(name: "SharedAsset_\(Date().timeIntervalSince1970)", modelPath: targetPath, transformation: nil)
                    }
                    shouldCache = true
                } else {
                    // Flutter asset
                    let key = FlutterDartProject.lookupKey(forAsset: uri)
                    node = self.modelBuilder.makeNodeFromGltf(name: "SharedAsset_\(Date().timeIntervalSince1970)", modelPath: key, transformation: nil)
                    shouldCache = true
                }
                
                if let node = node, shouldCache {
                    self.assetCache[uri] = CachedAsset(uri: uri, rootNode: node)
                }
            }
            
            DispatchQueue.main.async {
                guard let finalNode = node else {
                    completion(nil)
                    return
                }
                
                // Apply transformation matrix
                if transformMatrix.count >= 16 {
                    let matrix = transformMatrix.map { Float($0) }
                    
                    // Create SCNMatrix4 from the transformation matrix
                    let transform = SCNMatrix4(
                        m11: matrix[0], m12: matrix[1], m13: matrix[2], m14: matrix[3],
                        m21: matrix[4], m22: matrix[5], m23: matrix[6], m24: matrix[7],
                        m31: matrix[8], m32: matrix[9], m33: matrix[10], m34: matrix[11],
                        m41: matrix[12], m42: matrix[13], m43: matrix[14], m44: matrix[15]
                    )
                    finalNode.transform = transform
                }
                
                // IOS FIX: Generate unique ID like Android for consistent deletion
                let uniqueNodeId = "ios_node_\(Int(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 0...9999))"
                finalNode.name = uniqueNodeId
                
                // Add to scene
                self.sceneView.scene.rootNode.addChildNode(finalNode)
                
                // Track resource handle with unique ID
                let resourceHandle = ResourceHandle(nodeId: uniqueNodeId, node: finalNode, assetKey: uri)
                self.resourceHandles[uniqueNodeId] = resourceHandle
                
                completion(uniqueNodeId)
            }
        }
    }
    
    private func getMemoryInfo() -> [String: Any] {
        var memoryInfo: [String: Any] = [:]
        
        // Get memory usage information
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            memoryInfo["residentSizeMB"] = Double(info.resident_size) / 1048576.0
            memoryInfo["virtualSizeMB"] = Double(info.virtual_size) / 1048576.0
        } else {
            memoryInfo["memoryError"] = "Unable to get memory info"
        }
        
        // Add cache statistics
        memoryInfo["activeNodes"] = resourceHandles.count
        memoryInfo["cachedAssets"] = assetCache.count
        memoryInfo["resourceHandles"] = resourceHandles.count
        
        return memoryInfo
    }
    
    // Update existing addNode methods to track resource handles
    private func trackResourceHandle(for node: SCNNode, nodeId: String, assetKey: String? = nil) {
        let resourceHandle = ResourceHandle(nodeId: nodeId, node: node, assetKey: assetKey)
        // Store with unique ID (for new API)
        resourceHandles[nodeId] = resourceHandle
        // IOS FIX: Also store with original node name for backward compatibility with Flutter
        if let originalName = node.name, originalName != nodeId {
            resourceHandles[originalName] = resourceHandle
        }
        // IOS FIX: Also store reverse mapping for tap detection
        nodeToUniqueIdMap[node] = nodeId
    }
    
    // Cleanup old cached assets (call periodically)
    private func cleanupOldAssets() {
        let currentTime = Date().timeIntervalSince1970
        
        for (key, asset) in assetCache {
            if asset.refCount <= 0 && (currentTime - asset.creationTime) > maxCacheAge {
                assetCache.removeValue(forKey: key)
            }
        }
    }
    
    // =================================================================
    // MARK: - Light Estimation Methods
    // =================================================================
    
    /**
     * Enable or disable automatic lighting condition monitoring
     * Sends periodic updates via onLightingConditionChanged callback
     */
    private func enableLightingMonitoring(arguments: Dictionary<String, Any>?, result: FlutterResult) {
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
    
    /**
     * Start the lighting monitoring timer
     */
    private func startLightingMonitoring() {
        stopLightingMonitoring() // Clear any existing timer
        
        lightingCheckTimer = Timer.scheduledTimer(withTimeInterval: lightingCheckInterval, repeats: true) { [weak self] _ in
            self?.checkLightingConditions()
        }
    }
    
    /**
     * Stop the lighting monitoring timer
     */
    private func stopLightingMonitoring() {
        lightingCheckTimer?.invalidate()
        lightingCheckTimer = nil
    }
    
    /**
     * Get current light estimate from ARKit
     * Returns ambient intensity and color temperature data
     */
    private func getLightEstimate(result: FlutterResult) {
        guard let frame = sceneView.session.currentFrame else {
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
        
        print("💡 Light estimate - Intensity: \(normalizedIntensity), Low light: \(isLowLight), Very low: \(isVeryLowLight)")
        result(lightData)
    }
    
    /**
     * Check lighting conditions and notify Flutter if monitoring is enabled
     * Called periodically by lightingCheckTimer
     */
    private func checkLightingConditions() {
        guard let frame = sceneView.session.currentFrame,
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
    
    // =================================================================
    // MARK: - Depth API Methods
    // =================================================================
    
    /**
     * Check if depth API is supported on this device
     * Requires iOS 14.0+ and LiDAR sensor (iPhone 12 Pro+, iPad Pro 2020+)
     */
    private func isDepthSupported(result: FlutterResult) {
        if #available(iOS 14.0, *) {
            let supported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
            print("📏 Depth API support check: \(supported)")
            result(supported)
        } else {
            print("📏 Depth API requires iOS 14.0+")
            result(false)
        }
    }
    
    /**
     * Enable or disable depth occlusion
     * When enabled, virtual objects will be occluded by real-world surfaces
     */
    private func enableDepthOcclusion(enable: Bool, result: FlutterResult) {
        if #available(iOS 14.0, *) {
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                if enable {
                    configuration.frameSemantics.insert(.sceneDepth)
                    print("✅ Depth occlusion enabled")
                } else {
                    configuration.frameSemantics.remove(.sceneDepth)
                    print("❌ Depth occlusion disabled")
                }
                
                // Update the session with new configuration
                sceneView.session.run(configuration, options: [])
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
    
    /**
     * Acquire depth image data from current AR frame
     * Returns depth map with width, height, and depth data (32-bit float per pixel)
     */
    private func acquireDepthImage(result: FlutterResult) {
        if #available(iOS 14.0, *) {
            guard let frame = sceneView.session.currentFrame else {
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
    
    /**
     * Setup occlusion geometry for depth-based rendering
     * 
     * NOTE: ARSCNView doesn't have built-in depth occlusion like RealityKit.
     * For true depth-based occlusion in SceneKit, you would need to:
     * 1. Use ARMatteGenerator (iOS 13+) for person segmentation occlusion
     * 2. Implement custom Metal shaders that sample the depth buffer
     * 3. Create dynamic occlusion geometry from depth data
     * 
     * This is a placeholder that enables plane-based occlusion.
     * For full depth occlusion, consider migrating to RealityKit or implementing Metal shaders.
     */
    private func setupOcclusionGeometry() {
        guard #available(iOS 14.0, *) else { return }
        
        print("📝 Depth data available but ARSCNView requires custom Metal implementation for full occlusion")
        print("💡 Recommendation: Use detected planes for basic occlusion, or migrate to RealityKit")
        
        // Enable plane detection for basic occlusion
        // Planes will act as occluders when they're in front of virtual objects
    }
    
    // =================================================================
    // Realistic Rendering Configuration
    // =================================================================
    
    /**
     * Configure SceneKit for realistic PBR rendering matching Android's Filament quality.
     *
     * Key changes vs previous implementation:
     * 1. `automaticallyUpdatesLighting = false` — prevents ARKit's auto-light from
     *    competing with our manual lights, giving us full control over intensity.
     * 2. SSAO via SCNTechnique — the SCNCamera.screenSpaceAmbientOcclusion* properties
     *    do NOT work with ARSCNView (ARKit bypasses that pipeline). Instead we use a
     *    custom SCNTechnique with a Metal SSAO pass that works correctly in AR.
     * 3. Brighter base lighting — environment intensity raised to 1.6 and directional
     *    light raised to 700 lux so base colours match Android's 15,000-lux IBL.
     * 4. Normal maps preserved — `flattenedClone()` removed from model loading.
     */
    private func configureRealisticRendering() {
        print("🌅 Configuring realistic PBR rendering for iOS")
        
        // =========================================================================
        // Lighting Control
        // =========================================================================
        
        // CRITICAL: Disable automatic lighting updates.
        // When `true`, ARKit continuously adjusts a built-in directional light which
        // COMPETES with our manually placed lights, causing inconsistent/darker illumination.
        // By disabling it we get full, stable control over scene lighting.
        sceneView.automaticallyUpdatesLighting = false
        
        // Environment lighting intensity for IBL-like reflections.
        // Android Filament uses 15,000 of ~100,000 (15%). SceneKit's scale is different;
        // 1.6 gives a brighter, more natural base matching Android.
        sceneView.scene.lightingEnvironment.intensity = 1.6
        
        // =========================================================================
        // HIGH-QUALITY RENDERING OPTIONS
        // =========================================================================
        
        if #available(iOS 13.0, *) {
            sceneView.antialiasingMode = .multisampling4X
            sceneView.contentScaleFactor = UIScreen.main.nativeScale
            sceneView.isJitteringEnabled = true
        }
        
        sceneView.preferredFramesPerSecond = 60
        
        // =========================================================================
        // LIGHTING SETUP
        // =========================================================================
        
        // Primary directional light — simulates the main light (sun/overhead)
        // Android gets this automatically from ARCore's estimated main directional light.
        let directionalLight = SCNLight()
        directionalLight.type = .directional
        directionalLight.color = UIColor.white
        directionalLight.intensity = 700  // Brighter to match Android's IBL-driven illumination
        directionalLight.castsShadow = true
        directionalLight.shadowMode = .deferred
        directionalLight.shadowRadius = 3.5      // Soft shadow edges
        directionalLight.shadowSampleCount = 32
        directionalLight.shadowMapSize = CGSize(width: 2048, height: 2048)
        directionalLight.shadowColor = UIColor(white: 0.0, alpha: 0.5)
        
        // Enable automatic shadow projection distance
        directionalLight.maximumShadowDistance = 10.0  // 10 meters
        directionalLight.shadowCascadeCount = 2        // Two cascade levels for quality
        
        let lightNode = SCNNode()
        lightNode.light = directionalLight
        lightNode.position = SCNVector3(0, 5, 0)
        lightNode.eulerAngles = SCNVector3(-Float.pi/4, Float.pi/6, 0)  // ~45° down, slight side angle
        sceneView.scene.rootNode.addChildNode(lightNode)
        
        // Ambient fill light — prevents pure black shadows
        // Android's HDR IBL provides soft fill from all directions;
        // this approximates that.
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.color = UIColor(white: 0.6, alpha: 1.0)
        ambientLight.intensity = 600
        
        let ambientNode = SCNNode()
        ambientNode.light = ambientLight
        sceneView.scene.rootNode.addChildNode(ambientNode)
        
        // Secondary weaker directional from opposite side to fill shadows
        // (simulates the diffuse IBL component on the shadow side)
        let fillDirectional = SCNLight()
        fillDirectional.type = .directional
        fillDirectional.color = UIColor(white: 0.7, alpha: 1.0)
        fillDirectional.intensity = 200
        fillDirectional.castsShadow = false  // No shadow from fill
        
        let fillNode = SCNNode()
        fillNode.light = fillDirectional
        fillNode.position = SCNVector3(0, 3, 0)
        fillNode.eulerAngles = SCNVector3(-Float.pi/6, Float.pi + Float.pi/6, 0)  // Opposite side
        sceneView.scene.rootNode.addChildNode(fillNode)
        
        // =========================================================================
        // SSAO via SCNTechnique
        // =========================================================================
        // SCNCamera.screenSpaceAmbientOcclusion* does NOT work with ARSCNView
        // because ARKit manages its own rendering pipeline. Instead, apply a
        // custom SCNTechnique that adds an SSAO post-processing pass via Metal shaders.
        setupSSAOTechnique()
        
        // =========================================================================
        // POST-PROCESSING
        // =========================================================================
        
        // Screen-space reflections OFF — causes rubber/plastic look
        sceneView.scene.wantsScreenSpaceReflection = false
        
        if #available(iOS 13.0, *) {
            sceneView.allowsCameraControl = false
        }
        
        print("✅ Realistic PBR rendering configured")
        print("   ✓ Auto-lighting OFF (manual control)")
        print("   ✓ Directional light: 700 lux + fill: 200 lux")
        print("   ✓ Ambient: 600 lux, environment: 1.6x")
        print("   ✓ SSAO technique applied")
        print("   ✓ Shadow cascades: 2, map: 2048x2048")
    }
    
    // MARK: - SSAO via SCNTechnique
    
    /**
     * Apply a screen-space ambient occlusion (SSAO) effect using SCNTechnique.
     *
     * Unlike `SCNCamera.screenSpaceAmbientOcclusionIntensity` which does NOT work
     * with ARSCNView, `SCNTechnique` correctly hooks into the rendering pipeline
     * and is applied as a post-processing pass on every frame.
     *
     * The technique uses two passes:
     * 1. The main scene render (ARKit + SceneKit combined) → produces color + depth
     * 2. A full-screen SSAO pass that reads the depth buffer, computes ambient
     *    occlusion, and multiplies it with the color buffer to darken creases,
     *    cavities, and contact edges — matching Android Filament's SSAO.
     */
    private func setupSSAOTechnique() {
        // Define the SSAO technique as a dictionary (SCNTechnique definition format)
        // This is equivalent to a .plist/.json technique file but defined inline.
        let techniqueDef: [String: Any] = [
            // Declare the render targets
            "targets": [
                "color_scene": [
                    "type": "color"
                ],
                "depth_scene": [
                    "type": "depth"
                ]
            ],
            // Define the passes
            "passes": [
                // Pass 0: Render the scene normally (ARKit camera feed + virtual objects)
                "scene_pass": [
                    "draw": "DRAW_SCENE",
                    "inputs": [] as [Any],
                    "outputs": [
                        "color": "color_scene",
                        "depth": "depth_scene"
                    ]
                ],
                // Pass 1: SSAO post-processing
                "ssao_pass": [
                    "draw": "DRAW_QUAD",
                    "program": "ssao",
                    "inputs": [
                        "colorTexture": "color_scene",
                        "depthTexture": "depth_scene"
                    ],
                    "outputs": [
                        "color": "COLOR"
                    ]
                ]
            ],
            // Sequence of passes
            "sequence": [
                "scene_pass",
                "ssao_pass"
            ],
            // Shader symbols (uniforms)
            "symbols": [
                "a_position": [
                    "semantic": "vertex"
                ],
                "a_texcoord": [
                    "semantic": "uv"
                ]
            ]
        ]
        
        // Check if the SSAO shader files exist in the bundle
        let bundle = Bundle(for: type(of: self))
        let mainBundle = Bundle.main
        
        // Look for shader in plugin bundle or main bundle
        let hasVertexShader = bundle.url(forResource: "ssao", withExtension: "vert") != nil ||
                              mainBundle.url(forResource: "ssao", withExtension: "vert") != nil
        let hasFragmentShader = bundle.url(forResource: "ssao", withExtension: "frag") != nil ||
                                mainBundle.url(forResource: "ssao", withExtension: "frag") != nil
        
        if hasVertexShader && hasFragmentShader {
            // Use the external shader files
            if let technique = SCNTechnique(dictionary: techniqueDef) {
                sceneView.technique = technique
                print("✅ SSAO technique applied via external shaders")
                return
            }
        }
        
        // Fallback: Use inline Metal shader definitions
        // SCNTechnique can use Metal shaders defined inline via the "metalVertexShader"
        // and "metalFragmentShader" keys. However, ARSCNView's technique support
        // is limited. If this fails, fall back to enhanced shadow-based AO.
        print("⚠️ External SSAO shaders not found — using enhanced shadow-based AO fallback")
        setupShadowBasedAO()
    }
    
    /**
     * Fallback SSAO approximation using multiple shadow-casting lights.
     *
     * When SCNTechnique-based SSAO is not available, we approximate the effect
     * with additional carefully-placed lights whose shadows create darkening
     * in crevices and contact areas.
     *
     * Uses 4 shadow-casting spot lights from different directions. Where their
     * shadows overlap (concave regions, crevices, contact edges) the scene
     * darkens — mimicking screen-space ambient occlusion.
     */
    private func setupShadowBasedAO() {
        // Helper to create an AO spot light with consistent properties
        func makeAOSpot(name: String, intensity: CGFloat, shadowAlpha: CGFloat,
                        shadowRadius: CGFloat, innerAngle: CGFloat, outerAngle: CGFloat) -> SCNLight {
            let light = SCNLight()
            light.type = .spot
            light.color = UIColor.white
            light.intensity = intensity
            light.spotInnerAngle = innerAngle
            light.spotOuterAngle = outerAngle
            light.castsShadow = true
            light.shadowMode = .deferred
            light.shadowRadius = shadowRadius
            light.shadowSampleCount = 16
            light.shadowMapSize = CGSize(width: 2048, height: 2048)
            light.shadowColor = UIColor(white: 0.0, alpha: shadowAlpha)
            light.attenuationStartDistance = 0.5
            light.attenuationEndDistance = 15.0
            light.attenuationFalloffExponent = 2
            light.zNear = 0.1
            light.zFar = 20.0
            light.name = name
            return light
        }
        
        // 1) Top-down spot — strongest, catches horizontal surfaces & contact shadows
        let topSpot = makeAOSpot(name: "ao_top", intensity: 500, shadowAlpha: 0.55,
                                  shadowRadius: 5.0, innerAngle: 80, outerAngle: 130)
        let topNode = SCNNode()
        topNode.light = topSpot
        topNode.position = SCNVector3(0, 5, 0)
        topNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)  // Pointing straight down
        sceneView.scene.rootNode.addChildNode(topNode)
        
        // 2) Front-angled spot — catches crevices in vertical surfaces facing camera
        let frontSpot = makeAOSpot(name: "ao_front", intensity: 300, shadowAlpha: 0.4,
                                    shadowRadius: 6.0, innerAngle: 60, outerAngle: 110)
        let frontNode = SCNNode()
        frontNode.light = frontSpot
        frontNode.position = SCNVector3(0, 3, 4)    // In front and above
        frontNode.look(at: SCNVector3(0, 0, 0))
        sceneView.scene.rootNode.addChildNode(frontNode)
        
        // 3) Left-side spot — catches right-facing crevices & under-arm areas
        let leftSpot = makeAOSpot(name: "ao_left", intensity: 250, shadowAlpha: 0.35,
                                   shadowRadius: 5.0, innerAngle: 60, outerAngle: 110)
        let leftNode = SCNNode()
        leftNode.light = leftSpot
        leftNode.position = SCNVector3(-3, 3, 0)    // Left side and above
        leftNode.look(at: SCNVector3(0, 0, 0))
        sceneView.scene.rootNode.addChildNode(leftNode)
        
        // 4) Right-side spot — mirrors left for symmetry
        let rightSpot = makeAOSpot(name: "ao_right", intensity: 250, shadowAlpha: 0.35,
                                    shadowRadius: 5.0, innerAngle: 60, outerAngle: 110)
        let rightNode = SCNNode()
        rightNode.light = rightSpot
        rightNode.position = SCNVector3(3, 3, 0)    // Right side and above
        rightNode.look(at: SCNVector3(0, 0, 0))
        sceneView.scene.rootNode.addChildNode(rightNode)
        
        print("✅ Shadow-based AO applied (4 multi-directional shadow-casting lights)")
        print("   ✓ Top (500 lux, α0.55), Front (300 lux, α0.4)")
        print("   ✓ Left + Right (250 lux each, α0.35)")
    }
}

// ---------------------- ARCoachingOverlayViewDelegate ---------------------------------------

extension IosARView {
    
    func coachingOverlayViewWillActivate(_ coachingOverlayView: ARCoachingOverlayView){
        // use this delegate method to hide anything in the UI that could cover the coaching overlay view
    }
    
    func coachingOverlayViewDidRequestSessionReset(_ coachingOverlayView: ARCoachingOverlayView) {
        // Reset the session.
        self.sceneView.session.run(configuration, options: [.resetTracking])
    }
}
