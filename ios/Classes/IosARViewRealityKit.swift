import Flutter
import UIKit
import Foundation
import ARKit
import RealityKit
import Combine
import ModelIO
import ARCoreCloudAnchors

/// RealityKit-based AR view implementation with automatic depth occlusion
/// Replaces SceneKit (ARSCNView) with RealityKit (ARView) for better performance and automatic LiDAR occlusion
@available(iOS 13.0, *)
class IosARViewRealityKit: NSObject, FlutterPlatformView, ARSessionDelegate {
    
    // MARK: - Core Properties
    
    let arView: ARView
    let coachingView: ARCoachingOverlayView
    let sessionManagerChannel: FlutterMethodChannel
    let objectManagerChannel: FlutterMethodChannel
    let anchorManagerChannel: FlutterMethodChannel
    
    // MARK: - State Management
    
    var showPlanes = false
    var planeCount = 0
    var customPlaneTexturePath: String? = nil
    var trackedPlanes = [UUID: (AnchorEntity, ModelEntity)]()
    
    // Entity management (replaces SCNNode management)
    var entityCollection = [String: Entity]()
    var anchorCollection = [String: ARAnchor]()
    var anchorEntityCollection = [String: AnchorEntity]()
    
    // Resource management
    var assetCache = [String: Entity]()
    let maxCacheAge: TimeInterval = 300.0
    let loadingQueue = DispatchQueue(label: "ar.model.loading", qos: .userInitiated)
    
    // Gesture management
    var selectedEntity: Entity?
    var panGesture: UIPanGestureRecognizer?
    var rotationGesture: UIRotationGestureRecognizer?
    var pinchGesture: UIPinchGestureRecognizer?
    
    // Light estimation monitoring
    var isMonitoringLighting = false
    var lightingCheckTimer: Timer?
    var lightingCheckInterval: TimeInterval = 1.0
    
    // Depth occlusion state
    var depthOcclusionEnabled = true
    
    // Configurable gesture settings (set at init time only)
    var debugGesturesEnabled = false  // Enable verbose gesture logging for development
    var maxPanDistanceMeters: Float = 5.0  // Maximum distance from camera for pan gestures (default 5m)
    
    // Configuration
    var configuration: ARWorldTrackingConfiguration!
    
    // Cloud Anchors
    private var cloudAnchorHandler: CloudAnchorHandler?
    private var arcoreSession: GARSession?
    private var arcoreMode: Bool = false
    
    // Combine subscriptions
    var cancellableCollection = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    init(
        frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?,
        binaryMessenger messenger: FlutterBinaryMessenger
    ) {
        // Initialize ARView with default frame semantics
        self.arView = ARView(frame: frame)
        self.coachingView = ARCoachingOverlayView(frame: frame)
        
        // Initialize method channels
        self.sessionManagerChannel = FlutterMethodChannel(
            name: "arsession_\(viewId)",
            binaryMessenger: messenger
        )
        self.objectManagerChannel = FlutterMethodChannel(
            name: "arobjects_\(viewId)",
            binaryMessenger: messenger
        )
        self.anchorManagerChannel = FlutterMethodChannel(
            name: "aranchors_\(viewId)",
            binaryMessenger: messenger
        )
        
        super.init()
        
        // Configure ARView
        setupARView()
        
        // Setup method channel handlers
        self.sessionManagerChannel.setMethodCallHandler(self.onSessionMethodCalled)
        self.objectManagerChannel.setMethodCallHandler(self.onObjectMethodCalled)
        self.anchorManagerChannel.setMethodCallHandler(self.onAnchorMethodCalled)
        
        // Setup coaching overlay
        setupCoachingOverlay()
        
        print("✅ RealityKit ARView initialized")
    }
    
    // MARK: - Setup Methods
    
    private func setupARView() {
        // Configure environment for realistic rendering
        arView.environment.background = .cameraFeed()
        
        // RealityKit automatically manages lighting based on ARKit light estimation
        // No need to explicitly enable it like in SceneKit
        
        // Set session delegate
        arView.session.delegate = self
        
        // Start with default configuration
        let configuration = ARWorldTrackingConfiguration()
        arView.session.run(configuration)
        
        print("✅ ARView configured with camera feed")
    }
    
    private func setupCoachingOverlay() {
        // Configure coaching overlay
        coachingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        coachingView.session = arView.session
        coachingView.goal = .horizontalPlane
        coachingView.delegate = self
        
        print("✅ Coaching overlay configured")
    }
    
    // MARK: - FlutterPlatformView
    
    func view() -> UIView {
        return self.arView
    }
    
    func onDispose(_ result: FlutterResult) {
        print("🧹 Disposing RealityKit ARView...")
        
        // Pause AR session
        arView.session.pause()
        
        // Clear all entities
        arView.scene.anchors.removeAll()
        entityCollection.removeAll()
        anchorCollection.removeAll()
        anchorEntityCollection.removeAll()
        trackedPlanes.removeAll()
        assetCache.removeAll()
        
        // Stop lighting monitoring
        stopLightingMonitoring()
        
        // Clear cancellables
        cancellableCollection.removeAll()
        
        // Clear method channel handlers
        sessionManagerChannel.setMethodCallHandler(nil)
        objectManagerChannel.setMethodCallHandler(nil)
        anchorManagerChannel.setMethodCallHandler(nil)
        
        print("✅ RealityKit ARView disposed")
        result(nil)
    }
    
    // MARK: - Session Method Handler
    
    func onSessionMethodCalled(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let arguments = call.arguments as? Dictionary<String, Any>
        
        switch call.method {
        case "init":
            initializeARView(arguments: arguments!, result: result)
            
        case "getCameraPose":
            if let cameraPose = arView.session.currentFrame?.camera.transform {
                result(serializeMatrix(cameraPose))
            } else {
                result(FlutterError(code: "NO_FRAME", message: "Camera pose not available", details: nil))
            }
            
        case "getAnchorPose":
            if let anchorId = arguments?["anchorId"] as? String,
               let anchor = anchorCollection[anchorId] {
                result(serializeMatrix(anchor.transform))
            } else {
                result(FlutterError(code: "NO_ANCHOR", message: "Anchor not found", details: nil))
            }
            
        case "snapshot":
            takeSnapshot(result: result)
            
        case "dispose":
            onDispose(result)
            
        case "showPlanes":
            if let showPlanesArgument = arguments?["showPlanes"] as? Bool {
                showPlanes = showPlanesArgument
            } else {
                showPlanes = false
            }
            updatePlaneVisibility()
            result(nil)
            
        case "softResetSession":
            let removeAnchors = arguments?["removeExistingAnchors"] as? Bool ?? true
            let resetTracking = arguments?["resetTracking"] as? Bool ?? true
            let success = softResetSession(removeAnchors: removeAnchors, resetTracking: resetTracking)
            result(success)
            
        case "ar#nukeAll":
            let purgeCaches = arguments?["purgeCaches"] as? Bool ?? true
            let removeAnchors = arguments?["removeExistingAnchors"] as? Bool ?? true
            let resetTracking = arguments?["resetTracking"] as? Bool ?? true
            let success = nukeAll(
                purgeCaches: purgeCaches,
                removeAnchors: removeAnchors,
                resetTracking: resetTracking
            )
            result(success)
            
        case "ar#nukeAllNonBlocking":
            let purgeCaches = arguments?["purgeCaches"] as? Bool ?? true
            let removeAnchors = arguments?["removeExistingAnchors"] as? Bool ?? true
            let resetTracking = arguments?["resetTracking"] as? Bool ?? false
            nukeAllNonBlocking(
                purgeCaches: purgeCaches,
                removeAnchors: removeAnchors,
                resetTracking: resetTracking
            )
            result(true)
            
        case "ar#getPluginState":
            let state = getPluginState()
            result(state)
            
        case "getLightEstimate":
            getLightEstimate(result: result)
            
        case "enableLightingMonitoring":
            enableLightingMonitoring(arguments: arguments, result: result)
            
        case "isDepthSupported":
            isDepthSupported(result: result)
            
        case "enableDepthOcclusion":
            if let enable = arguments?["enable"] as? Bool {
                enableDepthOcclusion(enable: enable, result: result)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "enable parameter required", details: nil))
            }
            
        case "isDepthOcclusionEnabled":
            result(self.depthOcclusionEnabled)
            
        case "acquireDepthImage":
            acquireDepthImage(result: result)
            
        // MARK: - People Occlusion Methods
        case "isPeopleOcclusionSupported":
            print("📞 isPeopleOcclusionSupported called from Flutter")
            isPeopleOcclusionSupported(result: result)
            
        case "enablePeopleOcclusion":
            print("📞 enablePeopleOcclusion called from Flutter")
            if let enable = arguments?["enable"] as? Bool {
                enablePeopleOcclusion(enable: enable, result: result)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "enable parameter required", details: nil))
            }
            
        case "isPeopleOcclusionEnabled":
            print("📞 isPeopleOcclusionEnabled called from Flutter")
            isPeopleOcclusionEnabled(result: result)
            
        case "showDebugMesh":
            print("📞 showDebugMesh called from Flutter")
            if let show = arguments?["show"] as? Bool {
                showDebugMesh(show: show, result: result)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "show parameter required", details: nil))
            }
            
        default:
            print("⚠️ Unknown method called: \(call.method)")
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - AR Session Initialization
    
    func initializeARView(arguments: Dictionary<String, Any>, result: FlutterResult) {
        print("🚀 Initializing RealityKit ARView with arguments: \(arguments)")
        
        // Create configuration
        self.configuration = ARWorldTrackingConfiguration()
        
        // Enable automatic environment texturing
        self.configuration.environmentTexturing = .automatic
        
        // Enable light estimation
        self.configuration.isLightEstimationEnabled = true
        
        // MARK: - Depth API Configuration (AUTOMATIC OCCLUSION!)
        if #available(iOS 14.0, *) {
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                // Enable scene depth for data access
                self.configuration.frameSemantics.insert(.sceneDepth)
                
                // ✅ ENABLE AUTOMATIC DEPTH OCCLUSION (RealityKit magic!)
                self.arView.environment.sceneUnderstanding.options = [.occlusion, .receivesLighting]
                self.depthOcclusionEnabled = true
                
                print("✅ RealityKit Depth Occlusion ENABLED (automatic LiDAR occlusion)")
            } else {
                self.depthOcclusionEnabled = false
                print("⚠️ Depth occlusion not available on this device (requires LiDAR)")
            }
        } else {
            self.depthOcclusionEnabled = false
            print("⚠️ Depth occlusion requires iOS 14.0+")
        }
        
        // Configure plane detection
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
        
        // Configure plane rendering
        if let configShowPlanes = arguments["showPlanes"] as? Bool {
            showPlanes = configShowPlanes
        }
        
        // Setup gesture recognizers
        if let configHandleTaps = arguments["handleTaps"] as? Bool, configHandleTaps {
            setupTapGesture()
        }
        
        if let configHandlePans = arguments["handlePans"] as? Bool, configHandlePans {
            setupPanGesture()
        }
        
        if let configHandleRotation = arguments["handleRotation"] as? Bool, configHandleRotation {
            setupRotationGesture()
        }
        
        // Parse gesture configuration (set once at init)
        if let configDebugGestures = arguments["debugGestures"] as? Bool {
            debugGesturesEnabled = configDebugGestures
        }
        if let configMaxPanDistance = arguments["maxPanDistance"] as? Double {
            maxPanDistanceMeters = Float(configMaxPanDistance)
        }
        
        if debugGesturesEnabled {
            print("🔧 Gesture debug mode ENABLED")
            print("🔧 Max pan distance: \(maxPanDistanceMeters)m")
        }
        
        // Add coaching overlay if requested
        if let configShowAnimatedGuide = arguments["showAnimatedGuide"] as? Bool, configShowAnimatedGuide {
            if arView.superview != nil && coachingView.superview == nil {
                arView.addSubview(coachingView)
                coachingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            }
        }
        
        // Run AR session
        arView.session.run(configuration)
        
        print("✅ RealityKit ARView initialized successfully")
        result(nil)
    }
    
    // MARK: - Session Management
    
    private func softResetSession(removeAnchors: Bool, resetTracking: Bool) -> Bool {
        print("🔄 Soft reset session - removeAnchors: \(removeAnchors), resetTracking: \(resetTracking)")
        
        if removeAnchors {
            // Remove all anchors
            arView.scene.anchors.removeAll()
            anchorCollection.removeAll()
            anchorEntityCollection.removeAll()
            entityCollection.removeAll()
        }
        
        if resetTracking {
            // Reset tracking
            arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        } else {
            // Just restart without resetting tracking
            arView.session.run(configuration)
        }
        
        return true
    }
    
    private func nukeAll(purgeCaches: Bool, removeAnchors: Bool, resetTracking: Bool) -> Bool {
        print("💣 Nuke all - purgeCaches: \(purgeCaches), removeAnchors: \(removeAnchors), resetTracking: \(resetTracking)")
        
        if purgeCaches {
            assetCache.removeAll()
        }
        
        if removeAnchors {
            arView.scene.anchors.removeAll()
            anchorCollection.removeAll()
            anchorEntityCollection.removeAll()
            entityCollection.removeAll()
            trackedPlanes.removeAll()
        }
        
        if resetTracking {
            arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        }
        
        return true
    }
    
    private func nukeAllNonBlocking(purgeCaches: Bool, removeAnchors: Bool, resetTracking: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            _ = self.nukeAll(purgeCaches: purgeCaches, removeAnchors: removeAnchors, resetTracking: resetTracking)
        }
    }
    
    private func getPluginState() -> [String: Any] {
        return [
            "entityCount": entityCollection.count,
            "anchorCount": anchorCollection.count,
            "planeCount": planeCount,
            "cacheSize": assetCache.count,
            "depthOcclusionEnabled": depthOcclusionEnabled
        ]
    }
    
    // MARK: - Snapshot
    
    private func takeSnapshot(result: @escaping FlutterResult) {
        arView.snapshot(saveToHDR: false) { (image) in
            guard let image = image else {
                result(FlutterError(code: "SNAPSHOT_FAILED", message: "Failed to capture snapshot", details: nil))
                return
            }
            
            if let pngData = image.pngData() {
                let data = FlutterStandardTypedData(bytes: pngData)
                result(data)
            } else {
                result(nil)
            }
        }
    }
    
    // MARK: - Plane Visualization
    
    private func updatePlaneVisibility() {
        for (_, (_, planeEntity)) in trackedPlanes {
            planeEntity.isEnabled = showPlanes
        }
    }
    
    // MARK: - Object (Entity) Management Methods
    
    func onObjectMethodCalled(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let arguments = call.arguments as? Dictionary<String, Any>
        
        print("🔵 onObjectMethodCalled: \(call.method)")
        
        switch call.method {
        case "init":
            DispatchQueue.main.async {
                self.objectManagerChannel.invokeMethod("onError", arguments: ["🎯 RealityKit from iOS"])
            }
            result(nil)
            
        case "addNode":
            print("🔵 addNode case matched")
            addNode(dict_node: arguments!, result: result)
            
        case "addNodeToPlaneAnchor":
            print("🔵 addNodeToPlaneAnchor case matched")
            DispatchQueue.main.async {
                self.objectManagerChannel.invokeMethod("onError", arguments: ["🔵 addNodeToPlaneAnchor called!"])
            }
            // Handle node placement with anchor (same as addNode with anchor data)
            if let dict_node = arguments?["node"] as? Dictionary<String, Any>,
               let dict_anchor = arguments?["anchor"] as? Dictionary<String, Any> {
                print("🔵 Calling addNodeWithAnchor")
                DispatchQueue.main.async {
                    self.objectManagerChannel.invokeMethod("onError", arguments: ["🔵 About to call addNodeWithAnchor"])
                }
                addNodeWithAnchor(dict_node: dict_node, dict_anchor: dict_anchor, result: result)
            } else {
                print("❌ Missing node or anchor in arguments")
                DispatchQueue.main.async {
                    self.objectManagerChannel.invokeMethod("onError", arguments: ["❌ Missing node or anchor"])
                }
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Both node and anchor required", details: nil))
            }
            
        case "removeNode":
            if let nodeName = arguments?["name"] as? String {
                removeNode(nodeName: nodeName)
            }
            // Note: removeNode does not return a result (legacy behavior)
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - Anchor Management Methods
    
    func onAnchorMethodCalled(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let arguments = call.arguments as? Dictionary<String, Any>
        
        switch call.method {
        case "init":
            DispatchQueue.main.async {
                self.anchorManagerChannel.invokeMethod("onError", arguments: ["AnchorTEST from iOS"])
            }
            result(nil)
            
        case "addAnchor":
            addAnchor(arguments: arguments!, result: result)
            
        case "removeAnchor":
            if let anchorName = arguments?["name"] as? String {
                removeAnchor(anchorName: anchorName)
            }
            // Note: removeAnchor does not return a result (legacy behavior)
            
        case "downloadAnchor":
            if let anchorId = arguments?["cloudanchorid"] as? String {
                // Cloud anchors support - to be implemented
                print("⚠️ Cloud anchors not yet implemented in RealityKit version")
                result(FlutterError(code: "NOT_IMPLEMENTED", message: "Cloud anchors coming soon", details: nil))
            }
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - Utility Methods
    
    private func serializeMatrix(_ matrix: simd_float4x4) -> [NSNumber] {
        return [
            NSNumber(value: matrix.columns.0.x), NSNumber(value: matrix.columns.0.y),
            NSNumber(value: matrix.columns.0.z), NSNumber(value: matrix.columns.0.w),
            NSNumber(value: matrix.columns.1.x), NSNumber(value: matrix.columns.1.y),
            NSNumber(value: matrix.columns.1.z), NSNumber(value: matrix.columns.1.w),
            NSNumber(value: matrix.columns.2.x), NSNumber(value: matrix.columns.2.y),
            NSNumber(value: matrix.columns.2.z), NSNumber(value: matrix.columns.2.w),
            NSNumber(value: matrix.columns.3.x), NSNumber(value: matrix.columns.3.y),
            NSNumber(value: matrix.columns.3.z), NSNumber(value: matrix.columns.3.w)
        ]
    }
}

// MARK: - ARCoachingOverlayViewDelegate

@available(iOS 13.0, *)
extension IosARViewRealityKit: ARCoachingOverlayViewDelegate {
    func coachingOverlayViewDidDeactivate(_ coachingOverlayView: ARCoachingOverlayView) {
        print("✅ Coaching overlay deactivated")
    }
}
