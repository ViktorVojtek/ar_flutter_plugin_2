package com.uhg0.ar_flutter_plugin_2

import android.content.Context
import android.graphics.Bitmap
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.MotionEvent
import android.view.PixelCopy
import android.view.SurfaceView
import android.view.View
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.lifecycle.Lifecycle
import com.google.ar.core.Anchor
import com.google.ar.core.Config
import com.google.ar.core.Frame
import com.google.ar.core.HitResult
import com.google.ar.core.InstantPlacementPoint
import com.google.ar.core.Plane
import com.google.ar.core.Point
import com.google.ar.core.Pose
import com.google.ar.core.Session
import com.google.ar.core.TrackingState
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import io.github.sceneview.ar.ARSceneView
import io.github.sceneview.ar.node.AnchorNode
import io.github.sceneview.gesture.MoveGestureDetector
import io.github.sceneview.gesture.RotateGestureDetector
import io.github.sceneview.math.Position
import io.github.sceneview.math.Scale
import io.github.sceneview.math.quaternion
import io.github.sceneview.math.toColumnsFloatArray
import io.github.sceneview.node.ModelNode
import io.github.sceneview.node.Node
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.max
import kotlin.math.sqrt
import kotlin.math.abs
import kotlin.math.atan
import kotlin.math.tan
import dev.romainguy.kotlin.math.length

/**
 * New SceneView-based implementation of the Android platform view.
 *
 * IMPORTANT: This is an initial scaffolding that focuses on parity for the core flows
 * (session initialisation, anchor creation, node placement, taps and basic pose queries).
 * Additional gesture controls, deep memory cleanup, caching and Cloud Anchor flows still need
 * to be ported from the previous Sceneform implementation.
 */
class ArCoreCompatView(
    context: Context,
    messenger: BinaryMessenger,
    viewId: Int,
    private val activity: ComponentActivity?,
    private val lifecycle: Lifecycle
) : PlatformView {

    companion object {
        private const val TAG = "SceneViewCompat"
    }

    private val uiHandler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private val container = FrameLayout(context)
    private val sceneView: ARSceneView

    private val sessionChannel = MethodChannel(messenger, "arsession_$viewId")
    private val objectChannel = MethodChannel(messenger, "arobjects_$viewId")
    private val anchorChannel = MethodChannel(messenger, "aranchors_$viewId")

    private val anchorRecords = ConcurrentHashMap<String, AnchorRecord>()
    private val nodeRecords = ConcurrentHashMap<String, NodeRecord>()

    private val seenPlanes = mutableSetOf<String>()
    private var environmentInitialized = false
    private var isDisposed = false
    
    // Manual pan gesture tracking (bypassing SceneView's failing hit test system)
    private var panStartY = 0f
    private var panStartWorldPos: Position? = null
    private var panStartTouchX = 0f
    private var panStartTouchY = 0f
    private var currentTouchX = 0f  // Track absolute touch position
    private var currentTouchY = 0f
    
    // Depth occlusion state tracking (SceneView handles this automatically when depth is enabled)
    // We just track the state for the Flutter API
    private var depthOcclusionEnabled = true  // Enabled by default when depth mode is AUTOMATIC

    init {
        sceneView = ARSceneView(
            context = context,
            sharedActivity = activity,
            sharedLifecycle = lifecycle
        ).apply {
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
            this.lifecycle = lifecycle
            planeRenderer.isEnabled = true

            configureSession { session, config ->
                // Enable depth mode for occlusion support
                val depthSupported = session.isDepthModeSupported(Config.DepthMode.AUTOMATIC)
                config.depthMode = if (depthSupported) {
                    Config.DepthMode.AUTOMATIC
                } else {
                    Config.DepthMode.DISABLED
                }
                
                config.planeFindingMode = Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL
                config.lightEstimationMode = Config.LightEstimationMode.ENVIRONMENTAL_HDR
                config.instantPlacementMode = Config.InstantPlacementMode.LOCAL_Y_UP
                
                Log.i(TAG, "🔍 Depth API: ${if (depthSupported) "ENABLED - Occlusion supported" else "DISABLED - Device doesn't support depth"}")
                
                // When depth mode is enabled, SceneView automatically handles depth-based occlusion
                // Virtual objects will appear behind real-world objects
                if (depthSupported) {
                    depthOcclusionEnabled = true
                    Log.i(TAG, "✅ Depth occlusion ENABLED - Virtual objects will be occluded by real objects")
                } else {
                    depthOcclusionEnabled = false
                    Log.i(TAG, "⚠️ Depth not supported on this device - occlusion unavailable")
                }
            }

            onSessionUpdated = { _, frame ->
                if (!isDisposed) {
                    handleFrame(frame)
                }
            }

            setOnGestureListener(
                onSingleTapConfirmed = { event, node ->
                    if (!isDisposed) {
                        if (node != null) {
                            handleNodeTap(node)
                        } else {
                            handleHitTest(event.x, event.y)
                        }
                    }
                },
                onMoveBegin = { detector: MoveGestureDetector, event: MotionEvent, node: Node? ->
                    if (isDisposed) {
                        false
                    } else {
                        val record = node?.let(::findNodeRecord)
                        if (node != null && record?.enablePan == true && record.anchorId != null) {
                            // Store initial world Y for height-locked panning AND initial position
                            panStartY = node.worldPosition.y
                            panStartWorldPos = Position(node.worldPosition.x, node.worldPosition.y, node.worldPosition.z)
                            panStartTouchX = currentTouchX
                            panStartTouchY = currentTouchY
                            // Touch coordinates are tracked globally by container's touch listener
                            Log.d(TAG, "🔥 Pan started - Y=$panStartY, Touch: ($currentTouchX, $currentTouchY)")
                            handleGestureEvent("onPanStart", node)
                            true
                        } else false
                    }
                },
                onMove = { detector: MoveGestureDetector, event: MotionEvent, node: Node? ->
                    if (isDisposed) {
                        false
                    } else {
                    val record = node?.let(::findNodeRecord)
                    if (node != null && record?.enablePan == true && record.anchorId != null && panStartWorldPos != null) {
                        // Use ARCore hit testing to project touch position onto AR plane
                        // This works correctly regardless of camera position/rotation
                        val hitResult = sceneView.hitTestAR(
                            xPx = currentTouchX,
                            yPx = currentTouchY,
                            planeTypes = setOf(
                                Plane.Type.HORIZONTAL_UPWARD_FACING,
                                Plane.Type.HORIZONTAL_DOWNWARD_FACING
                            ),
                            point = true,
                            depthPoint = true,
                            pointOrientationModes = setOf(Point.OrientationMode.ESTIMATED_SURFACE_NORMAL)
                        )
                        
                        if (hitResult != null) {
                            // Get the 3D world position where the touch ray hits the AR plane
                            val hitPose = hitResult.hitPose
                            val hitTranslation = FloatArray(3)
                            hitPose.getTranslation(hitTranslation, 0)
                            
                            // Calculate delta from the pan start position
                            val worldDeltaX = hitTranslation[0] - panStartWorldPos!!.x
                            val worldDeltaZ = hitTranslation[2] - panStartWorldPos!!.z
                            
                            // Apply delta while keeping height locked
                            val newWorldPos = Position(
                                panStartWorldPos!!.x + worldDeltaX,
                                panStartY,  // Keep height locked at start Y
                                panStartWorldPos!!.z + worldDeltaZ
                            )
                            
                            // Check distance limit
                            val frame = sceneView.frame
                            val camera = frame?.camera
                            if (camera != null) {
                                val cameraTrans = FloatArray(3)
                                camera.pose.getTranslation(cameraTrans, 0)
                                
                                val dx = newWorldPos.x - cameraTrans[0]
                                val dy = newWorldPos.y - cameraTrans[1]
                                val dz = newWorldPos.z - cameraTrans[2]
                                val distance = sqrt(dx * dx + dy * dy + dz * dz)
                                
                                if (distance <= 5.0f) {
                                    record.node.worldPosition = newWorldPos
                                    Log.d(TAG, "🎯 Hit-test pan → World Pos: (%.3f, %.3f, %.3f) | Dist: %.2fm".format(
                                        newWorldPos.x, newWorldPos.y, newWorldPos.z, distance
                                    ))
                                } else {
                                    Log.d(TAG, "⚠️ Position too far: ${distance}m (max 5m) - ignoring")
                                }
                            }
                        } else {
                            Log.d(TAG, "⚠️ No hit result - pan ignored")
                        }
                        
                        handleGestureEvent("onPanChange", node)
                        true
                    } else false
                    }
                },
                onMoveEnd = { detector: MoveGestureDetector, event: MotionEvent, node: Node? ->
                    val record = node?.let(::findNodeRecord)
                    if (node != null && record?.enablePan == true && record.anchorId != null) {
                        // Create new anchor at ModelNode's current world position
                        val session = sceneView.session
                        if (session != null) {
                            try {
                                val worldPos = node.worldPosition
                                val pose = Pose.makeTranslation(worldPos.x, worldPos.y, worldPos.z)
                                val newAnchor = session.createAnchor(pose)
                                
                                // Update the anchor node
                                val anchorRec = record.anchorId?.let { anchorRecords[it] }
                                if (anchorRec != null) {
                                    anchorRec.anchor.detach()
                                    anchorRec.anchor = newAnchor
                                    anchorRec.node.anchor = newAnchor
                                    
                                    // Reset ModelNode to center of new anchor
                                    record.node.position = Position(0f, 0f, 0f)
                                    
                                    Log.d(TAG, "✅ Created new anchor at (${worldPos.x}, ${worldPos.y}, ${worldPos.z})")
                                }
                            } catch (e: Exception) {
                                Log.e(TAG, "Failed to create anchor: ${e.message}")
                            }
                        }
                        handleGestureEnd("onPanEnd", node)
                        true
                    } else false
                },
                onRotateBegin = { _: RotateGestureDetector, _: MotionEvent, node: Node? ->
                    val record = node?.let(::findNodeRecord)
                    if (node != null && record?.enableRotation == true) {
                        Log.d(
                            TAG,
                            "onRotateBegin for node: ${node.name}, isRotationEditable: ${node.isRotationEditable}"
                        )
                        handleGestureEvent("onRotationStart", node)
                    }
                },
                onRotate = { _: RotateGestureDetector, _: MotionEvent, node: Node? ->
                    val record = node?.let(::findNodeRecord)
                    if (node != null && record?.enableRotation == true) {
                        handleGestureEvent("onRotationChange", node)
                    }
                },
                onRotateEnd = { _: RotateGestureDetector, _: MotionEvent, node: Node? ->
                    val record = node?.let(::findNodeRecord)
                    if (node != null && record?.enableRotation == true) {
                        handleGestureEnd("onRotationEnd", node)
                    }
                }
            )
        }

        // Environment loading will be handled lazily on first frame update to ensure
        // proper thread context and lifecycle state
        // DO NOT load environment here to avoid Filament threading issues

        container.addView(sceneView)
        
        // Intercept ALL touch events to track real-time finger position
        // This is needed because MoveGestureDetector doesn't provide current coordinates
        sceneView.setOnTouchListener { view, event ->
            // Prevent touch processing during disposal
            if (isDisposed) return@setOnTouchListener false
            
            when (event.actionMasked) {
                android.view.MotionEvent.ACTION_DOWN -> {
                    // event.x and event.y are already relative to the view!
                    currentTouchX = event.x
                    currentTouchY = event.y
                    Log.d(TAG, "🖐️ Touch DOWN: ($currentTouchX, $currentTouchY)")
                }
                android.view.MotionEvent.ACTION_MOVE -> {
                    currentTouchX = event.x
                    currentTouchY = event.y
                    // Too verbose to log every move
                }
            }
            false // Don't consume, let gesture detectors handle it
        }

        sessionChannel.setMethodCallHandler(::handleSessionMethod)
        objectChannel.setMethodCallHandler(::handleObjectMethod)
        anchorChannel.setMethodCallHandler(::handleAnchorMethod)
    }

    // ------------------------------------------------------------------------
    // PlatformView contract
    // ------------------------------------------------------------------------

    override fun getView(): View = container

    override fun dispose() {
        if (isDisposed) return
        isDisposed = true
        
        Log.d(TAG, "🧹 Disposing ArCoreCompatView - starting cleanup")
        
        try {
            // Cancel method handlers immediately to prevent new calls
            sessionChannel.setMethodCallHandler(null)
            objectChannel.setMethodCallHandler(null)
            anchorChannel.setMethodCallHandler(null)
            scope.cancel()
            
            // Stop touch listener immediately to prevent gesture callbacks
            sceneView.setOnTouchListener(null)
            
            // CRITICAL FIX: Pause AR session FIRST to prevent camera errors
            // Must be done on UI thread before any cleanup
            uiHandler.post {
                try {
                    Log.d(TAG, "🧹 Phase 1: Pausing AR session")
                    
                    // Pause the AR session to stop camera
                    sceneView.session?.pause()
                    
                    // Give the camera time to actually stop (prevents "session already closed" errors)
                    Thread.sleep(100)
                    
                    Log.d(TAG, "🧹 Phase 2: Clearing nodes and anchors")
                    
                    // Clear nodes first (children before parents)
                    nodeRecords.values.forEach { record ->
                        runCatching { record.node.destroy() }
                    }
                    nodeRecords.clear()
                    
                    // Then clear anchors
                    anchorRecords.values.forEach { record ->
                        runCatching { 
                            record.anchor.detach()
                            record.node.destroy()
                        }
                    }
                    anchorRecords.clear()
                    
                    Log.d(TAG, "🧹 Phase 3: Destroying SceneView")
                    
                    // Finally destroy the scene view (this will close the session properly)
                    sceneView.destroy()
                    
                    Log.d(TAG, "✅ Disposal complete - all resources cleaned up")
                    
                } catch (t: Throwable) {
                    Log.e(TAG, "❌ Error during scene cleanup", t)
                }
            }
        } catch (t: Throwable) {
            Log.e(TAG, "❌ Error during dispose", t)
        }
    }

    // ------------------------------------------------------------------------
    // Session channel
    // ------------------------------------------------------------------------

    private fun handleSessionMethod(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> {
                val args = call.arguments as? Map<*, *>
                configureSession(args)
                result.success("initialized")
            }
            "getCameraPose" -> {
                val pose = sceneView.frame?.camera?.pose
                if (pose != null) {
                    result.success(poseToList(pose))
                } else {
                    result.error("NO_CAMERA", "AR camera not ready", null)
                }
            }
            "getAnchorPose" -> {
                val anchorId = (call.argument<String>("anchorId"))
                val anchorPose = anchorId?.let { anchorRecords[it]?.anchor?.pose }
                if (anchorPose != null) {
                    result.success(poseToList(anchorPose))
                } else {
                    result.error("ANCHOR_NOT_FOUND", "Unknown anchor: $anchorId", null)
                }
            }
            "showPlanes" -> {
                val show = call.argument<Boolean>("showPlanes") ?: true
                sceneView.planeRenderer.isVisible = show
                result.success(null)
            }
            "enableCamera" -> {
                resumeSession()
                result.success(null)
            }
            "disableCamera" -> {
                pauseSession()
                result.success(null)
            }
            "snapshot" -> takeSnapshot(result)
            "isDepthSupported" -> {
                val session = sceneView.session
                val supported = session?.isDepthModeSupported(Config.DepthMode.AUTOMATIC) ?: false
                result.success(supported)
            }
            "enableDepthOcclusion" -> {
                val enable = call.argument<Boolean>("enable") ?: true
                val session = sceneView.session
                if (session != null && session.isDepthModeSupported(Config.DepthMode.AUTOMATIC)) {
                    // Reconfigure session to change depth mode
                    sceneView.configureSession { _, config ->
                        config.depthMode = if (enable) {
                            Config.DepthMode.AUTOMATIC
                        } else {
                            Config.DepthMode.DISABLED
                        }
                    }
                    depthOcclusionEnabled = enable
                    Log.i(TAG, "🔍 Depth occlusion ${if (enable) "ENABLED" else "DISABLED"}")
                    result.success(true)
                } else {
                    Log.w(TAG, "⚠️ Depth not supported on this device")
                    depthOcclusionEnabled = false
                    result.success(false)
                }
            }
            "isDepthOcclusionEnabled" -> {
                result.success(depthOcclusionEnabled)
            }
            "acquireDepthImage" -> {
                acquireDepthImage(result)
            }
            "getLightEstimate" -> {
                val estimate = sceneView.frame?.lightEstimate
                if (estimate != null && estimate.state == com.google.ar.core.LightEstimate.State.VALID) {
                    val map = mapOf(
                        "pixelIntensity" to estimate.pixelIntensity.toDouble(),
                        "timestamp" to sceneView.frame?.timestamp
                    )
                    result.success(map)
                } else {
                    result.error("NO_LIGHT", "Light estimate unavailable", null)
                }
            }
            "dispose" -> {
                dispose()
                result.success(null)
            }
            "softResetSession" -> {
                val removeAnchors = (call.arguments as? Map<*, *>)?.get("removeExistingAnchors") as? Boolean ?: true
                val resetTracking = (call.arguments as? Map<*, *>)?.get("resetTracking") as? Boolean ?: true
                softResetSession(removeAnchors, resetTracking)
                result.success(true)
            }
            "ar#nukeAll" -> {
                val args = call.arguments as? Map<*, *>
                val purgeCaches = args?.get("purgeCaches") as? Boolean ?: true
                val removeAnchors = args?.get("removeExistingAnchors") as? Boolean ?: true
                val resetTracking = args?.get("resetTracking") as? Boolean ?: true
                nukeAll(purgeCaches, removeAnchors, resetTracking)
                result.success(true)
            }
            "ar#nukeAllNonBlocking" -> {
                val args = call.arguments as? Map<*, *>
                val purgeCaches = args?.get("purgeCaches") as? Boolean ?: true
                val removeAnchors = args?.get("removeExistingAnchors") as? Boolean ?: true
                val resetTracking = args?.get("resetTracking") as? Boolean ?: false
                // Execute async and return immediately
                scope.launch {
                    nukeAll(purgeCaches, removeAnchors, resetTracking)
                }
                result.success(true)
            }
            "removeAllObjects" -> {
                removeAllNodes()
                result.success(true)
            }
            "ar#getPluginState" -> {
                val state = getPluginState()
                result.success(state)
            }
            "enableLightingMonitoring" -> {
                // TODO: Implement polling listener once parity requirements are clarified.
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun configureSession(arguments: Map<*, *>?) {
        val showPlanes = arguments?.get("showPlanes") as? Boolean ?: true
        val planeDetectionIndex = (arguments?.get("planeDetectionConfig") as? Number)?.toInt()
        val showFeaturePoints = arguments?.get("showFeaturePoints") as? Boolean ?: false
        val showAnimatedGuide = arguments?.get("showAnimatedGuide") as? Boolean ?: false

        sceneView.configureSession { session, config ->
            config.lightEstimationMode = Config.LightEstimationMode.ENVIRONMENTAL_HDR
            config.instantPlacementMode = Config.InstantPlacementMode.LOCAL_Y_UP
            config.depthMode = if (session.isDepthModeSupported(Config.DepthMode.AUTOMATIC)) {
                Config.DepthMode.AUTOMATIC
            } else {
                Config.DepthMode.DISABLED
            }

            config.planeFindingMode = when (planeDetectionIndex) {
                1 -> Config.PlaneFindingMode.HORIZONTAL
                2 -> Config.PlaneFindingMode.VERTICAL
                3 -> Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL
                else -> Config.PlaneFindingMode.DISABLED
            }
        }

        sceneView.planeRenderer.isVisible = showPlanes
        sceneView.planeRenderer.isEnabled = planeDetectionIndex != null && planeDetectionIndex != 0
        if (showFeaturePoints) {
            Log.w(TAG, "Feature point visualization is not yet supported in the SceneView migration.")
        }

        // Handle coaching overlay for Android
        if (showAnimatedGuide) {
            Log.i(TAG, "📱 Coaching overlay requested - ARCore doesn't have a native equivalent to ARCoachingOverlayView")
            Log.i(TAG, "💡 Consider using the HandMotionView or implementing a custom Flutter overlay")
            // Note: ARCore doesn't provide a built-in coaching overlay like ARKit
            // You can implement custom guidance using:
            // 1. TrackingState monitoring (see handleFrame method)
            // 2. Custom Flutter overlay with instructions
            // 3. HandMotionView for plane scanning guidance
        }
    }

    private fun resumeSession() = Unit

    private fun pauseSession() = Unit

    // ------------------------------------------------------------------------
    // Object channel
    // ------------------------------------------------------------------------

    private fun handleObjectMethod(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> result.success(null)
            "addNode" -> handleAddNode(call.arguments, null, result)
            "addNodeToPlaneAnchor" -> {
                val args = call.arguments as? Map<*, *>
                val anchorData = args?.get("anchor") as? Map<*, *>
                val anchorId = anchorData?.get("name") as? String
                handleAddNode(args?.get("node"), anchorId, result)
            }
            "removeNode" -> {
                val name = (call.arguments as? Map<*, *>)?.get("name") as? String
                if (name != null && removeNode(name)) {
                    result.success(true)
                } else {
                    result.error("NODE_NOT_FOUND", "Unknown node: $name", null)
                }
            }
            "removeNodeDeep" -> {
                val nodeId = (call.arguments as? Map<*, *>)?.get("nodeId") as? String
                if (nodeId != null) {
                    val success = removeNodeDeep(nodeId)
                    result.success(success)
                } else {
                    result.success(false)
                }
            }
            "purgeCaches" -> {
                // SceneView manages its own caches, but we can force GC
                System.gc()
                result.success(true)
            }
            "getMemoryInfo" -> {
                val memoryInfo = getMemoryInfo()
                result.success(memoryInfo)
            }
            "transformationChanged" -> {
                val args = call.arguments as? Map<*, *>
                handleTransformationChanged(args)
                result.success(null)
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    private fun handleAddNode(
        rawNode: Any?,
        anchorId: String?,
        result: MethodChannel.Result
    ) {
        val nodeData = when (rawNode) {
            is Map<*, *> -> rawNode
            null -> {
                result.error("INVALID_ARGUMENTS", "Node payload missing", null)
                return
            }
            else -> {
                result.error("INVALID_ARGUMENTS", "Unsupported node payload type", null)
                return
            }
        }

        @Suppress("UNCHECKED_CAST")
        val nodeMap = try {
            nodeData as Map<String, Any?>
        } catch (e: ClassCastException) {
            result.error("INVALID_ARGUMENTS", "Node payload malformed", null)
            return
        }

        val nodeId = nodeMap["name"] as? String
        val uri = nodeMap["uri"] as? String
        if (nodeId == null || uri == null) {
            result.error("INVALID_ARGUMENTS", "Node id or uri missing", null)
            return
        }

        val transformMatrix = (nodeMap["transformation"] as? List<*>)?.let(::listToFloatArray)
            ?: FloatArray(16).apply {
                this[0] = 1f; this[5] = 1f; this[10] = 1f; this[15] = 1f
            }

        val scaleOverride = (nodeMap["scale"] as? List<*>)?.let(::listToFloatArray3)

        val isTransformable = nodeMap["isTransformable"] as? Boolean ?: false
        val enablePan = nodeMap["enablePanGestures"] as? Boolean ?: false
        val enableRotation = nodeMap["enableRotationGestures"] as? Boolean ?: false

        val anchorRecord = anchorId?.let { anchorRecords[it] }
        if (anchorId != null && anchorRecord == null) {
            result.error("ANCHOR_NOT_FOUND", "Unknown anchor: $anchorId", null)
            return
        }

        // Configure anchor node gestures
        if (anchorRecord != null) {
            anchorRecord.node.apply {
                isEditable = true
                // 🔥 CRITICAL: Do NOT enable isPositionEditable!
                // We handle panning manually via ray-plane intersection.
                // SceneView's built-in pan would conflict and cause jitter.
                isPositionEditable = false  // Always false, we do manual pan
                isRotationEditable = enableRotation
                
                Log.d(TAG, "✅ AnchorNode '${this.name}' configured: pan=$enablePan (manual), rotation=$enableRotation")
            }
        }

        // Check if already disposed
        if (isDisposed) {
            result.error("DISPOSED", "View has been disposed", null)
            return
        }

        // Load model on Main thread to ensure proper Filament thread context
        scope.launch(Dispatchers.Main) {
            try {
                // Load model instance - this must happen on the main/render thread
                val modelInstance = withContext(Dispatchers.Main) {
                    sceneView.modelLoader.loadModelInstance(uri)
                        ?: throw IllegalArgumentException("Unable to load model: $uri")
                }

                // Create and configure model node on main thread
                val modelNode = ModelNode(modelInstance).apply {
                    name = nodeId
                    val (position, rotation, scale) = parseTransform(transformMatrix, scaleOverride)
                    this.position = position
                    this.quaternion = rotation
                    this.scale = scale
                }

                // Add to scene on main thread
                if (anchorRecord != null) {
                    // Configure ModelNode - must be editable to receive touch events
                    // But with isPositionEditable=false so it delegates to parent
                    modelNode.apply {
                        isEditable = enablePan || enableRotation  // Must be true to detect touches
                        isPositionEditable = false  // Delegate position to parent
                        isRotationEditable = false  // Delegate rotation to parent
                        isScaleEditable = false
                        // 🔥 DISABLE smooth transforms - may be causing jitter
                        isSmoothTransformEnabled = false
                    }
                    
                    // Just add the child node
                    anchorRecord.node.addChildNode(modelNode)
                    
                    Log.d(TAG, "✅ Configured model on anchor - AnchorNode: pos=$enablePan,rot=$enableRotation | ModelNode: delegates to parent, smooth disabled")
                } else {
                    // Standalone node (no anchor) - ModelNode handles all gestures
                    modelNode.apply {
                        isEditable = isTransformable || enablePan || enableRotation
                        isPositionEditable = enablePan
                        isRotationEditable = enableRotation
                        isScaleEditable = false
                    }
                    sceneView.addChildNode(modelNode)
                    
                    Log.d(TAG, "Standalone ModelNode $nodeId - isEditable: ${modelNode.isEditable}, " +
                        "isPositionEditable: $enablePan, isRotationEditable: $enableRotation")
                }

                val nodeRecord = NodeRecord(
                    id = nodeId,
                    node = modelNode,
                    anchorId = anchorRecord?.id,
                    isTransformable = isTransformable,
                    enablePan = enablePan,
                    enableRotation = enableRotation
                )
                nodeRecords[nodeId] = nodeRecord

                result.success(nodeId)
            } catch (t: Throwable) {
                Log.e(TAG, "Failed to add node $nodeId", t)
                result.error("NODE_ERROR", t.message, null)
            }
        }
    }

    private fun removeNode(nodeId: String): Boolean {
        val record = nodeRecords.remove(nodeId) ?: return false
        runCatching {
            record.node.destroy()
        }
        return true
    }

    private fun removeNodeDeep(nodeId: String): Boolean {
        Log.d(TAG, "🗑️ Deep remove node: $nodeId")
        
        val record = nodeRecords.remove(nodeId)
        if (record == null) {
            Log.w(TAG, "⚠️ Node not found: $nodeId")
            return false
        }
        
        try {
            // Destroy the node (SceneView handles resource cleanup)
            record.node.destroy()
            
            Log.d(TAG, "✅ Node removed successfully: $nodeId")
            return true
        } catch (t: Throwable) {
            Log.e(TAG, "❌ Error removing node: $nodeId", t)
            return false
        }
    }

    private fun getMemoryInfo(): Map<String, Any> {
        val runtime = Runtime.getRuntime()
        val usedMemory = runtime.totalMemory() - runtime.freeMemory()
        
        return mapOf(
            "usedMemoryBytes" to usedMemory,
            "totalMemoryBytes" to runtime.totalMemory(),
            "maxMemoryBytes" to runtime.maxMemory(),
            "freeMemoryBytes" to runtime.freeMemory(),
            "nodeCount" to nodeRecords.size,
            "anchorCount" to anchorRecords.size,
            "planeCount" to seenPlanes.size
        )
    }

    private fun handleTransformationChanged(payload: Map<*, *>?) {
        val data = payload as? Map<*, *> ?: return
        val nodeId = data["name"] as? String ?: return
        val transform = (data["transformation"] as? List<*>)?.let(::listToFloatArray) ?: return

        val node = nodeRecords[nodeId]?.node ?: return
        val (position, rotation, scale) = parseTransform(transform, null)
        node.position = position
        node.quaternion = rotation
        node.scale = scale
    }

    private fun handleNodeTap(node: Node) {
        val record = nodeRecords.values.firstOrNull { it.node === node }
        record?.let {
            objectChannel.invokeMethod("onNodeTap", listOf(it.id))
            objectChannel.invokeMethod("onSelectionChanged", it.id)
        }
    }

    private fun handleGestureEvent(method: String, node: Node) {
        val record = nodeRecords.values.firstOrNull { it.node === node } ?: return
        objectChannel.invokeMethod(method, record.id)
    }

    private fun handleGestureEnd(method: String, node: Node) {
        val record = nodeRecords.values.firstOrNull { it.node === node } ?: return
        val transform = node.transform.toColumnsFloatArray()
        val payload = mapOf(
            "name" to record.id,
            "transform" to transform.map { it.toDouble() }
        )
        objectChannel.invokeMethod(method, payload)
    }

    // ------------------------------------------------------------------------
    // Anchor channel
    // ------------------------------------------------------------------------

    private fun handleAnchorMethod(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "addAnchor" -> {
                val args = call.arguments as? Map<*, *>
                val name = args?.get("name") as? String
                val transform = (args?.get("transformation") as? List<*>)?.let(::listToFloatArray)

                if (name == null || transform == null) {
                    result.error("INVALID_ARGUMENTS", "Anchor name or transform missing", null)
                    return
                }

                val session = sceneView.session
                if (session == null) {
                    result.error("SESSION_UNAVAILABLE", "AR session not ready", null)
                    return
                }

                val pose = matrixToPose(transform)
                val anchor = session.createAnchor(pose)
                val anchorNode = AnchorNode(sceneView.engine, anchor).apply {
                    this.name = name
                    isEditable = true
                    isPositionEditable = true
                    
                    // 🔥 CRITICAL: Do NOT configure moveHitTest!
                    // ARCore's depth API fails ("No point hit" errors), causing jittery movement
                    // Instead, our custom onMove callback uses screenToWorld which works perfectly
                    // The onMove callback is configured when adding nodes to this anchor
                }
                sceneView.addChildNode(anchorNode)
                anchorRecords[name] = AnchorRecord(name, anchor, anchorNode)
                Log.d(TAG, "✅ Created AnchorNode '$name' (onMove callbacks will be configured when nodes are added)")
                result.success(true)
            }
            "removeAnchor" -> {
                val args = call.arguments as? Map<*, *>
                val name = args?.get("name") as? String
                if (name == null) {
                    result.error("INVALID_ARGUMENTS", "Anchor name missing", null)
                    return
                }
                val anchor = anchorRecords.remove(name)
                if (anchor != null) {
                    runCatching { anchor.node.destroy() }
                    result.success(true)
                } else {
                    result.error("ANCHOR_NOT_FOUND", "Unknown anchor: $name", null)
                }
            }
            "initGoogleCloudAnchorMode",
            "uploadAnchor",
            "downloadAnchor" -> {
                // TODO: Port Cloud Anchor integration.
                result.notImplemented()
            }
            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------------------
    // Frame + hit test helpers
    // ------------------------------------------------------------------------

    private fun handleFrame(frame: Frame) {
        if (isDisposed) return
        
        if (!environmentInitialized) {
            initializeDefaultEnvironment()
        }
        sendPlaneUpdates(frame)
        sendLightingUpdate(frame)
    }

    private fun initializeDefaultEnvironment() {
        if (isDisposed || environmentInitialized) return
        
        val loader = sceneView.environmentLoader ?: run {
            environmentInitialized = true
            return
        }

        // Ensure we're on the main thread for Filament operations
        uiHandler.post {
            if (isDisposed) return@post
            
            runCatching {
                // Load environment synchronously on main thread to avoid threading issues
                val environment = loader.createHDREnvironment("environments/evening_meadow_2k.hdr")
                environment?.let { sceneView.environment = it }
                environmentInitialized = true
            }.onFailure { error ->
                Log.w(TAG, "Unable to load default HDR environment: ${error.message}")
                environmentInitialized = true
            }
        }
    }

    private fun sendPlaneUpdates(frame: Frame) {
        frame.getUpdatedTrackables(Plane::class.java)
            .filter { it.trackingState == TrackingState.TRACKING && it.subsumedBy == null }
            .forEach { plane ->
                val id = plane.hashCode().toString()
                if (seenPlanes.add(id)) {
                    sessionChannel.invokeMethod("onPlaneDetected", plane.toMap())
                }
            }
    }

    private fun sendLightingUpdate(frame: Frame) {
        val light = frame.lightEstimate
        if (light != null && light.state == com.google.ar.core.LightEstimate.State.VALID) {
            val map = mapOf(
                "pixelIntensity" to light.pixelIntensity.toDouble(),
                "timestamp" to frame.timestamp
            )
            sessionChannel.invokeMethod("onLightingConditionChanged", map)
        }
    }

    private fun handleHitTest(x: Float, y: Float) {
        val result = sceneView.hitTestAR(
            xPx = x,
            yPx = y,
            planeTypes = setOf(
                Plane.Type.HORIZONTAL_UPWARD_FACING,
                Plane.Type.HORIZONTAL_DOWNWARD_FACING,
                Plane.Type.VERTICAL
            ),
            point = true,
            depthPoint = true,
            pointOrientationModes = setOf(Point.OrientationMode.ESTIMATED_SURFACE_NORMAL)
        )

        if (result != null) {
            sessionChannel.invokeMethod(
                "onPlaneOrPointTap",
                listOf(result.toMap())
            )
        } else {
            sessionChannel.invokeMethod("onPlaneOrPointTap", emptyList<Map<String, Any>>())
        }
    }

    private fun HitResult.toMap(): Map<String, Any> {
        val pose = hitPose
        val matrix = FloatArray(16)
        pose.toMatrix(matrix, 0)
        val type = when (trackable) {
            is Plane -> 1
            is Point -> 2
            else -> 0
        }
        return mapOf(
            "type" to type,
            "distance" to distance.toDouble(),
            "worldTransform" to matrix.map { it.toDouble() }
        )
    }

    // ------------------------------------------------------------------------
    // Snapshot
    // ------------------------------------------------------------------------

    private fun takeSnapshot(result: MethodChannel.Result) {
        val surfaceView = sceneView as? SurfaceView
        if (surfaceView == null) {
            result.error("SNAPSHOT_ERROR", "SceneView is not a SurfaceView", null)
            return
        }

        if (surfaceView.width <= 0 || surfaceView.height <= 0) {
            result.error("SNAPSHOT_ERROR", "View has invalid dimensions", null)
            return
        }

        val bitmap = Bitmap.createBitmap(surfaceView.width, surfaceView.height, Bitmap.Config.ARGB_8888)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            PixelCopy.request(
                surfaceView,
                bitmap,
                { copyResult ->
                    if (copyResult == PixelCopy.SUCCESS) {
                        result.success(bitmapToByteArray(bitmap))
                    } else {
                        result.error("SNAPSHOT_ERROR", "PixelCopy failed with code $copyResult", null)
                    }
                },
                uiHandler
            )
        } else {
            result.error("SNAPSHOT_UNSUPPORTED", "PixelCopy requires Android O+", null)
        }
    }

    private fun bitmapToByteArray(bitmap: Bitmap): ByteArray {
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
        return stream.toByteArray()
    }

    // ------------------------------------------------------------------------
    // Depth API
    // ------------------------------------------------------------------------
    
    private fun acquireDepthImage(result: MethodChannel.Result) {
        try {
            val frame = sceneView.frame
            if (frame == null) {
                result.error("NO_FRAME", "AR frame not available", null)
                return
            }
            
            // Try to acquire depth image
            val depthImage = try {
                frame.acquireDepthImage16Bits()
            } catch (e: Exception) {
                // Depth data not yet available
                result.error("DEPTH_NOT_AVAILABLE", "Depth data not yet available: ${e.message}", null)
                return
            }
            
            try {
                // Extract depth information
                val width = depthImage.width
                val height = depthImage.height
                val plane = depthImage.planes[0]
                val buffer = plane.buffer
                
                // Convert depth data to a list of millimeter values
                val depthData = mutableListOf<Int>()
                buffer.rewind()
                while (buffer.remaining() >= 2) {
                    val depthMm = buffer.short.toInt() and 0xFFFF
                    depthData.add(depthMm)
                }
                
                result.success(mapOf(
                    "width" to width,
                    "height" to height,
                    "depthData" to depthData,
                    "format" to "millimeters"
                ))
                
                Log.d(TAG, "✅ Depth image acquired: ${width}x${height}, ${depthData.size} depth values")
            } finally {
                depthImage.close()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error acquiring depth image", e)
            result.error("DEPTH_ERROR", e.message, null)
        }
    }

    // ------------------------------------------------------------------------
    // Advanced cleanup methods
    // ------------------------------------------------------------------------

    private fun softResetSession(removeAnchors: Boolean, resetTracking: Boolean) {
        Log.d(TAG, "🔄 Soft reset session - removeAnchors: $removeAnchors, resetTracking: $resetTracking")
        
        uiHandler.post {
            try {
                if (removeAnchors) {
                    // Clear all anchors
                    anchorRecords.values.forEach { record ->
                        runCatching {
                            record.anchor.detach()
                            record.node.destroy()
                        }
                    }
                    anchorRecords.clear()
                    
                    // Clear nodes
                    nodeRecords.values.forEach { record ->
                        runCatching { record.node.destroy() }
                    }
                    nodeRecords.clear()
                }
                
                if (resetTracking) {
                    // Reset AR tracking by pausing and resuming
                    sceneView.session?.pause()
                    sceneView.session?.resume()
                    Log.d(TAG, "✅ AR tracking reset")
                }
                
                // Clear plane tracking
                seenPlanes.clear()
                
                Log.d(TAG, "✅ Soft reset complete")
            } catch (t: Throwable) {
                Log.e(TAG, "❌ Error during soft reset", t)
            }
        }
    }

    private fun nukeAll(purgeCaches: Boolean, removeAnchors: Boolean, resetTracking: Boolean) {
        Log.d(TAG, "💣 NUKE ALL - purgeCaches: $purgeCaches, removeAnchors: $removeAnchors, resetTracking: $resetTracking")
        
        uiHandler.post {
            try {
                // Phase 1: Clear all nodes (deep cleanup)
                Log.d(TAG, "Phase 1: Clearing nodes")
                nodeRecords.values.forEach { record ->
                    runCatching {
                        // Destroy node (SceneView handles resource cleanup)
                        record.node.destroy()
                    }
                }
                nodeRecords.clear()
                
                // Phase 2: Clear all anchors
                if (removeAnchors) {
                    Log.d(TAG, "Phase 2: Clearing anchors")
                    anchorRecords.values.forEach { record ->
                        runCatching {
                            record.anchor.detach()
                            record.node.destroy()
                        }
                    }
                    anchorRecords.clear()
                }
                
                // Phase 3: Clear tracking data
                Log.d(TAG, "Phase 3: Clearing tracking data")
                seenPlanes.clear()
                
                // Phase 4: Reset AR session
                if (resetTracking) {
                    Log.d(TAG, "Phase 4: Resetting AR session")
                    val session = sceneView.session
                    session?.pause()
                    session?.resume()
                }
                
                // Phase 5: Clear caches and force GC
                if (purgeCaches) {
                    Log.d(TAG, "Phase 5: Purging caches")
                    // SceneView manages its own caches, but we can suggest GC
                    System.gc()
                }
                
                Log.d(TAG, "✅ NUKE ALL complete")
            } catch (t: Throwable) {
                Log.e(TAG, "❌ Error during nuke all", t)
            }
        }
    }

    private fun removeAllNodes() {
        Log.d(TAG, "🗑️ Removing all nodes")
        nodeRecords.values.forEach { record ->
            runCatching { record.node.destroy() }
        }
        nodeRecords.clear()
        Log.d(TAG, "✅ All nodes removed")
    }

    private fun getPluginState(): Map<String, Any> {
        return mapOf(
            "isDisposed" to isDisposed,
            "nodeCount" to nodeRecords.size,
            "anchorCount" to anchorRecords.size,
            "planeCount" to seenPlanes.size,
            "isSessionActive" to (sceneView.session != null),
            "isSessionTracking" to (sceneView.frame?.camera?.trackingState == TrackingState.TRACKING)
        )
    }

    // ------------------------------------------------------------------------
    // Data classes & helpers
    // ------------------------------------------------------------------------

    private data class AnchorRecord(
        val id: String,
        var anchor: Anchor,  // var to allow updating during pan gestures
        val node: AnchorNode
    )

    private data class NodeRecord(
        val id: String,
        val node: ModelNode,
        val anchorId: String?,
        val isTransformable: Boolean,
        val enablePan: Boolean,
        val enableRotation: Boolean
    )

    /**
     * Find the NodeRecord for a given Node
     * This checks both ModelNode (child) and AnchorNode (parent) since gestures can be on either
     */
    private fun findNodeRecord(node: Node): NodeRecord? {
        // Check if it's a ModelNode directly
        val modelNodeRecord = nodeRecords.values.firstOrNull { it.node == node }
        if (modelNodeRecord != null) return modelNodeRecord
        
        // Check if it's an AnchorNode parent of a ModelNode
        val anchorNodeRecord = nodeRecords.values.firstOrNull { record ->
            record.anchorId?.let { anchorId ->
                anchorRecords[anchorId]?.node == node
            } ?: false
        }
        return anchorNodeRecord
    }

    private fun listToFloatArray(values: List<*>): FloatArray =
        FloatArray(values.size) { index ->
            (values[index] as Number).toFloat()
        }

    private fun listToFloatArray3(values: List<*>): FloatArray =
        FloatArray(3) { index ->
            (values[index] as Number).toFloat()
        }

    private fun parseTransform(
        matrix: FloatArray,
        scaleOverride: FloatArray?
    ): Triple<Position, dev.romainguy.kotlin.math.Quaternion, Scale> {
        val scale = extractScale(matrix, scaleOverride)
        val rotationMatrix = FloatArray(16)
        matrix.copyInto(rotationMatrix)
        normalizeRotation(rotationMatrix, scale)
        val quaternion = rotationMatrixToQuaternion(rotationMatrix)
        val position = Position(matrix[12], matrix[13], matrix[14])
        return Triple(position, quaternion, Scale(scale[0], scale[1], scale[2]))
    }

    private fun extractScale(matrix: FloatArray, override: FloatArray?): FloatArray {
        override?.let { return it }
        val scaleX = vectorLength(matrix[0], matrix[1], matrix[2])
        val scaleY = vectorLength(matrix[4], matrix[5], matrix[6])
        val scaleZ = vectorLength(matrix[8], matrix[9], matrix[10])
        return floatArrayOf(max(scaleX, 1e-6f), max(scaleY, 1e-6f), max(scaleZ, 1e-6f))
    }

    private fun normalizeRotation(matrix: FloatArray, scale: FloatArray) {
        matrix[0] /= scale[0]; matrix[1] /= scale[0]; matrix[2] /= scale[0]
        matrix[4] /= scale[1]; matrix[5] /= scale[1]; matrix[6] /= scale[1]
        matrix[8] /= scale[2]; matrix[9] /= scale[2]; matrix[10] /= scale[2]
    }

    private fun rotationMatrixToQuaternion(matrix: FloatArray): dev.romainguy.kotlin.math.Quaternion {
        val m00 = matrix[0]; val m11 = matrix[5]; val m22 = matrix[10]
        val m01 = matrix[4]; val m02 = matrix[8]; val m10 = matrix[1]
        val m12 = matrix[9]; val m20 = matrix[2]; val m21 = matrix[6]

        val trace = m00 + m11 + m22
        val q = FloatArray(4)

        if (trace > 0f) {
            val s = sqrt(trace + 1.0f) * 2f
            q[3] = 0.25f * s
            q[0] = (m21 - m12) / s
            q[1] = (m02 - m20) / s
            q[2] = (m10 - m01) / s
        } else if (m00 > m11 && m00 > m22) {
            val s = sqrt(1.0f + m00 - m11 - m22) * 2f
            q[3] = (m21 - m12) / s
            q[0] = 0.25f * s
            q[1] = (m01 + m10) / s
            q[2] = (m02 + m20) / s
        } else if (m11 > m22) {
            val s = sqrt(1.0f + m11 - m00 - m22) * 2f
            q[3] = (m02 - m20) / s
            q[0] = (m01 + m10) / s
            q[1] = 0.25f * s
            q[2] = (m12 + m21) / s
        } else {
            val s = sqrt(1.0f + m22 - m00 - m11) * 2f
            q[3] = (m10 - m01) / s
            q[0] = (m02 + m20) / s
            q[1] = (m12 + m21) / s
            q[2] = 0.25f * s
        }

        return dev.romainguy.kotlin.math.Quaternion(q[0], q[1], q[2], q[3])
    }

    private fun vectorLength(x: Float, y: Float, z: Float): Float =
        sqrt(x * x + y * y + z * z)

    private fun matrixToPose(matrix: FloatArray): Pose {
        val scale = extractScale(matrix, null)
        val rotationMatrix = FloatArray(16)
        matrix.copyInto(rotationMatrix)
        normalizeRotation(rotationMatrix, scale)
        val quaternion = rotationMatrixToQuaternion(rotationMatrix)
        val translation = floatArrayOf(matrix[12], matrix[13], matrix[14])
        return Pose(translation, floatArrayOf(quaternion.x, quaternion.y, quaternion.z, quaternion.w))
    }

    private fun poseToList(pose: Pose): List<Double> {
        val matrix = FloatArray(16)
        pose.toMatrix(matrix, 0)
        return matrix.map { it.toDouble() }
    }

    private fun Plane.toMap(): Map<String, Any> {
        val pose = centerPose
        val matrix = FloatArray(16)
        pose.toMatrix(matrix, 0)
        return mapOf(
            "identifier" to hashCode().toString(),
            "type" to type.name.lowercase(),
            "alignment" to when (type) {
                Plane.Type.VERTICAL -> "vertical"
                else -> "horizontal"
            },
            "center" to mapOf(
                "x" to pose.tx().toDouble(),
                "y" to pose.ty().toDouble(),
                "z" to pose.tz().toDouble()
            ),
            "extent" to mapOf(
                "width" to extentX.toDouble(),
                "height" to extentZ.toDouble()
            ),
            "transform" to matrix.map { it.toDouble() }
        )
    }
    
    /**
     * Calculate 3D world position by intersecting camera ray with horizontal plane.
     * This bypasses ARCore's hit test system which has proven unreliable in many environments.
     * 
     * @param touchX Absolute screen X coordinate
     * @param touchY Absolute screen Y coordinate
     * @param targetHeight Y-coordinate of the horizontal plane to intersect
     * @return 3D world position or null if calculation fails
     */
    private fun calculateRayPlaneIntersection(touchX: Float, touchY: Float, targetHeight: Float): Position? {
        // CRITICAL: Prevent access during disposal to avoid camera session crashes
        if (isDisposed) return null
        
        try {
            // Use current frame from rendering loop, DON'T call session.update()!
            val frame = sceneView.frame ?: return null
            val camera = frame.camera
            
            if (camera.trackingState != TrackingState.TRACKING) {
                return null
            }
            
            // Get view dimensions
            val viewWidth = sceneView.width.toFloat()
            val viewHeight = sceneView.height.toFloat()
            
            if (viewWidth <= 0f || viewHeight <= 0f) return null
            
            // Get camera pose and intrinsics
            val cameraPose = camera.pose
            val cameraTranslation = cameraPose.translation
            
            // Get camera intrinsics (focal length and principal point)
            val intrinsics = camera.textureIntrinsics
            val focalLength = intrinsics.focalLength // [fx, fy]
            val principalPoint = intrinsics.principalPoint // [cx, cy]
            
            // Convert screen coordinates to camera ray using intrinsics directly
            // Normalized image coordinates (relative to principal point and focal length)
            val normX = (touchX - principalPoint[0]) / focalLength[0]
            val normY = (touchY - principalPoint[1]) / focalLength[1]
            
            Log.d(TAG, "📐 normX=${"%.3f".format(normX)}, normY=${"%.3f".format(normY)} | touch=($touchX, $touchY)")
            
            // Get camera transformation matrix (column-major order)
            val cameraMatrix = FloatArray(16)
            cameraPose.toMatrix(cameraMatrix, 0)
            
            // Extract camera basis vectors from transformation matrix
            // Matrix is column-major: columns are [right, up, -forward, translation]
            // In camera space: X=right, Y=down (image coords), Z=forward (into scene)
            val rightX = cameraMatrix[0]
            val rightY = cameraMatrix[1]
            val rightZ = cameraMatrix[2]
            
            val upX = cameraMatrix[4]
            val upY = cameraMatrix[5]
            val upZ = cameraMatrix[6]
            
            // Forward is -Z axis (camera looks down -Z)
            val forwardX = -cameraMatrix[8]
            val forwardY = -cameraMatrix[9]
            val forwardZ = -cameraMatrix[10]
            
            Log.d(TAG, "🎥 right=(${"%.2f".format(rightX)}, ${"%.2f".format(rightY)}, ${"%.2f".format(rightZ)})")
            Log.d(TAG, "🎥 up=(${"%.2f".format(upX)}, ${"%.2f".format(upY)}, ${"%.2f".format(upZ)})")
            Log.d(TAG, "🎥 forward=(${"%.2f".format(forwardX)}, ${"%.2f".format(forwardY)}, ${"%.2f".format(forwardZ)})")
            
            // Project camera right vector onto horizontal plane (Y=0)
            val groundRightX = rightX
            val groundRightZ = rightZ
            val groundRightLen = sqrt(groundRightX * groundRightX + groundRightZ * groundRightZ)
            val normalizedGroundRightX = if (groundRightLen > 0.001f) groundRightX / groundRightLen else 1f
            val normalizedGroundRightZ = if (groundRightLen > 0.001f) groundRightZ / groundRightLen else 0f
            
            // Project camera forward vector onto horizontal plane  
            val groundForwardX = forwardX
            val groundForwardZ = forwardZ
            val groundForwardLen = sqrt(groundForwardX * groundForwardX + groundForwardZ * groundForwardZ)
            val normalizedGroundForwardX = if (groundForwardLen > 0.001f) groundForwardX / groundForwardLen else 0f
            val normalizedGroundForwardZ = if (groundForwardLen > 0.001f) groundForwardZ / groundForwardLen else -1f
            
            // Calculate ray direction using ONLY ground-projected vectors
            // This ensures movement is parallel to the ground plane
            // Screen X → ground right, Screen Y → ground forward
            val rayDirX = (normalizedGroundRightX * normX) + (normalizedGroundForwardX * -normY)
            val rayDirZ = (normalizedGroundRightZ * normX) + (normalizedGroundForwardZ * -normY)
            
            // Y component: ray must point from camera to plane
            // Use a small downward component to ensure intersection
            val rayDirY = -0.1f  // Always point slightly downward
            
            // Normalize ray direction
            val rayLength = sqrt(rayDirX * rayDirX + rayDirY * rayDirY + rayDirZ * rayDirZ)
            val normalizedRayX = rayDirX / rayLength
            val normalizedRayY = rayDirY / rayLength
            val normalizedRayZ = rayDirZ / rayLength
            
            // Check if ray is nearly parallel to plane
            if (abs(normalizedRayY) < 0.0001f) {
                return null
            }
            
            // Calculate intersection with horizontal plane at targetHeight
            val rayOriginY = cameraTranslation[1]
            val t = (targetHeight - rayOriginY) / normalizedRayY
            
            // Allow intersection slightly behind camera
            if (t < -0.1f) {
                return null
            }
            
            // Calculate intersection point
            val hitX = cameraTranslation[0] + normalizedRayX * t
            val hitY = targetHeight
            val hitZ = cameraTranslation[2] + normalizedRayZ * t
            
            // No distance limit here - we need ray intersections for delta calculation
            // Distance limiting happens in the pan gesture handler on the FINAL position
            
            return Position(hitX, hitY, hitZ)
            
        } catch (e: Exception) {
            Log.e(TAG, "Ray-plane intersection failed: ${e.message}")
            return null
        }
    }
}
