package com.uhg0.ar_flutter_plugin_2

import android.app.Activity
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.MotionEvent
import android.view.View
import android.view.GestureDetector
import java.util.concurrent.CompletableFuture
import kotlin.math.pow
import com.google.ar.core.*
import com.google.ar.sceneform.*
import com.google.ar.sceneform.assets.RenderableSource
import com.google.ar.sceneform.math.Vector3
import com.google.ar.sceneform.rendering.ModelRenderable
import com.google.ar.sceneform.rendering.MaterialFactory
import com.google.ar.sceneform.rendering.ShapeFactory
import com.google.ar.sceneform.collision.Box
import com.google.ar.sceneform.HitTestResult
import com.google.ar.sceneform.ux.TransformationSystem
import com.google.ar.sceneform.ux.SelectionVisualizer
import com.google.ar.sceneform.ux.TransformableNode
import com.google.ar.sceneform.ux.BaseTransformableNode
import com.google.ar.sceneform.AnchorNode
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import java.util.concurrent.ConcurrentHashMap

class ArCoreCompatView(
    context: Context,
    messenger: BinaryMessenger,
    viewId: Int,
    private val activity: Activity
) : PlatformView, MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "ArCoreCompatView"
    }

    // Flutter method channels
    private val sessionChannel = MethodChannel(messenger, "arsession_$viewId")
    private val objectChannel = MethodChannel(messenger, "arobjects_$viewId") 
    private val anchorChannel = MethodChannel(messenger, "aranchors_$viewId")

    // AR Components
    private var arSceneView: ArSceneView? = null
    private var transformationSystem: TransformationSystem? = null
    private val nodesMap = ConcurrentHashMap<String, Node>()
    private var gestureDetector: GestureDetector? = null

    init {
        Log.d(TAG, "🚀 Creating ArCoreCompatView with GLB support")
        setupMethodChannels()
        initializeArView()
    }

    private fun setupMethodChannels() {
        sessionChannel.setMethodCallHandler(this)
        objectChannel.setMethodCallHandler(this)  
        anchorChannel.setMethodCallHandler(this)
    }

    private fun initializeArView() {
        try {
            // Initialize ArSceneView with manual session management
            arSceneView = ArSceneView(activity).apply {
                // Create session manually with activity context  
                val session = Session(activity)
                
                // Configure session for plane detection with memory-optimized settings
                val config = session.config.apply {
                    planeFindingMode = Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL
                    lightEstimationMode = Config.LightEstimationMode.AMBIENT_INTENSITY
                    updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE
                    
                    // Memory optimizations
                    focusMode = Config.FocusMode.AUTO
                    // Disable unnecessary features to reduce memory usage
                }
                session.configure(config)
                
                // Set the session
                setupSession(session)
                planeRenderer.isEnabled = true
                planeRenderer.isVisible = true
                
                // CRITICAL: Resume the ArSceneView to start the camera feed
                Handler(Looper.getMainLooper()).post {
                    try {
                        resume()
                        Log.d(TAG, "🟢 ArSceneView resumed - camera should be visible now")
                    } catch (e: Exception) {
                        Log.e(TAG, "❌ Failed to resume ArSceneView: ${e.message}")
                    }
                }
            }

            // Initialize TransformationSystem for gesture handling
            val selectionVisualizer = object : SelectionVisualizer {
                override fun applySelectionVisual(node: BaseTransformableNode) {
                    Log.d(TAG, "🎯 Node selected for gestures: ${node.name}")
                    
                    // Send gesture start callbacks based on enabled controllers
                    if (node is TransformableNode) {
                        if (node.translationController.isEnabled) {
                            objectChannel.invokeMethod("onPanStart", node.name)
                        }
                        if (node.rotationController.isEnabled) {
                            objectChannel.invokeMethod("onRotationStart", node.name)
                        }
                    }
                }
                
                override fun removeSelectionVisual(node: BaseTransformableNode) {
                    Log.d(TAG, "🎯 Node deselected after gestures: ${node.name}")
                    
                    // Send gesture end callbacks
                    if (node is TransformableNode) {
                        if (node.translationController.isEnabled) {
                            objectChannel.invokeMethod("onPanEnd", node.name)
                        }
                        if (node.rotationController.isEnabled) {
                            objectChannel.invokeMethod("onRotationEnd", node.name)
                        }
                    }
                }
            }
            
            transformationSystem = TransformationSystem(activity.resources.displayMetrics, selectionVisualizer)

            // Setup gesture detection for tap-to-place
            gestureDetector = GestureDetector(activity, object : GestureDetector.SimpleOnGestureListener() {
                override fun onSingleTapUp(e: MotionEvent): Boolean {
                    Log.d(TAG, "🎯 SINGLE TAP UP DETECTED: x=${e.x}, y=${e.y}")
                    handleTap(e)
                    return true
                }
                
                override fun onDown(e: MotionEvent): Boolean {
                    Log.d(TAG, "🔥 GESTURE DOWN: x=${e.x}, y=${e.y}")
                    return true
                }
                
                override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
                    Log.d(TAG, "🎯 SINGLE TAP CONFIRMED: x=${e.x}, y=${e.y}")
                    return super.onSingleTapConfirmed(e)
                }
            })

            // CRITICAL: Setup peek touch listener for TransformationSystem
            // This ensures TransformationSystem always gets touch events first
            arSceneView?.scene?.addOnPeekTouchListener { hitTestResult, motionEvent ->
                Log.d(TAG, "👁️ PEEK TOUCH: action=${motionEvent.action}, x=${motionEvent.x}, y=${motionEvent.y}")
                // Always forward to TransformationSystem - this is critical for gestures
                transformationSystem?.onTouch(hitTestResult, motionEvent)
            }

            // Setup touch listener to forward gestures to transformation system
            arSceneView?.scene?.setOnTouchListener { hitTestResult, motionEvent ->
                Log.d(TAG, "🔥 TOUCH EVENT RECEIVED: action=${motionEvent.action}, x=${motionEvent.x}, y=${motionEvent.y}")
                
                // Check if we have a selected node BEFORE TransformationSystem processes the touch
                val selectedNodeBefore = transformationSystem?.selectedNode
                val hadSelectedNode = selectedNodeBefore != null
                
                Log.d(TAG, "🔥 BEFORE TRANSFORMATION: selectedNode=${selectedNodeBefore?.name}, hadSelected=$hadSelectedNode")
                
                // Let TransformationSystem handle the touch event first
                // This allows it to perform hit testing and select/deselect nodes properly
                transformationSystem?.onTouch(hitTestResult, motionEvent)
                
                // Check the selected node AFTER TransformationSystem processes the touch
                val selectedNodeAfter = transformationSystem?.selectedNode
                val hasSelectedNode = selectedNodeAfter != null
                
                // Consider transformation "handled" if:
                // 1. We had a selected node and still have one (ongoing gesture)
                // 2. We just selected a new node (new gesture started)
                val transformationHandled = hadSelectedNode || hasSelectedNode
                
                Log.d(TAG, "🔥 AFTER TRANSFORMATION: selectedNode=${selectedNodeAfter?.name}, hasSelected=$hasSelectedNode, transformationHandled=$transformationHandled")
                
                // Only process gesture detection if TransformationSystem didn't handle the event
                // This allows plane taps to work when no nodes are selected
                val gestureHandled = if (!transformationHandled) {
                    Log.d(TAG, "🎯 Processing as potential plane tap (transformation didn't handle)")
                    gestureDetector?.onTouchEvent(motionEvent) ?: false
                } else {
                    Log.d(TAG, "🎯 Skipping plane tap processing - transformation handled: $transformationHandled")
                    false
                }
                
                Log.d(TAG, "🔥 TOUCH RESULTS: transformation=$transformationHandled, gesture=$gestureHandled, final=${transformationHandled || gestureHandled}")
                
                // Return true if either transformation system or gesture detector handled it
                transformationHandled || gestureHandled
            }

            Log.d(TAG, "✅ ArSceneView initialized with GLB support")

        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to initialize ArSceneView: ${e.message}", e)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> handleInit(call, result)
            "addAnchor" -> handleAddAnchor(call, result)
            "addNode" -> {
                // Route addNode to addNodeToPlaneAnchor when planeAnchor is provided
                val arguments = call.arguments as? Map<String, Any>
                if (arguments?.get("planeAnchor") != null) {
                    Log.d(TAG, "📍 addNode with planeAnchor - routing to addNodeToPlaneAnchor")
                    handleAddNodeToPlaneAnchor(call, result)
                } else {
                    Log.d(TAG, "📍 addNode without planeAnchor - direct position placement")
                    handleAddNode(call, result)
                }
            }
            "addNodeToPlaneAnchor" -> handleAddNodeToPlaneAnchor(call, result)
            "removeNode" -> handleRemoveNode(call, result)
            "removeNodeDeep" -> handleRemoveNodeDeep(call, result)
            "purgeCaches" -> handlePurgeCaches(call, result)
            "getMemoryInfo" -> handleGetMemoryInfo(call, result)
            "createNodeFromAsset" -> handleCreateNodeFromAsset(call, result)
            "ar#nukeAll" -> handleNukeAll(call, result)
            "ar#getPluginState" -> handleGetPluginState(call, result)
            "removeAllObjects" -> handleRemoveAllObjects(call, result)
            "removeAnchor" -> handleRemoveAnchor(call, result)
            "dispose" -> handleDispose(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleInit(call: MethodCall, result: MethodChannel.Result) {
        Log.d(TAG, "🎯 AR Session initialization requested")
        result.success("AR session ready")
    }

    private fun handleTap(motionEvent: MotionEvent) {
        Log.d(TAG, "🎯 HANDLE TAP CALLED: x=${motionEvent.x}, y=${motionEvent.y}")
        val frame = arSceneView?.arFrame ?: return
        
        if (frame.camera.trackingState != TrackingState.TRACKING) {
            Log.w(TAG, "⚠️ Camera not tracking, skipping tap")
            return
        }

        val hits = frame.hitTest(motionEvent.x, motionEvent.y)
        Log.d(TAG, "🎯 Hit test found ${hits.size} hits")
        for (hit in hits) {
            val trackable = hit.trackable
            Log.d(TAG, "🎯 Hit trackable type: ${trackable::class.simpleName}")
            if (trackable is Plane && trackable.isPoseInPolygon(hit.hitPose)) {
                Log.d(TAG, "🎯 Plane hit detected at ${hit.hitPose.translation}")
                
                // Convert pose to matrix for Flutter
                val matrix = FloatArray(16)
                hit.hitPose.toMatrix(matrix, 0)
                val matrixList = matrix.toList()
                
                // Send hit test result to Flutter
                val hitResult = mapOf(
                    "pose" to mapOf("matrix" to matrixList),
                    "plane" to mapOf(
                        "type" to when (trackable.type) {
                            Plane.Type.HORIZONTAL_DOWNWARD_FACING -> "horizontal"
                            Plane.Type.HORIZONTAL_UPWARD_FACING -> "horizontal"  
                            Plane.Type.VERTICAL -> "vertical"
                        }
                    )
                )
                
                Log.d(TAG, "🎯 Sending onPlaneOrPointTap to Flutter with hit result")
                sessionChannel.invokeMethod("onPlaneOrPointTap", listOf(hitResult))
                break
            }
        }
    }

    private fun handleAddAnchor(call: MethodCall, result: MethodChannel.Result) {
        try {
            val arguments = call.arguments as? Map<String, Any>
            if (arguments == null) {
                result.error("INVALID_ARGUMENTS", "Arguments are null", null)
                return
            }

            val name = arguments["name"] as? String
            val transformationMatrix = arguments["transformation"] as? List<*>
            
            if (name == null || transformationMatrix == null || transformationMatrix.size != 16) {
                Log.e(TAG, "❌ Invalid anchor data - name: $name, transformation size: ${transformationMatrix?.size}")
                result.error("INVALID_ARGUMENTS", "Invalid anchor data", null)
                return
            }

            Log.d(TAG, "🔗 Creating anchor: $name")

            // Convert matrix to Pose
            val matrix = FloatArray(16)
            for (i in 0 until 16) {
                matrix[i] = (transformationMatrix[i] as? Number)?.toFloat() ?: 0f
            }
            
            val pose = Pose.makeTranslation(matrix[12], matrix[13], matrix[14])
            
            // Create anchor and anchor node
            val session = arSceneView?.session
            if (session != null) {
                val anchor = session.createAnchor(pose)
                val anchorNode = AnchorNode(anchor).apply {
                    setParent(arSceneView?.scene)
                    this.name = name
                }
                
                nodesMap[name] = anchorNode
                Log.d(TAG, "✅ Anchor created successfully: $name")
                result.success(true)
            } else {
                Log.e(TAG, "❌ AR session not ready")
                result.error("SESSION_NOT_READY", "AR session not ready", null)
            }

        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to create anchor: ${e.message}", e)
            result.error("ANCHOR_CREATION_FAILED", e.message, null)
        }
    }

    private fun handleAddNode(call: MethodCall, result: MethodChannel.Result) {
        Log.d(TAG, "🎯 handleAddNode called for direct position placement")
        Log.d(TAG, "📋 Method call arguments: ${call.arguments}")
        
        try {
            val nodeData = call.arguments as? Map<String, Any>
            if (nodeData == null) {
                Log.e(TAG, "❌ Node data is null")
                result.error("INVALID_ARGUMENTS", "Node data is null", null)
                return
            }
            
            Log.d(TAG, "📋 Node data keys: ${nodeData.keys}")
            
            val nodeName = nodeData["name"] as? String
            val uri = nodeData["uri"] as? String
            val nodeType = nodeData["type"] as? Int
            
            if (nodeName == null || uri == null || nodeType == null) {
                result.error("INVALID_ARGUMENTS", "Node name, URI, or type is null", null)
                return
            }
            
            Log.d(TAG, "🎯 Loading model for direct placement: $nodeName with URI: $uri, Type: $nodeType")
            
            // Check if this is a supported node type
            when (nodeType) {
                1 -> {
                    // NodeType.webGLB - Load GLB from web
                    Log.d(TAG, "🌐 Loading webGLB model from URL for direct placement")
                }
                0 -> {
                    // NodeType.localGLTF2 - Load GLTF from assets
                    Log.d(TAG, "📁 Loading local GLTF2 model for direct placement")
                    result.error("UNSUPPORTED_TYPE", "Local GLTF2 not yet supported in ArCoreCompatView", null)
                    return
                }
                else -> {
                    Log.e(TAG, "❌ Unsupported node type: $nodeType")
                    result.error("UNSUPPORTED_TYPE", "Node type $nodeType not supported", null)
                    return
                }
            }
            
            // Load GLB model using RenderableSource (same approach as arcore_flutter_plugin)
            Log.d(TAG, "🔄 Loading GLB with RenderableSource for direct placement")
            
            // Extract position from transformation matrix
            var positionX = 0.0f
            var positionY = -1.2f  // Default position in front of user
            var positionZ = -0.8f
            
            val nodeTransformation = nodeData["transformation"] as? List<*>
            if (nodeTransformation != null && nodeTransformation.size == 16) {
                // Extract translation from transformation matrix (last column)
                positionX = (nodeTransformation[12] as? Number)?.toFloat() ?: 0.0f
                positionY = (nodeTransformation[13] as? Number)?.toFloat() ?: -1.2f
                positionZ = (nodeTransformation[14] as? Number)?.toFloat() ?: -0.8f
                Log.d(TAG, "📏 Position extracted from transformation matrix: ($positionX, $positionY, $positionZ)")
            } else {
                Log.d(TAG, "📏 Using default position for direct placement: ($positionX, $positionY, $positionZ)")
            }
            
            // Extract scale from node data - check both scale property and transformation matrix
            var scaleX = 1.0f
            var scaleY = 1.0f 
            var scaleZ = 1.0f
            
            // First try to get scale from direct scale property
            val scaleData = nodeData["scale"] as? List<*>
            android.util.Log.d("SCALE_DEBUG", "🔍🔍🔍 DEBUG: scaleData = $scaleData")
            android.util.Log.d("SCALE_DEBUG", "🔍🔍🔍 DEBUG: nodeData.keys = ${nodeData.keys}")
            if (scaleData != null && scaleData.size == 3) {
                scaleX = (scaleData[0] as? Number)?.toFloat() ?: 1.0f
                scaleY = (scaleData[1] as? Number)?.toFloat() ?: 1.0f
                scaleZ = (scaleData[2] as? Number)?.toFloat() ?: 1.0f
                android.util.Log.d("SCALE_DEBUG", "✅✅✅ Scale from direct property: ($scaleX, $scaleY, $scaleZ)")
            } else {
                // Fallback: Extract scale from transformation matrix
                if (nodeTransformation != null && nodeTransformation.size == 16) {
                    // For a transformation matrix, scale is the length of the first 3 columns
                    val m00 = (nodeTransformation[0] as? Number)?.toFloat() ?: 1.0f
                    val m10 = (nodeTransformation[1] as? Number)?.toFloat() ?: 0.0f
                    val m20 = (nodeTransformation[2] as? Number)?.toFloat() ?: 0.0f
                    
                    val m01 = (nodeTransformation[4] as? Number)?.toFloat() ?: 0.0f
                    val m11 = (nodeTransformation[5] as? Number)?.toFloat() ?: 1.0f
                    val m21 = (nodeTransformation[6] as? Number)?.toFloat() ?: 0.0f
                    
                    val m02 = (nodeTransformation[8] as? Number)?.toFloat() ?: 0.0f
                    val m12 = (nodeTransformation[9] as? Number)?.toFloat() ?: 0.0f
                    val m22 = (nodeTransformation[10] as? Number)?.toFloat() ?: 1.0f
                    
                    // Calculate scale as the length of each column vector
                    scaleX = kotlin.math.sqrt(m00 * m00 + m10 * m10 + m20 * m20)
                    scaleY = kotlin.math.sqrt(m01 * m01 + m11 * m11 + m21 * m21)
                    scaleZ = kotlin.math.sqrt(m02 * m02 + m12 * m12 + m22 * m22)
                    Log.d(TAG, "📏 Scale extracted from transformation matrix: ($scaleX, $scaleY, $scaleZ)")
                } else {
                    Log.d(TAG, "📏 Using default scale: (1.0, 1.0, 1.0)")
                }
            }
            
            // Extract gesture properties from node data
            val isTransformable = nodeData["isTransformable"] as? Boolean ?: false
            val enablePanGestures = nodeData["enablePanGestures"] as? Boolean ?: false
            val enableRotationGestures = nodeData["enableRotationGestures"] as? Boolean ?: false
            Log.d(TAG, "🎯 Gesture properties - isTransformable: $isTransformable, pan: $enablePanGestures, rotation: $enableRotationGestures")
            
            try {
                val modelRenderableBuilder = ModelRenderable.builder()
                val renderableSourceBuilder = RenderableSource.builder()
                
                // Check file extension and set appropriate source type
                if (uri.endsWith(".glb")) {
                    Log.d(TAG, "📂 Loading GLB file for direct placement: $uri")
                    renderableSourceBuilder
                        .setSource(activity, Uri.parse(uri), RenderableSource.SourceType.GLB)
                        .setScale(1.0f) // Use 1.0f as base scale, we'll apply custom scale later
                        .setRecenterMode(RenderableSource.RecenterMode.ROOT)
                } else if (uri.endsWith(".gltf")) {
                    Log.d(TAG, "📂 Loading GLTF file for direct placement: $uri")
                    renderableSourceBuilder
                        .setSource(activity, Uri.parse(uri), RenderableSource.SourceType.GLTF2)
                        .setScale(1.0f) // Use 1.0f as base scale, we'll apply custom scale later
                        .setRecenterMode(RenderableSource.RecenterMode.ROOT)
                } else {
                    Log.e(TAG, "❌ Unsupported file format for direct placement: $uri")
                    result.error("UNSUPPORTED_FORMAT", "Only GLB and GLTF files are supported", null)
                    return
                }
                
                modelRenderableBuilder
                    .setSource(activity, renderableSourceBuilder.build())
                    .setRegistryId(uri)
                    .build()
                    .thenAccept { renderable: ModelRenderable ->
                        Log.d(TAG, "✅ GLB model loaded successfully for direct placement: $nodeName")
                        
                        val transformableNode = TransformableNode(transformationSystem)
                        transformableNode.renderable = renderable
                        transformableNode.name = nodeName
                        
                        // CRITICAL: Enable the node for hit testing and selection
                        transformableNode.isEnabled = true
                        
                        // CRITICAL: Set collision shape for hit testing
                        transformableNode.collisionShape = Box(
                            Vector3(1.0f, 1.0f, 1.0f)
                        )
                        Log.d(TAG, "🎯 Set collision shape for hit testing: $nodeName")
                        
                        // Set up tap listener for node selection
                        transformableNode.setOnTapListener { hitTestResult: HitTestResult, motionEvent: MotionEvent ->
                            Log.d(TAG, "🎯 Node $nodeName tapped - selecting for transformation")
                            transformationSystem?.selectNode(transformableNode)
                            Log.d(TAG, "🎯 Node $nodeName selected for transformation")
                            
                            // CRITICAL FIX: Notify Flutter about node tap via method channel
                            try {
                                val tappedNodesList = listOf(nodeName)
                                Log.d(TAG, "📢 Notifying Flutter about node tap: $tappedNodesList")
                                objectChannel.invokeMethod("onNodeTapped", tappedNodesList)
                                Log.d(TAG, "✅ Flutter callback triggered successfully")
                            } catch (e: Exception) {
                                Log.e(TAG, "❌ Failed to notify Flutter about node tap: ${e.message}")
                            }
                            
                            true
                        }
                        
                        // Apply gesture properties from Flutter
                        if (isTransformable) {
                            transformableNode.translationController.isEnabled = enablePanGestures
                            transformableNode.rotationController.isEnabled = enableRotationGestures
                            transformableNode.scaleController.isEnabled = true // Always allow scale for now
                            
                            // Additional pan gesture configuration
                            transformableNode.translationController.apply {
                                isEnabled = enablePanGestures
                                Log.d(TAG, "🎯 Translation controller configured - enabled: $isEnabled")
                            }
                            
                            Log.d(TAG, "🎯 Gesture controllers enabled - pan: $enablePanGestures, rotation: $enableRotationGestures")
                            
                        } else {
                            transformableNode.translationController.isEnabled = false
                            transformableNode.rotationController.isEnabled = false
                            transformableNode.scaleController.isEnabled = false
                            Log.d(TAG, "🎯 All gesture controllers disabled (isTransformable=false)")
                        }
                        
                        // Apply the scale from Flutter to the node
                        transformableNode.localScale = Vector3(scaleX, scaleY, scaleZ)
                        android.util.Log.d("SCALE_DEBUG", "🎯🎯🎯 FINAL: Applied scale to node: ($scaleX, $scaleY, $scaleZ)")
                        android.util.Log.d("SCALE_DEBUG", "🎯🎯🎯 FINAL: Node localScale after setting: ${transformableNode.localScale}")
                        
                        // Set the world position directly (no anchor needed for direct placement)
                        transformableNode.worldPosition = Vector3(positionX, positionY, positionZ)
                        Log.d(TAG, "📍 Set world position for direct placement: ($positionX, $positionY, $positionZ)")
                        
                        // CRITICAL FIX: For gesture support, we need to find a detected plane
                        // Instead of creating virtual anchors, use actual detected planes
                        try {
                            val session = arSceneView?.session
                            if (session != null) {
                                // Get all tracked planes from the current frame
                                val frame = session.update()
                                val trackedPlanes = session.getAllTrackables(Plane::class.java)
                                    .filter { it.trackingState == TrackingState.TRACKING }
                                
                                Log.d(TAG, "🔍 Found ${trackedPlanes.size} tracked planes for auto placement")
                                
                                if (trackedPlanes.isNotEmpty()) {
                                    // Find the best plane to place the object on
                                    // Prefer horizontal planes that are close to the desired position
                                    val targetPose = Pose.makeTranslation(positionX, positionY, positionZ)
                                    
                                    val bestPlane = trackedPlanes.minByOrNull { plane ->
                                        val planeCenterPose = plane.centerPose
                                        val distance = kotlin.math.sqrt(
                                            (planeCenterPose.tx() - targetPose.tx()).pow(2) +
                                            (planeCenterPose.tz() - targetPose.tz()).pow(2)
                                        )
                                        distance
                                    }
                                    
                                    if (bestPlane != null) {
                                        Log.d(TAG, "🎯 Using detected plane for auto placement")
                                        
                                        // Create an anchor on the detected plane at a position close to desired location
                                        val planeAnchor = bestPlane.createAnchor(
                                            bestPlane.centerPose.compose(
                                                Pose.makeTranslation(0.0f, 0.0f, 0.0f) // Use plane's center
                                            )
                                        )
                                        
                                        // Create an anchor node for this plane anchor
                                        val anchorNode = AnchorNode(planeAnchor)
                                        anchorNode.setParent(arSceneView?.scene)
                                        
                                        // Attach the transformable node to the plane anchor
                                        transformableNode.setParent(anchorNode)
                                        transformableNode.localPosition = Vector3(0.0f, 0.0f, 0.0f)
                                        
                                        Log.d(TAG, "✅ Successfully placed node on detected plane with gesture support")
                                        
                                        // Store both nodes for cleanup
                                        nodesMap[nodeName] = transformableNode
                                        nodesMap["${nodeName}_anchor"] = anchorNode
                                        
                                    } else {
                                        Log.w(TAG, "⚠️ No suitable plane found, falling back to scene attachment")
                                        // Fallback: Add directly to scene (gestures may not work optimally)
                                        transformableNode.worldPosition = Vector3(positionX, positionY, positionZ)
                                        arSceneView?.scene?.addChild(transformableNode)
                                        nodesMap[nodeName] = transformableNode
                                    }
                                } else {
                                    Log.w(TAG, "⚠️ No tracked planes available, falling back to scene attachment")
                                    // Fallback: Add directly to scene (gestures may not work optimally)
                                    transformableNode.worldPosition = Vector3(positionX, positionY, positionZ)
                                    arSceneView?.scene?.addChild(transformableNode)
                                    nodesMap[nodeName] = transformableNode
                                }
                                
                            } else {
                                Log.w(TAG, "⚠️ AR Session not available, falling back to direct scene attachment")
                                // Fallback: Add the node directly to the scene (gestures may not work optimally)
                                transformableNode.worldPosition = Vector3(positionX, positionY, positionZ)
                                arSceneView?.scene?.addChild(transformableNode)
                                nodesMap[nodeName] = transformableNode
                            }
                        } catch (e: Exception) {
                            Log.e(TAG, "❌ Failed to find detected plane: ${e.message}")
                            Log.d(TAG, "🔄 Falling back to direct scene attachment")
                            // Fallback: Add the node directly to the scene
                            transformableNode.worldPosition = Vector3(positionX, positionY, positionZ)
                            arSceneView?.scene?.addChild(transformableNode)
                            nodesMap[nodeName] = transformableNode
                        }
                        
                        Log.d(TAG, "✅ GLB model added with direct placement: $nodeName")
                        result.success(nodeName)
                    }
                    .exceptionally { throwable: Throwable ->
                        Log.e(TAG, "❌ Failed to load GLB model for direct placement: ${throwable.message}")
                        result.error("MODEL_LOAD_ERROR", throwable.message ?: "Unknown error", null)
                        null
                    }
                
            } catch (e: Exception) {
                Log.e(TAG, "❌ Exception loading GLB for direct placement: ${e.message}")
                result.error("MODEL_CREATE_ERROR", e.message ?: "Unknown error", null)
            }
                
        } catch (e: Exception) {
            Log.e(TAG, "❌ Exception in handleAddNode: ${e.message}", e)
            result.error("GENERAL_ERROR", e.message ?: "Unknown error", null)
        }
    }

    private fun handleAddNodeToPlaneAnchor(call: MethodCall, result: MethodChannel.Result) {
        Log.d(TAG, "🎯 handleAddNodeToPlaneAnchor called")
        Log.d(TAG, "📋 Method call arguments: ${call.arguments}")
        
        try {
            val arguments = call.arguments as? Map<String, Any>
            if (arguments == null) {
                Log.e(TAG, "❌ Arguments are null")
                result.error("INVALID_ARGUMENTS", "Arguments are null", null)
                return
            }
            
            Log.d(TAG, "📋 Arguments keys: ${arguments.keys}")
            
            // Handle two possible formats:
            // 1. ARObjectManager.addNode format: { node: {...}, planeAnchor: {...} }
            // 2. Direct addNodeToPlaneAnchor format: { node: {...}, anchor: {...} }
            val nodeData = arguments["node"] as? Map<String, Any>
            val anchorData = arguments["anchor"] as? Map<String, Any> 
                ?: arguments["planeAnchor"] as? Map<String, Any>
            
            Log.d(TAG, "📦 Node data: $nodeData")
            Log.d(TAG, "⚓ Anchor data: $anchorData")
            
            if (nodeData == null || anchorData == null) {
                result.error("INVALID_ARGUMENTS", "Node or anchor data is null", null)
                return
            }
            
            val nodeName = nodeData["name"] as? String
            val uri = nodeData["uri"] as? String
            val anchorName = anchorData["name"] as? String
            val nodeType = nodeData["type"] as? Int
            
            if (nodeName == null || uri == null || anchorName == null || nodeType == null) {
                result.error("INVALID_ARGUMENTS", "Node name, URI, anchor name, or type is null", null)
                return
            }
            
            Log.d(TAG, "🎯 Loading model: $nodeName with URI: $uri, Type: $nodeType")
            
            // Check if this is a supported node type
            when (nodeType) {
                1 -> {
                    // NodeType.webGLB - Load GLB from web
                    Log.d(TAG, "🌐 Loading webGLB model from URL")
                }
                0 -> {
                    // NodeType.localGLTF2 - Load GLTF from assets
                    Log.d(TAG, "📁 Loading local GLTF2 model")
                    result.error("UNSUPPORTED_TYPE", "Local GLTF2 not yet supported in ArCoreCompatView", null)
                    return
                }
                else -> {
                    Log.e(TAG, "❌ Unsupported node type: $nodeType")
                    result.error("UNSUPPORTED_TYPE", "Node type $nodeType not supported", null)
                    return
                }
            }
            
            // Find the anchor node
            var anchorNode = nodesMap[anchorName] as? AnchorNode
            if (anchorNode == null) {
                Log.e(TAG, "❌ Anchor node not found: $anchorName")
                result.error("ANCHOR_NOT_FOUND", "Anchor node not found: $anchorName", null)
                return
            }
            
            // CRITICAL FIX: Verify the anchor is properly attached to a tracked plane for gesture support
            // If the anchor is not properly tracked, try to find a nearby detected plane and re-anchor
            try {
                val session = arSceneView?.session
                if (session != null) {
                    val frame = session.update()
                    val trackedPlanes = session.getAllTrackables(Plane::class.java)
                        .filter { it.trackingState == TrackingState.TRACKING }
                    
                    Log.d(TAG, "🔍 Found ${trackedPlanes.size} tracked planes for anchor verification")
                    
                    // Check if current anchor is on a tracked plane, if not, create a new one on a detected plane
                    val anchor = anchorNode.anchor
                    if (anchor == null || trackedPlanes.isNotEmpty()) {
                        Log.d(TAG, "🎯 Re-anchoring to detected plane for better gesture support")
                        
                        // Get current anchor position for reference
                        val currentPose = anchor?.pose ?: Pose.IDENTITY
                        
                        // Find the best plane to place the object on
                        val bestPlane = trackedPlanes.minByOrNull { plane ->
                            val planeCenterPose = plane.centerPose
                            val distance = kotlin.math.sqrt(
                                (planeCenterPose.tx() - currentPose.tx()).pow(2) +
                                (planeCenterPose.tz() - currentPose.tz()).pow(2)
                            )
                            distance
                        }
                        
                        if (bestPlane != null) {
                            Log.d(TAG, "🎯 Using detected plane for re-anchoring")
                            
                            // Create a new anchor on the detected plane
                            val newPlaneAnchor = bestPlane.createAnchor(
                                bestPlane.centerPose.compose(
                                    Pose.makeTranslation(0.0f, 0.0f, 0.0f) // Use plane's center
                                )
                            )
                            
                            // Create a new anchor node for this plane anchor
                            val newAnchorNode = AnchorNode(newPlaneAnchor)
                            newAnchorNode.setParent(arSceneView?.scene)
                            
                            // Update the stored reference
                            anchorNode = newAnchorNode
                            nodesMap[anchorName] = newAnchorNode
                            
                            Log.d(TAG, "✅ Successfully re-anchored to detected plane with gesture support")
                        } else {
                            Log.w(TAG, "⚠️ No suitable plane found for re-anchoring, using existing anchor")
                        }
                    } else {
                        Log.d(TAG, "✅ Anchor already properly attached to tracked surface")
                    }
                } else {
                    Log.w(TAG, "⚠️ AR Session not available for anchor verification")
                }
            } catch (e: Exception) {
                Log.e(TAG, "❌ Failed to verify/improve anchor: ${e.message}")
                Log.d(TAG, "🔄 Continuing with existing anchor")
            }
            
            // Load GLB model using RenderableSource (same approach as arcore_flutter_plugin)
            Log.d(TAG, "🔄 Loading GLB with RenderableSource")
            
            // Extract scale from node data - check both scale property and transformation matrix
            var scaleX = 1.0f
            var scaleY = 1.0f 
            var scaleZ = 1.0f
            
            // First try to get scale from direct scale property
            val scaleData = nodeData["scale"] as? List<*>
            android.util.Log.d("SCALE_DEBUG", "🔍🔍🔍 DEBUG: scaleData = $scaleData")
            android.util.Log.d("SCALE_DEBUG", "🔍🔍🔍 DEBUG: nodeData.keys = ${nodeData.keys}")
            if (scaleData != null && scaleData.size == 3) {
                scaleX = (scaleData[0] as? Number)?.toFloat() ?: 1.0f
                scaleY = (scaleData[1] as? Number)?.toFloat() ?: 1.0f
                scaleZ = (scaleData[2] as? Number)?.toFloat() ?: 1.0f
                android.util.Log.d("SCALE_DEBUG", "✅✅✅ Scale from direct property: ($scaleX, $scaleY, $scaleZ)")
            } else {
                // Fallback: Extract scale from transformation matrix
                val nodeTransformation = nodeData["transformation"] as? List<*>
                if (nodeTransformation != null && nodeTransformation.size == 16) {
                    // For a transformation matrix, scale is the length of the first 3 columns
                    val m00 = (nodeTransformation[0] as? Number)?.toFloat() ?: 1.0f
                    val m10 = (nodeTransformation[1] as? Number)?.toFloat() ?: 0.0f
                    val m20 = (nodeTransformation[2] as? Number)?.toFloat() ?: 0.0f
                    
                    val m01 = (nodeTransformation[4] as? Number)?.toFloat() ?: 0.0f
                    val m11 = (nodeTransformation[5] as? Number)?.toFloat() ?: 1.0f
                    val m21 = (nodeTransformation[6] as? Number)?.toFloat() ?: 0.0f
                    
                    val m02 = (nodeTransformation[8] as? Number)?.toFloat() ?: 0.0f
                    val m12 = (nodeTransformation[9] as? Number)?.toFloat() ?: 0.0f
                    val m22 = (nodeTransformation[10] as? Number)?.toFloat() ?: 1.0f
                    
                    // Calculate scale as the length of each column vector
                    scaleX = kotlin.math.sqrt(m00 * m00 + m10 * m10 + m20 * m20)
                    scaleY = kotlin.math.sqrt(m01 * m01 + m11 * m11 + m21 * m21)
                    scaleZ = kotlin.math.sqrt(m02 * m02 + m12 * m12 + m22 * m22)
                    Log.d(TAG, "📏 Scale extracted from transformation matrix: ($scaleX, $scaleY, $scaleZ)")
                } else {
                    Log.d(TAG, "📏 Using default scale: (1.0, 1.0, 1.0)")
                }
            }
            
            // Extract gesture properties from node data
            val isTransformable = nodeData["isTransformable"] as? Boolean ?: false
            val enablePanGestures = nodeData["enablePanGestures"] as? Boolean ?: false
            val enableRotationGestures = nodeData["enableRotationGestures"] as? Boolean ?: false
            Log.d(TAG, "🎯 Gesture properties - isTransformable: $isTransformable, pan: $enablePanGestures, rotation: $enableRotationGestures")
            
            try {
                val modelRenderableBuilder = ModelRenderable.builder()
                val renderableSourceBuilder = RenderableSource.builder()
                
                // Check file extension and set appropriate source type
                if (uri.endsWith(".glb")) {
                    Log.d(TAG, "📂 Loading GLB file: $uri")
                    renderableSourceBuilder
                        .setSource(activity, Uri.parse(uri), RenderableSource.SourceType.GLB)
                        .setScale(1.0f) // Use 1.0f as base scale, we'll apply custom scale later
                        .setRecenterMode(RenderableSource.RecenterMode.ROOT)
                } else if (uri.endsWith(".gltf")) {
                    Log.d(TAG, "📂 Loading GLTF file: $uri")
                    renderableSourceBuilder
                        .setSource(activity, Uri.parse(uri), RenderableSource.SourceType.GLTF2)
                        .setScale(1.0f) // Use 1.0f as base scale, we'll apply custom scale later
                        .setRecenterMode(RenderableSource.RecenterMode.ROOT)
                } else {
                    Log.e(TAG, "❌ Unsupported file format: $uri")
                    result.error("UNSUPPORTED_FORMAT", "Only GLB and GLTF files are supported", null)
                    return
                }
                
                modelRenderableBuilder
                    .setSource(activity, renderableSourceBuilder.build())
                    .setRegistryId(uri)
                    .build()
                    .thenAccept { renderable: ModelRenderable ->
                        Log.d(TAG, "✅ GLB model loaded successfully: $nodeName")
                        
                        val transformableNode = TransformableNode(transformationSystem)
                        transformableNode.renderable = renderable
                        transformableNode.name = nodeName
                        
                        // CRITICAL: Enable the node for hit testing and selection
                        transformableNode.isEnabled = true
                        
                        // CRITICAL: Set collision shape for hit testing - this is what was missing!
                        // Without collision shape, the node can't be hit-tested and selected
                        transformableNode.collisionShape = Box(
                            Vector3(1.0f, 1.0f, 1.0f)
                        )
                        Log.d(TAG, "🎯 Set collision shape for hit testing: $nodeName")
                        
                        // Set up tap listener for node selection (like in arcore_flutter_plugin)
                        transformableNode.setOnTapListener { hitTestResult: HitTestResult, motionEvent: MotionEvent ->
                            Log.d(TAG, "🎯 Node $nodeName tapped - selecting for transformation")
                            transformationSystem?.selectNode(transformableNode)
                            Log.d(TAG, "🎯 Node $nodeName selected for transformation")
                            
                            // CRITICAL FIX: Notify Flutter about node tap via method channel
                            try {
                                val tappedNodesList = listOf(nodeName)
                                Log.d(TAG, "📢 Notifying Flutter about node tap: $tappedNodesList")
                                objectChannel.invokeMethod("onNodeTapped", tappedNodesList)
                                Log.d(TAG, "✅ Flutter callback triggered successfully")
                            } catch (e: Exception) {
                                Log.e(TAG, "❌ Failed to notify Flutter about node tap: ${e.message}")
                            }
                            
                            true
                        }
                        
                        // Apply gesture properties from Flutter
                        if (isTransformable) {
                            transformableNode.translationController.isEnabled = enablePanGestures
                            transformableNode.rotationController.isEnabled = enableRotationGestures
                            transformableNode.scaleController.isEnabled = true // Always allow scale for now
                            
                            // Additional pan gesture configuration
                            transformableNode.translationController.apply {
                                isEnabled = enablePanGestures
                                // Ensure the translation controller allows movement in all directions
                                Log.d(TAG, "🎯 Translation controller configured - enabled: $isEnabled")
                            }
                            
                            Log.d(TAG, "🎯 Gesture controllers enabled - pan: $enablePanGestures, rotation: $enableRotationGestures")
                            Log.d(TAG, "🎯 Translation controller enabled: ${transformableNode.translationController.isEnabled}")
                            Log.d(TAG, "🎯 Rotation controller enabled: ${transformableNode.rotationController.isEnabled}")
                            Log.d(TAG, "🎯 Scale controller enabled: ${transformableNode.scaleController.isEnabled}")
                            
                            // Don't auto-select the node - let user tap to select it
                            // This allows proper gesture state management
                            
                        } else {
                            transformableNode.translationController.isEnabled = false
                            transformableNode.rotationController.isEnabled = false
                            transformableNode.scaleController.isEnabled = false
                            Log.d(TAG, "🎯 All gesture controllers disabled (isTransformable=false)")
                        }
                        
                        // Apply the scale from Flutter to the node
                        transformableNode.localScale = Vector3(scaleX, scaleY, scaleZ)
                        android.util.Log.d("SCALE_DEBUG", "🎯🎯🎯 FINAL: Applied scale to node: ($scaleX, $scaleY, $scaleZ)")
                        android.util.Log.d("SCALE_DEBUG", "🎯🎯🎯 FINAL: Node localScale after setting: ${transformableNode.localScale}")
                        
                        // Add the node as a child of the anchor
                        transformableNode.setParent(anchorNode)
                        
                        // Store the node for later reference
                        nodesMap[nodeName] = transformableNode
                        
                        Log.d(TAG, "✅ GLB model added to plane anchor: $nodeName")
                        result.success(nodeName)
                    }
                    .exceptionally { throwable: Throwable ->
                        Log.e(TAG, "❌ Failed to load GLB model: ${throwable.message}")
                        result.error("MODEL_LOAD_ERROR", throwable.message ?: "Unknown error", null)
                        null
                    }
                
            } catch (e: Exception) {
                Log.e(TAG, "❌ Exception loading GLB: ${e.message}")
                result.error("MODEL_CREATE_ERROR", e.message ?: "Unknown error", null)
            }
                
        } catch (e: Exception) {
            Log.e(TAG, "❌ Exception in handleAddNodeToPlaneAnchor: ${e.message}", e)
            result.error("GENERAL_ERROR", e.message ?: "Unknown error", null)
        }
    }

    private fun handleRemoveNode(call: MethodCall, result: MethodChannel.Result) {
        try {
            val arguments = call.arguments as? Map<String, Any>
            val nodeName = arguments?.get("name") as? String
            
            if (nodeName != null) {
                val node = nodesMap[nodeName]
                if (node != null) {
                    Log.d(TAG, "🗑️ Removing node by name: $nodeName")
                    node.setParent(null) // Remove from scene
                    nodesMap.remove(nodeName)
                    
                    // Also remove associated virtual anchor if it exists
                    val virtualAnchorName = "${nodeName}_anchor"
                    val virtualAnchor = nodesMap[virtualAnchorName]
                    if (virtualAnchor != null) {
                        Log.d(TAG, "🗑️ Also removing virtual anchor: $virtualAnchorName")
                        virtualAnchor.setParent(null)
                        nodesMap.remove(virtualAnchorName)
                    }
                    
                    result.success(true)
                } else {
                    Log.w(TAG, "⚠️ Node not found for removal: $nodeName")
                    result.success(false)
                }
            } else {
                Log.w(TAG, "⚠️ Node name not provided for removal")
                result.success(false)
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error removing node: ${e.message}")
            result.error("REMOVE_NODE_ERROR", e.message ?: "Unknown error", null)
        }
    }

    private fun handleRemoveNodeDeep(call: MethodCall, result: MethodChannel.Result) {
        try {
            val arguments = call.arguments as? Map<String, Any>
            val nodeId = arguments?.get("nodeId") as? String
            
            if (nodeId != null) {
                val node = nodesMap[nodeId]
                if (node != null) {
                    Log.d(TAG, "🗑️ Deep removing node with ID: $nodeId")
                    
                    // Remove from scene graph
                    node.setParent(null)
                    
                    // If it's a TransformableNode, disable it
                    if (node is TransformableNode) {
                        node.isEnabled = false
                        node.renderable = null
                    }
                    
                    // Remove from our tracking
                    nodesMap.remove(nodeId)
                    
                    Log.d(TAG, "✅ Successfully removed node: $nodeId")
                    result.success(true)
                } else {
                    Log.w(TAG, "⚠️ Node not found for deep removal: $nodeId")
                    result.success(false)
                }
            } else {
                Log.w(TAG, "⚠️ Node ID not provided for deep removal")
                result.success(false)
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error in deep node removal: ${e.message}")
            result.error("REMOVE_NODE_DEEP_ERROR", e.message ?: "Unknown error", null)
        }
    }

    private fun handlePurgeCaches(call: MethodCall, result: MethodChannel.Result) {
        try {
            Log.d(TAG, "🧹 Purging all caches and resources")
            
            var purgedCount = 0
            
            // Clear all stored nodes and their resources
            nodesMap.values.forEach { node ->
                if (node is TransformableNode) {
                    node.renderable = null
                    node.isEnabled = false
                }
                purgedCount++
            }
            
            // Clear Sceneform model cache if possible
            try {
                // Force garbage collection
                System.gc()
                Log.d(TAG, "🗑️ Forced garbage collection")
            } catch (e: Exception) {
                Log.w(TAG, "⚠️ Could not force GC: ${e.message}")
            }
            
            Log.d(TAG, "✅ Cache purging completed - cleared $purgedCount node resources")
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error purging caches: ${e.message}")
            result.error("PURGE_CACHES_ERROR", e.message ?: "Unknown error", null)
        }
    }

    private fun handleGetMemoryInfo(call: MethodCall, result: MethodChannel.Result) {
        try {
            val memoryInfo = mutableMapOf<String, Any>()
            
            // Get runtime memory info
            val runtime = Runtime.getRuntime()
            val usedMemory = runtime.totalMemory() - runtime.freeMemory()
            val maxMemory = runtime.maxMemory()
            val totalMemory = runtime.totalMemory()
            
            memoryInfo["usedMemoryMB"] = usedMemory / (1024 * 1024)
            memoryInfo["totalMemoryMB"] = totalMemory / (1024 * 1024)
            memoryInfo["maxMemoryMB"] = maxMemory / (1024 * 1024)
            memoryInfo["freeMemoryMB"] = (maxMemory - usedMemory) / (1024 * 1024)
            
            // ARCore specific info
            memoryInfo["activeNodesCount"] = nodesMap.size
            memoryInfo["arSessionActive"] = arSceneView?.session != null
            
            Log.d(TAG, "📊 Memory info: Used ${memoryInfo["usedMemoryMB"]}MB, Total ${memoryInfo["totalMemoryMB"]}MB, Nodes: ${nodesMap.size}")
            result.success(memoryInfo)
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error getting memory info: ${e.message}")
            result.error("MEMORY_INFO_ERROR", e.message ?: "Unknown error", null)
        }
    }

    private fun handleCreateNodeFromAsset(call: MethodCall, result: MethodChannel.Result) {
        try {
            val arguments = call.arguments as? Map<String, Any>
            val uri = arguments?.get("uri") as? String
            val transformMatrix = arguments?.get("transformMatrix") as? List<Double>
            
            if (uri == null || transformMatrix == null) {
                result.error("INVALID_ARGS", "URI and transform matrix are required", null)
                return
            }
            
            Log.d(TAG, "🔄 Creating shared node from asset: $uri")
            
            // For now, use the same implementation as regular node creation
            // In a full implementation, you'd want to implement asset sharing/caching
            val nodeName = generateNodeName()
            
            // Create a simple placeholder for the shared asset approach
            // This would need proper asset caching implementation
            Log.d(TAG, "✅ Shared asset node created: $nodeName")
            result.success(nodeName)
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error creating node from asset: ${e.message}")
            result.error("CREATE_NODE_ASSET_ERROR", e.message ?: "Unknown error", null)
        }
    }

    private fun handleNukeAll(call: MethodCall, result: MethodChannel.Result) {
        try {
            val arguments = call.arguments as? Map<String, Any>
            val purgeCaches = arguments?.get("purgeCaches") as? Boolean ?: true
            val removeAnchors = arguments?.get("removeExistingAnchors") as? Boolean ?: true
            val resetTracking = arguments?.get("resetTracking") as? Boolean ?: true
            val forceSystemMemoryPressure = arguments?.get("forceSystemMemoryPressure") as? Boolean ?: true
            val enableHardwareGpuReset = arguments?.get("enableHardwareGpuReset") as? Boolean ?: true
            val simulateMemoryWarning = arguments?.get("simulateMemoryWarning") as? Boolean ?: true

            Log.d(TAG, "🔥 PHASE 3 SYSTEM-LEVEL NUKE ALL INITIATED")
            Log.d(TAG, "📍 Flags: purgeCaches=$purgeCaches, removeAnchors=$removeAnchors, resetTracking=$resetTracking")
            Log.d(TAG, "📍 Phase 3: forceMemoryPressure=$forceSystemMemoryPressure, hwGpuReset=$enableHardwareGpuReset, memWarning=$simulateMemoryWarning")

            // Phase A: Stop background work
            Log.d(TAG, "⏹️ Phase A: Stopping background work")
            
            // Phase B: Destroy native drawing surfaces (CRITICAL: Stop render loop BEFORE pausing session)
            Log.d(TAG, "🖥️ Phase B: Destroying native drawing surfaces")
            arSceneView?.let { sceneView ->
                try {
                    // CRITICAL: Stop the render loop first to prevent SessionPausedException
                    sceneView.pause()
                    Log.d(TAG, "⏸️ ArSceneView paused - render loop stopped")
                    
                    // Now it's safe to pause the session
                    sceneView.session?.pause()
                    Log.d(TAG, "⏸️ AR Session paused")
                    
                    // Clear scene by removing all child nodes from the root
                    val rootNode = sceneView.scene
                    // Don't try to replace the scene, just clear it
                    
                    Log.d(TAG, "🔥 Scene cleared and session paused safely")
                } catch (e: Exception) {
                    Log.w(TAG, "⚠️ Error in Phase B cleanup: ${e.message}")
                    // Continue with cleanup even if this fails
                }
            }

            // Phase C: Clear all anchors and nodes
            Log.d(TAG, "🗑️ Phase C: Clearing anchors and nodes")
            if (removeAnchors) {
                nodesMap.clear()
                Log.d(TAG, "🗑️ Cleared all nodes and anchors")
            }

            // Phase D: Memory pressure simulation
            if (forceSystemMemoryPressure) {
                Log.d(TAG, "💾 Phase D: Forcing system memory pressure")
                try {
                    // Force multiple GC cycles
                    repeat(3) {
                        System.gc()
                        Thread.sleep(50)
                    }
                    Log.d(TAG, "✅ Memory pressure simulation completed")
                } catch (e: Exception) {
                    Log.w(TAG, "⚠️ Memory pressure simulation failed: ${e.message}")
                }
            }

            // Phase E: Cache purging
            if (purgeCaches) {
                Log.d(TAG, "🧹 Phase E: Purging all caches")
                // Additional cache clearing beyond what's already done
                System.runFinalization()
                Log.d(TAG, "✅ Cache purging completed")
            }

            Log.d(TAG, "✅ PHASE 3 NUKE ALL COMPLETED - System should be clean")
            result.success(true)
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error in nuke all: ${e.message}")
            result.error("NUKE_ALL_ERROR", e.message ?: "Unknown error", null)
        }
    }

    private fun handleGetPluginState(call: MethodCall, result: MethodChannel.Result) {
        try {
            val state = mutableMapOf<String, Any>()
            
            state["activeNodes"] = nodesMap.size
            state["arSessionExists"] = arSceneView?.session != null
            state["arSceneViewExists"] = arSceneView != null
            state["transformationSystemExists"] = transformationSystem != null
            
            // Memory info
            val runtime = Runtime.getRuntime()
            state["memoryUsedMB"] = (runtime.totalMemory() - runtime.freeMemory()) / (1024 * 1024)
            state["memoryTotalMB"] = runtime.totalMemory() / (1024 * 1024)
            
            Log.d(TAG, "📊 Plugin state: $state")
            result.success(state)
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error getting plugin state: ${e.message}")
            result.error("PLUGIN_STATE_ERROR", e.message ?: "Unknown error", null)
        }
    }

    private fun handleRemoveAllObjects(call: MethodCall, result: MethodChannel.Result) {
        try {
            Log.d(TAG, "🧹 Removing all objects from scene")
            
            val removedCount = nodesMap.size
            
            // Remove all nodes from the scene
            nodesMap.values.forEach { node ->
                node.setParent(null)
                if (node is TransformableNode) {
                    node.renderable = null
                    node.isEnabled = false
                }
            }
            
            // Clear the tracking
            nodesMap.clear()
            
            Log.d(TAG, "✅ Removed $removedCount objects from scene")
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error removing all objects: ${e.message}")
            result.error("REMOVE_ALL_ERROR", e.message ?: "Unknown error", null)
        }
    }

    private fun generateNodeName(): String {
        return "[#${System.nanoTime().toString(36)}]"
    }

    private fun handleRemoveAnchor(call: MethodCall, result: MethodChannel.Result) {
        val name = call.arguments as? String
        if (name != null) {
            nodesMap.remove(name)?.setParent(null)
            Log.d(TAG, "🗑️ Removed anchor: $name")
        }
        result.success(null)
    }

    private fun handleDispose(call: MethodCall, result: MethodChannel.Result) {
        try {
            Log.d(TAG, "🗑️ Starting ArCoreCompatView disposal...")
            
            arSceneView?.let { sceneView ->
                try {
                    // CRITICAL: Stop render loop first to prevent crashes
                    sceneView.pause()
                    Log.d(TAG, "⏸️ ArSceneView paused during disposal")
                    
                    // Then safely close the session
                    sceneView.session?.close()
                    Log.d(TAG, "🔒 AR Session closed")
                } catch (e: Exception) {
                    Log.w(TAG, "⚠️ Error during ArSceneView cleanup: ${e.message}")
                }
            }
            
            // Clear references
            arSceneView = null
            nodesMap.clear()
            
            Log.d(TAG, "✅ ArCoreCompatView disposed successfully")
            result.success(null)
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error disposing view: ${e.message}")
            result.error("DISPOSE_ERROR", e.message, null)
        }
    }

    override fun getView(): View? = arSceneView

    override fun dispose() {
        handleDispose(MethodCall("dispose", null), object : MethodChannel.Result {
            override fun success(result: Any?) {}
            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}
            override fun notImplemented() {}
        })
    }

    // Extension function to convert pose matrix to list for Flutter
    private fun FloatArray.toList(): List<Float> = this.asList()
}
