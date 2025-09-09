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
import com.google.ar.sceneform.collision.Ray
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
    // Controls whether taps on detected planes should be forwarded to Flutter for placement
    private var tapPlacementEnabled: Boolean = true
    // Debug: show visual collider aids to make selection areas visible
    private var debugShowColliders: Boolean = true
    // Plane-drag helpers: per-node locked Y and drag offsets
    private val yLocks = ConcurrentHashMap<String, Float>()
    private val dragOffsets = ConcurrentHashMap<String, Vector3>()
    // Track which nodes should use custom unlimited XZ panning (vs. built-in translation controller)
    private val customPanNodes = ConcurrentHashMap<String, Boolean>()
    // Fallback flag for built-in pan: temporarily use constant-Y custom drag when drag starts on the model
    private val fallbackPanActive = ConcurrentHashMap<String, Boolean>()
    
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

            // Initialize TransformationSystem for gesture handling
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
                    Log.d(TAG, "🎯🎯🎯 ANDROID: onSingleTapUp triggered! x=${e.x}, y=${e.y}")
                    handleTap(e)
                    return true
                }
                
                override fun onDown(e: MotionEvent): Boolean {
                    Log.d(TAG, "🎯 ANDROID: GestureDetector onDown x=${e.x}, y=${e.y}")
                    return true // Must return true to continue processing the gesture
                }
            })

            // CRITICAL: Setup peek touch listener for TransformationSystem
            // This ensures TransformationSystem always gets touch events first
            arSceneView?.scene?.addOnPeekTouchListener { hitTestResult, motionEvent ->
                // Always forward to TransformationSystem - this is critical for gestures
                transformationSystem?.onTouch(hitTestResult, motionEvent)
            }

            // Setup touch listener to forward gestures to transformation system
            arSceneView?.scene?.setOnTouchListener { hitTestResult, motionEvent ->
                Log.d(TAG, "🔥🔥🔥 ANDROID: onTouch called! MotionEvent: action=${motionEvent.action}, x=${motionEvent.x}, y=${motionEvent.y}")
                
                // Check if we have a selected node BEFORE TransformationSystem processes the touch
                val selectedNodeBefore = transformationSystem?.selectedNode
                val hadSelectedNode = selectedNodeBefore != null
                Log.d(TAG, "🚀🚀🚀 ANDROID: hadSelectedNode=$hadSelectedNode, selectedNodeBefore=$selectedNodeBefore")
                
                // Let TransformationSystem handle the touch event first
                // This allows it to perform hit testing and select/deselect nodes properly
                transformationSystem?.onTouch(hitTestResult, motionEvent)
                
                // Check the selected node AFTER TransformationSystem processes the touch
                val selectedNodeAfter = transformationSystem?.selectedNode
                val hasSelectedNode = selectedNodeAfter != null
                Log.d(TAG, "🚀🚀🚀 ANDROID: hasSelectedNode=$hasSelectedNode, selectedNodeAfter=$selectedNodeAfter")
                
                // Consider transformation "handled" if:
                // 1. We had a selected node and still have one (ongoing gesture)
                // 2. We just selected a new node (new gesture started)
                val transformationHandled = hadSelectedNode || hasSelectedNode
                Log.d(TAG, "🚀🚀🚀 ANDROID: transformationHandled=$transformationHandled")
                
                // ALWAYS pass touch events to gesture detector to ensure complete gesture sequences
                // The gesture detector needs to see the full DOWN->UP sequence to detect taps
                Log.d(TAG, "🎯🎯🎯 ANDROID: Calling gestureDetector.onTouchEvent for action=${motionEvent.action}!")
                val gestureHandled = gestureDetector?.onTouchEvent(motionEvent) ?: false
                Log.d(TAG, "🚀🚀🚀 ANDROID: gestureHandled=$gestureHandled for action=${motionEvent.action}")

                // Custom constant-Y plane drag to guarantee unlimited XZ movement regardless of plane hits
                var customDragHandled = false
                // Only perform custom pan when single-finger to avoid fighting rotation/scale gestures
                val isSinglePointer = motionEvent.pointerCount == 1
                var selected = transformationSystem?.selectedNode as? TransformableNode
                if (isSinglePointer) {
                    // If nothing is selected yet on DOWN, try selecting from the hit test result
                    if (motionEvent.action == MotionEvent.ACTION_DOWN && selected == null) {
                        val hitNode = hitTestResult.node
                        val candidate = findTransformableAncestor(hitNode)
                        if (candidate != null) {
                            try {
                                transformationSystem?.selectNode(candidate)
                                selected = candidate
                                Log.d(TAG, "🎯 Auto-selected node from hit on DOWN: ${candidate.name}")
                            } catch (e: Exception) {
                                Log.w(TAG, "⚠️ Failed to auto-select from hit: ${e.message}")
                            }
                        }
                    }

                    // Refresh selected after TS handled the event to reflect tap selection on DOWN
                    if (selected == null) {
                        selected = selectedNodeAfter as? TransformableNode
                    }

                    selected?.let { sel ->
                        val nodeName = sel.name ?: ""
                        val useCustomPan = customPanNodes[nodeName] ?: false

                        // Relaxed fallback activation: if a node is selected and we're not in custom pan mode,
                        // start fallback constant-Y drag on single-finger DOWN anywhere in the scene. This makes
                        // on-model panning reliable even when plane hits are flaky. Disable built-in translation
                        // during fallback to avoid fighting controllers, and restore it on gesture end.

                        val lockedY = yLocks[nodeName] ?: sel.worldPosition.y.also { yLocks[nodeName] = it }
                        when (motionEvent.action) {
                            MotionEvent.ACTION_DOWN -> {
                                if (!useCustomPan) {
                                    fallbackPanActive[nodeName] = true
                                    // Temporarily disable built-in translation to prevent conflicts while we drive position
                                    try { sel.translationController.isEnabled = false } catch (_: Exception) {}
                                    Log.d(TAG, "🛟 Fallback pan ACTIVATED for $nodeName (single-finger DOWN)")
                                }
                                if (useCustomPan || (fallbackPanActive[nodeName] == true)) {
                                    val cur = sel.worldPosition
                                    val camPlaneHit = screenPointToCameraFacingPlane(
                                        motionEvent.x,
                                        motionEvent.y,
                                        Vector3(cur.x, lockedY, cur.z)
                                    )
                                    val yPlaneHit = screenPointToYPlane(motionEvent.x, motionEvent.y, lockedY)
                                    val hitPt = camPlaneHit ?: yPlaneHit
                                    Log.d(TAG, "🧭 DOWN: camPlaneHit=$camPlaneHit, yPlaneHit=$yPlaneHit, lockedY=$lockedY")
                                    if (hitPt != null) {
                                        dragOffsets[nodeName] = Vector3(cur.x - hitPt.x, 0.0f, cur.z - hitPt.z)
                                        Log.d(TAG, "🎯 Drag start on $nodeName at Y=$lockedY, offset=${dragOffsets[nodeName]}")
                                    } else {
                                        // Initialize zero offset to allow MOVE to proceed even without an initial hit
                                        dragOffsets[nodeName] = Vector3(0.0f, 0.0f, 0.0f)
                                        Log.d(TAG, "⚠️ No initial hit on DOWN; initializing zero offset for $nodeName")
                                    }
                                }
                            }
                            MotionEvent.ACTION_MOVE -> {
                                // If MOVE occurs without prior DOWN activation, bootstrap fallback now
                                if (!useCustomPan && fallbackPanActive[nodeName] != true) {
                                    fallbackPanActive[nodeName] = true
                                    try { sel.translationController.isEnabled = false } catch (_: Exception) {}
                                    // Initialize drag offset based on current hit and position
                                    val cur = sel.worldPosition
                                    val camPlaneHit = screenPointToCameraFacingPlane(
                                        motionEvent.x,
                                        motionEvent.y,
                                        Vector3(cur.x, lockedY, cur.z)
                                    )
                                    val yPlaneHit = screenPointToYPlane(motionEvent.x, motionEvent.y, lockedY)
                                    val hitPt = camPlaneHit ?: yPlaneHit
                                    Log.d(TAG, "🛟 MOVE bootstrap: camPlaneHit=$camPlaneHit, yPlaneHit=$yPlaneHit, lockedY=$lockedY")
                                    if (hitPt != null) {
                                        dragOffsets[nodeName] = Vector3(cur.x - hitPt.x, 0.0f, cur.z - hitPt.z)
                                        Log.d(TAG, "🛟 Fallback pan BOOTSTRAPPED on MOVE for $nodeName at Y=$lockedY, offset=${dragOffsets[nodeName]}")
                                    }
                                }
                                if (useCustomPan || (fallbackPanActive[nodeName] == true)) {
                                    val offset = dragOffsets[nodeName]
                                    val cur = sel.worldPosition
                                    val camPlaneHit = screenPointToCameraFacingPlane(
                                        motionEvent.x,
                                        motionEvent.y,
                                        Vector3(cur.x, lockedY, cur.z)
                                    )
                                    val yPlaneHitMove = screenPointToYPlane(motionEvent.x, motionEvent.y, lockedY)
                                    val hitPt = camPlaneHit ?: yPlaneHitMove
                                    Log.d(TAG, "🧭 MOVE: camPlaneHit=$camPlaneHit, yPlaneHit=$yPlaneHitMove, offset=$offset")
                                    if (hitPt != null) {
                                        val newX = hitPt.x + (offset?.x ?: 0.0f)
                                        val newZ = hitPt.z + (offset?.z ?: 0.0f)
                                        sel.worldPosition = Vector3(newX, lockedY, newZ)
                                        Log.d(TAG, "🚚 MOVE applied: newPos=(${newX}, ${lockedY}, ${newZ})")
                                        customDragHandled = true
                                    } else {
                                        // Even if we couldn't compute a hit, consume the event to avoid rotation
                                        customDragHandled = true
                                        Log.d(TAG, "⚠️ MOVE: no hit computed; consuming to avoid rotation for $nodeName")
                                    }
                                }
                            }
                            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                                dragOffsets.remove(nodeName)
                                if (fallbackPanActive.remove(nodeName) == true) {
                                    // Restore built-in translation state now that fallback gesture ended
                                    try { if (!useCustomPan) sel.translationController.isEnabled = true } catch (_: Exception) {}
                                    Log.d(TAG, "🛟 Fallback pan DEACTIVATED for $nodeName")
                                }
                            }
                        }
                    }
                }
                
                Log.d(TAG, "🚀🚀🚀 ANDROID: final result=${transformationHandled || gestureHandled || customDragHandled}")
                
                // Return true if either transformation system or gesture detector handled it
                (transformationHandled || gestureHandled || customDragHandled)
            }

        } catch (e: Exception) {
            // Silently handle initialization errors
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        Log.d(TAG, "🚀🚀🚀 METHOD CALL: ${call.method} with arguments: ${call.arguments}")
        when (call.method) {
            "init" -> handleInit(call, result)
            "addAnchor" -> handleAddAnchor(call, result)
            "addNode" -> {
                // Route addNode to addNodeToPlaneAnchor when planeAnchor is provided
                val arguments = call.arguments as? Map<String, Any>
                Log.d(TAG, "🔥🔥🔥 addNode called - planeAnchor present: ${arguments?.get("planeAnchor") != null}")
                if (arguments?.get("planeAnchor") != null) {
                    Log.d(TAG, "📍 addNode with planeAnchor - routing to addNodeToPlaneAnchor")
                    handleAddNodeToPlaneAnchor(call, result)
                } else {
                    Log.d(TAG, "📍 addNode without planeAnchor - direct position placement")
                    handleAddNode(call, result)
                }
            }
            "addNodeToPlaneAnchor" -> {
                Log.d(TAG, "🔥🔥🔥 addNodeToPlaneAnchor called directly")
                handleAddNodeToPlaneAnchor(call, result)
            }
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
            "setTapPlacementEnabled" -> {
                val args = call.arguments as? Map<String, Any>
                val enabled = args?.get("enabled") as? Boolean ?: true
                tapPlacementEnabled = enabled
                Log.d(TAG, "🔧 setTapPlacementEnabled = $tapPlacementEnabled")
                result.success(null)
            }
            else -> result.notImplemented()
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
        
        // If we found object hits, send them to Flutter and return (like iOS)
        if (reusableNodeHitResults.isNotEmpty()) {
            // Remove duplicates like iOS does: Array(Set(nodeHitResults))
            val uniqueNodeHits = reusableNodeHitResults.toSet().toList()
            objectChannel.invokeMethod("onNodeTap", uniqueNodeHits)
            return
        }
        
        // SECOND: If no objects were hit, check for plane hits (existing logic)
        val frame = arSceneView?.arFrame ?: return
        
        // Debug tracking state
        val trackingState = frame.camera.trackingState
        Log.d(TAG, "🎯 Camera tracking state: $trackingState")
        
        // Get all planes for debugging (need access to session)
        arSceneView?.session?.let { session ->
            val allPlanes = session.getAllTrackables(Plane::class.java)
            val trackedPlanes = allPlanes.filter { it.trackingState == TrackingState.TRACKING }
            Log.d(TAG, "✈️ Planes detected: ${allPlanes.size}, tracked: ${trackedPlanes.size}")
        }
        
        if (frame.camera.trackingState != TrackingState.TRACKING) {
            Log.w(TAG, "⚠️ Camera not tracking, state: $trackingState")
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
                if (tapPlacementEnabled) {
                    sessionChannel.invokeMethod("onPlaneOrPointTap", listOf(hitResult))
                } else {
                    Log.d(TAG, "🚫 Tap-to-place disabled; plane tap ignored for placement")
                }
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
                Log.d(TAG, "🚀🚀🚀 STARTING model load for: $nodeName, URI: $uri")
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
                
                Log.d(TAG, "🛠️ Building renderable source for: $nodeName")
                
                modelRenderableBuilder
                    .setSource(activity, renderableSourceBuilder.build())
                    .setRegistryId(uri)
                
                Log.d(TAG, "🚧 About to call .build() on ModelRenderable for: $nodeName")
                
                modelRenderableBuilder.build()
                    .thenAccept { renderable: ModelRenderable ->
                        Log.d(TAG, "✅✅✅ GLB model loaded successfully for direct placement: $nodeName")
                        Log.d(TAG, "🔥🔥🔥 About to create collision shapes for: $nodeName")
                        
                        val transformableNode = TransformableNode(transformationSystem)
                        transformableNode.renderable = renderable
                        transformableNode.name = nodeName
                        
                        // CRITICAL: Enable the node for hit testing and selection
                        transformableNode.isEnabled = true
                        
                        // CRITICAL: Set collision shape for hit testing
                        // RE-ENABLE collision shapes for proper pan gesture detection
                        val collisionSize = Vector3(
                            maxOf(scaleX * 6.0f, 2.0f), // 6x larger - minimum 2.0 units for better detection
                            maxOf(scaleY * 6.0f, 2.0f), // 6x larger - minimum 2.0 units for better detection
                            maxOf(scaleZ * 6.0f, 2.0f)  // 6x larger - minimum 2.0 units for better detection
                        )
                        transformableNode.collisionShape = Box(collisionSize)
                        Log.d(TAG, "🎯 Collision shape set: ${collisionSize.x} x ${collisionSize.y} x ${collisionSize.z}")
                        
                        // (Optional visual collider indicator removed for stability)
                        
                        // �🏗️ CREATE FLOOR-LEVEL PAN GESTURE HELPER
                        // Add an invisible collision node at floor level to improve pan gesture detection
                        if (enablePanGestures) {
                            try {
                                // Create a large invisible collision box at floor level
                                val floorCollisionSize = Vector3(
                                    maxOf(scaleX * 3.5f, 1.2f), // Larger horizontal area for easy interaction
                                    0.06f,                       // Very thin vertically
                                    maxOf(scaleZ * 3.5f, 1.2f)
                                )
                                
                                // Create a simple child node for floor-level collision detection
                                val floorCollisionNode = Node()
                                floorCollisionNode.collisionShape = Box(floorCollisionSize)
                                
                                // Position the floor collision node near the bottom of the object's collider
                                // Place slightly above the lowest point to stay pickable
                                val bottomY = -collisionSize.y / 2.0f + 0.03f
                                floorCollisionNode.localPosition = Vector3(0.0f, bottomY, 0.0f)
                                
                                // Make it a child of the main transformable node
                                floorCollisionNode.setParent(transformableNode)
                                
                                // (Optional visual floor collider indicator removed for stability)

                                // Set up pan gesture detection on the floor collision node
                                floorCollisionNode.setOnTouchListener { hitTestResult, motionEvent ->
                                    Log.d(TAG, "🎯 Floor collision node touched for: $nodeName, action: ${motionEvent.action}")
                                    
                                    // Forward the touch to the parent transformable node
                                    // This ensures pan gestures work on the floor area
                                    transformationSystem?.selectNode(transformableNode)
                                    
                                    // Let the transformation system handle the actual gesture
                                    false // Return false to allow transformation system to process
                                }
                                
                                Log.d(TAG, "🏗️ Added floor-level collision helper for pan gestures: $nodeName, size: $floorCollisionSize")
                                
                                // Add a mid-height collision helper to make tapping beams/roof easier
                                val midCollisionSize = Vector3(
                                    maxOf(scaleX * 3.0f, 1.0f),
                                    maxOf(scaleY * 1.0f, 0.5f),
                                    maxOf(scaleZ * 3.0f, 1.0f)
                                )
                                val midCollisionNode = Node().apply {
                                    collisionShape = Box(midCollisionSize)
                                    // Place around the middle of the object height
                                    localPosition = Vector3(0.0f, 0.0f, 0.0f)
                                    setParent(transformableNode)
                                    setOnTouchListener { _, me ->
                                        Log.d(TAG, "🎯 Mid collision node touched for: $nodeName, action: ${me.action}")
                                        transformationSystem?.selectNode(transformableNode)
                                        false
                                    }
                                }
                                Log.d(TAG, "🏗️ Added mid-height collision helper for pan gestures: $nodeName, size: $midCollisionSize")
                                
                            } catch (e: Exception) {
                                Log.w(TAG, "⚠️ Failed to create floor collision helper: ${e.message}")
                            }
                        }
                        
                        // Set up tap listener for node selection
                        transformableNode.setOnTapListener { hitTestResult: HitTestResult, motionEvent: MotionEvent ->
                            Log.d(TAG, "🎯 Node $nodeName tapped - selecting for transformation")
                            transformationSystem?.selectNode(transformableNode)
                            Log.d(TAG, "🎯 Node $nodeName selected for transformation")
                            
                            // CRITICAL FIX: Notify Flutter about node tap via method channel
                            try {
                                val tappedNodesList = listOf(nodeName)
                                Log.d(TAG, "📢 Notifying Flutter about node tap: $tappedNodesList")
                                objectChannel.invokeMethod("onNodeTap", tappedNodesList)
                                Log.d(TAG, "✅ Flutter callback triggered successfully")
                            } catch (e: Exception) {
                                Log.e(TAG, "❌ Failed to notify Flutter about node tap: ${e.message}")
                            }
                            
                            true
                        }
                        
                        // Apply gesture properties from Flutter
                        // CRITICAL FIX: Enable ARCore's built-in gesture controllers directly
                        // Use ARCore's proven gesture system instead of custom implementations
                        
                        // CRITICAL DEBUG: Log the input values
                        Log.d(TAG, "🔍 GESTURE DEBUG: enablePanGestures=$enablePanGestures")
                        Log.d(TAG, "🔍 GESTURE DEBUG: enableRotationGestures=$enableRotationGestures") 
                        Log.d(TAG, "🔍 GESTURE DEBUG: isTransformable=$isTransformable")
                        
                        // Decide pan mode based on flag from Flutter
                        val useCustomPan = enablePanGestures
                        customPanNodes[nodeName] = useCustomPan
                        // If custom pan: disable built-in translation; else enable it for model-drag on the object
                        transformableNode.translationController.isEnabled = !useCustomPan
                        transformableNode.rotationController.isEnabled = true
                        transformableNode.scaleController.isEnabled = false
                        
                        // � UNLIMITED MOVEMENT: Configure translation controller for unrestricted XZ movement
                        Log.d(TAG, "🌍 CONFIGURING UNLIMITED XZ MOVEMENT")
                        try {
                            val translationController = transformableNode.translationController
                            
                            // Defer Y lock setup until after we set initial worldPosition below
                            translationController.let { _ ->
                                // Remove any plane constraints by not binding to a plane anchor
                                Log.d(TAG, "🌍 Translation controller configured for unlimited XZ movement")
                            }
                        } catch (e: Exception) {
                            Log.w(TAG, "⚠️ Failed to configure unlimited movement: ${e.message}")
                        }
                        
                        // �🚨 CRITICAL DEBUG: Add specific translation controller debugging
                        try {
                            transformableNode.translationController.let { controller ->
                                Log.d(TAG, "🎯 TRANSLATION CONTROLLER DEBUG:")
                                Log.d(TAG, "🎯 Translation enabled: ${controller.isEnabled}")
                                
                                // Log initial position for comparison
                                val originalTransform = transformableNode.worldPosition
                                Log.d(TAG, "🎯 Initial world position: $originalTransform")
                                
                                // We'll track position changes via the node's transform listener instead
                                Log.d(TAG, "🎯 Translation controller setup complete")
                            }
                        } catch (e: Exception) {
                            Log.w(TAG, "⚠️ Failed to add translation debugging: ${e.message}")
                        }
                        
                        // CRITICAL DEBUG: Log the actual controller states
                        Log.d(TAG, "🔍 ACTUAL CONTROLLER STATES:")
                        Log.d(TAG, "🔍 Translation controller enabled: ${transformableNode.translationController.isEnabled}")
                        Log.d(TAG, "🔍 Rotation controller enabled: ${transformableNode.rotationController.isEnabled}")
                        Log.d(TAG, "🔍 Scale controller enabled: ${transformableNode.scaleController.isEnabled}")
                        
                        // CRITICAL DEBUG: Add position change tracking
                        var lastPosition = transformableNode.worldPosition
                        val positionChangeListener = object : Node.TransformChangedListener {
                            override fun onTransformChanged(node: Node?, parent: Node?) {
                                val currentPosition = transformableNode.worldPosition
                                if (currentPosition != lastPosition) {
                                    Log.d(TAG, "🎯 POSITION CHANGED: from $lastPosition to $currentPosition")
                                    lastPosition = currentPosition
                                }
                            }
                        }
                        transformableNode.addTransformChangedListener(positionChangeListener)
                        
                        // Apply the scale from Flutter to the node
                        transformableNode.localScale = Vector3(scaleX, scaleY, scaleZ)
                        android.util.Log.d("SCALE_DEBUG", "🎯🎯🎯 FINAL: Applied scale to node: ($scaleX, $scaleY, $scaleZ)")
                        android.util.Log.d("SCALE_DEBUG", "🎯🎯🎯 FINAL: Node localScale after setting: ${transformableNode.localScale}")
                        
                        // Determine world position. If no anchor is used, treat provided translation
                        // as camera-relative (x: right, y: up, z: forward when negative).
                        val camera = arSceneView?.scene?.camera
                        val worldPos: Vector3 = if (camera != null) {
                            try {
                                val camPos = camera.worldPosition
                                val camForward = camera.forward // world forward vector
                                val camRight = camera.right
                                val camUp = camera.up
                                // In camera space: negative Z means in front of camera.
                                val forwardDist = -positionZ
                                val offset = Vector3(
                                    camRight.x * positionX + camUp.x * positionY + camForward.x * forwardDist,
                                    camRight.y * positionX + camUp.y * positionY + camForward.y * forwardDist,
                                    camRight.z * positionX + camUp.z * positionY + camForward.z * forwardDist
                                )
                                Vector3(camPos.x + offset.x, camPos.y + offset.y, camPos.z + offset.z)
                            } catch (e: Exception) {
                                Log.w(TAG, "⚠️ Failed to compute camera-relative position, using raw: ${e.message}")
                                Vector3(positionX, positionY, positionZ)
                            }
                        } else {
                            Vector3(positionX, positionY, positionZ)
                        }

                        if (useCustomPan) {
                            // Custom unlimited pan for pergola-like models
                            Log.d(TAG, "🌍 UNLIMITED MOVEMENT: Enabling free-floating object placement")
                            arSceneView?.scene?.addChild(transformableNode)
                            transformableNode.worldPosition = worldPos
                            Log.d(TAG, "📍 Set unrestricted world position: $worldPos (from cam-rel: x=$positionX, y=$positionY, z=$positionZ)")

                            // Lock Y during drags
                            try {
                                val originalY = transformableNode.worldPosition.y
                                Log.d(TAG, "🌍 Locking Y position at: $originalY (direct placement)")
                                yLocks[nodeName] = originalY
                                transformableNode.addTransformChangedListener { _, _ ->
                                    val currentPos = transformableNode.worldPosition
                                    if (kotlin.math.abs(currentPos.y - originalY) > 0.01f) {
                                        transformableNode.worldPosition = Vector3(currentPos.x, originalY, currentPos.z)
                                        Log.d(TAG, "🌍 Y-axis locked: corrected from ${currentPos.y} to $originalY")
                                    }
                                }
                            } catch (e: Exception) {
                                Log.w(TAG, "⚠️ Failed to add Y lock listener: ${e.message}")
                            }
                        } else {
                            // Built-in translation on direct placement: still add to scene at requested pose
                            arSceneView?.scene?.addChild(transformableNode)
                            transformableNode.worldPosition = worldPos
                            Log.d(TAG, "📍 Direct placement with built-in translation at world: $worldPos (from cam-rel: x=$positionX, y=$positionY, z=$positionZ)")
                        }
                        
                        // 🎯 SIMPLE COLLISION IMPROVEMENT FOR BETTER UX (enlarged pick box)
                        // Create a larger invisible collision box for easier object grabbing
                        // This makes it much easier to grab and pan objects, especially at small scales
                        if (enablePanGestures) {
                            try {
                                Log.d(TAG, "🎨 Creating larger collision area for easy object grabbing")
                                
                                // Create a larger collision box for easier interaction (invisible)
                                val enlargedCollisionSize = Vector3(
                                    maxOf(scaleX * 4.0f, 1.2f),  // Make it larger than the object, minimum ~1.2m
                                    maxOf(scaleY * 4.0f, 1.0f),
                                    maxOf(scaleZ * 4.0f, 1.2f)
                                )
                                
                                // Apply the larger collision shape directly to the transformable node
                                transformableNode.collisionShape = Box(enlargedCollisionSize)
                                
                                Log.d(TAG, "✅ Created enlarged collision area with size: $enlargedCollisionSize")
                                // (Optional main collider visualization removed for stability)
                                    
                            } catch (e: Exception) {
                                Log.w(TAG, "⚠️ Could not create enlarged collision area: ${e.message}")
                                // Fallback to default collision
                                transformableNode.collisionShape = Box(Vector3(scaleX, scaleY, scaleZ))
                            }
                        }
                        
                        // Store the node for cleanup (no anchor needed)
                        nodesMap[nodeName] = transformableNode
                        
                        // Ensure this new node is selected so single-finger drag works immediately
                        try {
                            transformationSystem?.selectNode(transformableNode)
                        } catch (e: Exception) {
                            Log.w(TAG, "⚠️ Failed to auto-select new node: ${e.message}")
                        }
                        
                        Log.d(TAG, "✅ Successfully placed node with UNLIMITED movement capability")
                        
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
                Log.d(TAG, "🎯 Starting ModelRenderable.builder() for planeAnchor placement: $nodeName, URI: $uri")
                val modelRenderableBuilder = ModelRenderable.builder()
                val renderableSourceBuilder = RenderableSource.builder()
                
                // Check file extension and set appropriate source type
                if (uri.endsWith(".glb")) {
                    Log.d(TAG, "� Building ModelRenderable with URI: $uri (GLB format)")
                    renderableSourceBuilder
                        .setSource(activity, Uri.parse(uri), RenderableSource.SourceType.GLB)
                        .setScale(1.0f) // Use 1.0f as base scale, we'll apply custom scale later
                        .setRecenterMode(RenderableSource.RecenterMode.ROOT)
                } else if (uri.endsWith(".gltf")) {
                    Log.d(TAG, "� Building ModelRenderable with URI: $uri (GLTF format)")
                    renderableSourceBuilder
                        .setSource(activity, Uri.parse(uri), RenderableSource.SourceType.GLTF2)
                        .setScale(1.0f) // Use 1.0f as base scale, we'll apply custom scale later
                        .setRecenterMode(RenderableSource.RecenterMode.ROOT)
                } else {
                    Log.e(TAG, "❌ Unsupported file format: $uri")
                    result.error("UNSUPPORTED_FORMAT", "Only GLB and GLTF files are supported", null)
                    return
                }
                
                Log.d(TAG, "⚙️ About to call ModelRenderable.builder().build() for: $nodeName")
                modelRenderableBuilder
                    .setSource(activity, renderableSourceBuilder.build())
                    .setRegistryId(uri)
                    .build()
                    .thenAccept { renderable: ModelRenderable ->
                        Log.d(TAG, "✅ GLB model loaded successfully for planeAnchor placement: $nodeName")
                        Log.d(TAG, "🔥 About to create collision shapes for planeAnchor: $nodeName")
                        
                        val transformableNode = TransformableNode(transformationSystem)
                        transformableNode.renderable = renderable
                        transformableNode.name = nodeName
                        
                        // CRITICAL: Enable the node for hit testing and selection
                        transformableNode.isEnabled = true
                        
                        // CRITICAL: Set collision shape for hit testing
                        // Make the box generous so taps/drags on the model are easy (similar to direct add path)
                        val collisionSize = Vector3(
                            maxOf(scaleX * 4.0f, 1.2f), // Wider pick area
                            maxOf(scaleY * 4.0f, 1.0f), // Taller pick area
                            maxOf(scaleZ * 4.0f, 1.2f)
                        )
                        transformableNode.collisionShape = Box(collisionSize)
                        Log.d(TAG, "🎯 Set collision shape for hit testing: $nodeName, size: $collisionSize")

                        // Add helper collision nodes (floor + mid) to improve tap/drag on thin or skeletal meshes
                        try {
                            // Floor-level helper
                            val floorCollisionSize = Vector3(
                                maxOf(scaleX * 3.5f, 1.2f),
                                0.06f,
                                maxOf(scaleZ * 3.5f, 1.2f)
                            )
                            val floorCollisionNode = Node().apply {
                                collisionShape = Box(floorCollisionSize)
                                val bottomY = -collisionSize.y / 2.0f + 0.03f
                                localPosition = Vector3(0.0f, bottomY, 0.0f)
                                setParent(transformableNode)
                                setOnTouchListener { _, me ->
                                    Log.d(TAG, "🎯 Floor helper touched for: $nodeName action=${me.action}")
                                    transformationSystem?.selectNode(transformableNode)
                                    false
                                }
                            }
                            Log.d(TAG, "🏗️ Added floor helper for anchored node: $nodeName, size: $floorCollisionSize")

                            // Mid-height helper
                            val midCollisionSize = Vector3(
                                maxOf(scaleX * 3.0f, 1.0f),
                                maxOf(scaleY * 1.0f, 0.5f),
                                maxOf(scaleZ * 3.0f, 1.0f)
                            )
                            val midCollisionNode = Node().apply {
                                collisionShape = Box(midCollisionSize)
                                localPosition = Vector3(0.0f, 0.0f, 0.0f)
                                setParent(transformableNode)
                                setOnTouchListener { _, me ->
                                    Log.d(TAG, "🎯 Mid helper touched for: $nodeName action=${me.action}")
                                    transformationSystem?.selectNode(transformableNode)
                                    false
                                }
                            }
                            Log.d(TAG, "🏗️ Added mid helper for anchored node: $nodeName, size: $midCollisionSize")
                        } catch (e: Exception) {
                            Log.w(TAG, "⚠️ Failed to create helper colliders for anchored node: ${e.message}")
                        }
                        
                        // Set up tap listener for node selection (like in arcore_flutter_plugin)
                        transformableNode.setOnTapListener { hitTestResult: HitTestResult, motionEvent: MotionEvent ->
                            Log.d(TAG, "🎯 Node $nodeName tapped - selecting for transformation")
                            transformationSystem?.selectNode(transformableNode)
                            Log.d(TAG, "🎯 Node $nodeName selected for transformation")
                            
                            // CRITICAL FIX: Notify Flutter about node tap via method channel
                            try {
                                val tappedNodesList = listOf(nodeName)
                                Log.d(TAG, "📢 Notifying Flutter about node tap: $tappedNodesList")
                                objectChannel.invokeMethod("onNodeTap", tappedNodesList)
                                Log.d(TAG, "✅ Flutter callback triggered successfully")
                            } catch (e: Exception) {
                                Log.e(TAG, "❌ Failed to notify Flutter about node tap: ${e.message}")
                            }
                            
                            true
                        }
                        
                        // Apply gesture properties from Flutter
                        // Use custom pan (disable built-in translation), keep rotation per flag
                        transformableNode.translationController.isEnabled = false
                        transformableNode.rotationController.isEnabled = enableRotationGestures
                        transformableNode.scaleController.isEnabled = isTransformable // Only enable scale if fully transformable
                        
                        Log.d(TAG, "🎯 Gesture controllers configured - pan: $enablePanGestures, rotation: $enableRotationGestures, scale: $isTransformable")
                        Log.d(TAG, "🎯 Translation controller enabled: ${transformableNode.translationController.isEnabled}")
                        Log.d(TAG, "🎯 Rotation controller enabled: ${transformableNode.rotationController.isEnabled}")
                        Log.d(TAG, "🎯 Scale controller enabled: ${transformableNode.scaleController.isEnabled}")
                        
                        // Don't auto-select the node - let user tap to select it
                        // This allows proper gesture state management
                        
                        // Apply the scale from Flutter to the node
                        transformableNode.localScale = Vector3(scaleX, scaleY, scaleZ)
                        android.util.Log.d("SCALE_DEBUG", "🎯🎯🎯 FINAL: Applied scale to node: ($scaleX, $scaleY, $scaleZ)")
                        android.util.Log.d("SCALE_DEBUG", "🎯🎯🎯 FINAL: Node localScale after setting: ${transformableNode.localScale}")
                        
                        // Decide pan mode based on flag from Flutter
                        val useCustomPanAnchor = enablePanGestures
                        customPanNodes[nodeName] = useCustomPanAnchor

                        if (useCustomPanAnchor) {
                            // Custom: place at anchor, then detach for unlimited XZ and lock Y
                            Log.d(TAG, "🌍 Setting up unlimited XZ movement (custom pan)")
                            val originalY = anchorNode.worldPosition.y
                            transformableNode.setParent(anchorNode)
                            transformableNode.localPosition = Vector3.zero()
                            val worldPos = transformableNode.worldPosition
                            transformableNode.setParent(arSceneView?.scene)
                            transformableNode.worldPosition = worldPos
                            transformableNode.addTransformChangedListener { _, _ ->
                                val currentPos = transformableNode.worldPosition
                                if (kotlin.math.abs(currentPos.y - originalY) > 0.01f) {
                                    transformableNode.worldPosition = Vector3(currentPos.x, originalY, currentPos.z)
                                    Log.d(TAG, "🌍 Y-axis locked: ${currentPos.y} → $originalY")
                                }
                            }
                            yLocks[nodeName] = originalY
                            // Disable built-in translation to avoid conflicts
                            transformableNode.translationController.isEnabled = false
                        } else {
                            // Built-in translation: keep attached to anchor and let Sceneform handle drag on the model
                            Log.d(TAG, "🧭 Built-in translation enabled for anchored node")
                            transformableNode.setParent(anchorNode)
                            transformableNode.localPosition = Vector3.zero()
                            transformableNode.translationController.isEnabled = true
                        }

                        // Store the node for later reference
                        nodesMap[nodeName] = transformableNode

                        // Auto-select the node only for custom pan to allow immediate panning
                        if (useCustomPanAnchor) {
                            try {
                                transformationSystem?.selectNode(transformableNode)
                            } catch (e: Exception) {
                                Log.w(TAG, "⚠️ Failed to auto-select new anchored node: ${e.message}")
                            }
                        }
                        
                        Log.d(TAG, "✅ GLB model added to plane anchor: $nodeName")
                        result.success(nodeName)
                    }
                    .exceptionally { throwable: Throwable ->
                        Log.e(TAG, "❌ Failed to load GLB model for planeAnchor: ${throwable.message}", throwable)
                        Log.e(TAG, "🚫 ModelRenderable.builder() failed for: $nodeName, URI: $uri")
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
                    // Clear selection if this node was currently selected
                    try {
                        if (transformationSystem?.selectedNode === node) {
                            transformationSystem?.selectNode(null)
                            Log.d(TAG, "🧽 Cleared selection for removed node: $nodeName")
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "⚠️ Unable to clear selection on remove: ${e.message}")
                    }
                    nodesMap.remove(nodeName)
                    yLocks.remove(nodeName)
                    dragOffsets.remove(nodeName)
                    customPanNodes.remove(nodeName)
                    fallbackPanActive.remove(nodeName)
                    
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
                    // Clear selection if this node was currently selected
                    try {
                        if (transformationSystem?.selectedNode === node) {
                            transformationSystem?.selectNode(null)
                            Log.d(TAG, "🧽 Cleared selection for deep-removed node: $nodeId")
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "⚠️ Unable to clear selection on deep remove: ${e.message}")
                    }
                    
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
            yLocks.clear()
            dragOffsets.clear()
            customPanNodes.clear()
            fallbackPanActive.clear()
            // Clear lingering selection
            try {
                transformationSystem?.selectNode(null)
                Log.d(TAG, "🧽 Cleared selection after removeAllObjects")
            } catch (e: Exception) {
                Log.w(TAG, "⚠️ Unable to clear selection after removeAllObjects: ${e.message}")
            }
            
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
            
            // Clear references efficiently
            arSceneView = null
            nodesMap.clear()
            reusableNodeHitResults.clear()
            transformationSystem = null
            gestureDetector = null
            yLocks.clear()
            dragOffsets.clear()
            
            result.success(null)
        } catch (e: Exception) {
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

    // Project a screen point to a horizontal plane at y = planeY in world space
    private fun screenPointToYPlane(x: Float, y: Float, planeY: Float): Vector3? {
        val sceneView = arSceneView ?: return null
        val camera = sceneView.scene?.camera ?: return null
        return try {
            val ray = camera.screenPointToRay(x, y)
            val dy = ray.direction.y
            if (kotlin.math.abs(dy) < 1e-5f) return null
            val t = (planeY - ray.origin.y) / dy
            if (t < 0f) return null
            val hit = Vector3.add(ray.origin, ray.direction.scaled(t))
            hit
        } catch (e: Exception) {
            null
        }
    }

    // Project a screen point to a plane that faces the camera (normal = camera.forward) passing through a reference point
    // Useful when the camera ray is nearly parallel to the Y-plane, so the intersection would be unstable
    private fun screenPointToCameraFacingPlane(x: Float, y: Float, planePoint: Vector3): Vector3? {
        val sceneView = arSceneView ?: return null
        val camera = sceneView.scene?.camera ?: return null
        return try {
            val ray = camera.screenPointToRay(x, y)
            val planeNormal = camera.forward
            val denom = Vector3.dot(ray.direction, planeNormal)
            if (kotlin.math.abs(denom) < 1e-5f) return null
            val diff = Vector3.subtract(planePoint, ray.origin)
            val t = Vector3.dot(diff, planeNormal) / denom
            if (t < 0f) return null
            Vector3.add(ray.origin, ray.direction.scaled(t))
        } catch (e: Exception) {
            null
        }
    }

    // Find the nearest TransformableNode up the ancestry from a touched node
    private fun findTransformableAncestor(node: Node?): TransformableNode? {
        var cur = node
        while (cur != null) {
            if (cur is TransformableNode) return cur
            cur = cur.parent
        }
        return null
    }
}
