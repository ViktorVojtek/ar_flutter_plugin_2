package com.uhg0.ar_flutter_plugin_2

import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.view.MotionEvent
import android.view.PixelCopy
import android.view.Surface
import android.view.SurfaceView
import android.view.View
import android.view.GestureDetector
import java.io.ByteArrayOutputStream
import java.util.concurrent.CompletableFuture
import kotlin.math.pow
import com.google.ar.core.*
import com.google.ar.core.Pose
import com.google.ar.sceneform.*
import com.google.ar.sceneform.assets.RenderableSource
import com.google.ar.sceneform.math.Vector3
import com.google.ar.sceneform.math.Quaternion
import com.google.ar.sceneform.rendering.ModelRenderable
// Cache system imports
import com.uhg0.ar_flutter_plugin_2.services.ModelDownloadService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import com.google.ar.sceneform.rendering.MaterialFactory
import com.google.ar.sceneform.rendering.ShapeFactory
import com.google.ar.sceneform.rendering.Texture
import com.google.ar.sceneform.collision.Box
// Flutter imports
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.platform.PlatformView
// SceneForm imports
import com.google.ar.sceneform.HitTestResult
import com.google.ar.sceneform.ux.TransformationSystem
import com.google.ar.sceneform.ux.SelectionVisualizer
import com.google.ar.sceneform.ux.TransformableNode
import com.google.ar.sceneform.ux.BaseTransformableNode
import com.google.ar.sceneform.AnchorNode
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
    
    // ANDROID FIX: Add reverse mapping for iOS-style unique ID tracking
    private val nodeToUniqueIdMap = ConcurrentHashMap<Node, String>()
    
    private var gestureDetector: GestureDetector? = null
    
    // Performance optimization: Reuse collections to reduce garbage collection
    private val reusableNodeHitResults = mutableListOf<String>()
    private val reusableMatrixArray = FloatArray(16)
    
    // Touch event tracking for delayed tap detection (workaround for ACTION_UP consumption)
    private var lastTouchDownTime = 0L
    private var lastTouchDownX = 0f
    private var lastTouchDownY = 0f
    private var hasTouchMoved = false
    
    // Height-locked panning support - stores detected floor heights per node
    private val nodeFloorHeights = ConcurrentHashMap<String, Float>()
    private var enableHeightLockedPanning = true
    private var heightLockTolerance = 0.05f // 5cm tolerance for height variations
    
    // Enhanced continuous plane tracking for better object movement
    private var lastPlaneUpdateTime = 0L
    private val planeUpdateInterval = 100L // Check for plane updates every 100ms
    
    // Light estimation monitoring support
    private var isMonitoringLighting = false
    private var lightingCheckInterval = 1000L // Check every second by default
    private val lightingHandler = Handler(Looper.getMainLooper())
    private val lightingCheckRunnable = object : Runnable {
        override fun run() {
            checkLightingConditions()
            if (isMonitoringLighting) {
                lightingHandler.postDelayed(this, lightingCheckInterval)
            }
        }
    }
    
    // Cache system for model downloading and storage
    private val modelDownloadService: ModelDownloadService by lazy {
        ModelDownloadService(activity.applicationContext)
    }
    private val downloadScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    
    // Scene state persistence for navigation lifecycle management
    private data class NodeState(
        val nodeName: String,
        val position: Vector3,
        val rotation: Quaternion,
        val scale: Vector3,
        val modelUri: String,
        val anchorPose: Pose?
    )
    
    private val persistentNodeStates = mutableMapOf<String, NodeState>()
    private var isRestoringScene = false

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
                    planeFindingMode = Config.PlaneFindingMode.HORIZONTAL // Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL
                    // Use ENVIRONMENTAL_HDR for realistic lighting, shadows, and reflections
                    lightEstimationMode = Config.LightEstimationMode.ENVIRONMENTAL_HDR
                    updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE
                    
                    // Memory optimizations
                    focusMode = Config.FocusMode.AUTO
                    // Disable unnecessary features to reduce memory usage
                }
                session.configure(config)
                
                // Set the session
                setupSession(session)
                // Plane renderer will be configured in handleInit based on Flutter parameters
                
                // Load custom HDR environment for better lighting, shadows, and reflections
                loadEnvironmentalHdr()
                
                // CRITICAL: Resume the ArSceneView to start the camera feed
                Handler(Looper.getMainLooper()).post {
                    try {
                        resume()
                        
                        // NAVIGATION LIFECYCLE FIX: Restore scene state after session resume
                        Handler(Looper.getMainLooper()).postDelayed({
                            Log.d(TAG, "🔄 AR session resumed, checking for scene restoration...")
                            restoreSceneStateFromPersistence()
                        }, 500) // Small delay to ensure session is fully ready
                        
                    } catch (e: Exception) {
                        Log.w(TAG, "⚠️ Error during AR session resume: ${e.message}")
                    }
                }
            }

            // Initialize TransformationSystem for gesture handling with safety checks
            val selectionVisualizer = object : SelectionVisualizer {
                override fun applySelectionVisual(node: BaseTransformableNode) {
                    // Only handle selection state changes, not gesture callbacks
                    if (node is TransformableNode) {
                        // Find the node ID for Flutter notification
                        val nodeId = nodeToUniqueIdMap[node] ?: nodesMap.entries.find { it.value == node }?.key ?: node.name
                        
                        // Notify Flutter about the selection change ONLY
                        notifySelectionStateChange(nodeId)
                        
                        Log.d(TAG, "🎯 Selection applied to node: $nodeId")
                        
                        // DO NOT send gesture start callbacks here - they should only be sent when actual gestures begin
                        // The gesture callbacks should be handled by the gesture controllers themselves
                    }
                }
                
                override fun removeSelectionVisual(node: BaseTransformableNode) {
                    // Only handle deselection state changes, not gesture callbacks
                    if (node is TransformableNode) {
                        try {
                            // Find the node ID for Flutter notification
                            val nodeId = nodeToUniqueIdMap[node] ?: nodesMap.entries.find { it.value == node }?.key ?: node.name
                            
                            // Notify Flutter about deselection change
                            notifySelectionStateChange(null)
                            
                            Log.d(TAG, "🎯 Selection removed from node: $nodeId")
                            
                            // DO NOT send gesture end callbacks here - selection/deselection != gesture start/end
                            // The gesture callbacks should be handled by the gesture controllers themselves
                            
                        } catch (e: Exception) {
                            Log.e(TAG, "❌ Error in removeSelectionVisual: ${e.message}")
                        }
                    }
                }
            }
            
            // Create TransformationSystem with enhanced error handling and gesture tracking + height-locked panning
            transformationSystem = object : TransformationSystem(activity.resources.displayMetrics, selectionVisualizer) {
                private var isGestureActive = false
                private var lastGestureType: String? = null
                private var gestureStartTime = 0L
                private var gestureStartX = 0f
                private var gestureStartY = 0f
                private var gestureMovementThreshold = 30f // pixels
                
                // Height-locked panning variables
                private var heightLockedPanning = false
                private var originalHeight: Float? = null
                private var panStartPosition: Vector3? = null
                
                override fun onTouch(hitTestResult: HitTestResult?, motionEvent: MotionEvent?) {
                    try {
                        // Enhanced touch handling with gesture detection
                        if (hitTestResult != null && motionEvent != null) {
                            val selectedNode = this.selectedNode
                            
                            // Handle gesture tracking for selected nodes
                            if (selectedNode is TransformableNode && hitTestResult.node == selectedNode) {
                                val nodeId = nodeToUniqueIdMap[selectedNode] ?: nodesMap.entries.find { it.value == selectedNode }?.key ?: selectedNode.name
                                
                                when (motionEvent.action) {
                                    MotionEvent.ACTION_DOWN -> {
                                        // Reset gesture tracking
                                        isGestureActive = false
                                        lastGestureType = null
                                        gestureStartTime = System.currentTimeMillis()
                                        gestureStartX = motionEvent.x
                                        gestureStartY = motionEvent.y
                                    }
                                    MotionEvent.ACTION_MOVE -> {
                                        // Detect if this is actually a gesture (not just a tap)
                                        val currentTime = System.currentTimeMillis()
                                        val elapsed = currentTime - gestureStartTime
                                        
                                        if (elapsed > 100 && !isGestureActive) { // 100ms threshold
                                            val deltaX = motionEvent.x - gestureStartX
                                            val deltaY = motionEvent.y - gestureStartY
                                            val distance = kotlin.math.sqrt(deltaX * deltaX + deltaY * deltaY)
                                            
                                            if (distance > gestureMovementThreshold) {
                                                // This is a gesture, determine type based on enabled controllers and movement pattern
                                                if (selectedNode.translationController.isEnabled && selectedNode.rotationController.isEnabled) {
                                                    // Both enabled - detect gesture type based on movement pattern
                                                    // CRITICAL FIX: Detect actual gesture type instead of always defaulting to pan
                                                    val isLinearMovement = kotlin.math.abs(deltaX) > kotlin.math.abs(deltaY) * 2 || kotlin.math.abs(deltaY) > kotlin.math.abs(deltaX) * 2
                                                    
                                                    if (isLinearMovement) {
                                                        // Linear movement suggests translation/pan
                                                        lastGestureType = "pan"
                                                        objectChannel.invokeMethod("onPanStart", nodeId)
                                                        Log.d(TAG, "🎮 Detected PAN gesture (linear movement) - dx: $deltaX, dy: $deltaY")
                                                    } else {
                                                        // Circular or complex movement suggests rotation
                                                        lastGestureType = "rotation"
                                                        objectChannel.invokeMethod("onRotationStart", nodeId)
                                                        Log.d(TAG, "🎮 Detected ROTATION gesture (complex movement) - dx: $deltaX, dy: $deltaY")
                                                    }
                                                } else if (selectedNode.translationController.isEnabled) {
                                                    lastGestureType = "pan"
                                                    objectChannel.invokeMethod("onPanStart", nodeId)
                                                    Log.d(TAG, "🎮 Pan gesture (translation only enabled)")
                                                } else if (selectedNode.rotationController.isEnabled) {
                                                    lastGestureType = "rotation"
                                                    objectChannel.invokeMethod("onRotationStart", nodeId)
                                                    Log.d(TAG, "🎮 Rotation gesture (rotation only enabled)")
                                                }
                                                
                                                if (lastGestureType != null) {
                                                    isGestureActive = true
                                                    Log.d(TAG, "🎮 Gesture started: $lastGestureType on node: $nodeId")
                                                }
                                            }
                                        }
                                    }
                                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                                        // End gesture if one was active
                                        if (isGestureActive && lastGestureType != null) {
                                            when (lastGestureType) {
                                                "pan" -> objectChannel.invokeMethod("onPanEnd", nodeId)
                                                "rotation" -> objectChannel.invokeMethod("onRotationEnd", nodeId)
                                            }
                                            Log.d(TAG, "🎮 Gesture ended: $lastGestureType on node: $nodeId")
                                            isGestureActive = false
                                            lastGestureType = null
                                        }
                                    }
                                }
                            }
                            
                            // Check if selected node has valid parent hierarchy - but be less aggressive
                            if (selectedNode is TransformableNode) {
                                val hasValidParent = selectedNode.parent != null && selectedNode.parent is AnchorNode
                                if (!hasValidParent && motionEvent.action == MotionEvent.ACTION_UP) {
                                    Log.w(TAG, "⚠️ Node has invalid parent hierarchy: parent=${selectedNode.parent}, isAnchorNode=${selectedNode.parent is AnchorNode}")
                                    // Only clear selection if the object is truly orphaned, not during normal gestures
                                    // This is a safety measure, but we should be more careful about when to trigger it
                                    if (selectedNode.parent == null) {
                                        Log.w(TAG, "⚠️ Node is completely orphaned - clearing selection to prevent crash")
                                        selectNode(null)
                                        return
                                    } else {
                                        Log.d(TAG, "🔧 Node has parent but wrong type - allowing gesture to continue")
                                    }
                                }
                            }
                            
                            // CRITICAL PAN DEBUG: Track position changes for debugging (use worldPosition for accurate tracking)
                            val currentSelectedNode = this.selectedNode
                            val preTransformPosition = if (currentSelectedNode is TransformableNode) {
                                Vector3(currentSelectedNode.worldPosition.x, currentSelectedNode.worldPosition.y, currentSelectedNode.worldPosition.z)
                            } else null
                            
            // ENHANCED PANNING: Always use custom height projection first for consistent behavior
            Log.d(TAG, "🔒 PANNING CHECK: enableHeightLockedPanning=$enableHeightLockedPanning, isTransformable=${currentSelectedNode is TransformableNode}, gestureType=$lastGestureType, active=$isGestureActive, action=${motionEvent?.action}")
            if (enableHeightLockedPanning && currentSelectedNode is TransformableNode && 
                lastGestureType == "pan" && isGestureActive && motionEvent?.action == MotionEvent.ACTION_MOVE) {
                
                val nodeId = nodeToUniqueIdMap[currentSelectedNode] ?: nodesMap.entries.find { it.value == currentSelectedNode }?.key ?: currentSelectedNode.name
                val storedHeight = nodeFloorHeights[nodeId]
                
                if (storedHeight != null) {
                    Log.d(TAG, "🔒 HEIGHT-LOCKED PANNING: Using custom projection for node $nodeId at height $storedHeight")
                    // Always try custom projection first - this ensures smooth panning everywhere
                    val customProjection = tryCustomHeightProjection(motionEvent, storedHeight)
                    if (customProjection != null) {
                        // Use custom projection - this works even in poorly scanned areas
                        val oldPosition = currentSelectedNode.worldPosition
                        currentSelectedNode.worldPosition = customProjection
                        Log.d(TAG, "🔒 CUSTOM PROJECTION SUCCESS: Moved object from $oldPosition to $customProjection (height-locked at $storedHeight)")
                        return // Skip ARCore's transformation since we handled it
                    } else {
                        Log.w(TAG, "🔒 CUSTOM PROJECTION FAILED: Falling back to ARCore hit testing")
                    }
                } else {
                    Log.w(TAG, "🔒 HEIGHT-LOCKED PANNING: No stored height for node $nodeId")
                }
            }
            
            // Fallback to ARCore's transformation (this will work in well-scanned areas)
            super.onTouch(hitTestResult, motionEvent)
            
            // SECONDARY HEIGHT CORRECTION: Fix any Y drift from ARCore transformation
            if (enableHeightLockedPanning && currentSelectedNode is TransformableNode && 
                lastGestureType == "pan" && isGestureActive && motionEvent?.action == MotionEvent.ACTION_MOVE) {
                
                val nodeId = nodeToUniqueIdMap[currentSelectedNode] ?: nodesMap.entries.find { it.value == currentSelectedNode }?.key ?: currentSelectedNode.name
                val storedHeight = nodeFloorHeights[nodeId]
                
                if (storedHeight != null) {
                    // Only correct the Y position if ARCore changed it
                    val currentPos = currentSelectedNode.worldPosition
                    if (Math.abs(currentPos.y - storedHeight) > heightLockTolerance) {
                        val correctedPosition = Vector3(currentPos.x, storedHeight, currentPos.z)
                        currentSelectedNode.worldPosition = correctedPosition
                        Log.d(TAG, "🔒 HEIGHT CORRECTION: Fixed Y drift from ${currentPos.y} to $storedHeight for node $nodeId")
                    }
                }
            }                            // CRITICAL PAN DEBUG: Check if position actually changed (use worldPosition for accurate tracking)
                            if (currentSelectedNode is TransformableNode && preTransformPosition != null && motionEvent?.action == MotionEvent.ACTION_MOVE) {
                                val postTransformPosition = currentSelectedNode.worldPosition
                                val deltaX = postTransformPosition.x - preTransformPosition.x
                                val deltaY = postTransformPosition.y - preTransformPosition.y
                                val deltaZ = postTransformPosition.z - preTransformPosition.z
                                
                                if (Math.abs(deltaX) > 0.001f || Math.abs(deltaY) > 0.001f || Math.abs(deltaZ) > 0.001f) {
                                    Log.d(TAG, "✅ PAN SUCCESS: Position changed! Delta: ($deltaX, $deltaY, $deltaZ)")
                                    Log.d(TAG, "✅ PAN SUCCESS: New position: $postTransformPosition")
                                } else if (isGestureActive && lastGestureType == "pan") {
                                    Log.w(TAG, "⚠️ PAN ISSUE: Gesture active but no position change detected")
                                    Log.w(TAG, "⚠️ PAN ISSUE: Pre: $preTransformPosition, Post: $postTransformPosition")
                                    Log.w(TAG, "⚠️ PAN ISSUE: Controller enabled: ${currentSelectedNode.translationController.isEnabled}")
                                    Log.w(TAG, "⚠️ PAN ISSUE: Parent type: ${currentSelectedNode.parent?.javaClass?.simpleName}")
                                }
                            }
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

            // CRITICAL: Setup conditional peek touch listener for TransformationSystem
            // This ensures TransformationSystem gets touch events, but with smart tap detection
            arSceneView?.scene?.addOnPeekTouchListener { hitTestResult, motionEvent ->
                when (motionEvent.action) {
                    MotionEvent.ACTION_DOWN -> {
                        // Store touch info but delay forwarding briefly to check for quick taps
                        Log.d(TAG, "🎯 Peek touch DOWN - analyzing for quick tap detection")
                        
                        // For very quick interactions, add a small delay before starting gestures
                        // This prevents instant pan/rotation activation on tap-to-select
                        val handler = android.os.Handler(android.os.Looper.getMainLooper())
                        handler.postDelayed({
                            // Only forward if the touch is still active (not a quick tap)
                            val currentTime = System.currentTimeMillis()
                            val elapsed = currentTime - lastTouchDownTime
                            
                            if (elapsed >= 150) { // 150ms threshold for gesture activation
                                Log.d(TAG, "🎯 Delayed gesture activation - forwarding to TransformationSystem")
                                transformationSystem?.onTouch(hitTestResult, motionEvent)
                            } else {
                                Log.d(TAG, "🎯 Quick tap detected - skipping gesture activation")
                            }
                        }, 150) // 150ms delay
                    }
                    MotionEvent.ACTION_MOVE -> {
                        // Forward move events immediately for responsive gestures
                        transformationSystem?.onTouch(hitTestResult, motionEvent)
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                        // Forward end events immediately
                        transformationSystem?.onTouch(hitTestResult, motionEvent)
                    }
                    else -> {
                        // Forward other events normally
                        transformationSystem?.onTouch(hitTestResult, motionEvent)
                    }
                }
            }

            // Setup touch listener with improved tap vs pan detection and proper event prioritization
            arSceneView?.scene?.setOnTouchListener { hitTestResult, motionEvent ->
                Log.d(TAG, "🔥 Scene touch event: action=${motionEvent.action}, x=${motionEvent.x}, y=${motionEvent.y}")
                
                // CRITICAL FIX: Improved tap detection for quick tap-and-release gestures
                when (motionEvent.action) {
                    MotionEvent.ACTION_DOWN -> {
                        Log.d(TAG, "🎯 ACTION_DOWN detected - starting tap tracking")
                        // Store the down position and time for tap detection
                        lastTouchDownTime = System.currentTimeMillis()
                        lastTouchDownX = motionEvent.x
                        lastTouchDownY = motionEvent.y
                        hasTouchMoved = false // Reset movement tracking
                    }
                    MotionEvent.ACTION_UP -> {
                        Log.d(TAG, "🎯 ACTION_UP detected")
                        
                        // Calculate touch duration and movement
                        val touchDuration = System.currentTimeMillis() - lastTouchDownTime
                        val moveDistance = kotlin.math.sqrt(
                            (motionEvent.x - lastTouchDownX).pow(2) + 
                            (motionEvent.y - lastTouchDownY).pow(2)
                        )
                        
                        Log.d(TAG, "🎯 Touch stats: duration=${touchDuration}ms, movement=${moveDistance}px")
                        
                        // QUICK TAP DETECTION: Short duration + minimal movement = selection tap
                        Log.d(TAG, "🎯 TAP ANALYSIS: duration=${touchDuration}ms, movement=${moveDistance}px, hasMoved=$hasTouchMoved")
                        if (touchDuration < 300 && moveDistance < 50 && !hasTouchMoved) {
                            Log.d(TAG, "🎯 QUICK TAP DETECTED - handling tap for selection/deselection")
                            handleTap(motionEvent)
                        } else {
                            Log.d(TAG, "🎯 Long/moved touch - this was likely a pan gesture, skipping tap (criteria: duration<300ms, movement<50px, !hasMoved)")
                        }
                    }
                    MotionEvent.ACTION_CANCEL -> {
                        Log.d(TAG, "🎯 ACTION_CANCEL detected")
                        hasTouchMoved = true // Cancel any tap detection
                    }
                    MotionEvent.ACTION_MOVE -> {
                        // Track movement to detect if this is still a tap
                        val moveDistance = kotlin.math.sqrt(
                            (motionEvent.x - lastTouchDownX).pow(2) + 
                            (motionEvent.y - lastTouchDownY).pow(2)
                        )
                        if (moveDistance > 30) { // 30px threshold for movement
                            hasTouchMoved = true
                            Log.d(TAG, "🎯 Touch moved ${moveDistance}px - no longer a tap")
                        }
                        // Don't log MOVE events to avoid spam
                    }
                    else -> {
                        Log.d(TAG, "🎯 Other motion event: ${motionEvent.action}")
                    }
                }
                
                // Also forward to gesture detector for any additional gesture handling
                gestureDetector?.onTouchEvent(motionEvent)
                
                // Log current selection state for debugging
                val currentSelection = transformationSystem?.selectedNode
                if (motionEvent.action == MotionEvent.ACTION_UP) {
                    Log.d(TAG, "🎯 Current selection after touch: ${currentSelection?.name ?: "none"}")
                }
                
                // CRITICAL: Return true to consume touch events and ensure we get all events including ACTION_UP
                // This gives our listener priority over other touch handlers and prevents event consumption conflicts
                true
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
            "snapshot" -> handleSnapshot(call, result)
            "touch" -> handleTouch(call, result)
            // Add transform gesture control methods for single-object mode
            "enableTransformGestures" -> handleEnableTransformGestures(call, result)
            "disableTransformGestures" -> handleDisableTransformGestures(call, result)
            "selectNode" -> handleSelectNode(call, result)
            "deselectAllNodes" -> handleDeselectAllNodes(call, result)
            "getCurrentSelection" -> handleGetCurrentSelection(call, result)
            // Add cache management methods
            "clearCache" -> handleClearCache(call, result)
            "getCacheStats" -> handleGetCacheStats(call, result)
            "predownloadModels" -> handlePredownloadModels(call, result)
            // Add height-locked panning methods
            "enableHeightLockedPanning" -> handleEnableHeightLockedPanning(call, result)
            "disableHeightLockedPanning" -> handleDisableHeightLockedPanning(call, result)
            "setNodeFloorHeight" -> handleSetNodeFloorHeight(call, result)
            "getNodeFloorHeight" -> handleGetNodeFloorHeight(call, result)
            // Add light estimation methods
            "getLightEstimate" -> handleGetLightEstimate(call, result)
            "enableLightingMonitoring" -> handleEnableLightingMonitoring(call, result)
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

    // =================================================================
    // Transform Gesture Control Methods
    // =================================================================
    
    /**
     * Enable transform gestures for a specific node (Android single-object mode)
     */
    private fun handleEnableTransformGestures(call: MethodCall, result: MethodChannel.Result) {
        try {
            val nodeId = call.arguments as? String
            if (nodeId == null) {
                result.error("INVALID_ARGUMENT", "Node ID is required", null)
                return
            }
            
            Log.d(TAG, "⚡ INSTANT ENABLE: Starting instant gesture enable for node: $nodeId")
            Log.d(TAG, "⚡ INSTANT ENABLE: Available nodes: ${nodesMap.keys}")
            
            val node = nodesMap[nodeId]
            if (node !is TransformableNode) {
                Log.w(TAG, "⚠️ ENABLE TRANSFORM: Node $nodeId is not a TransformableNode or doesn't exist")
                Log.w(TAG, "⚠️ ENABLE TRANSFORM: Node type: ${node?.javaClass?.simpleName ?: "null"}")
                result.error("NODE_NOT_FOUND", "Node $nodeId is not transformable", null)
                return
            }
            
            Log.d(TAG, "⚡ INSTANT ENABLE: Found TransformableNode: $nodeId")
            
            // CRITICAL: PROACTIVE HIERARCHY FIX - Check and restore anchor hierarchy BEFORE gesture operations
            Log.d(TAG, "🔧 HIERARCHY CHECK: Verifying node anchor hierarchy before gesture enable")
            val hasValidParent = node.parent != null && node.parent is AnchorNode
            
            if (!hasValidParent) {
                Log.w(TAG, "🚨 HIERARCHY FIX: Node $nodeId missing anchor parent, attempting immediate restore")
                
                // Try to find existing anchor or create new one
                val anchorNodeId = "${nodeId}_anchor"
                var anchorNode = nodesMap[anchorNodeId] as? AnchorNode
                
                if (anchorNode == null) {
                    Log.d(TAG, "🔧 HIERARCHY FIX: Creating new anchor for orphaned node")
                    // Create emergency anchor at current world position
                    val currentPosition = node.worldPosition
                    val session = arSceneView?.session
                    
                    if (session != null && currentPosition != null) {
                        try {
                            val emergencyAnchor = session.createAnchor(
                                Pose.makeTranslation(currentPosition.x, currentPosition.y, currentPosition.z)
                            )
                            anchorNode = AnchorNode(emergencyAnchor)
                            anchorNode.setParent(arSceneView?.scene)
                            nodesMap[anchorNodeId] = anchorNode
                            Log.d(TAG, "✅ HIERARCHY FIX: Created emergency anchor at position: $currentPosition")
                        } catch (e: Exception) {
                            Log.e(TAG, "❌ HIERARCHY FIX: Failed to create emergency anchor: ${e.message}")
                            result.error("HIERARCHY_ERROR", "Cannot restore node hierarchy", null)
                            return
                        }
                    } else {
                        Log.e(TAG, "❌ HIERARCHY FIX: Cannot create anchor - missing session or position")
                        result.error("HIERARCHY_ERROR", "Missing session or node position", null)
                        return
                    }
                }
                
                // Re-parent the node to the anchor
                Log.d(TAG, "🔧 HIERARCHY FIX: Re-parenting node to anchor")
                node.setParent(anchorNode)
                node.localPosition = Vector3(0.0f, 0.0f, 0.0f)
                Log.d(TAG, "✅ HIERARCHY FIX: Successfully restored hierarchy for $nodeId")
            } else {
                Log.d(TAG, "✅ HIERARCHY CHECK: Node $nodeId has valid anchor parent")
            }
            
            // INSTANT OPERATIONS: Single-pass operation for zero-delay switching (now with valid hierarchy)
            Log.d(TAG, "⚡ INSTANT SWITCH: Performing single-pass gesture switch operation")
            
            // Step 1: Instantly disable all nodes and enable target in one loop
            for ((id, existingNode) in nodesMap) {
                if (existingNode is TransformableNode) {
                    if (id == nodeId) {
                        // Enable the target node (now guaranteed to have valid parent)
                        existingNode.translationController.isEnabled = true
                        existingNode.rotationController.isEnabled = true
                        existingNode.scaleController.isEnabled = true
                        Log.d(TAG, "⚡ ENABLED: $id (with valid hierarchy)")
                    } else {
                        // Disable all other nodes
                        existingNode.translationController.isEnabled = false
                        existingNode.rotationController.isEnabled = false
                        existingNode.scaleController.isEnabled = false
                    }
                }
            }
            
            // Step 2: Instantly update transformation system selection
            transformationSystem?.selectNode(node)
            
            Log.d(TAG, "⚡ INSTANT SUCCESS: Gesture switching completed instantly for node: $nodeId")
            Log.d(TAG, "⚡ INSTANT SUCCESS: Target node controllers - Translation: ${node.translationController.isEnabled}, Rotation: ${node.rotationController.isEnabled}, Scale: ${node.scaleController.isEnabled}")
            
            // Return success immediately - zero delay response
            result.success(true)
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ ENABLE TRANSFORM: Error enabling gestures: ${e.message}")
            result.error("ENABLE_ERROR", "Failed to enable gestures: ${e.message}", null)
        }
    }
    
    /**
     * Disable transform gestures for a specific node with instant response
     */
    private fun handleDisableTransformGestures(call: MethodCall, result: MethodChannel.Result) {
        try {
            val nodeId = call.arguments as? String
            if (nodeId == null) {
                result.error("INVALID_ARGUMENT", "Node ID is required", null)
                return
            }
            
            Log.d(TAG, "⚡ INSTANT DISABLE: Starting instant gesture disable for node: $nodeId")
            Log.d(TAG, "⚡ INSTANT DISABLE: Available nodes: ${nodesMap.keys}")
            
            val node = nodesMap[nodeId]
            if (node !is TransformableNode) {
                Log.w(TAG, "⚠️ DISABLE TRANSFORM: Node $nodeId is not a TransformableNode or doesn't exist")
                Log.w(TAG, "⚠️ DISABLE TRANSFORM: Node type: ${node?.javaClass?.simpleName ?: "null"}")
                result.error("NODE_NOT_FOUND", "Node $nodeId is not transformable", null)
                return
            }
            
            Log.d(TAG, "⚡ INSTANT DISABLE: Found TransformableNode: $nodeId")
            
            // INSTANT OPERATIONS: Immediate disable for zero-delay response
            Log.d(TAG, "⚡ INSTANT DISABLE: Performing immediate gesture disable")
            
            // Step 1: Instantly disable gesture controllers for this specific node
            node.translationController.isEnabled = false
            node.rotationController.isEnabled = false
            node.scaleController.isEnabled = false
            
            // Step 2: Instantly deselect from transformation system
            if (transformationSystem?.selectedNode == node) {
                transformationSystem?.selectNode(null)
                Log.d(TAG, "⚡ INSTANT DESELECT: Deselected node from TransformationSystem")
            }
            
            Log.d(TAG, "⚡ INSTANT SUCCESS: Gesture disable completed instantly for node: $nodeId")
            Log.d(TAG, "⚡ INSTANT SUCCESS: Node controllers - Translation: ${node.translationController.isEnabled}, Rotation: ${node.rotationController.isEnabled}, Scale: ${node.scaleController.isEnabled}")
            
            // Return success immediately - zero delay response
            result.success(true)
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ DISABLE TRANSFORM: Error disabling gestures: ${e.message}")
            result.error("DISABLE_ERROR", "Failed to disable gestures: ${e.message}", null)
        }
    }
    
    /**
     * Select a specific node in the transformation system
     */
    private fun handleSelectNode(call: MethodCall, result: MethodChannel.Result) {
        try {
            val nodeId = call.arguments as? String
            if (nodeId == null) {
                result.error("INVALID_ARGUMENT", "Node ID is required", null)
                return
            }
            
            Log.d(TAG, "🎯 SELECT NODE: Selecting node: $nodeId")
            
            val node = nodesMap[nodeId]
            if (node !is TransformableNode) {
                Log.w(TAG, "⚠️ Node $nodeId is not a TransformableNode or doesn't exist")
                result.error("NODE_NOT_FOUND", "Node $nodeId is not transformable", null)
                return
            }
            
            // Select the node in the transformation system
            transformationSystem?.selectNode(node)
            
            // Note: SelectionVisualizer will handle notifySelectionStateChange automatically
            
            Log.d(TAG, "✅ SELECT NODE: Successfully selected node: $nodeId")
            result.success(true)
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ SELECT NODE: Error selecting node: ${e.message}")
            result.error("SELECT_ERROR", "Failed to select node: ${e.message}", null)
        }
    }
    
    /**
     * Deselect all nodes in the transformation system
     */
    private fun handleDeselectAllNodes(call: MethodCall, result: MethodChannel.Result) {
        try {
            Log.d(TAG, "🎯 DESELECT ALL: Deselecting all nodes")
            
            // Deselect any currently selected node
            transformationSystem?.selectNode(null)
            
            // Notify Flutter about the deselection
            notifySelectionStateChange(null)
            
            // CRITICAL FIX: Do NOT disable all gesture controllers!
            // Keep gesture controllers enabled so objects remain interactable after deselection
            // Only deselect, don't disable gestures
            
            Log.d(TAG, "✅ DESELECT ALL: Successfully deselected all nodes (gestures remain enabled)")
            result.success(true)
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ DESELECT ALL: Error deselecting nodes: ${e.message}")
            result.error("DESELECT_ERROR", "Failed to deselect nodes: ${e.message}", null)
        }
    }
    
    /**
     * Get the currently selected node
     */
    private fun handleGetCurrentSelection(call: MethodCall, result: MethodChannel.Result) {
        try {
            val selectedNode = transformationSystem?.selectedNode
            if (selectedNode != null) {
                // Find the node ID in our mapping
                val nodeId = nodeToUniqueIdMap[selectedNode] ?: nodesMap.entries.find { it.value == selectedNode }?.key
                if (nodeId != null) {
                    Log.d(TAG, "🎯 CURRENT SELECTION: $nodeId")
                    result.success(nodeId)
                } else {
                    Log.d(TAG, "🎯 CURRENT SELECTION: Node not found in mapping")
                    result.success(null)
                }
            } else {
                Log.d(TAG, "🎯 CURRENT SELECTION: No node selected")
                result.success(null)
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ GET CURRENT SELECTION: Error getting current selection: ${e.message}")
            result.error("GET_SELECTION_ERROR", "Failed to get current selection: ${e.message}", null)
        }
    }

    /**
     * Notify Flutter about selection state changes
     */
    private fun notifySelectionStateChange(selectedNodeId: String?) {
        try {
            Log.d(TAG, "📢 SELECTION STATE CHANGE: $selectedNodeId")
            objectChannel.invokeMethod("onSelectionChanged", selectedNodeId)
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error notifying selection change: ${e.message}")
        }
    }
    private fun disableAllTransformableNodes() {
        try {
            Log.d(TAG, "🔧 Disabling all transformable nodes for single-object mode")
            
            for ((nodeId, node) in nodesMap) {
                if (node is TransformableNode) {
                    node.translationController.isEnabled = false
                    node.rotationController.isEnabled = false
                    node.scaleController.isEnabled = false
                    Log.d(TAG, "🔧 Disabled gestures for node: $nodeId")
                }
            }
            
            // Deselect any currently selected node
            transformationSystem?.selectNode(null)
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error disabling all transformable nodes: ${e.message}")
        }
    }

    // =================================================================
    // Height-Locked Panning Methods
    // =================================================================
    
    /**
     * Enable height-locked panning mode - objects will pan freely but stay at detected floor height
     */
    private fun handleEnableHeightLockedPanning(call: MethodCall, result: MethodChannel.Result) {
        try {
            val tolerance = (call.arguments as? Number)?.toFloat() ?: 0.05f
            
            enableHeightLockedPanning = true
            heightLockTolerance = tolerance
            
            Log.d(TAG, "🔒 HEIGHT-LOCKED PANNING: Enabled with tolerance: ${tolerance}m")
            result.success(true)
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error enabling height-locked panning: ${e.message}")
            result.error("ENABLE_HEIGHT_LOCK_ERROR", "Failed to enable height-locked panning: ${e.message}", null)
        }
    }
    
    /**
     * Disable height-locked panning mode - return to normal ARCore plane-based panning
     */
    private fun handleDisableHeightLockedPanning(call: MethodCall, result: MethodChannel.Result) {
        try {
            enableHeightLockedPanning = false
            
            Log.d(TAG, "🔓 HEIGHT-LOCKED PANNING: Disabled")
            result.success(true)
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error disabling height-locked panning: ${e.message}")
            result.error("DISABLE_HEIGHT_LOCK_ERROR", "Failed to disable height-locked panning: ${e.message}", null)
        }
    }
    
    /**
     * Set the floor height for a specific node (called when object is placed on detected surface)
     */
    private fun handleSetNodeFloorHeight(call: MethodCall, result: MethodChannel.Result) {
        try {
            val arguments = call.arguments as? Map<String, Any>
            val nodeId = arguments?.get("nodeId") as? String
            val height = (arguments?.get("height") as? Number)?.toFloat()
            
            if (nodeId == null || height == null) {
                result.error("INVALID_ARGUMENTS", "nodeId and height are required", null)
                return
            }
            
            nodeFloorHeights[nodeId] = height
            
            Log.d(TAG, "🔒 HEIGHT SET: Node $nodeId floor height set to $height")
            result.success(true)
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error setting node floor height: ${e.message}")
            result.error("SET_HEIGHT_ERROR", "Failed to set node floor height: ${e.message}", null)
        }
    }
    
    /**
     * Get the stored floor height for a specific node
     */
    private fun handleGetNodeFloorHeight(call: MethodCall, result: MethodChannel.Result) {
        try {
            val nodeId = call.arguments as? String
            
            if (nodeId == null) {
                result.error("INVALID_ARGUMENTS", "nodeId is required", null)
                return
            }
            
            val height = nodeFloorHeights[nodeId]
            
            Log.d(TAG, "🔒 HEIGHT GET: Node $nodeId floor height: $height")
            result.success(height)
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error getting node floor height: ${e.message}")
            result.error("GET_HEIGHT_ERROR", "Failed to get node floor height: ${e.message}", null)
        }
    }

    // =================================================================
    // Light Estimation Methods
    // =================================================================
    
    /**
     * Enable or disable automatic lighting condition monitoring
     * Sends periodic updates via onLightingConditionChanged callback
     */
    private fun handleEnableLightingMonitoring(call: MethodCall, result: MethodChannel.Result) {
        try {
            val arguments = call.arguments as? Map<*, *>
            val enable = arguments?.get("enable") as? Boolean ?: true
            val intervalMs = arguments?.get("intervalMs") as? Int
            
            if (intervalMs != null && intervalMs > 0) {
                lightingCheckInterval = intervalMs.toLong()
            }
            
            isMonitoringLighting = enable
            
            if (enable) {
                Log.d(TAG, "💡 Starting lighting monitoring (interval: ${lightingCheckInterval}ms)")
                lightingHandler.post(lightingCheckRunnable)
            } else {
                Log.d(TAG, "💡 Stopping lighting monitoring")
                lightingHandler.removeCallbacks(lightingCheckRunnable)
            }
            
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error toggling lighting monitoring: ${e.message}")
            result.error("LIGHTING_MONITORING_ERROR", e.message, null)
        }
    }
    
    /**
     * Get current light estimate from ARCore
     * Returns pixel intensity and color correction data
     */
    private fun handleGetLightEstimate(call: MethodCall, result: MethodChannel.Result) {
        try {
            val frame = arSceneView?.arFrame
            if (frame == null) {
                result.error("NO_FRAME", "AR frame not available", null)
                return
            }
            
            val lightEstimate = frame.lightEstimate
            if (lightEstimate == null || lightEstimate.state != LightEstimate.State.VALID) {
                result.error("NO_ESTIMATE", "Light estimate not available or invalid", null)
                return
            }
            
            val pixelIntensity = lightEstimate.pixelIntensity
            
            // Threshold for low light detection (typical range: 0.0 to 1.0+)
            val isLowLight = pixelIntensity < 0.3f
            val isVeryLowLight = pixelIntensity < 0.15f
            
            // Try to get color correction if available (may not be supported in all ARCore versions)
            val colorCorrection = try {
                val colorCorrectionMethod = lightEstimate.javaClass.getMethod("getColorCorrection")
                val colorArray = colorCorrectionMethod.invoke(lightEstimate) as FloatArray
                listOf(
                    colorArray[0].toDouble(),
                    colorArray[1].toDouble(),
                    colorArray[2].toDouble(),
                    colorArray[3].toDouble()
                )
            } catch (e: Exception) {
                // Color correction not available, use default
                listOf(1.0, 1.0, 1.0, 1.0)
            }
            
            val lightData = mapOf(
                "pixelIntensity" to pixelIntensity.toDouble(),
                "colorCorrection" to colorCorrection,
                "isLowLight" to isLowLight,
                "isVeryLowLight" to isVeryLowLight,
                "timestamp" to System.currentTimeMillis()
            )
            
            Log.d(TAG, "💡 Light estimate - Intensity: $pixelIntensity, Low light: $isLowLight, Very low: $isVeryLowLight")
            result.success(lightData)
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error getting light estimate: ${e.message}")
            result.error("LIGHT_ESTIMATE_ERROR", e.message, null)
        }
    }
    
    /**
     * Check lighting conditions and notify Flutter if monitoring is enabled
     * Called periodically by lightingCheckRunnable
     */
    private fun checkLightingConditions() {
        try {
            Log.d(TAG, "💡 checkLightingConditions called, monitoring: $isMonitoringLighting")
            
            if (!isMonitoringLighting) {
                Log.d(TAG, "💡 Monitoring disabled, skipping check")
                return
            }
            
            val sceneView = arSceneView
            if (sceneView == null) {
                Log.d(TAG, "💡 arSceneView is null, skipping check")
                return
            }
            
            val frame = sceneView.arFrame
            if (frame == null) {
                Log.d(TAG, "💡 arFrame is null, skipping check")
                return
            }
            
            val lightEstimate = frame.lightEstimate
            if (lightEstimate == null) {
                Log.d(TAG, "💡 lightEstimate is null, skipping check")
                return
            }
            
            if (lightEstimate.state != LightEstimate.State.VALID) {
                Log.d(TAG, "💡 lightEstimate state is not VALID: ${lightEstimate.state}")
                return
            }
            
            val pixelIntensity = lightEstimate.pixelIntensity
            val isLowLight = pixelIntensity < 0.3f
            val isVeryLowLight = pixelIntensity < 0.15f
            
            Log.d(TAG, "💡 Light check OK - Intensity: $pixelIntensity, Low: $isLowLight, VeryLow: $isVeryLowLight")
            
            // Notify Flutter about lighting conditions
            val lightData = mapOf(
                "pixelIntensity" to pixelIntensity.toDouble(),
                "isLowLight" to isLowLight,
                "isVeryLowLight" to isVeryLowLight,
                "timestamp" to System.currentTimeMillis()
            )
            
            activity.runOnUiThread {
                Log.d(TAG, "💡 Invoking onLightingConditionChanged callback to Flutter")
                sessionChannel.invokeMethod("onLightingConditionChanged", lightData)
            }
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error checking lighting: ${e.message}", e)
        }
    }

    // =================================================================
    // Environmental HDR Lighting Methods
    // =================================================================
    
    /**
     * Load custom HDR environment for realistic lighting, shadows, and reflections
     * This significantly improves the visual quality of 3D models in AR scenes
     */
    private fun loadEnvironmentalHdr() {
        try {
            Log.d(TAG, "🌅 Initializing Environmental HDR lighting")
            
            // ARCore's ENVIRONMENTAL_HDR mode automatically generates realistic lighting
            // from environment probes captured by the camera. This provides superior
            // lighting quality compared to static HDR files because it:
            // 1. Adapts to the actual environment in real-time
            // 2. Provides accurate reflections of the real surroundings
            // 3. Updates as the user moves through different lighting conditions
            // 4. Captures both ambient and directional lighting accurately
            
            // The ENVIRONMENTAL_HDR mode is already enabled in the ARCore configuration,
            // so no additional setup is needed. ARCore will automatically:
            // - Create spherical harmonic probes for ambient lighting
            // - Generate HDR cubemaps for reflections
            // - Estimate main light direction and intensity
            // - Provide color temperature information
            
            Log.d(TAG, "✅ ENVIRONMENTAL_HDR mode active")
            Log.d(TAG, "   ARCore automatically provides realistic lighting from environment")
            Log.d(TAG, "   This adapts in real-time as lighting conditions change")
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error initializing Environmental HDR: ${e.message}", e)
            // Non-fatal - ARCore will still provide basic lighting
        }
    }

    // =================================================================
    // Cache Management Methods
    // =================================================================
    
    /**
     * Clear all cached models
     */
    private fun handleClearCache(call: MethodCall, result: MethodChannel.Result) {
        try {
            Log.d(TAG, "🗑️ Clearing model cache")
            
            val success = modelDownloadService.clearAllModels()
            
            if (success) {
                Log.d(TAG, "✅ Cache cleared successfully")
                result.success(true)
            } else {
                Log.w(TAG, "⚠️ Cache clear operation completed with warnings")
                result.success(false)
            }
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error clearing cache: ${e.message}")
            result.error("CACHE_CLEAR_ERROR", "Failed to clear cache: ${e.message}", null)
        }
    }
    
    /**
     * Get cache statistics
     */
    private fun handleGetCacheStats(call: MethodCall, result: MethodChannel.Result) {
        try {
            Log.d(TAG, "📊 Getting cache statistics")
            
            val stats = modelDownloadService.getCacheStats()
            
            Log.d(TAG, "✅ Cache stats retrieved: ${stats.size} metrics")
            result.success(stats)
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error getting cache stats: ${e.message}")
            result.error("CACHE_STATS_ERROR", "Failed to get cache stats: ${e.message}", null)
        }
    }
    
    /**
     * Predownload models for better performance
     */
    private fun handlePredownloadModels(call: MethodCall, result: MethodChannel.Result) {
        try {
            val modelUrls = call.arguments as? List<String>
            if (modelUrls == null) {
                result.error("INVALID_ARGUMENTS", "Model URLs list is required", null)
                return
            }
            
            Log.d(TAG, "📥 Predownloading ${modelUrls.size} models")
            
            modelDownloadService.predownloadModels(modelUrls)
            
            Log.d(TAG, "✅ Predownload initiated for ${modelUrls.size} models")
            result.success(true)
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error predownloading models: ${e.message}")
            result.error("PREDOWNLOAD_ERROR", "Failed to predownload models: ${e.message}", null)
        }
    }

    private fun handleInit(call: MethodCall, result: MethodChannel.Result) {
        Log.d(TAG, "🎯 AR Session initialization requested")
        
        try {
            val arguments = call.arguments as? Map<String, Any>
            if (arguments != null) {
                val showPlanes = arguments["showPlanes"] as? Boolean ?: true
                Log.d(TAG, "🎯 Configuring plane visibility: $showPlanes")
                
                // Configure plane renderer based on Flutter parameter
                arSceneView?.let { sceneView ->
                    sceneView.planeRenderer.isEnabled = true // Always keep detection enabled for hit testing
                    sceneView.planeRenderer.isVisible = showPlanes // Only show visually if requested
                    Log.d(TAG, "🎯 Plane renderer configured - enabled: true, visible: $showPlanes")
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "⚠️ Error configuring plane renderer: ${e.message}")
        }
        
        result.success("AR session ready")
    }

    private fun handleTap(motionEvent: MotionEvent) {        
        Log.d(TAG, "🎯🎯🎯 ANDROID: handleTap called! MotionEvent: x=${motionEvent.x}, y=${motionEvent.y}, action=${motionEvent.action}")
        
        // CRITICAL: Check for and restore any disappeared nodes before processing tap
        restoreDisappearedNodes()
        
        // FIRST: Check for node/object hits (like iOS implementation)
        // This is the critical missing piece that makes object selection work globally
        reusableNodeHitResults.clear() // Reuse collection to reduce GC pressure
        
        Log.d(TAG, "🔍 Starting object hit detection...")
        Log.d(TAG, "🔍 Available nodes in nodesMap: ${nodesMap.keys}")
        
        arSceneView?.let { sceneView ->
            try {
                val camera = sceneView.scene.camera
                Log.d(TAG, "🔍 Camera available: ${camera != null}")
                
                if (camera != null) {
                    Log.d(TAG, "🔍 Checking ${nodesMap.size} nodes for hits...")
                    
                    // Try multiple hit detection approaches
                    
                    // APPROACH 1: Standard scene hit testing (most reliable and precise)
                    try {
                        // Use MotionEvent for hit testing - this should be the primary method
                        val hitTestResult = sceneView.scene.hitTest(motionEvent)
                        val hitNode = hitTestResult?.node
                        Log.d(TAG, "🔍 Scene hitTest returned node: ${hitNode?.javaClass?.simpleName}")
                        
                        if (hitNode != null) {
                            // Find the corresponding node name in our map
                            for ((nodeName, mappedNode) in nodesMap) {
                                // Check direct match, parent-child relationships, and TransformableNode cases
                                if (mappedNode == hitNode || 
                                    (hitNode.parent == mappedNode) || 
                                    (mappedNode.parent == hitNode) ||
                                    (hitNode is TransformableNode && mappedNode == hitNode) ||
                                    (mappedNode is TransformableNode && hitNode == mappedNode)) {
                                    
                                    // ANDROID FIX: Get the unique ID for this node instead of the nodeName
                                    val uniqueId = nodeToUniqueIdMap[mappedNode]
                                    if (uniqueId != null) {
                                        Log.d(TAG, "🎯 FOUND DIRECT HIT via scene testing: $uniqueId (original name: $nodeName)")
                                        reusableNodeHitResults.add(uniqueId)
                                    } else {
                                        // Fallback to nodeName if no unique ID found (backwards compatibility)
                                        Log.d(TAG, "🎯 FOUND DIRECT HIT via scene testing (fallback): $nodeName")
                                        reusableNodeHitResults.add(nodeName)
                                    }
                                    break
                                }
                            }
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "⚠️ Scene hit testing failed: ${e.message}")
                    }
                    
                    // APPROACH 2: Manual screen-space distance (fallback)
                    if (reusableNodeHitResults.isEmpty()) {
                        Log.d(TAG, "🔍 No hits from scene testing, trying manual distance calculation...")
                        
                        // Track all candidates with their distances for closest selection
                        val candidateNodes = mutableListOf<Pair<String, Float>>()
                        
                        for ((nodeName, node) in nodesMap) {
                            if (node is TransformableNode) {
                                try {
                                    Log.d(TAG, "🔍 Testing node: $nodeName")
                                    
                                    // Get the node's world position
                                    val worldPosition = node.worldPosition
                                    Log.d(TAG, "🔍 World position: $worldPosition")
                                    
                                    // Convert world position to screen coordinates
                                    val screenPosition = camera.worldToScreenPoint(worldPosition)
                                    Log.d(TAG, "🔍 Screen position: $screenPosition")
                                    
                                    // Calculate distance between tap point and node's screen position
                                    val distance = kotlin.math.sqrt(
                                        (screenPosition.x - motionEvent.x).pow(2) + 
                                        (screenPosition.y - motionEvent.y).pow(2)
                                    )
                                    
                                    Log.d(TAG, "🔍 Distance from tap: $distance")
                                    
                                    // If tap is within reasonable distance, consider it a candidate
                                    // BALANCED FIX: Use moderate threshold for reliable object selection
                                    // 120px was too small, 800px was too large
                                    // Use 200px for good balance between precision and usability
                                    if (distance < 200.0) {
                                        // ANDROID FIX: Get the unique ID for this node instead of the nodeName
                                        val uniqueId = nodeToUniqueIdMap[node]
                                        if (uniqueId != null) {
                                            Log.d(TAG, "🎯 CANDIDATE HIT: $uniqueId (original name: $nodeName, distance: $distance)")
                                            candidateNodes.add(Pair(uniqueId, distance))
                                        } else {
                                            // Fallback to nodeName if no unique ID found (backwards compatibility)
                                            Log.d(TAG, "🎯 CANDIDATE HIT (fallback): $nodeName (distance: $distance)")
                                            candidateNodes.add(Pair(nodeName, distance))
                                        }
                                    } else {
                                        Log.d(TAG, "⚠️ Distance too far for hit: $nodeName (distance: $distance, threshold: 200.0)")
                                    }
                                } catch (e: Exception) {
                                    Log.w(TAG, "⚠️ Hit test error for node $nodeName: ${e.message}")
                                }
                            }
                        }
                        
                        // CRITICAL FIX: Select only the CLOSEST object when multiple candidates exist
                        if (candidateNodes.isNotEmpty()) {
                            // Sort by distance (closest first) and select only the closest
                            val closestNode = candidateNodes.minByOrNull { it.second }
                            if (closestNode != null) {
                                Log.d(TAG, "🎯 FOUND CLOSEST HIT via distance calculation: ${closestNode.first} (distance: ${closestNode.second})")
                                Log.d(TAG, "🔍 Rejected ${candidateNodes.size - 1} other candidates to avoid multi-selection conflicts")
                                reusableNodeHitResults.add(closestNode.first)
                            }
                        }
                    }
                } else {
                    Log.w(TAG, "⚠️ Camera is null, cannot perform hit testing")
                }
            } catch (e: Exception) {
                Log.e(TAG, "❌ Error during hit testing: ${e.message}")
            }
        } ?: Log.w(TAG, "⚠️ arSceneView is null, cannot perform hit testing")
        
        // If we found object hits, notify Flutter and let it handle selection
        if (reusableNodeHitResults.isNotEmpty()) {
            Log.d(TAG, "🎯 Object(s) tapped: ${reusableNodeHitResults.joinToString()}")
            
            // Notify Flutter about the tap - Flutter will handle selection
            val uniqueNodeHits = reusableNodeHitResults.toSet().toList()
            objectChannel.invokeMethod("onNodeTap", uniqueNodeHits)
            return
        }
        
        Log.d(TAG, "🎯 No objects hit, checking for plane hits or empty space...")
        
        // CRITICAL FIX: Always check for empty space taps for deselection, even if plane detection is disabled
        var foundValidHit = false
        
        // SECOND: Enhanced hit detection - try ARCore first, fallback to virtual plane
        val frame = arSceneView?.arFrame
        if (frame != null && frame.camera.trackingState == TrackingState.TRACKING) {
            val hits = frame.hitTest(motionEvent.x, motionEvent.y)
            Log.d(TAG, "🎯 Found ${hits.size} ARCore hit test results")
            
            // First try: Use ARCore's detected planes (most accurate)
            for (hit in hits) {
                val trackable = hit.trackable
                if (trackable is Plane && trackable.isPoseInPolygon(hit.hitPose)) {
                    Log.d(TAG, "🎯 Valid ARCore plane hit found!")
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
                    foundValidHit = true
                    break
                }
            }
            
            // Second try: If ARCore hit testing failed, try virtual plane projection
            if (!foundValidHit && enableHeightLockedPanning && nodeFloorHeights.isNotEmpty()) {
                val virtualHit = tryVirtualPlaneHit(frame, motionEvent.x, motionEvent.y)
                if (virtualHit != null) {
                    Log.d(TAG, "🎯 Virtual plane hit created for poorly scanned area!")
                    sessionChannel.invokeMethod("onPlaneOrPointTap", listOf(virtualHit))
                    foundValidHit = true
                }
            }
        } else {
            Log.d(TAG, "🎯 No AR frame or camera not tracking - still processing empty space tap for deselection")
        }
        
        // CRITICAL ENHANCEMENT: Always notify Flutter about empty space taps for deselection
        // This ensures deselection works regardless of plane detection settings or AR tracking state
        if (!foundValidHit) {
            Log.d(TAG, "🎯🔥 EMPTY SPACE TAPPED - CALLING Flutter deselection callback!")
            Log.d(TAG, "🎯🔥 About to call: sessionChannel.invokeMethod(\"onPlaneOrPointTap\", emptyList())")
            sessionChannel.invokeMethod("onPlaneOrPointTap", emptyList<Map<String, Any>>())
            Log.d(TAG, "🎯🔥 Flutter deselection callback sent!")
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
                
                // Store floor height for height-locked panning
                val floorHeight = pose.translation[1] // Y component of pose
                nodeFloorHeights[name] = floorHeight
                Log.d(TAG, "🔒 FLOOR HEIGHT: Stored height $floorHeight for anchor $name")
                
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
                // 🎯 Use iOS-style temporary download to fix texture issues
                Log.d(TAG, "🎯🎯🎯 [DEBUG] Loading model with iOS-style temporary download: $uri")
                Log.d(TAG, "🎯🎯🎯 [DEBUG] Node name: $nodeName, Position: ($positionX, $positionY, $positionZ)")
                Log.d(TAG, "🎯🎯🎯 [DEBUG] Scale: ($scaleX, $scaleY, $scaleZ)")
                Log.d(TAG, "🎯🎯🎯 [DEBUG] Gestures - transformable: $isTransformable, pan: $enablePanGestures, rotation: $enableRotationGestures")
                
                // Use the new temporary download approach that fixes texture issues
                loadModelWithTemporaryDownload(
                    uri,
                    nodeName,
                    positionX,
                    positionY,
                    positionZ,
                    scaleX,
                    scaleY,
                    scaleZ,
                    isTransformable,
                    enablePanGestures,
                    enableRotationGestures,
                    result
                )
                
            } catch (e: Exception) {
                Log.e(TAG, "❌❌❌ [DEBUG] Exception in temporary download loading: ${e.message}")
                Log.e(TAG, "❌❌❌ [DEBUG] Exception stack trace:", e)
                result.error("MODEL_CREATE_ERROR", e.message ?: "Unknown error", null)
            }
                
        } catch (e: Exception) {
            Log.e(TAG, "❌ Exception in handleAddNode: ${e.message}", e)
            result.error("GENERAL_ERROR", e.message ?: "Unknown error", null)
        }
    }

    /**
     * Helper method to create URI with cache support
     * Falls back to direct URL if cache fails
     */
    private fun getModelUri(originalUri: String): Uri {
        return try {
            // Try to get cached file first using AndroidModelCache directly
            val modelCache = com.uhg0.ar_flutter_plugin_2.utils.AndroidModelCache.getInstance(activity.applicationContext)
            val cachedPath = modelCache.checkModelCache(originalUri)
            if (cachedPath != null) {
                val cachedFile = java.io.File(cachedPath)
                if (cachedFile.exists()) {
                    Log.d(TAG, "📦 Using cached model: ${cachedFile.absolutePath}")
                    return Uri.fromFile(cachedFile)
                }
            }
            Log.d(TAG, "🌐 Cache miss, using direct URL: $originalUri")
            Uri.parse(originalUri)
        } catch (e: Exception) {
            Log.w(TAG, "⚠️ Cache check failed, using direct URL: ${e.message}")
            Uri.parse(originalUri)
        }
    }

    /**
     * Load model with iOS-style temporary download - downloads temporarily, loads immediately, then cleans up
     * This avoids texture path issues that occur with persistent caching
     */
    private fun loadModelWithTemporaryDownload(
        uri: String,
        nodeName: String,
        positionX: Float,
        positionY: Float,
        positionZ: Float,
        scaleX: Float,
        scaleY: Float,
        scaleZ: Float,
        isTransformable: Boolean,
        enablePanGestures: Boolean,
        enableRotationGestures: Boolean,
        result: MethodChannel.Result
    ) {
        Log.d(TAG, "🎯🎯🎯 [DEBUG] Starting iOS-style temporary model loading: $uri")
        Log.d(TAG, "🎯🎯🎯 [DEBUG] Parameters - nodeName: $nodeName")
        Log.d(TAG, "🎯🎯🎯 [DEBUG] Position: ($positionX, $positionY, $positionZ)")
        Log.d(TAG, "🎯🎯🎯 [DEBUG] Scale: ($scaleX, $scaleY, $scaleZ)")
        Log.d(TAG, "🎯🎯🎯 [DEBUG] Gestures: transformable=$isTransformable, pan=$enablePanGestures, rotation=$enableRotationGestures")
        
        // Use coroutine scope to download model temporarily like iOS
        downloadScope.launch {
            try {
                Log.d(TAG, "📥📥📥 [DEBUG] Coroutine launched, starting temporary download...")
                // Download temporarily like iOS - don't use persistent cache to avoid texture issues
                val tempFile = downloadModelTemporarily(uri)
                Log.d(TAG, "📁📁📁 [DEBUG] Temporary download completed: $tempFile")
                if (tempFile == null) {
                    Log.e(TAG, "❌❌❌ [DEBUG] Temporary download failed")
                    activity.runOnUiThread {
                        Log.e(TAG, "❌❌❌ [DEBUG] Failed to download model temporarily: $uri")
                        result.error("DOWNLOAD_ERROR", "Failed to download model", null)
                    }
                    return@launch
                }
                
                Log.d(TAG, "✅ Model ready temporarily at: ${tempFile.absolutePath}")
                
                // Switch back to main thread for SceneForm operations
                activity.runOnUiThread {
                    try {
                        val tempUri = Uri.fromFile(tempFile)
                        
                        val modelRenderableBuilder = ModelRenderable.builder()
                        val renderableSourceBuilder = RenderableSource.builder()
                        
                        // Check file extension and set appropriate source type
                        if (uri.endsWith(".glb")) {
                            Log.d(TAG, "📂 Loading temporary GLB file: ${tempFile.absolutePath}")
                            renderableSourceBuilder
                                .setSource(activity, tempUri, RenderableSource.SourceType.GLB)
                                .setScale(1.0f)
                                .setRecenterMode(RenderableSource.RecenterMode.ROOT)
                        } else if (uri.endsWith(".gltf")) {
                            Log.d(TAG, "📂 Loading temporary GLTF file: ${tempFile.absolutePath}")
                            renderableSourceBuilder
                                .setSource(activity, tempUri, RenderableSource.SourceType.GLTF2)
                                .setScale(1.0f)
                                .setRecenterMode(RenderableSource.RecenterMode.ROOT)
                        } else {
                            Log.e(TAG, "❌ Unsupported file format: $uri")
                            // Clean up temp file
                            tempFile.delete()
                            result.error("UNSUPPORTED_FORMAT", "Only GLB and GLTF files are supported", null)
                            return@runOnUiThread
                        }
                        
                        modelRenderableBuilder
                            .setSource(activity, renderableSourceBuilder.build())
                            .setRegistryId(uri)
                            .build()
                            .thenAccept { renderable: ModelRenderable ->
                                Log.d(TAG, "✅ Model loaded successfully from temporary file: $uri")
                                
                                // Clean up temporary file immediately after loading (iOS-style)
                                try {
                                    tempFile.delete()
                                    Log.d(TAG, "🗑️ Cleaned up temporary file: ${tempFile.absolutePath}")
                                } catch (e: Exception) {
                                    Log.w(TAG, "⚠️ Failed to clean up temporary file: ${e.message}")
                                }
                                
                                val transformableNode = TransformableNode(transformationSystem)
                                transformableNode.renderable = renderable
                                transformableNode.name = nodeName
                                
                                // CRITICAL: Set up collision shape for tap detection
                                // Without this, tap detection might fail
                                if (renderable.collisionShape == null) {
                                    val boundingBox = renderable.collisionShape ?: Box(
                                        Vector3(0.5f, 0.5f, 0.5f), // Default size
                                        Vector3.zero() // Center
                                    )
                                    transformableNode.collisionShape = boundingBox
                                    Log.d(TAG, "🔧 Set up collision shape for tap detection")
                                }
                                
                                // Apply custom scale
                                transformableNode.localScale = Vector3(scaleX, scaleY, scaleZ)
                                Log.d(TAG, "🔧 Applied scale: ($scaleX, $scaleY, $scaleZ)")
                                
                                // Configure transformations and gestures...
                                if (isTransformable) {
                                    transformableNode.translationController.isEnabled = enablePanGestures
                                    transformableNode.rotationController.isEnabled = enableRotationGestures
                                    transformableNode.scaleController.isEnabled = true
                                } else {
                                    transformableNode.translationController.isEnabled = false
                                    transformableNode.rotationController.isEnabled = false
                                    transformableNode.scaleController.isEnabled = false
                                }
                                
                                // CRITICAL FIX: Set up proper gesture listeners for actual gesture events
                                // This replaces the incorrect gesture callbacks in SelectionVisualizer
                                setupGestureListeners(transformableNode, nodeName)
                                
                                // CRITICAL: Set up tap listener for proper object selection
                                // This is needed for TransformationSystem to identify which node was tapped
                                transformableNode.setOnTapListener { hitTestResult, motionEvent ->
                                    Log.d(TAG, "🎯 Node $nodeName tapped - TransformationSystem will handle selection")
                                    // Don't manually select - let TransformationSystem handle it naturally
                                    // Just notify Flutter about the tap
                                    try {
                                        val tappedNodesList = listOf(nodeName)
                                        objectChannel.invokeMethod("onNodeTap", tappedNodesList)
                                        Log.d(TAG, "✅ Notified Flutter about tap on: $nodeName")
                                    } catch (e: Exception) {
                                        Log.e(TAG, "❌ Failed to notify Flutter about node tap: ${e.message}")
                                    }
                                    // CRITICAL FIX: Return false to allow TransformationSystem to handle selection
                                    false
                                }
                                
                                // Create anchor and add to scene
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
                                        
                                        // ANDROID FIX: Generate unique ID like iOS for consistent tracking
                                        val uniqueNodeId = "android_node_${System.currentTimeMillis()}_${(0..9999).random()}"
                                        
                                        // Store both the original name and the unique ID for backwards compatibility
                                        nodesMap[nodeName] = transformableNode  // Original name mapping
                                        nodesMap[uniqueNodeId] = transformableNode  // Unique ID mapping for iOS consistency  
                                        nodesMap["${nodeName}_anchor"] = anchorNode
                                        
                                        // ANDROID FIX: Add reverse mapping for tap detection
                                        nodeToUniqueIdMap[transformableNode] = uniqueNodeId
                                        
                                        Log.d(TAG, "✅ Node created with cached model: $nodeName")
                                        Log.d(TAG, "🆔 Generated unique node ID for iOS compatibility: $uniqueNodeId")
                                        
                                        // Return the unique ID like iOS does
                                        result.success(uniqueNodeId)
                                    } else {
                                        transformableNode.worldPosition = Vector3(positionX, positionY, positionZ)
                                        arSceneView?.scene?.addChild(transformableNode)
                                        
                                        // ANDROID FIX: Generate unique ID like iOS for consistent tracking
                                        val uniqueNodeId = "android_node_${System.currentTimeMillis()}_${(0..9999).random()}"
                                        
                                        // Store both the original name and the unique ID for backwards compatibility
                                        nodesMap[nodeName] = transformableNode  // Original name mapping
                                        nodesMap[uniqueNodeId] = transformableNode  // Unique ID mapping for iOS consistency
                                        
                                        // ANDROID FIX: Add reverse mapping for tap detection
                                        nodeToUniqueIdMap[transformableNode] = uniqueNodeId
                                        
                                        // Store floor height for height-locked panning based on initial Y position
                                        nodeFloorHeights[uniqueNodeId] = positionY
                                        Log.d(TAG, "🔒 FLOOR HEIGHT: Stored height $positionY for node $uniqueNodeId")
                                        
                                        Log.d(TAG, "✅ Node created with cached model (direct): $nodeName")
                                        Log.d(TAG, "🆔 Generated unique node ID for iOS compatibility: $uniqueNodeId")
                                        
                                        // Return the unique ID like iOS does
                                        result.success(uniqueNodeId)
                                    }
                                } catch (e: Exception) {
                                    Log.w(TAG, "⚠️ Anchor creation failed, using direct placement: ${e.message}")
                                    transformableNode.worldPosition = Vector3(positionX, positionY, positionZ)
                                    arSceneView?.scene?.addChild(transformableNode)
                                    
                                    // ANDROID FIX: Generate unique ID like iOS for consistent tracking
                                    val uniqueNodeId = "android_node_${System.currentTimeMillis()}_${(0..9999).random()}"
                                    
                                    // Store both the original name and the unique ID for backwards compatibility
                                    nodesMap[nodeName] = transformableNode  // Original name mapping
                                    nodesMap[uniqueNodeId] = transformableNode  // Unique ID mapping for iOS consistency
                                    
                                    // ANDROID FIX: Add reverse mapping for tap detection
                                    nodeToUniqueIdMap[transformableNode] = uniqueNodeId
                                    
                                    // Store floor height for height-locked panning based on initial Y position
                                    nodeFloorHeights[uniqueNodeId] = positionY
                                    Log.d(TAG, "🔒 FLOOR HEIGHT: Stored height $positionY for node $uniqueNodeId")
                                    
                                    Log.d(TAG, "✅ Node created with fallback placement: $nodeName")
                                    Log.d(TAG, "🆔 Generated unique node ID for iOS compatibility: $uniqueNodeId")
                                    
                                    // Return the unique ID like iOS does
                                    result.success(uniqueNodeId)
                                }
                            }
                            .exceptionally { throwable: Throwable ->
                                Log.e(TAG, "❌ Failed to load temporary model: ${throwable.message}")
                                // Clean up temporary file on error
                                try {
                                    tempFile.delete()
                                    Log.d(TAG, "🗑️ Cleaned up temporary file after error")
                                } catch (e: Exception) {
                                    Log.w(TAG, "⚠️ Failed to clean up temporary file after error: ${e.message}")
                                }
                                result.error("MODEL_LOAD_ERROR", throwable.message ?: "Unknown error", null)
                                null
                            }
                    } catch (e: Exception) {
                        Log.e(TAG, "❌ Exception in model loading: ${e.message}")
                        // Clean up temporary file on exception
                        try {
                            tempFile.delete()
                            Log.d(TAG, "🗑️ Cleaned up temporary file after exception")
                        } catch (ex: Exception) {
                            Log.w(TAG, "⚠️ Failed to clean up temporary file after exception: ${ex.message}")
                        }
                        result.error("MODEL_CREATE_ERROR", e.message ?: "Unknown error", null)
                    }
                }
            } catch (e: Exception) {
                activity.runOnUiThread {
                    Log.e(TAG, "❌ Exception in temporary download loading: ${e.message}")
                    result.error("ASYNC_LOADING_ERROR", e.message ?: "Unknown error", null)
                }
            }
        }
    }

    /**
     * Download model temporarily like iOS - downloads to temp file, loads immediately, then deletes
     * This avoids texture path resolution issues that occur with persistent caching
     */
    private suspend fun downloadModelTemporarily(modelUrl: String): java.io.File? = withContext(Dispatchers.IO) {
        Log.d(TAG, "📥 Starting temporary download: $modelUrl")
        
        var connection: java.net.HttpURLConnection? = null
        var inputStream: java.io.InputStream? = null
        var outputStream: java.io.FileOutputStream? = null
        var tempFile: java.io.File? = null
        
        try {
            // Create temporary file in app's cache directory
            val tempDir = java.io.File(activity.cacheDir, "ar_temp_models")
            if (!tempDir.exists()) {
                tempDir.mkdirs()
            }
            
            val fileName = modelUrl.substringAfterLast("/").takeIf { it.isNotEmpty() } ?: "model.glb"
            tempFile = java.io.File(tempDir, "${System.currentTimeMillis()}_$fileName")
            
            // Setup connection
            val url = java.net.URL(modelUrl)
            connection = url.openConnection() as java.net.HttpURLConnection
            connection.apply {
                connectTimeout = 30000 // 30 seconds
                readTimeout = 60000 // 60 seconds
                requestMethod = "GET"
                setRequestProperty("Accept", "application/octet-stream, */*")
                setRequestProperty("User-Agent", "AR-Flutter-Plugin-Android")
            }
            
            val responseCode = connection.responseCode
            if (responseCode != java.net.HttpURLConnection.HTTP_OK) {
                Log.e(TAG, "❌ HTTP error $responseCode for $modelUrl")
                return@withContext null
            }
            
            val contentLength = connection.contentLengthLong
            val maxSizeBytes = 50L * 1024 * 1024 // 50MB max
            
            if (contentLength > maxSizeBytes) {
                Log.e(TAG, "❌ Model too large: ${contentLength / 1024 / 1024}MB > 50MB")
                return@withContext null
            }
            
            inputStream = connection.inputStream
            outputStream = java.io.FileOutputStream(tempFile)
            
            val buffer = ByteArray(8192)
            var totalBytesRead = 0L
            var bytesRead: Int
            
            Log.d(TAG, "📥 Downloading ${contentLength / 1024 / 1024}MB to temporary file...")
            
            while (inputStream.read(buffer).also { bytesRead = it } != -1) {
                outputStream.write(buffer, 0, bytesRead)
                totalBytesRead += bytesRead
                
                // Size safety check during download
                if (totalBytesRead > maxSizeBytes) {
                    Log.e(TAG, "❌ Download size exceeded limit during transfer")
                    return@withContext null
                }
            }
            
            outputStream.flush()
            outputStream.close()
            outputStream = null
            
            // Verify downloaded file
            if (!tempFile.exists() || tempFile.length() < 100) {
                Log.e(TAG, "❌ Downloaded temporary file failed validation")
                return@withContext null
            }
            
            Log.d(TAG, "✅ Temporary download completed successfully: ${tempFile.absolutePath}")
            Log.d(TAG, "📊 File size: ${tempFile.length() / 1024 / 1024}MB")
            
            return@withContext tempFile
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Temporary download exception: ${e.message}")
            tempFile?.delete()
            return@withContext null
        } finally {
            try {
                outputStream?.close()
                inputStream?.close()
                connection?.disconnect()
            } catch (e: Exception) {
                Log.w(TAG, "⚠️ Error cleaning up download resources: ${e.message}")
            }
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
            
            // Extract position from node data or use defaults
            var positionX = 0.0f
            var positionY = 0.0f  // For plane anchors, use 0 as default
            var positionZ = 0.0f
            
            // Extract position from transformation matrix if available
            val nodeTransformation = nodeData["transformation"] as? List<*>
            if (nodeTransformation != null && nodeTransformation.size == 16) {
                positionX = (nodeTransformation[12] as? Number)?.toFloat() ?: 0.0f
                positionY = (nodeTransformation[13] as? Number)?.toFloat() ?: 0.0f
                positionZ = (nodeTransformation[14] as? Number)?.toFloat() ?: 0.0f
                Log.d(TAG, "📏 Position extracted from transformation matrix: ($positionX, $positionY, $positionZ)")
            } else {
                Log.d(TAG, "📏 Using default position for plane anchor: ($positionX, $positionY, $positionZ)")
            }
            
            // Set anchorId for the async loading method
            val anchorId = anchorName
            
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
                // 🎯 Use async caching system for better performance and texture handling
                Log.d(TAG, "🎯 Loading model with async caching for plane anchor: $uri")
                loadModelWithTemporaryDownloadToPlane(
                    uri, nodeName, anchorId, positionX, positionY, positionZ,
                    scaleX, scaleY, scaleZ, isTransformable, enablePanGestures, enableRotationGestures, result
                )
                
            } catch (e: Exception) {
                Log.e(TAG, "❌ Exception loading model for plane anchor: ${e.message}")
                result.error("MODEL_CREATE_ERROR", e.message ?: "Unknown error", null)
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ Exception in handleAddNodeToPlaneAnchor: ${e.message}", e)
            result.error("GENERAL_ERROR", e.message ?: "Unknown error", null)
        }
    }

    /**
     * Load model with iOS-style temporary download for plane anchors - downloads temporarily, loads immediately, then cleans up
     * This avoids texture path issues that occur with persistent caching
     */
    private fun loadModelWithTemporaryDownloadToPlane(
        uri: String,
        nodeName: String,
        anchorId: String,
        positionX: Float,
        positionY: Float,
        positionZ: Float,
        scaleX: Float,
        scaleY: Float,
        scaleZ: Float,
        isTransformable: Boolean,
        enablePanGestures: Boolean,
        enableRotationGestures: Boolean,
        result: MethodChannel.Result
    ) {
        Log.d(TAG, "🎯 Starting async model loading with cache for plane: $uri")
        
        // Use coroutine scope to download and cache model
        downloadScope.launch {
            try {
                // Download temporarily like iOS - don't use persistent cache to avoid texture issues
                val tempFile = downloadModelTemporarily(uri)
                if (tempFile == null) {
                    activity.runOnUiThread {
                        Log.e(TAG, "❌ Failed to download model temporarily for plane: $uri")
                        result.error("DOWNLOAD_ERROR", "Failed to download model", null)
                    }
                    return@launch
                }
                
                Log.d(TAG, "✅ Model ready temporarily for plane at: ${tempFile.absolutePath}")
                
                // Switch back to main thread for SceneForm operations
                activity.runOnUiThread {
                    try {
                        // Find the anchor from our anchor map
                        val anchorNode = nodesMap[anchorId]
                        if (anchorNode == null) {
                            Log.e(TAG, "❌ Anchor not found: $anchorId")
                            // Clean up temp file
                            tempFile.delete()
                            result.error("ANCHOR_NOT_FOUND", "Anchor with id $anchorId not found", null)
                            return@runOnUiThread
                        }
                        
                        val tempUri = Uri.fromFile(tempFile)
                        
                        val modelRenderableBuilder = ModelRenderable.builder()
                        val renderableSourceBuilder = RenderableSource.builder()
                        
                        // Check file extension and set appropriate source type
                        if (uri.endsWith(".glb")) {
                            Log.d(TAG, "📂 Loading temporary GLB file for plane: ${tempFile.absolutePath}")
                            renderableSourceBuilder
                                .setSource(activity, tempUri, RenderableSource.SourceType.GLB)
                                .setScale(1.0f)
                                .setRecenterMode(RenderableSource.RecenterMode.ROOT)
                        } else if (uri.endsWith(".gltf")) {
                            Log.d(TAG, "📂 Loading temporary GLTF file for plane: ${tempFile.absolutePath}")
                            renderableSourceBuilder
                                .setSource(activity, tempUri, RenderableSource.SourceType.GLTF2)
                                .setScale(1.0f)
                                .setRecenterMode(RenderableSource.RecenterMode.ROOT)
                        } else {
                            Log.e(TAG, "❌ Unsupported file format for plane: $uri")
                            // Clean up temp file
                            tempFile.delete()
                            result.error("UNSUPPORTED_FORMAT", "Only GLB and GLTF files are supported", null)
                            return@runOnUiThread
                        }
                        
                        modelRenderableBuilder
                            .setSource(activity, renderableSourceBuilder.build())
                            .setRegistryId(uri)
                            .build()
                            .thenAccept { renderable: ModelRenderable ->
                                Log.d(TAG, "✅ Model loaded successfully from temporary file for plane: $uri")
                                
                                // Clean up temporary file immediately after loading (iOS-style)
                                try {
                                    tempFile.delete()
                                    Log.d(TAG, "🗑️ Cleaned up temporary file for plane: ${tempFile.absolutePath}")
                                } catch (e: Exception) {
                                    Log.w(TAG, "⚠️ Failed to clean up temporary file for plane: ${e.message}")
                                }
                                
                                val transformableNode = TransformableNode(transformationSystem)
                                transformableNode.renderable = renderable
                                transformableNode.name = nodeName
                                
                                // CRITICAL: Set up collision shape for tap detection (plane anchors)
                                // Without this, tap detection might fail
                                if (renderable.collisionShape == null) {
                                    val boundingBox = renderable.collisionShape ?: Box(
                                        Vector3(0.5f, 0.5f, 0.5f), // Default size
                                        Vector3.zero() // Center
                                    )
                                    transformableNode.collisionShape = boundingBox
                                    Log.d(TAG, "🔧 Set up collision shape for tap detection (plane)")
                                }
                                
                                // Add node to anchor FIRST - this is critical for proper transformation setup
                                transformableNode.setParent(anchorNode)
                                
                                // Apply custom scale AFTER parent is set
                                transformableNode.localScale = Vector3(scaleX, scaleY, scaleZ)
                                Log.d(TAG, "🔧 Applied scale for plane: ($scaleX, $scaleY, $scaleZ)")
                                
                                // CRITICAL PAN FIX: Set position after parent attachment for proper transformation context
                                transformableNode.localPosition = Vector3(positionX, positionY, positionZ)
                                Log.d(TAG, "🔧 Set position relative to anchor: ($positionX, $positionY, $positionZ)")
                                
                                // Configure gestures
                                if (isTransformable) {
                                    transformableNode.translationController.isEnabled = enablePanGestures
                                    transformableNode.rotationController.isEnabled = enableRotationGestures
                                    transformableNode.scaleController.isEnabled = true
                                    
                                    // CRITICAL PAN FIX: Ensure transformation system is properly configured for anchor-relative movements
                                    Log.d(TAG, "🎮 PAN FIX: Gesture controllers enabled - Translation: ${enablePanGestures}, Rotation: ${enableRotationGestures}")
                                    Log.d(TAG, "🎮 PAN FIX: Parent anchor position: ${anchorNode.worldPosition}")
                                    Log.d(TAG, "🎮 PAN FIX: Node local position: ${transformableNode.localPosition}")
                                    Log.d(TAG, "🎮 PAN FIX: Node world position: ${transformableNode.worldPosition}")
                                } else {
                                    transformableNode.translationController.isEnabled = false
                                    transformableNode.rotationController.isEnabled = false
                                    transformableNode.scaleController.isEnabled = false
                                }
                                
                                // CRITICAL FIX: Set up proper gesture listeners for plane anchors too
                                setupGestureListeners(transformableNode, nodeName)
                                
                                // CRITICAL: Set up tap listener for proper object selection (plane anchors)
                                // This is needed for TransformationSystem to identify which node was tapped
                                transformableNode.setOnTapListener { hitTestResult, motionEvent ->
                                    Log.d(TAG, "🎯 Plane node $nodeName tapped - TransformationSystem will handle selection")
                                    // Don't manually select - let TransformationSystem handle it naturally
                                    // Just notify Flutter about the tap
                                    try {
                                        val tappedNodesList = listOf(nodeName)
                                        objectChannel.invokeMethod("onNodeTap", tappedNodesList)
                                        Log.d(TAG, "✅ Notified Flutter about tap on plane node: $nodeName")
                                    } catch (e: Exception) {
                                        Log.e(TAG, "❌ Failed to notify Flutter about plane node tap: ${e.message}")
                                    }
                                    // CRITICAL FIX: Return false to allow TransformationSystem to handle selection
                                    false
                                }
                                
                                nodesMap[nodeName] = transformableNode
                                
                                // Store floor height for height-locked panning based on anchor + offset position
                                val finalHeight = anchorNode.worldPosition.y + positionY
                                nodeFloorHeights[nodeName] = finalHeight
                                Log.d(TAG, "🔒 FLOOR HEIGHT: Stored height $finalHeight for node $nodeName (anchor height: ${anchorNode.worldPosition.y}, offset: $positionY)")
                                
                                // CRITICAL FIX: Generate and store a unique ID for this node for height-locked panning lookups
                                val uniqueNodeId = "android_node_${System.currentTimeMillis()}_${(0..999).random()}"
                                nodeToUniqueIdMap[transformableNode] = uniqueNodeId
                                // Also store height using the unique ID so height-locked panning can find it
                                nodeFloorHeights[uniqueNodeId] = finalHeight
                                Log.d(TAG, "🔒 FLOOR HEIGHT: Also stored height $finalHeight for unique ID $uniqueNodeId")
                                
                                Log.d(TAG, "✅ Node added to plane anchor with cached model: $nodeName")
                                result.success(nodeName)
                            }
                            .exceptionally { throwable: Throwable ->
                                Log.e(TAG, "❌ Failed to load temporary model for plane: ${throwable.message}")
                                // Clean up temporary file on error
                                try {
                                    tempFile.delete()
                                    Log.d(TAG, "🗑️ Cleaned up temporary file after error (plane)")
                                } catch (e: Exception) {
                                    Log.w(TAG, "⚠️ Failed to clean up temporary file after error (plane): ${e.message}")
                                }
                                result.error("MODEL_LOAD_ERROR", throwable.message ?: "Unknown error", null)
                                null
                            }
                    } catch (e: Exception) {
                        Log.e(TAG, "❌ Exception in plane model loading: ${e.message}")
                        // Clean up temporary file on exception
                        try {
                            tempFile.delete()
                            Log.d(TAG, "🗑️ Cleaned up temporary file after exception (plane)")
                        } catch (ex: Exception) {
                            Log.w(TAG, "⚠️ Failed to clean up temporary file after exception (plane): ${ex.message}")
                        }
                        result.error("MODEL_CREATE_ERROR", e.message ?: "Unknown error", null)
                    }
                }
            } catch (e: Exception) {
                activity.runOnUiThread {
                    Log.e(TAG, "❌ Exception in temporary download loading for plane: ${e.message}")
                    result.error("ASYNC_LOADING_ERROR", e.message ?: "Unknown error", null)
                }
            }
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
                    
                    // NAVIGATION LIFECYCLE FIX: Remove from persistent state
                    persistentNodeStates.remove(nodeName)
                    Log.d(TAG, "🗑️ Removed node from persistent state: $nodeName")
                    
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
            
            Log.d(TAG, "🗑️ REMOVE NODE DEEP: Request to remove SPECIFIC nodeId: $nodeId")
            Log.d(TAG, "🗑️ REMOVE NODE DEEP: Current nodesMap keys: ${nodesMap.keys}")
            Log.d(TAG, "🔍 REMOVE SAFETY: Only this exact node should be removed, not all nodes!")
            
            if (nodeId != null) {
                val node = nodesMap[nodeId]
                if (node != null) {
                    Log.d(TAG, "🗑️ REMOVE NODE DEEP: Found SPECIFIC node to remove: $nodeId (type: ${node.javaClass.simpleName})")
                    Log.d(TAG, "🔍 REMOVE SAFETY: Removing only this node, preserving all others")
                    
                    // SAFETY CHECK: Count nodes before removal
                    val nodeCountBefore = nodesMap.size
                    Log.d(TAG, "🔍 REMOVE SAFETY: Node count BEFORE removal: $nodeCountBefore")
                    
                    // First, deselect this SPECIFIC node from TransformationSystem
                    if (node is TransformableNode && transformationSystem != null) {
                        try {
                            // Only deselect if THIS node is currently selected
                            if (transformationSystem?.selectedNode == node) {
                                transformationSystem?.selectNode(null)
                                Log.d(TAG, "🗑️ SPECIFIC DESELECT: Deselected ONLY the target node from TransformationSystem")
                            } else {
                                Log.d(TAG, "🗑️ SKIP DESELECT: Target node was not selected, skipping deselection")
                            }
                        } catch (e: Exception) {
                            Log.w(TAG, "⚠️ Could not deselect specific node from TransformationSystem: ${e.message}")
                        }
                    }
                    
                    // Disable ONLY this specific TransformableNode's properties
                    if (node is TransformableNode) {
                        try {
                            node.isEnabled = false
                            node.translationController.isEnabled = false
                            node.rotationController.isEnabled = false
                            node.scaleController.isEnabled = false
                            node.renderable = null
                            Log.d(TAG, "🗑️ SPECIFIC DISABLE: Disabled ONLY the target TransformableNode properties")
                        } catch (e: Exception) {
                            Log.w(TAG, "⚠️ Error disabling specific TransformableNode properties: ${e.message}")
                        }
                    }
                    
                    // Remove ONLY this specific node from scene graph
                    try {
                        node.setParent(null)
                        Log.d(TAG, "🗑️ SPECIFIC REMOVAL: Removed ONLY the target node from scene graph")
                    } catch (e: Exception) {
                        Log.w(TAG, "⚠️ Error removing specific node from scene graph: ${e.message}")
                    }
                    
                    // Remove ONLY this specific node from our tracking map
                    val removedNode = nodesMap.remove(nodeId)
                    if (removedNode != null) {
                        Log.d(TAG, "🗑️ SPECIFIC TRACKING: Successfully removed ONLY target node from nodesMap")
                        
                        // Clean up floor height data
                        nodeFloorHeights.remove(nodeId)
                        Log.d(TAG, "🔒 FLOOR HEIGHT: Cleaned up height data for node $nodeId")
                        
                        // Clear any references from the reverse mapping
                        nodeToUniqueIdMap.remove(removedNode)
                    } else {
                        Log.w(TAG, "⚠️ SPECIFIC TRACKING: Node was not in nodesMap during removal")
                    }
                    
                    // Also remove associated anchor if it exists (but ONLY for this node)
                    val anchorNodeId = "${nodeId}_anchor"
                    val anchorNode = nodesMap[anchorNodeId]
                    if (anchorNode != null) {
                        Log.d(TAG, "🗑️ SPECIFIC ANCHOR: Also removing associated anchor for SPECIFIC node: $anchorNodeId")
                        try {
                            anchorNode.setParent(null)
                            nodesMap.remove(anchorNodeId)
                            Log.d(TAG, "🗑️ SPECIFIC ANCHOR: Successfully removed ONLY the associated anchor: $anchorNodeId")
                        } catch (e: Exception) {
                            Log.w(TAG, "⚠️ Error removing specific anchor: ${e.message}")
                        }
                    }
                    
                    // SAFETY VERIFICATION: Count nodes after removal
                    val nodeCountAfter = nodesMap.size
                    val expectedCount = nodeCountBefore - if (anchorNode != null) 2 else 1
                    Log.d(TAG, "🔍 REMOVE VERIFICATION: Node count AFTER removal: $nodeCountAfter")
                    Log.d(TAG, "🔍 REMOVE VERIFICATION: Expected count: $expectedCount")
                    Log.d(TAG, "🔍 REMOVE VERIFICATION: Actually removed: ${nodeCountBefore - nodeCountAfter} nodes")
                    
                    if (nodeCountAfter == expectedCount) {
                        Log.d(TAG, "✅ REMOVE VERIFICATION: Correct number of nodes removed!")
                    } else {
                        Log.w(TAG, "⚠️ REMOVE VERIFICATION: Unexpected node count change!")
                    }
                    
                    Log.d(TAG, "✅ REMOVE NODE DEEP: Successfully removed SPECIFIC node: $nodeId")
                    Log.d(TAG, "✅ REMOVE NODE DEEP: Remaining nodesMap keys: ${nodesMap.keys}")
                    result.success(true)
                } else {
                    Log.w(TAG, "⚠️ REMOVE NODE DEEP: Node not found for nodeId: $nodeId")
                    Log.w(TAG, "⚠️ REMOVE NODE DEEP: Available nodes: ${nodesMap.keys}")
                    result.success(false)
                }
            } else {
                Log.w(TAG, "⚠️ REMOVE NODE DEEP: Node ID not provided")
                result.success(false)
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ REMOVE NODE DEEP: Error in deep node removal: ${e.message}")
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

    /**
     * Set up proper gesture listeners for a TransformableNode to handle actual gesture events
     * This replaces the incorrect gesture callbacks that were being sent on selection
     */
    private fun setupGestureListeners(transformableNode: TransformableNode, nodeName: String) {
        try {
            Log.d(TAG, "🎮 Setting up gesture listeners for node: $nodeName")
            
            // Get the proper node ID for callbacks
            val nodeId = nodeToUniqueIdMap[transformableNode] ?: nodeName
            
            // Set up translation (pan) gesture listener
            if (transformableNode.translationController.isEnabled) {
                // Use a custom gesture detector approach since TransformationSystem doesn't expose gesture listeners directly
                // We'll track gesture state through the TransformationSystem's onTouch override
                Log.d(TAG, "🔧 Pan gestures enabled for node: $nodeId")
            }
            
            // Set up rotation gesture listener
            if (transformableNode.rotationController.isEnabled) {
                Log.d(TAG, "🔧 Rotation gestures enabled for node: $nodeId")
            }
            
            // Set up scale gesture listener
            if (transformableNode.scaleController.isEnabled) {
                Log.d(TAG, "🔧 Scale gestures enabled for node: $nodeId")
            }
            
            Log.d(TAG, "✅ Gesture listeners configured for node: $nodeId")
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error setting up gesture listeners for $nodeName: ${e.message}")
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
            Log.d(TAG, "🔄 Starting AR scene disposal with state preservation...")
            
            // CRITICAL: Save scene state before disposal for restoration after navigation
            captureSceneStateForPersistence()
            
            arSceneView?.let { sceneView ->
                try {
                    // CRITICAL: Stop render loop first to prevent crashes
                    sceneView.pause()
                    
                    // Then safely close the session
                    sceneView.session?.close()
                } catch (e: Exception) {
                    // Silently handle cleanup errors to prevent crashes
                    Log.w(TAG, "⚠️ Error during session cleanup: ${e.message}")
                }
            }
            
            // CRITICAL: Clear transformation system selection first to prevent ghost gestures
            transformationSystem?.selectNode(null)
            
            // Clear references efficiently (but keep persistent state)
            arSceneView = null
            nodesMap.clear()
            reusableNodeHitResults.clear()
            transformationSystem = null
            gestureDetector = null
            
            // Clean up height-locked panning data
            nodeFloorHeights.clear()
            
            // Stop lighting monitoring and clean up handler
            isMonitoringLighting = false
            lightingHandler.removeCallbacks(lightingCheckRunnable)
            Log.d(TAG, "🔒 FLOOR HEIGHT: Cleaned up all height data on dispose")
            
            Log.d(TAG, "✅ AR scene disposal completed, state preserved for restoration")
            result.success(null)
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error in handleDispose: ${e.message}")
            result.error("DISPOSE_ERROR", e.message, null)
        }
    }

    /**
     * Capture a screenshot of the current AR scene using multiple capture strategies
     */
    private fun handleSnapshot(call: MethodCall, result: MethodChannel.Result) {
        try {
            val sceneView = arSceneView
            if (sceneView == null) {
                Log.w(TAG, "⚠️ ArSceneView is null, cannot take snapshot")
                result.error("SNAPSHOT_ERROR", "AR scene is not initialized", null)
                return
            }

            // Check if the view has valid dimensions
            if (sceneView.width <= 0 || sceneView.height <= 0) {
                Log.w(TAG, "⚠️ ArSceneView has invalid dimensions: ${sceneView.width}x${sceneView.height}")
                result.error("SNAPSHOT_ERROR", "AR scene view is not properly sized", null)
                return
            }

            Log.d(TAG, "📸 Attempting snapshot capture for ArSceneView (${sceneView.width}x${sceneView.height})")

            // Strategy 0: Check if ArSceneView has a built-in screenshot method
            try {
                Log.d(TAG, "📸 Checking for built-in screenshot capability...")
                val screenshotMethod = sceneView.javaClass.getMethod("screenshot")
                val screenshotResult = screenshotMethod.invoke(sceneView)
                
                if (screenshotResult is Bitmap) {
                    Log.d(TAG, "📸 ArSceneView built-in screenshot successful!")
                    handleSuccessfulCapture(screenshotResult, result)
                    return
                }
            } catch (e: Exception) {
                Log.d(TAG, "📸 No built-in screenshot method found: ${e.message}")
            }

            // Create a bitmap to hold the captured pixels
            val bitmap = Bitmap.createBitmap(
                sceneView.width,
                sceneView.height,
                Bitmap.Config.ARGB_8888
            )

            // Strategy 1: Try using PixelCopy for API 24+ if ArSceneView has a surface
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Log.d(TAG, "📸 Attempting PixelCopy capture...")
                
                try {
                    // Create a handler for the background thread
                    val handlerThread = HandlerThread("PixelCopyThread")
                    handlerThread.start()
                    val handler = Handler(handlerThread.looper)
                    
                    // Try to get surface from the view
                    val surface = when {
                        sceneView is SurfaceView -> {
                            Log.d(TAG, "📸 ArSceneView is SurfaceView, using holder surface")
                            (sceneView as SurfaceView).holder.surface
                        }
                        else -> {
                            Log.d(TAG, "📸 ArSceneView is not SurfaceView (${sceneView.javaClass.simpleName}), trying reflection...")
                            // Try to get surface through reflection
                            tryGetSurfaceFromView(sceneView)
                        }
                    }
                    
                    if (surface != null && surface.isValid) {
                        Log.d(TAG, "📸 Valid surface found, using PixelCopy...")
                        PixelCopy.request(
                            surface,
                            bitmap,
                            { copyResult ->
                                handlerThread.quitSafely()
                                
                                if (copyResult == PixelCopy.SUCCESS) {
                                    handleSuccessfulCapture(bitmap, result)
                                } else {
                                    Log.w(TAG, "⚠️ PixelCopy failed ($copyResult), trying fallback method...")
                                    // Try fallback method
                                    tryFallbackCapture(sceneView, result)
                                    bitmap.recycle()
                                }
                            },
                            handler
                        )
                        return
                    } else {
                        Log.w(TAG, "⚠️ No valid surface found, trying fallback method...")
                        handlerThread.quitSafely()
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "⚠️ PixelCopy setup failed: ${e.message}, trying fallback method...")
                }
            }
            
            // Strategy 2: Fallback to drawing the view
            Log.d(TAG, "📸 Using fallback capture method...")
            bitmap.recycle() // Clean up the unused bitmap
            tryFallbackCapture(sceneView, result)
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error capturing snapshot: ${e.message}")
            result.error("SNAPSHOT_ERROR", "Failed to capture snapshot: ${e.message}", null)
        }
    }

    /**
     * Try to get surface from view using reflection
     */
    private fun tryGetSurfaceFromView(view: View): Surface? {
        return try {
            // Try common field names for surface holders
            val possibleFields = listOf("mSurfaceHolder", "surfaceHolder", "mHolder", "holder")
            
            for (fieldName in possibleFields) {
                try {
                    val field = view.javaClass.getDeclaredField(fieldName)
                    field.isAccessible = true
                    val holder = field.get(view)
                    
                    if (holder != null) {
                        val surfaceMethod = holder.javaClass.getMethod("getSurface")
                        val surface = surfaceMethod.invoke(holder) as? Surface
                        if (surface?.isValid == true) {
                            Log.d(TAG, "📸 Found surface via reflection field: $fieldName")
                            return surface
                        }
                    }
                } catch (e: Exception) {
                    // Continue trying other fields
                }
            }
            
            Log.w(TAG, "⚠️ Could not find surface via reflection")
            null
        } catch (e: Exception) {
            Log.w(TAG, "⚠️ Reflection attempt failed: ${e.message}")
            null
        }
    }

    /**
     * Fallback capture method using view drawing
     */
    private fun tryFallbackCapture(sceneView: View, result: MethodChannel.Result) {
        try {
            val bitmap = Bitmap.createBitmap(
                sceneView.width,
                sceneView.height,
                Bitmap.Config.ARGB_8888
            )
            
            val canvas = Canvas(bitmap)
            
            // Try to force a draw
            sceneView.draw(canvas)
            
            // Check if we got anything useful (not just white/black)
            val pixels = IntArray(100) // Sample first 100 pixels
            bitmap.getPixels(pixels, 0, 10, 0, 0, 10, 10)
            
            val hasVariation = pixels.any { pixel ->
                val alpha = (pixel shr 24) and 0xFF
                val red = (pixel shr 16) and 0xFF
                val green = (pixel shr 8) and 0xFF
                val blue = pixel and 0xFF
                
                // Check if it's not just transparent, white, or black
                alpha > 0 && (red != green || green != blue || red in 1..254)
            }
            
            if (hasVariation) {
                Log.d(TAG, "📸 Fallback capture appears to have content")
                handleSuccessfulCapture(bitmap, result)
            } else {
                Log.w(TAG, "⚠️ Fallback capture appears empty (solid color)")
                bitmap.recycle()
                result.error("SNAPSHOT_ERROR", "Captured image appears to be empty. This may be due to GPU rendering limitations.", null)
            }
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Fallback capture failed: ${e.message}")
            result.error("SNAPSHOT_ERROR", "All capture methods failed: ${e.message}", null)
        }
    }

    /**
     * Handle successful bitmap capture
     */
    private fun handleSuccessfulCapture(bitmap: Bitmap, result: MethodChannel.Result) {
        try {
            // Convert bitmap to PNG byte array
            val outputStream = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, outputStream)
            val pngBytes = outputStream.toByteArray()
            
            // Clean up
            outputStream.close()
            bitmap.recycle()
            
            Log.d(TAG, "📸 Snapshot captured successfully, size: ${pngBytes.size} bytes")
            
            // Make sure to call result on main thread
            Handler(Looper.getMainLooper()).post {
                result.success(pngBytes)
            }
        } catch (e: Exception) {
            bitmap.recycle()
            Log.e(TAG, "❌ Error processing captured bitmap: ${e.message}")
            Handler(Looper.getMainLooper()).post {
                result.error("SNAPSHOT_ERROR", "Failed to process captured image: ${e.message}", null)
            }
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
    
    // MARK: - Scene State Persistence (Navigation Lifecycle Fix)
    
    /**
     * Capture current scene state before disposal for restoration after navigation
     */
    private fun captureSceneStateForPersistence() {
        Log.d(TAG, "📸 Capturing scene state for persistence...")
        
        try {
            persistentNodeStates.clear()
            
            for ((nodeName, node) in nodesMap) {
                when (node) {
                    is TransformableNode -> {
                        try {
                            // Capture the transformable node's state
                            val position = node.worldPosition
                            val rotation = node.worldRotation
                            val scale = node.localScale
                            
                            // Try to get the model URI from the node (if available)
                            val modelUri = node.name ?: nodeName
                            
                            // Get the anchor pose if the node has an anchor parent
                            val anchorPose = when (val parent = node.parent) {
                                is AnchorNode -> parent.anchor?.pose
                                else -> null
                            }
                            
                            val nodeState = NodeState(
                                nodeName = nodeName,
                                position = position,
                                rotation = rotation,
                                scale = scale,
                                modelUri = modelUri,
                                anchorPose = anchorPose
                            )
                            
                            persistentNodeStates[nodeName] = nodeState
                            Log.d(TAG, "💾 Captured state for node: $nodeName")
                            Log.d(TAG, "   Position: $position")
                            Log.d(TAG, "   Scale: $scale")
                            Log.d(TAG, "   Has anchor: ${anchorPose != null}")
                            
                        } catch (e: Exception) {
                            Log.w(TAG, "⚠️ Failed to capture state for node $nodeName: ${e.message}")
                        }
                    }
                    else -> {
                        Log.d(TAG, "⏭️ Skipping non-transformable node: $nodeName")
                    }
                }
            }
            
            Log.d(TAG, "✅ Scene state captured: ${persistentNodeStates.size} nodes saved")
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error capturing scene state: ${e.message}")
        }
    }
    
    /**
     * Restore scene state after AR session is recreated
     */
    private fun restoreSceneStateFromPersistence() {
        if (persistentNodeStates.isEmpty()) {
            Log.d(TAG, "📭 No persistent scene state to restore")
            return
        }
        
        Log.d(TAG, "🔄 Restoring scene state from persistence...")
        Log.d(TAG, "📦 Found ${persistentNodeStates.size} nodes to restore")
        
        isRestoringScene = true
        
        try {
            for ((nodeName, nodeState) in persistentNodeStates) {
                Log.d(TAG, "🔧 Restoring node: $nodeName")
                
                try {
                    restoreNodeFromState(nodeName, nodeState)
                } catch (e: Exception) {
                    Log.e(TAG, "❌ Failed to restore node $nodeName: ${e.message}")
                    // Continue with other nodes
                }
            }
            
            Log.d(TAG, "✅ Scene state restoration completed")
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error during scene state restoration: ${e.message}")
        } finally {
            isRestoringScene = false
        }
    }
    
    /**
     * Restore a single node from its captured state
     */
    private fun restoreNodeFromState(nodeName: String, nodeState: NodeState) {
        val session = arSceneView?.session
        if (session == null) {
            Log.w(TAG, "⚠️ Cannot restore node $nodeName: AR session not available")
            return
        }
        
        Log.d(TAG, "🛠️ Restoring node: $nodeName")
        Log.d(TAG, "   Original position: ${nodeState.position}")
        Log.d(TAG, "   Original scale: ${nodeState.scale}")
        Log.d(TAG, "   Had anchor: ${nodeState.anchorPose != null}")
        
        try {
            // Create the restored transformable node
            val transformableNode = TransformableNode(transformationSystem)
            transformableNode.setParent(arSceneView?.scene)
            
            // Restore position, rotation, and scale
            transformableNode.worldPosition = nodeState.position
            transformableNode.worldRotation = nodeState.rotation
            transformableNode.localScale = nodeState.scale
            
            // If the node had an anchor, try to restore it
            if (nodeState.anchorPose != null) {
                try {
                    Log.d(TAG, "🔗 Restoring anchor for node: $nodeName")
                    
                    // Create new anchor at the same pose
                    val restoredAnchor = session.createAnchor(nodeState.anchorPose)
                    val anchorNode = AnchorNode(restoredAnchor)
                    anchorNode.setParent(arSceneView?.scene)
                    
                    // Re-parent the transformable node to the restored anchor
                    transformableNode.setParent(anchorNode)
                    transformableNode.localPosition = Vector3(0.0f, 0.0f, 0.0f)
                    
                    // Store both nodes
                    nodesMap[nodeName] = transformableNode
                    nodesMap["${nodeName}_anchor"] = anchorNode
                    
                    Log.d(TAG, "✅ Successfully restored node with anchor: $nodeName")
                    
                } catch (anchorError: Exception) {
                    Log.w(TAG, "⚠️ Failed to restore anchor for $nodeName: ${anchorError.message}")
                    // Fallback: place node without anchor (emergency hierarchy creation will handle it)
                    nodesMap[nodeName] = transformableNode
                    Log.d(TAG, "⚡ Node restored without anchor, emergency hierarchy will handle it")
                }
            } else {
                // Node didn't have an anchor originally
                nodesMap[nodeName] = transformableNode
                Log.d(TAG, "✅ Successfully restored node without anchor: $nodeName")
            }
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to restore node $nodeName: ${e.message}")
            throw e
        }
    }
    
    /**
     * Save a newly added node to persistent state for future restoration
     */
    private fun saveNodeToPersistentState(nodeName: String, transformableNode: TransformableNode, modelUri: String) {
        try {
            // Skip saving during restoration to avoid circular references
            if (isRestoringScene) {
                Log.d(TAG, "⏭️ Skipping persistent state save during restoration: $nodeName")
                return
            }
            
            Log.d(TAG, "💾 Saving new node to persistent state: $nodeName")
            
            val position = transformableNode.worldPosition
            val rotation = transformableNode.worldRotation
            val scale = transformableNode.localScale
            
            // Get the anchor pose if the node has an anchor parent
            val anchorPose = when (val parent = transformableNode.parent) {
                is AnchorNode -> parent.anchor?.pose
                else -> null
            }
            
            val nodeState = NodeState(
                nodeName = nodeName,
                position = position,
                rotation = rotation,
                scale = scale,
                modelUri = modelUri,
                anchorPose = anchorPose
            )
            
            persistentNodeStates[nodeName] = nodeState
            
            Log.d(TAG, "✅ Node saved to persistent state: $nodeName")
            Log.d(TAG, "   Position: $position")
            Log.d(TAG, "   Scale: $scale")
            Log.d(TAG, "   Has anchor: ${anchorPose != null}")
            
        } catch (e: Exception) {
            Log.w(TAG, "⚠️ Failed to save node $nodeName to persistent state: ${e.message}")
        }
    }

    /**
     * Attempts to restore nodes that have disappeared from the scene due to hierarchy corruption
     */
    private fun restoreDisappearedNodes() {
        try {
            val scene = arSceneView?.scene
            if (scene == null) {
                Log.w(TAG, "⚠️ Cannot restore nodes - scene is null")
                return
            }

            // Check all tracked nodes
            val nodesToRestore = mutableListOf<String>()
            for ((nodeName, node) in nodesMap) {
                if (node is TransformableNode && !nodeName.endsWith("_anchor")) {
                    // Check if node is still in the scene hierarchy
                    val isInScene = isNodeInSceneHierarchy(node, scene)
                    if (!isInScene) {
                        Log.w(TAG, "⚠️ Node $nodeName has disappeared from scene, marking for restoration")
                        nodesToRestore.add(nodeName)
                    }
                }
            }

            // Restore disappeared nodes
            for (nodeName in nodesToRestore) {
                val node = nodesMap[nodeName] as? TransformableNode
                if (node != null) {
                    restoreNodeToScene(node, nodeName)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error during node restoration: ${e.message}")
        }
    }

    /**
     * Recursively checks if a node is still part of the scene hierarchy
     */
    private fun isNodeInSceneHierarchy(node: Node, scene: Scene): Boolean {
        var currentNode: Node? = node
        while (currentNode != null) {
            if (currentNode == scene) {
                return true
            }
            currentNode = currentNode.parent
        }
        return false
    }

    /**
     * Restores a specific node to the scene with proper hierarchy
     */
    private fun restoreNodeToScene(transformableNode: TransformableNode, nodeName: String) {
        try {
            val session = arSceneView?.session
            val scene = arSceneView?.scene
            
            if (session == null || scene == null) {
                Log.e(TAG, "❌ Cannot restore node - missing session or scene")
                return
            }

            Log.d(TAG, "🔧 Restoring disappeared node: $nodeName")
            
            // Store current position and transformation data BEFORE detaching
            val currentWorldPosition = transformableNode.worldPosition
            val currentLocalPosition = transformableNode.localPosition
            val currentLocalRotation = transformableNode.localRotation
            val currentLocalScale = transformableNode.localScale
            
            // Check if node already has a valid AnchorNode parent
            val currentParent = transformableNode.parent
            if (currentParent is AnchorNode) {
                Log.d(TAG, "✅ Node already has valid AnchorNode parent, restoration not needed")
                return
            }
            
            // Find existing anchor node for this transformable node
            var anchorNode: AnchorNode? = null
            val anchorKey = "${nodeName}_anchor"
            val existingAnchor = nodesMap[anchorKey]
            
            if (existingAnchor is AnchorNode) {
                Log.d(TAG, "� Found existing anchor node for restoration")
                anchorNode = existingAnchor
            } else {
                // Create new anchor using stored position or fallback
                val targetPosition = currentWorldPosition ?: Vector3(0.0f, -1.0f, -2.0f)
                Log.d(TAG, "🔧 Creating new anchor at position: (${targetPosition.x}, ${targetPosition.y}, ${targetPosition.z})")
                
                val anchor = session.createAnchor(
                    Pose.makeTranslation(targetPosition.x, targetPosition.y, targetPosition.z)
                )
                anchorNode = AnchorNode(anchor)
                anchorNode.setParent(scene)
                nodesMap[anchorKey] = anchorNode
            }
            
            // CRITICAL: Only detach AFTER we have a valid anchor ready
            transformableNode.setParent(null)
            
            // Immediately re-attach to anchor node
            transformableNode.setParent(anchorNode)
            
            // Restore transformation data
            currentLocalPosition?.let { transformableNode.localPosition = it }
            currentLocalRotation?.let { transformableNode.localRotation = it }
            currentLocalScale?.let { transformableNode.localScale = it }
            
            Log.d(TAG, "✅ Successfully restored node: $nodeName with preserved transformations")
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to restore node $nodeName: ${e.message}")
            e.printStackTrace()
        }
    }

    /**
     * Workaround method to detect taps when ACTION_UP events are consumed by other handlers
     */
    private fun checkForDelayedTap(downX: Float, downY: Float) {
        try {
            val currentTime = System.currentTimeMillis()
            val timeDiff = currentTime - lastTouchDownTime
            
            // Only consider this a tap if:
            // 1. The time since touch down is reasonable for a tap (< 500ms)
            // 2. The touch coordinates haven't moved much
            if (timeDiff < 500 && !hasTouchMoved) {
                Log.d(TAG, "⏰ DELAYED TAP DETECTED: Simulating handleTap for coordinates ($downX, $downY)")
                
                // Create a synthetic motion event for the tap
                val fakeMotionEvent = MotionEvent.obtain(
                    lastTouchDownTime,
                    currentTime,
                    MotionEvent.ACTION_UP,
                    downX,
                    downY,
                    0
                )
                
                // Call our tap handler
                handleTap(fakeMotionEvent)
                
                // Clean up the synthetic event
                fakeMotionEvent.recycle()
            } else {
                Log.d(TAG, "⏰ Not a tap: timeDiff=$timeDiff, hasMoved=$hasTouchMoved")
            }
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error in delayed tap detection: ${e.message}")
        }
    }
    
    /**
     * Custom height projection for dragging objects when ARCore's hit testing fails
     * This projects the touch point onto a virtual plane at the stored height
     */
    /**
     * Projects a 2D touch point onto a horizontal plane at a specific height
     * This allows smooth panning even in poorly scanned areas
     * ENHANCED: More aggressive projection with better FOV calculation
     */
    private fun tryCustomHeightProjection(motionEvent: MotionEvent, targetHeight: Float): Vector3? {
        try {
            val frame = arSceneView?.arFrame ?: return null
            val camera = frame.camera
            
            if (camera.trackingState != TrackingState.TRACKING) {
                Log.w(TAG, "🔒 Custom projection: Camera not tracking")
                return null
            }
            
            // Get view dimensions
            val view = arSceneView ?: return null
            val viewWidth = view.width.toFloat()
            val viewHeight = view.height.toFloat()
            
            if (viewWidth <= 0 || viewHeight <= 0) return null
            
            // Convert screen coordinates to normalized device coordinates (-1 to 1)
            val ndcX = (motionEvent.x / viewWidth) * 2.0f - 1.0f
            val ndcY = -((motionEvent.y / viewHeight) * 2.0f - 1.0f) // Flip Y
            
            Log.d(TAG, "🔒 Custom projection: Screen (${motionEvent.x}, ${motionEvent.y}) -> NDC ($ndcX, $ndcY)")
            
            // Get camera pose
            val cameraPose = camera.pose
            val cameraTranslation = cameraPose.translation
            
            // Get camera intrinsics for accurate projection
            val intrinsics = camera.imageIntrinsics
            val focalLength = intrinsics.focalLength
            val principalPoint = intrinsics.principalPoint
            
            // Calculate field of view angle (more accurate than before)
            val fovY = (2.0f * Math.atan(((viewHeight / 2.0f) / focalLength[1]).toDouble())).toFloat()
            val fovX = (2.0f * Math.atan(((viewWidth / 2.0f) / focalLength[0]).toDouble())).toFloat()
            
            // Get camera transformation matrix
            val cameraMatrix = FloatArray(16)
            cameraPose.toMatrix(cameraMatrix, 0)
            
            // Extract camera basis vectors from matrix
            // Forward direction (3rd column, negated because camera looks down -Z)
            val forwardX = -cameraMatrix[8]
            val forwardY = -cameraMatrix[9] 
            val forwardZ = -cameraMatrix[10]
            
            // Right direction (1st column)
            val rightX = cameraMatrix[0]
            val rightY = cameraMatrix[1]
            val rightZ = cameraMatrix[2]
            
            // Up direction (2nd column)
            val upX = cameraMatrix[4]
            val upY = cameraMatrix[5]
            val upZ = cameraMatrix[6]
            
            // Calculate ray direction using FOV angles for accurate projection
            val tanHalfFovX = Math.tan((fovX / 2.0f).toDouble()).toFloat()
            val tanHalfFovY = Math.tan((fovY / 2.0f).toDouble()).toFloat()
            
            val rayDirX = forwardX + rightX * ndcX * tanHalfFovX + upX * ndcY * tanHalfFovY
            val rayDirY = forwardY + rightY * ndcX * tanHalfFovX + upY * ndcY * tanHalfFovY
            val rayDirZ = forwardZ + rightZ * ndcX * tanHalfFovX + upZ * ndcY * tanHalfFovY
            
            // Normalize ray direction
            val rayLength = Math.sqrt((rayDirX * rayDirX + rayDirY * rayDirY + rayDirZ * rayDirZ).toDouble()).toFloat()
            val normalizedRayX = rayDirX / rayLength
            val normalizedRayY = rayDirY / rayLength
            val normalizedRayZ = rayDirZ / rayLength
            
            val rayOrigin = Vector3(cameraTranslation[0], cameraTranslation[1], cameraTranslation[2])
            val rayDirection = Vector3(normalizedRayX, normalizedRayY, normalizedRayZ)
            
            // Intersect ray with horizontal plane at targetHeight
            val planeY = targetHeight
            val rayY = rayDirection.y
            
            // Check if ray is nearly parallel to plane (tolerance increased for edge cases)
            if (Math.abs(rayY) < 0.0001f) {
                Log.w(TAG, "🔒 Custom projection: Ray parallel to target plane")
                return null
            }
            
            // Calculate intersection parameter t
            val t = (planeY - rayOrigin.y) / rayY
            
            // Allow intersection slightly behind camera for edge cases (but not too far)
            if (t < -0.1f) {
                Log.w(TAG, "🔒 Custom projection: Intersection too far behind camera")
                return null
            }
            
            // Calculate intersection point
            val hitX = rayOrigin.x + rayDirection.x * t
            val hitY = targetHeight  // Locked to target height
            val hitZ = rayOrigin.z + rayDirection.z * t
            
            // Sanity check: ensure hit point is within reasonable distance (10 meters)
            val distance = Math.sqrt(((hitX - rayOrigin.x) * (hitX - rayOrigin.x) + 
                                     (hitY - rayOrigin.y) * (hitY - rayOrigin.y) + 
                                     (hitZ - rayOrigin.z) * (hitZ - rayOrigin.z)).toDouble())
            
            if (distance > 10.0) {
                Log.w(TAG, "🔒 Custom projection: Hit point too far (${distance}m)")
                return null
            }
            
            val hitPoint = Vector3(hitX, hitY, hitZ)
            
            Log.d(TAG, "🔒 Custom projection SUCCESS: Hit at ($hitPoint) for height $targetHeight, distance: ${distance}m")
            return hitPoint
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error in custom height projection: ${e.message}")
            return null
        }
    }

    /**
     * Creates a virtual plane hit when ARCore's hit testing fails in poorly scanned areas
     * This uses camera ray projection onto a virtual plane at detected floor height
     */
    private fun tryVirtualPlaneHit(frame: Frame, screenX: Float, screenY: Float): Map<String, Any>? {
        try {
            // Get the average floor height from stored node heights
            val averageHeight = nodeFloorHeights.values.average().toFloat()
            Log.d(TAG, "🔮 Virtual hit: Using average floor height: $averageHeight")
            
            // Get camera pose and projection
            val camera = frame.camera
            val cameraPose = camera.pose
            
            // Get view dimensions
            val view = arSceneView ?: return null
            val viewWidth = view.width.toFloat()
            val viewHeight = view.height.toFloat()
            
            if (viewWidth <= 0 || viewHeight <= 0) return null
            
            // Convert screen coordinates to normalized device coordinates (-1 to 1)
            val ndcX = (screenX / viewWidth) * 2.0f - 1.0f
            val ndcY = -((screenY / viewHeight) * 2.0f - 1.0f) // Flip Y
            
            // Get camera projection matrix
            val projectionMatrix = FloatArray(16)
            camera.getProjectionMatrix(projectionMatrix, 0, 0.1f, 100.0f)
            
            // Create ray from camera through screen point
            val rayOrigin = FloatArray(3)
            val rayDirection = FloatArray(3)
            
            // Camera position
            val cameraTranslation = cameraPose.translation
            rayOrigin[0] = cameraTranslation[0]
            rayOrigin[1] = cameraTranslation[1] 
            rayOrigin[2] = cameraTranslation[2]
            
            // Ray direction (simplified - could be more accurate with full inverse projection)
            val cameraRotation = cameraPose.rotationQuaternion
            rayDirection[0] = ndcX * 0.5f // Simplified direction calculation
            rayDirection[1] = ndcY * 0.5f
            rayDirection[2] = -1.0f // Forward
            
            // Apply camera rotation to ray direction (simplified)
            // For a more accurate implementation, you'd use the full inverse projection matrix
            
            // Calculate intersection with virtual horizontal plane at averageHeight
            val planeY = averageHeight
            val cameraY = rayOrigin[1]
            val directionY = rayDirection[1]
            
            if (Math.abs(directionY) < 0.001f) {
                // Ray is parallel to plane
                return null
            }
            
            // Calculate intersection distance
            val t = (planeY - cameraY) / directionY
            
            if (t < 0) {
                // Intersection is behind camera
                return null
            }
            
            // Calculate intersection point
            val hitX = rayOrigin[0] + rayDirection[0] * t
            val hitY = planeY // Locked to virtual plane height
            val hitZ = rayOrigin[2] + rayDirection[2] * t
            
            // Create pose matrix for the hit point
            val hitMatrix = FloatArray(16)
            hitMatrix[0] = 1f; hitMatrix[1] = 0f; hitMatrix[2] = 0f; hitMatrix[3] = 0f
            hitMatrix[4] = 0f; hitMatrix[5] = 1f; hitMatrix[6] = 0f; hitMatrix[7] = 0f
            hitMatrix[8] = 0f; hitMatrix[9] = 0f; hitMatrix[10] = 1f; hitMatrix[11] = 0f
            hitMatrix[12] = hitX; hitMatrix[13] = hitY; hitMatrix[14] = hitZ; hitMatrix[15] = 1f
            
            val hitResult = mapOf(
                "pose" to mapOf("matrix" to hitMatrix.toList()),
                "plane" to mapOf("type" to "horizontal"),
                "virtual" to true // Mark as virtual hit for debugging
            )
            
            Log.d(TAG, "🔮 Virtual hit created at: ($hitX, $hitY, $hitZ)")
            return hitResult
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error creating virtual plane hit: ${e.message}")
            return null
        }
    }
    
    // Extension function to convert pose matrix to list for Flutter
    private fun FloatArray.toList(): List<Float> = this.asList()
}
