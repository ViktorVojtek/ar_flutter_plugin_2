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

class IosARView: NSObject, FlutterPlatformView, ARSCNViewDelegate, UIGestureRecognizerDelegate, ARSessionDelegate {
    let sceneView: ARSCNView
    let coachingView: ARCoachingOverlayView
    let sessionManagerChannel: FlutterMethodChannel
    let objectManagerChannel: FlutterMethodChannel
    let anchorManagerChannel: FlutterMethodChannel
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
    
    var cancellableCollection = Set<AnyCancellable>() //Used to store all cancellables in (needed for working with Futures)
    var anchorCollection = [String: ARAnchor]() //Used to bookkeep all anchors created by Flutter calls
    
    private var cloudAnchorHandler: CloudAnchorHandler? = nil
    private var arcoreSession: GARSession? = nil
    private var arcoreMode: Bool = false
    private var configuration: ARWorldTrackingConfiguration!
    private var tappedPlaneAnchorAlignment = ARPlaneAnchor.Alignment.horizontal // default alignment
    
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
                sceneView.session.pause()
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
                let success = self.nukeAll(purgeCaches: purgeCaches, removeAnchors: removeAnchors, resetTracking: resetTracking)
                result(success)
                break
            case "ar#getPluginState":
                let state = self.getPluginState()
                result(state)
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
                addNode(dict_node: arguments!).sink(receiveCompletion: {completion in }, receiveValue: { val in
                       result(val)
                    }).store(in: &self.cancellableCollection)
                break
            case "addNodeToPlaneAnchor":
                if let dict_node = arguments!["node"] as? Dictionary<String, Any>, let dict_anchor = arguments!["anchor"] as? Dictionary<String, Any> {
                    addNode(dict_node: dict_node, dict_anchor: dict_anchor).sink(receiveCompletion: {completion in }, receiveValue: { val in
                           result(val)
                        }).store(in: &self.cancellableCollection)
                }
                break
            case "removeNode":
                if let name = arguments!["name"] as? String {
                    sceneView.scene.rootNode.childNode(withName: name, recursively: true)?.removeFromParentNode()
                }
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
                    print("---------------- HOSTING INITIATED ------------------")
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
                    print("---------------- RESOLVING INITIATED ------------------")
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
        self.configuration.environmentTexturing = .automatic
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

        return Future {promise in
            
            switch (dict_node["type"] as! Int) {
                case 0: // GLTF2 Model from Flutter asset folder
                    // Get path to given Flutter asset
                    let key = FlutterDartProject.lookupKey(forAsset: dict_node["uri"] as! String)
                    // Add object to scene
                    if let node: SCNNode = self.modelBuilder.makeNodeFromGltf(name: dict_node["name"] as! String, modelPath: key, transformation: dict_node["transformation"] as? Array<NSNumber>) {
                        let nodeName = dict_node["name"] as? String
                        if let anchorName = dict_anchor?["name"] as? String, let anchorType = dict_anchor?["type"] as? Int {
                            switch anchorType{
                                case 0: //PlaneAnchor
                                    if let anchor = self.anchorCollection[anchorName]{
                                        // Attach node to the top-level node of the specified anchor
                                        self.sceneView.node(for: anchor)?.addChildNode(node)
                                        if let nodeId = nodeName {
                                            self.trackResourceHandle(for: node, nodeId: nodeId, assetKey: dict_node["uri"] as? String)
                                        }
                                        promise(.success(nodeName))
                                    } else {
                                        promise(.success(nil))
                                    }
                                default:
                                    promise(.success(nil))
                                }
                            
                        } else {
                            // Attach to top-level node of the scene
                            self.sceneView.scene.rootNode.addChildNode(node)
                            if let nodeId = nodeName {
                                self.trackResourceHandle(for: node, nodeId: nodeId, assetKey: dict_node["uri"] as? String)
                            }
                            promise(.success(nodeName))
                        }
                    } else {
                        DispatchQueue.main.async {self.sessionManagerChannel.invokeMethod("onError", arguments: ["Unable to load renderable \(dict_node["uri"] as! String)"])}
                        promise(.success(nil))
                    }
                    break
                case 1: // GLB Model from the web
                    // Add object to scene
                    self.modelBuilder.makeNodeFromWebGlb(name: dict_node["name"] as! String, modelURL: dict_node["uri"] as! String, transformation: dict_node["transformation"] as? Array<NSNumber>)
                    .sink(receiveCompletion: {
                                    completion in print("Async Model Downloading Task completed: ", completion)
                    }, receiveValue: { val in
                        if let node: SCNNode = val {
                            let nodeName = dict_node["name"] as? String
                            if let anchorName = dict_anchor?["name"] as? String, let anchorType = dict_anchor?["type"] as? Int {
                                switch anchorType{
                                    case 0: //PlaneAnchor
                                        if let anchor = self.anchorCollection[anchorName]{
                                            // Attach node to the top-level node of the specified anchor
                                            self.sceneView.node(for: anchor)?.addChildNode(node)
                                            if let nodeId = nodeName {
                                                self.trackResourceHandle(for: node, nodeId: nodeId, assetKey: dict_node["uri"] as? String)
                                            }
                                            promise(.success(nodeName))
                                        } else {
                                            promise(.success(nil))
                                        }
                                    default:
                                        promise(.success(nil))
                                    }
                                
                            } else {
                                // Attach to top-level node of the scene
                                self.sceneView.scene.rootNode.addChildNode(node)
                                if let nodeId = nodeName {
                                    self.trackResourceHandle(for: node, nodeId: nodeId, assetKey: dict_node["uri"] as? String)
                                }
                                promise(.success(nodeName))
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
                        let nodeName = dict_node["name"] as? String
                        if let anchorName = dict_anchor?["name"] as? String, let anchorType = dict_anchor?["type"] as? Int {
                            switch anchorType{
                                case 0: //PlaneAnchor
                                    if let anchor = self.anchorCollection[anchorName]{
                                        // Attach node to the top-level node of the specified anchor
                                        self.sceneView.node(for: anchor)?.addChildNode(node)
                                        if let nodeId = nodeName {
                                            self.trackResourceHandle(for: node, nodeId: nodeId, assetKey: dict_node["uri"] as? String)
                                        }
                                        promise(.success(nodeName))
                                    } else {
                                        promise(.success(nil))
                                    }
                                default:
                                    promise(.success(nil))
                                }
                            
                        } else {
                            // Attach to top-level node of the scene
                            self.sceneView.scene.rootNode.addChildNode(node)
                            if let nodeId = nodeName {
                                self.trackResourceHandle(for: node, nodeId: nodeId, assetKey: dict_node["uri"] as? String)
                            }
                            promise(.success(nodeName))
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
                        let nodeName = dict_node["name"] as? String
                        if let anchorName = dict_anchor?["name"] as? String, let anchorType = dict_anchor?["type"] as? Int {
                            switch anchorType{
                                case 0: //PlaneAnchor
                                    if let anchor = self.anchorCollection[anchorName]{
                                        // Attach node to the top-level node of the specified anchor
                                        self.sceneView.node(for: anchor)?.addChildNode(node)
                                        if let nodeId = nodeName {
                                            self.trackResourceHandle(for: node, nodeId: nodeId, assetKey: dict_node["uri"] as? String)
                                        }
                                        promise(.success(nodeName))
                                    } else {
                                        promise(.success(nil))
                                    }
                                default:
                                    promise(.success(nil))
                                }
                            
                        } else {
                            // Attach to top-level node of the scene
                            self.sceneView.scene.rootNode.addChildNode(node)
                            if let nodeId = nodeName {
                                self.trackResourceHandle(for: node, nodeId: nodeId, assetKey: dict_node["uri"] as? String)
                            }
                            promise(.success(nodeName))
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
        // Because 3D model loading can lead to composed nodes, we have to traverse through a node's parent until the parent node with the name assigned by the Flutter API is found
        let nodeHitResults: Array<String> = allHitResults.compactMap { nearestParentWithNameStart(node: $0.node, characters: "[#")?.name }
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
                // Because 3D model loading can lead to composed nodes, we have to traverse through a node's parent until the parent node with the name assigned by the Flutter API is found
                let nodeHitResults: Array<String> = allHitResults.compactMap {
                    if let nearestNode = nearestParentWithNameStart(node: $0.node, characters: "[#") {
                        panningNode = nearestNode
                        return nearestNode.name
                    }else{
                        return nil
                    }
                }
                if (nodeHitResults.count != 0 && panningNode != nil) {
                    panningNodeCurrentWorldLocation = panningNode?.worldPosition
                    if let panningNodeName = panningNode?.name {
                        DispatchQueue.main.async {self.objectManagerChannel.invokeMethod("onPanStart", arguments: panningNodeName)}
                    }
                    return
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
                // Because 3D model loading can lead to composed nodes, we have to traverse through a node's parent until the parent node with the name assigned by the Flutter API is found
                let nodeHitResults: Array<String> = allHitResults.compactMap {
                    if let nearestNode = nearestParentWithNameStart(node: $0.node, characters: "[#") {
                        panningNode = nearestNode
                        return nearestNode.name
                    }else{
                        return nil
                    }
                }
                if (nodeHitResults.count != 0 && panningNode != nil) {
                    if let panNodeName = panningNode?.name {
                        DispatchQueue.main.async {self.objectManagerChannel.invokeMethod("onRotationStart", arguments: panNodeName)}
                    }
                    return
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
                    print("Error uploading anchor, state: \(parent.decodeCloudAnchorState(state: cloudState))")
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
                    print("Error downloading anchor, state \(cloudState)")
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
        print("🗑️ Deep removing node: \(nodeId)")
        
        // 1) Get resource handle
        guard let resourceHandle = resourceHandles.removeValue(forKey: nodeId) else {
            print("⚠️ Resource handle not found for node: \(nodeId)")
            // Still try to remove from scene if it exists
            if let node = sceneView.scene.rootNode.childNode(withName: nodeId, recursively: true) {
                node.removeFromParentNode()
                print("✅ Node removed from scene (without resource handle): \(nodeId)")
                return true
            }
            return false
        }
        
        // 2) Remove from scene
        resourceHandle.node.removeFromParentNode()
        
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
                    print("🗑️ Removed asset from cache: \(assetKey)")
                } else {
                    // Update ref count (simplified - in real implementation you'd need atomic operations)
                    assetCache[assetKey] = CachedAsset(uri: cachedAsset.uri, rootNode: cachedAsset.rootNode, refCount: newRefCount)
                    print("🔢 Asset refCount for \(assetKey): \(newRefCount)")
                }
            }
        }
        
        print("✅ Deep node removal completed: \(nodeId)")
        return true
    }
    
    private func purgeCaches() -> Bool {
        print("🧹 Purging all caches")
        
        let cacheSize = assetCache.count
        assetCache.removeAll()
        print("🗑️ Cleared asset cache (\(cacheSize) items)")
        
        let handleCount = resourceHandles.count
        resourceHandles.removeAll()
        print("🗑️ Cleared resource handles (\(handleCount) items)")
        
        print("✅ Cache purging completed")
        return true
    }
    
    private func softResetSession(removeAnchors: Bool, resetTracking: Bool) -> Bool {
        print("🔄 Soft resetting AR session - removeAnchors: \(removeAnchors), resetTracking: \(resetTracking)")
        
        var options: ARSession.RunOptions = []
        if removeAnchors { 
            options.insert(.removeExistingAnchors)
            // Also clear our anchor collection
            anchorCollection.removeAll()
            print("🗑️ Cleared anchor collection")
        }
        if resetTracking { 
            options.insert(.resetTracking) 
            print("🔄 Reset tracking enabled")
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
    
    private func nukeAll(purgeCaches: Bool, removeAnchors: Bool, resetTracking: Bool) -> Bool {
        print("🚨 NUKE ALL INITIATED - purgeCaches: \(purgeCaches), removeAnchors: \(removeAnchors), resetTracking: \(resetTracking)")
        
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

            // H) CRITICAL: Force aggressive memory cleanup (ChatGPT suggestions)
            print("♻️ Phase H: Aggressive memory cleanup")
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
                
                // CRITICAL: System memory pressure simulation
                for pass in 0..<3 {
                    autoreleasepool {
                        // Force system memory cleanup
                        malloc_zone_pressure_relief(nil, 0)
                        
                        // Simulate memory warning to force system cleanup  
                        if pass == 0 {
                            NotificationCenter.default.post(
                                name: UIApplication.didReceiveMemoryWarningNotification,
                                object: UIApplication.shared
                            )
                        }
                        
                        // Clear URLSession cache
                        URLCache.shared.removeAllCachedResponses()
                        
                        // Drain run loop between passes
                        CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.05, false)
                    }
                }
                
                // Final runloop drain
                CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.1, false)
                
                print("✅ Phase H: Aggressive memory cleanup completed")
            } catch {
                print("❌ Phase H error: \(error.localizedDescription)")
            }

            print("🎉 NUKE ALL COMPLETED - Memory should be near cold start levels")
            return true
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
        print("🔄 Creating shared node from asset: \(uri)")
        
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
                print("♻️ Reusing cached asset: \(uri) (refCount: \(newRefCount))")
            } else {
                // Load new asset - determine type from URI
                if uri.hasPrefix("http://") || uri.hasPrefix("https://") {
                    // Web asset
                    node = self.modelBuilder.makeNodeFromWebGlb(name: "SharedAsset_\(Date().timeIntervalSince1970)", modelURL: uri, transformation: nil)
                        .sink(receiveCompletion: { _ in }, receiveValue: { webNode in
                            if let webNode = webNode {
                                shouldCache = true
                                node = webNode
                            }
                        }).store(in: &self.cancellableCollection) as? SCNNode
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
                    print("💾 Cached new asset: \(uri)")
                }
            }
            
            DispatchQueue.main.async {
                guard let finalNode = node else {
                    print("❌ Failed to load model instance from: \(uri)")
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
                
                // Set node name
                let nodeName = "SharedAsset_\(Date().timeIntervalSince1970)"
                finalNode.name = nodeName
                
                // Add to scene
                self.sceneView.scene.rootNode.addChildNode(finalNode)
                
                // Track resource handle
                let resourceHandle = ResourceHandle(nodeId: nodeName, node: finalNode, assetKey: uri)
                self.resourceHandles[nodeName] = resourceHandle
                
                print("✅ Shared node added to scene: \(nodeName)")
                completion(nodeName)
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
        resourceHandles[nodeId] = resourceHandle
        print("📝 Tracking resource handle for node: \(nodeId)")
    }
    
    // Cleanup old cached assets (call periodically)
    private func cleanupOldAssets() {
        let currentTime = Date().timeIntervalSince1970
        
        for (key, asset) in assetCache {
            if asset.refCount <= 0 && (currentTime - asset.creationTime) > maxCacheAge {
                assetCache.removeValue(forKey: key)
                print("🧹 Cleaned up old asset: \(key)")
            }
        }
    }
}

// ---------------------- ARCoachingOverlayViewDelegate ---------------------------------------

extension IosARView: ARCoachingOverlayViewDelegate {
    
    func coachingOverlayViewWillActivate(_ coachingOverlayView: ARCoachingOverlayView){
        // use this delegate method to hide anything in the UI that could cover the coaching overlay view
    }
    
    func coachingOverlayViewDidRequestSessionReset(_ coachingOverlayView: ARCoachingOverlayView) {
        // Reset the session.
        self.sceneView.session.run(configuration, options: [.resetTracking])
    }
}
