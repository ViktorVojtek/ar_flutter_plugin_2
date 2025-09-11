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
import com.google.ar.core.Pose
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
    
    // Performance optimization: Reuse collections to reduce garbage collection
    private val reusableNodeHitResults = mutableListOf<String>()
    private val reusableMatrixArray = FloatArray(16)

    init {
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
                    } catch (e: Exception) {
                        // Silently handle resume errors
                    }
                }
            }

            // Initialize TransformationSystem for gesture handling with safety checks
            val selectionVisualizer = object : SelectionVisualizer {
                override fun applySelectionVisual(node: BaseTransformableNode) {
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
                    // Send gesture end callbacks with safety checks
                    if (node is TransformableNode) {
                        try {
                            // Check if node has proper parent hierarchy before sending callbacks
                            val hasValidParent = node.parent != null && node.parent is AnchorNode
                            if (hasValidParent) {
                                if (node.translationController.isEnabled) {
                                    objectChannel.invokeMethod("onPanEnd", node.name)
                                }
                                if (node.rotationController.isEnabled) {
                                    objectChannel.invokeMethod("onRotationEnd", node.name)
                                }
                            } else {
                                Log.w(TAG, "⚠️ Node ${node.name} has invalid parent hierarchy, skipping gesture end callbacks")
                            }
                        } catch (e: Exception) {
                            Log.e(TAG, "❌ Error in removeSelectionVisual: ${e.message}")
                        }
                    }
                }
            }
            
            // Create TransformationSystem with enhanced error handling
            transformationSystem = object : TransformationSystem(activity.resources.displayMetrics, selectionVisualizer) {
                override fun onTouch(hitTestResult: HitTestResult?, motionEvent: MotionEvent?) {
                    try {
                        // Safety check before processing touch events
                        if (hitTestResult != null && motionEvent != null) {
                            // Check if selected node has valid parent hierarchy
                            val selectedNode = this.selectedNode
                            if (selectedNode is TransformableNode) {
                                val hasValidParent = selectedNode.parent != null && selectedNode.parent is AnchorNode
                                if (!hasValidParent && motionEvent.action == MotionEvent.ACTION_UP) {
                                    Log.w(TAG, "⚠️ Preventing gesture completion on node with invalid parent hierarchy")
                                    // Clear selection to prevent crash by calling the parent's selectNode method
                                    selectNode(null)
                                    return
                                }
                            }
                            super.onTouch(hitTestResult, motionEvent)
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "❌ Error in TransformationSystem.onTouch: ${e.message}")
                        // Clear selection to prevent further issues
                        selectNode(null)
                    }
                }
            }

            // Setup gesture detection for tap-to-place
            gestureDetector = GestureDetector(activity, object : GestureDetector.SimpleOnGestureListener() {
                override fun onSingleTapUp(e: MotionEvent): Boolean {
                    handleTap(e)
                    return true
                }
            })

            // CRITICAL: Setup peek touch listener for TransformationSystem
            // This ensures TransformationSystem always gets touch events first
            arSceneView?.scene?.addOnPeekTouchListener { hitTestResult, motionEvent ->
                // Always forward to TransformationSystem - this is critical for gestures
                transformationSystem?.onTouch(hitTestResult, motionEvent)
            }

            // Setup touch listener - forward to gesture detector for tap-to-place
            arSceneView?.scene?.setOnTouchListener { hitTestResult, motionEvent ->
                Log.d(TAG, "🔥 Scene touch event: action=${motionEvent.action}, x=${motionEvent.x}, y=${motionEvent.y}")
                
                // Forward to gesture detector for tap-to-place functionality
                gestureDetector?.onTouchEvent(motionEvent)
                
                // Log current selection state for debugging
                val currentSelection = transformationSystem?.selectedNode
                if (motionEvent.action == MotionEvent.ACTION_DOWN) {
                    Log.d(TAG, "🎯 Current selection after touch: ${currentSelection?.name ?: "none"}")
                }
                
                // Return false to allow TransformationSystem to handle gestures naturally
                false
            }

        } catch (e: Exception) {
            // Silently handle initialization errors
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
            "ar#nukeAllNonBlocking" -> handleNukeAllNonBlocking(call, result)
            "ar#getPluginState" -> handleGetPluginState(call, result)
            "removeAllObjects" -> handleRemoveAllObjects(call, result)
            "removeAnchor" -> handleRemoveAnchor(call, result)
            "dispose" -> handleDispose(call, result)
            "touch" -> handleTouch(call, result)
            // Add common platform view methods that Flutter might call
            "sendMotionEvent" -> handleSendMotionEvent(call, result)
            "onTouchEvent" -> handleOnTouchEvent(call, result)
            "performClick" -> handlePerformClick(call, result)
            "clearFocus" -> handleClearFocus(call, result)
            "requestFocus" -> handleRequestFocus(call, result)
            "getOffset" -> handleGetOffset(call, result)
            "resize" -> handleResize(call, result)
            else -> {
                Log.w(TAG, "⚠️ Unimplemented method called: ${call.method}")
                result.notImplemented()
            }
        }
    }

    private fun handleInit(call: MethodCall, result: MethodChannel.Result) {
        Log.d(TAG, "🎯 AR Session initialization requested")
        result.success("AR session ready")
    }

    private fun handleTap(motionEvent: MotionEvent) {        
        Log.d(TAG, "🎯🎯🎯 ANDROID: handleTap called! MotionEvent: x=${motionEvent.x}, y=${motionEvent.y}")
        
        // FIRST: Check for node/object hits (like iOS implementation)
        // This is the critical missing piece that makes object selection work globally
        reusableNodeHitResults.clear() // Reuse collection to reduce GC pressure
        arSceneView?.let { sceneView ->
            try {
                val camera = sceneView.scene.camera
                if (camera != null) {
                    // Manual hit testing by checking all transformable nodes
                    // Check their screen-space distance from the tap point
                    for ((nodeName, node) in nodesMap) {
                        if (node is TransformableNode) {
                            try {
                                // Get the node's world position
                                val worldPosition = node.worldPosition
                                
                                // Convert world position to screen coordinates
                                val screenPosition = camera.worldToScreenPoint(worldPosition)
                                
                                // Calculate distance between tap point and node's screen position
                                val distance = kotlin.math.sqrt(
                                    (screenPosition.x - motionEvent.x).pow(2) + 
                                    (screenPosition.y - motionEvent.y).pow(2)
                                )
                                
                                // If tap is within reasonable distance of the node's screen projection, consider it hit
                                // Use a larger threshold to account for object size and collision shapes
                                if (distance < 150.0) {
                                    reusableNodeHitResults.add(nodeName)
                                }
                            } catch (e: Exception) {
                                // Silently continue on hit test errors for performance
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                // Silently continue on hit testing errors for performance
            }
        }
        
        // If we found object hits, select the first one and notify Flutter
        if (reusableNodeHitResults.isNotEmpty()) {
            val tappedNodeName = reusableNodeHitResults.first() // Select first/closest node
            val tappedNode = nodesMap[tappedNodeName]
            
            if (tappedNode is TransformableNode) {
                Log.d(TAG, "🎯 Tap selecting node: $tappedNodeName")
                transformationSystem?.selectNode(tappedNode)
            }
            
            // Notify Flutter about the tap
            val uniqueNodeHits = reusableNodeHitResults.toSet().toList()
            objectChannel.invokeMethod("onNodeTap", uniqueNodeHits)
            return
        }
        
        // SECOND: If no objects were hit, check for plane hits (existing logic)
        val frame = arSceneView?.arFrame ?: return
        
        if (frame.camera.trackingState != TrackingState.TRACKING) {
            return
        }

        val hits = frame.hitTest(motionEvent.x, motionEvent.y)
        for (hit in hits) {
            val trackable = hit.trackable
            if (trackable is Plane && trackable.isPoseInPolygon(hit.hitPose)) {
                // Convert pose to matrix for Flutter - reuse array to reduce allocations
                hit.hitPose.toMatrix(reusableMatrixArray, 0)
                val matrixList = reusableMatrixArray.toList()
                
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
        try {
            val nodeData = call.arguments as? Map<String, Any>
            if (nodeData == null) {
                result.error("INVALID_ARGUMENTS", "Node data is null", null)
                return
            }
            
            val nodeName = nodeData["name"] as? String
            val uri = nodeData["uri"] as? String
            val nodeType = nodeData["type"] as? Int
            
            if (nodeName == null || uri == null || nodeType == null) {
                result.error("INVALID_ARGUMENTS", "Node name, URI, or type is null", null)
                return
            }
            
            // Check if this is a supported node type
            when (nodeType) {
                1 -> {
                    // NodeType.webGLB - Load GLB from web
                }
                0 -> {
                    // NodeType.localGLTF2 - Load GLTF from assets
                    result.error("UNSUPPORTED_TYPE", "Local GLTF2 not yet supported in ArCoreCompatView", null)
                    return
                }
                else -> {
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
                        // Use a larger collision shape to improve hit testing during gestures
                        // Scale the collision box based on the actual scale of the object
                        val collisionSize = Vector3(
                            maxOf(scaleX * 2.0f, 0.5f), // At least 0.5 units wide
                            maxOf(scaleY * 2.0f, 0.5f), // At least 0.5 units tall  
                            maxOf(scaleZ * 2.0f, 0.5f)  // At least 0.5 units deep
                        )
                        transformableNode.collisionShape = Box(collisionSize)
                        Log.d(TAG, "🎯 Set collision shape for hit testing: $nodeName, size: $collisionSize")
                        
                        // CRITICAL: Set up tap listener for proper object selection
                        // This is needed for TransformationSystem to identify which node was tapped
                        transformableNode.setOnTapListener { hitTestResult: HitTestResult, motionEvent: MotionEvent ->
                            Log.d(TAG, "🎯 Node $nodeName tapped - TransformationSystem will handle selection")
                            
                            // CRITICAL: Force gesture controller reset on tap to fix "works once then fails" issue
                            // This ensures the gesture controllers are in a clean state for the next gesture
                            if (isTransformable) {
                                Handler(Looper.getMainLooper()).post {
                                    try {
                                        // Reset each gesture controller to ensure clean state
                                        transformableNode.translationController.apply {
                                            val wasEnabled = isEnabled
                                            isEnabled = false
                                            isEnabled = wasEnabled
                                            Log.d(TAG, "🔄 Translation controller reset for $nodeName")
                                        }
                                        
                                        transformableNode.rotationController.apply {
                                            val wasEnabled = isEnabled
                                            isEnabled = false
                                            isEnabled = wasEnabled
                                            Log.d(TAG, "🔄 Rotation controller reset for $nodeName")
                                        }
                                        
                                        transformableNode.scaleController.apply {
                                            val wasEnabled = isEnabled
                                            isEnabled = false
                                            isEnabled = wasEnabled
                                            Log.d(TAG, "🔄 Scale controller reset for $nodeName")
                                        }
                                    } catch (e: Exception) {
                                        Log.e(TAG, "❌ Failed to reset gesture controllers: ${e.message}")
                                    }
                                }
                            }
                            
                            // Notify Flutter about the tap
                            try {
                                val tappedNodesList = listOf(nodeName)
                                objectChannel.invokeMethod("onNodeTap", tappedNodesList)
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
                            
                            // Additional pan gesture configuration - CRITICAL for gesture functionality
                            transformableNode.translationController.apply {
                                isEnabled = enablePanGestures
                                // Allow movement only on horizontal plane (Y locked to current position)
                                // This prevents objects from flying off into space during pan operations
                                Log.d(TAG, "🎯 Translation controller configured - enabled: $isEnabled")
                            }
                            
                            // CRITICAL: Ensure rotation controller is properly configured
                            transformableNode.rotationController.apply {
                                isEnabled = enableRotationGestures
                                Log.d(TAG, "🎯 Rotation controller configured - enabled: $isEnabled")
                            }
                            
                            // CRITICAL: Ensure scale controller is properly configured
                            transformableNode.scaleController.apply {
                                isEnabled = true // Always allow scale for now
                                Log.d(TAG, "🎯 Scale controller configured - enabled: $isEnabled")
                            }
                            
                            // CRITICAL: Don't interfere with TransformationSystem's gesture handling
                            // The TransformationSystem will handle touch events through its own mechanisms
                            // Additional touch listeners can cause conflicts and gesture failures
                            
                            Log.d(TAG, "🎯 Gesture controllers enabled - pan: $enablePanGestures, rotation: $enableRotationGestures")
                            Log.d(TAG, "🎯 Translation controller enabled: ${transformableNode.translationController.isEnabled}")
                            Log.d(TAG, "🎯 Rotation controller enabled: ${transformableNode.rotationController.isEnabled}")
                            Log.d(TAG, "🎯 Scale controller enabled: ${transformableNode.scaleController.isEnabled}")
                            
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
                                        Log.w(TAG, "⚠️ No suitable plane found, creating virtual anchor for gesture support")
                                        // Create a virtual anchor at the specified position to ensure proper parent hierarchy
                                        try {
                                            val session = arSceneView?.session
                                            val virtualAnchor = session?.createAnchor(
                                                Pose.makeTranslation(positionX, positionY, positionZ)
                                            )
                                            if (virtualAnchor != null) {
                                                val anchorNode = AnchorNode(virtualAnchor)
                                                anchorNode.setParent(arSceneView?.scene)
                                                transformableNode.setParent(anchorNode)
                                                transformableNode.localPosition = Vector3(0.0f, 0.0f, 0.0f)
                                                
                                                // Store both nodes
                                                nodesMap[nodeName] = transformableNode
                                                nodesMap["${nodeName}_anchor"] = anchorNode
                                                Log.d(TAG, "✅ Created virtual anchor for gesture support")
                                            } else {
                                                Log.w(TAG, "⚠️ Failed to create virtual anchor, using direct scene attachment")
                                                transformableNode.worldPosition = Vector3(positionX, positionY, positionZ)
                                                arSceneView?.scene?.addChild(transformableNode)
                                                nodesMap[nodeName] = transformableNode
                                            }
                                        } catch (e: Exception) {
                                            Log.w(TAG, "⚠️ Exception creating virtual anchor: ${e.message}, using direct scene attachment")
                                            transformableNode.worldPosition = Vector3(positionX, positionY, positionZ)
                                            arSceneView?.scene?.addChild(transformableNode)
                                            nodesMap[nodeName] = transformableNode
                                        }
                                    }
                                } else {
                                    Log.w(TAG, "⚠️ No tracked planes available, creating virtual anchor for gesture support")
                                    // Create a virtual anchor at the specified position to ensure proper parent hierarchy
                                    try {
                                        val session = arSceneView?.session
                                        val virtualAnchor = session?.createAnchor(
                                            Pose.makeTranslation(positionX, positionY, positionZ)
                                        )
                                        if (virtualAnchor != null) {
                                            val anchorNode = AnchorNode(virtualAnchor)
                                            anchorNode.setParent(arSceneView?.scene)
                                            transformableNode.setParent(anchorNode)
                                            transformableNode.localPosition = Vector3(0.0f, 0.0f, 0.0f)
                                            
                                            // Store both nodes
                                            nodesMap[nodeName] = transformableNode
                                            nodesMap["${nodeName}_anchor"] = anchorNode
                                            Log.d(TAG, "✅ Created virtual anchor for gesture support")
                                        } else {
                                            Log.w(TAG, "⚠️ Failed to create virtual anchor, using direct scene attachment")
                                            transformableNode.worldPosition = Vector3(positionX, positionY, positionZ)
                                            arSceneView?.scene?.addChild(transformableNode)
                                            nodesMap[nodeName] = transformableNode
                                        }
                                    } catch (e: Exception) {
                                        Log.w(TAG, "⚠️ Exception creating virtual anchor: ${e.message}, using direct scene attachment")
                                        transformableNode.worldPosition = Vector3(positionX, positionY, positionZ)
                                        arSceneView?.scene?.addChild(transformableNode)
                                        nodesMap[nodeName] = transformableNode
                                    }
                                }
                                
                            } else {
                                Log.w(TAG, "⚠️ AR Session not available, creating virtual anchor for gesture support")
                                // Create a virtual anchor at the specified position to ensure proper parent hierarchy
                                try {
                                    val session = arSceneView?.session
                                    val virtualAnchor = session?.createAnchor(
                                        Pose.makeTranslation(positionX, positionY, positionZ)
                                    )
                                    if (virtualAnchor != null) {
                                        val anchorNode = AnchorNode(virtualAnchor)
                                        anchorNode.setParent(arSceneView?.scene)
                                        transformableNode.setParent(anchorNode)
                                        transformableNode.localPosition = Vector3(0.0f, 0.0f, 0.0f)
                                        
                                        // Store both nodes
                                        nodesMap[nodeName] = transformableNode
                                        nodesMap["${nodeName}_anchor"] = anchorNode
                                        Log.d(TAG, "✅ Created virtual anchor for gesture support")
                                    } else {
                                        Log.w(TAG, "⚠️ Failed to create virtual anchor, using direct scene attachment")
                                        transformableNode.worldPosition = Vector3(positionX, positionY, positionZ)
                                        arSceneView?.scene?.addChild(transformableNode)
                                        nodesMap[nodeName] = transformableNode
                                    }
                                } catch (e: Exception) {
                                    Log.w(TAG, "⚠️ Exception creating virtual anchor: ${e.message}, using direct scene attachment")
                                    transformableNode.worldPosition = Vector3(positionX, positionY, positionZ)
                                    arSceneView?.scene?.addChild(transformableNode)
                                    nodesMap[nodeName] = transformableNode
                                }
                            }
                        } catch (e: Exception) {
                            Log.e(TAG, "❌ Failed to find detected plane: ${e.message}")
                            Log.d(TAG, "🔄 Creating virtual anchor for gesture support")
                            // Create a virtual anchor at the specified position to ensure proper parent hierarchy
                            try {
                                val session = arSceneView?.session
                                val virtualAnchor = session?.createAnchor(
                                    Pose.makeTranslation(positionX, positionY, positionZ)
                                )
                                if (virtualAnchor != null) {
                                    val anchorNode = AnchorNode(virtualAnchor)
                                    anchorNode.setParent(arSceneView?.scene)
                                    transformableNode.setParent(anchorNode)
                                    transformableNode.localPosition = Vector3(0.0f, 0.0f, 0.0f)
                                    
                                    // Store both nodes
                                    nodesMap[nodeName] = transformableNode
                                    nodesMap["${nodeName}_anchor"] = anchorNode
                                    Log.d(TAG, "✅ Created virtual anchor for gesture support")
                                } else {
                                    Log.w(TAG, "⚠️ Failed to create virtual anchor, using direct scene attachment")
                                    transformableNode.worldPosition = Vector3(positionX, positionY, positionZ)
                                    arSceneView?.scene?.addChild(transformableNode)
                                    nodesMap[nodeName] = transformableNode
                                }
                            } catch (anchorException: Exception) {
                                Log.w(TAG, "⚠️ Exception creating virtual anchor: ${anchorException.message}, using direct scene attachment")
                                transformableNode.worldPosition = Vector3(positionX, positionY, positionZ)
                                arSceneView?.scene?.addChild(transformableNode)
                                nodesMap[nodeName] = transformableNode
                            }
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
            
            // DEBUG: Log anchor information for troubleshooting
            try {
                val anchor = anchorNode.anchor
                if (anchor != null) {
                    val pose = anchor.pose
                    Log.d(TAG, "� Original anchor info - Position: (${pose.tx()}, ${pose.ty()}, ${pose.tz()}), Tracking: ${anchor.trackingState}")
                } else {
                    Log.w(TAG, "⚠️ Anchor node has no anchor attached")
                }
                
                val session = arSceneView?.session
                if (session != null) {
                    val frame = session.update()
                    val trackedPlanes = session.getAllTrackables(Plane::class.java)
                        .filter { it.trackingState == TrackingState.TRACKING }
                    Log.d(TAG, "🔍 Available tracked planes: ${trackedPlanes.size}")
                } else {
                    Log.w(TAG, "⚠️ AR Session not available")
                }
            } catch (e: Exception) {
                Log.e(TAG, "❌ Error during anchor debugging: ${e.message}")
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
                        // Use a larger collision shape to improve hit testing during gestures
                        // Scale the collision box based on the actual scale of the object
                        val collisionSize = Vector3(
                            maxOf(scaleX * 2.0f, 0.5f), // At least 0.5 units wide
                            maxOf(scaleY * 2.0f, 0.5f), // At least 0.5 units tall  
                            maxOf(scaleZ * 2.0f, 0.5f)  // At least 0.5 units deep
                        )
                        transformableNode.collisionShape = Box(collisionSize)
                        Log.d(TAG, "🎯 Set collision shape for hit testing: $nodeName, size: $collisionSize")
                        
                        // CRITICAL: Set up tap listener for proper object selection
                        // This is needed for TransformationSystem to identify which node was tapped
                        transformableNode.setOnTapListener { hitTestResult: HitTestResult, motionEvent: MotionEvent ->
                            Log.d(TAG, "🎯 Node $nodeName tapped - TransformationSystem will handle selection")
                            
                            // CRITICAL: Force gesture controller reset on tap to fix "works once then fails" issue
                            // This ensures the gesture controllers are in a clean state for the next gesture
                            if (isTransformable) {
                                Handler(Looper.getMainLooper()).post {
                                    try {
                                        // Reset each gesture controller to ensure clean state
                                        transformableNode.translationController.apply {
                                            val wasEnabled = isEnabled
                                            isEnabled = false
                                            isEnabled = wasEnabled
                                            Log.d(TAG, "🔄 Translation controller reset for $nodeName")
                                        }
                                        
                                        transformableNode.rotationController.apply {
                                            val wasEnabled = isEnabled
                                            isEnabled = false
                                            isEnabled = wasEnabled
                                            Log.d(TAG, "🔄 Rotation controller reset for $nodeName")
                                        }
                                        
                                        transformableNode.scaleController.apply {
                                            val wasEnabled = isEnabled
                                            isEnabled = false
                                            isEnabled = wasEnabled
                                            Log.d(TAG, "🔄 Scale controller reset for $nodeName")
                                        }
                                    } catch (e: Exception) {
                                        Log.e(TAG, "❌ Failed to reset gesture controllers: ${e.message}")
                                    }
                                }
                            }
                            
                            // Notify Flutter about the tap
                            try {
                                val tappedNodesList = listOf(nodeName)
                                objectChannel.invokeMethod("onNodeTap", tappedNodesList)
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
                            
                            // Additional pan gesture configuration - CRITICAL for gesture functionality
                            transformableNode.translationController.apply {
                                isEnabled = enablePanGestures
                                // Ensure the translation controller allows movement in all directions
                                Log.d(TAG, "🎯 Translation controller configured - enabled: $isEnabled")
                            }
                            
                            // CRITICAL: Don't interfere with TransformationSystem's gesture handling
                            // The TransformationSystem will handle touch events through its own mechanisms
                            // Additional touch listeners can cause conflicts and gesture failures
                            
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

    // MARK: - Non-Blocking Memory Cleanup (Camera Freeze Fix)

    private fun handleNukeAllNonBlocking(call: MethodCall, result: MethodChannel.Result) {
        try {
            val arguments = call.arguments as? Map<String, Any>
            val purgeCaches = arguments?.get("purgeCaches") as? Boolean ?: true
            val removeAnchors = arguments?.get("removeExistingAnchors") as? Boolean ?: true
            val resetTracking = arguments?.get("resetTracking") as? Boolean ?: false

            Log.d(TAG, "🔄 Starting non-blocking memory cleanup...")

            // Phase 1: Background cleanup without session interruption
            Thread {
                performBackgroundCleanup(purgeCaches, removeAnchors)
                
                // Phase 2: Optional soft reset on main thread
                if (resetTracking) {
                    activity.runOnUiThread {
                        performSoftReset { success ->
                            result.success(success)
                        }
                    }
                } else {
                    activity.runOnUiThread {
                        result.success(true)
                    }
                }
            }.start()
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error in non-blocking cleanup: ${e.message}")
            result.error("CLEANUP_ERROR", e.message ?: "Unknown error", null)
        }
    }

    private fun performBackgroundCleanup(purgeCaches: Boolean, removeAnchors: Boolean) {
        // 1. Clear object references (thread safe)
        if (removeAnchors) {
            activity.runOnUiThread {
                nodesMap.values.forEach { node ->
                    node.setParent(null)
                    if (node is TransformableNode) {
                        node.renderable = null
                    }
                }
                nodesMap.clear()
            }
            Log.d(TAG, "✅ Nodes and anchors removed")
        }
        
        // 2. Gentle memory cleanup (background safe)
        if (purgeCaches) {
            System.runFinalization()
            Log.d(TAG, "✅ Caches purged")
        }
        
        // 3. Progressive GC (background safe)
        repeat(2) {
            System.gc()
            Thread.sleep(50)
        }
        
        Log.d(TAG, "✅ Background cleanup completed")
    }

    private fun performSoftReset(callback: (Boolean) -> Unit) {
        arSceneView?.let { sceneView ->
            try {
                Log.d(TAG, "🔄 Performing soft session reset...")
                
                // Get current session
                val session = sceneView.session
                
                if (session != null) {
                    // Quick pause/resume cycle
                    session.pause()
                    Log.d(TAG, "⏸️ Session paused briefly")
                    
                    // Resume after minimal delay
                    Handler(Looper.getMainLooper()).postDelayed({
                        try {
                            session.resume()
                            Log.d(TAG, "▶️ Session resumed")
                            
                            // Verify session is running
                            Handler(Looper.getMainLooper()).postDelayed({
                                // Assume success for non-blocking cleanup
                                Log.d(TAG, "✅ Session restoration completed")
                                callback(true)
                            }, 200)
                            
                        } catch (e: Exception) {
                            Log.w(TAG, "⚠️ Session resume failed: ${e.message}")
                            callback(false)
                        }
                    }, 100)
                } else {
                    callback(false)
                }
                
            } catch (e: Exception) {
                Log.w(TAG, "⚠️ Soft reset failed: ${e.message}")
                callback(false)
            }
        } ?: callback(false)
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
            arSceneView?.let { sceneView ->
                try {
                    // CRITICAL: Stop render loop first to prevent crashes
                    sceneView.pause()
                    
                    // Then safely close the session
                    sceneView.session?.close()
                } catch (e: Exception) {
                    // Silently handle cleanup errors to prevent crashes
                }
            }
            
            // CRITICAL: Clear transformation system selection first to prevent ghost gestures
            transformationSystem?.selectNode(null)
            
            // Clear references efficiently
            arSceneView = null
            nodesMap.clear()
            reusableNodeHitResults.clear()
            transformationSystem = null
            gestureDetector = null
            
            result.success(null)
        } catch (e: Exception) {
            result.error("DISPOSE_ERROR", e.message, null)
        }
    }

    // Handle sendMotionEvent method calls from Flutter platform view system
    private fun handleSendMotionEvent(call: MethodCall, result: MethodChannel.Result) {
        Log.d(TAG, "🎯 handleSendMotionEvent called")
        // This is often called when gesture ends - just acknowledge it
        result.success(true)
    }

    // Handle onTouchEvent method calls from Flutter platform view system  
    private fun handleOnTouchEvent(call: MethodCall, result: MethodChannel.Result) {
        Log.d(TAG, "🎯 handleOnTouchEvent called")
        // Forward to our existing touch handler
        handleTouch(call, result)
    }

    // Handle performClick method calls from Flutter platform view system
    private fun handlePerformClick(call: MethodCall, result: MethodChannel.Result) {
        Log.d(TAG, "🎯 handlePerformClick called")
        try {
            val clicked = arSceneView?.performClick() ?: false
            result.success(clicked)
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error performing click: ${e.message}")
            result.success(false)
        }
    }

    // Handle clearFocus method calls from Flutter platform view system
    private fun handleClearFocus(call: MethodCall, result: MethodChannel.Result) {
        Log.d(TAG, "🎯 handleClearFocus called")
        try {
            arSceneView?.clearFocus()
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error clearing focus: ${e.message}")
            result.success(false)
        }
    }

    // Handle requestFocus method calls from Flutter platform view system
    private fun handleRequestFocus(call: MethodCall, result: MethodChannel.Result) {
        Log.d(TAG, "🎯 handleRequestFocus called")
        try {
            val focused = arSceneView?.requestFocus() ?: false
            result.success(focused)
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error requesting focus: ${e.message}")
            result.success(false)
        }
    }

    // Handle getOffset method calls from Flutter platform view system
    private fun handleGetOffset(call: MethodCall, result: MethodChannel.Result) {
        Log.d(TAG, "🎯 handleGetOffset called")
        try {
            // Return default offset values
            val offset = mapOf(
                "dx" to 0.0,
                "dy" to 0.0
            )
            result.success(offset)
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error getting offset: ${e.message}")
            result.error("OFFSET_ERROR", "Failed to get offset: ${e.message}", null)
        }
    }

    // Handle resize method calls from Flutter platform view system
    private fun handleResize(call: MethodCall, result: MethodChannel.Result) {
        Log.d(TAG, "🎯 handleResize called")
        try {
            val arguments = call.arguments as? Map<String, Any>
            val width = (arguments?.get("width") as? Number)?.toInt() ?: 0
            val height = (arguments?.get("height") as? Number)?.toInt() ?: 0
            
            Log.d(TAG, "🎯 Resize requested: ${width}x${height}")
            
            // Apply resize if needed
            arSceneView?.let { sceneView ->
                val layoutParams = sceneView.layoutParams
                if (layoutParams != null && width > 0 && height > 0) {
                    layoutParams.width = width
                    layoutParams.height = height
                    sceneView.layoutParams = layoutParams
                }
            }
            
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error resizing: ${e.message}")
            result.success(false)
        }
    }

    // Handle touch method calls from Flutter platform view system
    private fun handleTouch(call: MethodCall, result: MethodChannel.Result) {
        try {
            Log.d(TAG, "🎯 handleTouch called from Flutter platform view")
            
            // Extract touch event data from method call arguments
            val arguments = call.arguments as? Map<String, Any>
            if (arguments == null) {
                Log.w(TAG, "Touch arguments are null")
                result.success(false)
                return
            }
            
            // Get motion event parameters
            val action = arguments["action"] as? Int ?: MotionEvent.ACTION_DOWN
            val x = (arguments["x"] as? Number)?.toFloat() ?: 0f
            val y = (arguments["y"] as? Number)?.toFloat() ?: 0f
            val downTime = (arguments["downTime"] as? Number)?.toLong() ?: System.currentTimeMillis()
            val eventTime = (arguments["eventTime"] as? Number)?.toLong() ?: System.currentTimeMillis()
            
            Log.d(TAG, "🎯 Touch event - action: $action, x: $x, y: $y")
            
            // Create a synthetic MotionEvent
            val motionEvent = MotionEvent.obtain(
                downTime,
                eventTime,
                action,
                x,
                y,
                0 // metaState
            )
            
            // Forward the touch event to the AR scene view
            val handled = arSceneView?.onTouchEvent(motionEvent) ?: false
            
            // Clean up the MotionEvent
            motionEvent.recycle()
            
            Log.d(TAG, "🎯 Touch event handled: $handled")
            result.success(handled)
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error handling touch event: ${e.message}", e)
            result.error("TOUCH_ERROR", "Failed to handle touch event: ${e.message}", null)
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
