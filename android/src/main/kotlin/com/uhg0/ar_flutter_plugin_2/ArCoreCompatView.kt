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
import com.google.android.filament.Texture
import java.nio.ByteBuffer
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
import io.github.sceneview.gesture.ScaleGestureDetector
import io.github.sceneview.math.Position
import io.github.sceneview.math.Scale
import io.github.sceneview.math.quaternion
import io.github.sceneview.math.toColumnsFloatArray
import io.github.sceneview.node.ModelNode
import io.github.sceneview.node.Node
import kotlinx.coroutines.CoroutineExceptionHandler
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
    private val lifecycle: Lifecycle,
    // Optional: reuse a cached SceneView instead of creating new one
    cachedSceneViewArg: ARSceneView? = null
) : PlatformView {

    companion object {
        private const val TAG = "SceneViewCompat"

        // ── Lighting intensity caps ──────────────────────────────────────────
        // ARCore's ENVIRONMENTAL_HDR mode updates indirectLightEstimated and
        // mainLightEstimatedNode every frame.  In bright outdoor/indoor scenes
        // these values can reach 100,000+ lux, blowing out the top surfaces of
        // models to solid white.  We cap them after SceneView's estimator has
        // written the frame so ENVIRONMENTAL_HDR keeps working normally.
        private const val MAX_INDIRECT_LIGHT_INTENSITY = 15_000f   // lux – IBL / ambient
        private const val MAX_DIRECTIONAL_LIGHT_INTENSITY = 40_000f // lux – main sun light
        // Only enforce caps every N frames to minimise Filament state writes
        private const val LIGHT_CAP_FRAME_INTERVAL = 2
    }

    private val uiHandler = Handler(Looper.getMainLooper())
    
    // CRITICAL FIX: Add exception handler to coroutine scope to prevent crashes
    // from background coroutines that access disposed camera/session resources
    private val coroutineExceptionHandler = CoroutineExceptionHandler { _: kotlin.coroutines.CoroutineContext, throwable: Throwable ->
        val errorMessage = throwable.message?.lowercase() ?: ""
        val stackTrace = throwable.stackTraceToString()
        
        // Check if this is an expected camera/session exception.
        // CameraAccessException explicit type check is R8/obfuscation-safe and covers
        // the "createDefaultRequest template 3 not implemented" crash from the camera HAL.
        val isCameraException = throwable is android.hardware.camera2.CameraAccessException ||
            (throwable is IllegalStateException &&
                (errorMessage.contains("session") || errorMessage.contains("camera") || errorMessage.contains("closed")))
        val isCameraStackTrace = stackTrace.contains("CameraCaptureSession") ||
            stackTrace.contains("stopRepeating") || stackTrace.contains("Camera")
        
        if (isCameraException || isCameraStackTrace) {
            Log.w(TAG, "🔇 Suppressing camera exception in coroutine (expected during lifecycle): ${throwable.message}")
        } else if (isDisposed) {
            Log.w(TAG, "⚠️ Exception in coroutine after dispose (ignoring): ${throwable.message}")
        } else {
            Log.e(TAG, "❌ Unexpected exception in coroutine", throwable)
            // Don't rethrow - let it be logged but don't crash the app
        }
    }
    
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate + coroutineExceptionHandler)

    private val container = FrameLayout(context)
    private val sceneView: ARSceneView
    
    // Track if we're reusing a cached SceneView
    private val isReusingCachedView: Boolean
    
    // Lifecycle observer to detect background transitions and cache SceneView
    private var lifecycleObserver: androidx.lifecycle.LifecycleEventObserver? = null

    private val sessionChannel = MethodChannel(messenger, "arsession_$viewId")
    private val objectChannel = MethodChannel(messenger, "arobjects_$viewId")
    private val anchorChannel = MethodChannel(messenger, "aranchors_$viewId")

    private val anchorRecords = ConcurrentHashMap<String, AnchorRecord>()
    private val nodeRecords = ConcurrentHashMap<String, NodeRecord>()

    private val seenPlanes = mutableSetOf<String>()
    private var environmentInitialized = false
    private var isDisposed = false
    // Frame counter used to throttle per-frame light-cap enforcement
    private var lightCapFrameCount = 0
    
    // CRITICAL FIX: Track when the native session/engine has been destroyed
    // This prevents SIGSEGV crashes when calling session.pause() on a destroyed session
    @Volatile
    private var sessionDestroyed = false
    
    // Track our creation sequence to detect stale dispose calls
    private var creationSequence: Long = 0L
    
    // Manual pan gesture tracking (bypassing SceneView's failing hit test system)
    private var panStartY = 0f
    private var panStartWorldPos: Position? = null
    private var panStartTouchX = 0f
    private var panStartTouchY = 0f
    private var currentTouchX = 0f  // Track absolute touch position
    private var currentTouchY = 0f
    
    // Scale gesture blocking - store original scale to force reset
    private var originalScaleWhenBlocked: Scale? = null
    
    // Rotation-scale interference detection
    private var rotationStartScale: Scale? = null
    private var rotationStartWorldY: Float? = null
    private var currentlyRotatingNode: Node? = null  // Track node being rotated for per-frame scale enforcement
    
    // CRITICAL: Track if we're in a multi-touch gesture to aggressively block scale
    private var activePointerCount = 0
    private var isRotationActive = false  // Flag to track active rotation state
    
    // Depth occlusion state tracking (SceneView handles this automatically when depth is enabled)
    // We just track the state for the Flutter API
    private var depthOcclusionEnabled = true  // Enabled by default when depth mode is AUTOMATIC
    
    // Configurable gesture settings (set at init time only)
    private var debugGesturesEnabled = false  // Enable verbose gesture logging for development
    private var maxPanDistanceMeters = 5.0f   // Maximum distance from camera for pan gestures (default 5m)

    init {
        // Check if we're reusing a cached SceneView from background transition
        if (cachedSceneViewArg != null) {
            Log.d(TAG, "♻️ REUSING cached SceneView - preserving AR session!")
            isReusingCachedView = true
            sceneView = cachedSceneViewArg
            
            // Remove from old parent if any
            (sceneView.parent as? android.view.ViewGroup)?.removeView(sceneView)
            
            // Reattach to our new container
            sceneView.layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
            
            // Update lifecycle reference
            sceneView.lifecycle = lifecycle
            
            // Resume the session if paused
            try {
                sceneView.session?.resume()
                Log.d(TAG, "▶️ Cached SceneView session resumed")
            } catch (e: Exception) {
                Log.e(TAG, "Error resuming cached session", e)
            }
        } else {
            isReusingCachedView = false
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
            }
        }
        
        // Install lifecycle observer to detect when app goes to background
        // This is CRITICAL - Flutter doesn't call dispose() during background transitions
        // Use the Flutter-provided lifecycle parameter directly
        Log.d(TAG, "🔍 Installing lifecycle observer:")
        Log.d(TAG, "   lifecycle (flutter param) = $lifecycle")
        Log.d(TAG, "   activity = $activity")
        Log.d(TAG, "   context = ${context.javaClass.name}")
        
        lifecycleObserver = androidx.lifecycle.LifecycleEventObserver { _, event ->
            Log.d(TAG, "🔄 Lifecycle event: $event (anchorRecords=${anchorRecords.size}, nodeRecords=${nodeRecords.size})")
            when (event) {
                androidx.lifecycle.Lifecycle.Event.ON_PAUSE -> {
                    Log.d(TAG, "⏸️ App going to background - session will be paused by dispose()")
                }
                androidx.lifecycle.Lifecycle.Event.ON_RESUME -> {
                    Log.d(TAG, "▶️ App resumed from background - resuming session")
                    
                    // Resume the AR session if it was paused
                    try {
                        sceneView.session?.resume()
                        Log.d(TAG, "✅ AR session resumed - camera should restart")
                    } catch (e: Exception) {
                        Log.e(TAG, "❌ Error resuming session", e)
                    }
                }
                else -> {}
            }
        }
        lifecycle.addObserver(lifecycleObserver!!)
        Log.d(TAG, "👀 Lifecycle observer installed on Flutter lifecycle - will detect background transitions")

        // CRITICAL FIX: Detect when the SurfaceView is detached from the window hierarchy.
        // SceneView auto-destroys its Filament engine + EGL context when the SurfaceView is
        // detached. This happens BEFORE Flutter calls dispose(), so we must mark the session
        // destroyed here to prevent safelyPauseSession() from calling session.pause() on an
        // already-destroyed EGL context (which causes a native SIGABRT).
        sceneView.addOnAttachStateChangeListener(object : android.view.View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(v: android.view.View) {
                Log.d(TAG, "🔗 SceneView attached to window")
            }
            override fun onViewDetachedFromWindow(v: android.view.View) {
                Log.d(TAG, "🔌 SceneView detached from window - marking session as destroyed to prevent EGL crash")
                sessionDestroyed = true
            }
        })

        // Setup callbacks for BOTH new and reused SceneViews
        sceneView.apply {
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
                            if (debugGesturesEnabled) {
                                Log.d(TAG, "🔥 Pan started - Y=$panStartY, Touch: ($currentTouchX, $currentTouchY)")
                            }
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
                        // Debug: Log available planes in the scene
                        if (debugGesturesEnabled) {
                            val frame = sceneView.frame
                            val session = sceneView.session
                            if (frame != null && session != null) {
                                val planes = session.getAllTrackables(Plane::class.java)
                                val horizontalCount = planes.count { it.type == Plane.Type.HORIZONTAL_UPWARD_FACING || it.type == Plane.Type.HORIZONTAL_DOWNWARD_FACING }
                                val verticalCount = planes.count { it.type == Plane.Type.VERTICAL }
                                Log.d(TAG, "📊 Available planes: $horizontalCount horizontal, $verticalCount vertical (total: ${planes.size})")
                            }
                        }
                        
                        // Use ARCore hit testing to project touch position onto ANY detected plane
                        // This allows objects to snap to walls (vertical) or floors (horizontal)
                        // mimicking iOS behavior where objects automatically transition between surfaces
                        val hitResult = sceneView.hitTestAR(
                            xPx = currentTouchX,
                            yPx = currentTouchY,
                            planeTypes = setOf(
                                Plane.Type.HORIZONTAL_UPWARD_FACING,
                                Plane.Type.HORIZONTAL_DOWNWARD_FACING,
                                Plane.Type.VERTICAL  // Enable wall/vertical surface snapping
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
                            
                            // Determine if we hit a vertical or horizontal plane
                            val trackable = hitResult.trackable
                            val isVerticalPlane = trackable is Plane && trackable.type == Plane.Type.VERTICAL
                            
                            // For vertical planes: use full hit position (allows movement along wall)
                            // For horizontal planes: can optionally lock Y height
                            val newWorldPos = if (isVerticalPlane) {
                                // Full 3D position for wall-mounted objects
                                Position(hitTranslation[0], hitTranslation[1], hitTranslation[2])
                            } else {
                                // For horizontal surfaces, use hit X/Z but preserve some height behavior
                                // Use hit Y position to allow transitioning between different height surfaces
                                Position(hitTranslation[0], hitTranslation[1], hitTranslation[2])
                            }
                            
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
                                
                                if (distance <= maxPanDistanceMeters) {
                                    record.node.worldPosition = newWorldPos
                                    
                                    // Update the current plane type for the node (used later for anchor creation)
                                    record.currentPlaneType = if (isVerticalPlane) Plane.Type.VERTICAL else Plane.Type.HORIZONTAL_UPWARD_FACING
                                    
                                    if (debugGesturesEnabled) {
                                        val planeTypeStr = if (isVerticalPlane) "VERTICAL (wall)" else "HORIZONTAL (floor/ceiling)"
                                        Log.d(TAG, "🎯 Hit-test pan → $planeTypeStr | World Pos: (%.3f, %.3f, %.3f) | Dist: %.2fm".format(
                                            newWorldPos.x, newWorldPos.y, newWorldPos.z, distance
                                        ))
                                    }
                                } else {
                                    if (debugGesturesEnabled) {
                                        Log.d(TAG, "⚠️ Position too far: ${distance}m (max ${maxPanDistanceMeters}m) - ignoring")
                                    }
                                }
                            }
                        } else {
                            if (debugGesturesEnabled) {
                                Log.d(TAG, "⚠️ No hit result - pan ignored")
                            }
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
                                
                                // Do a final hit test to get the proper anchor pose
                                // This ensures proper orientation for vertical surfaces
                                val hitResult = sceneView.hitTestAR(
                                    xPx = currentTouchX,
                                    yPx = currentTouchY,
                                    planeTypes = setOf(
                                        Plane.Type.HORIZONTAL_UPWARD_FACING,
                                        Plane.Type.HORIZONTAL_DOWNWARD_FACING,
                                        Plane.Type.VERTICAL
                                    ),
                                    point = true,
                                    depthPoint = true,
                                    pointOrientationModes = setOf(Point.OrientationMode.ESTIMATED_SURFACE_NORMAL)
                                )
                                
                                val newAnchor = if (hitResult != null) {
                                    // Use the hit result's anchor if available, or create from pose
                                    // This preserves proper orientation for the surface
                                    val trackable = hitResult.trackable
                                    val isVerticalPlane = trackable is Plane && trackable.type == Plane.Type.VERTICAL
                                    
                                    if (isVerticalPlane) {
                                        // For vertical planes, create anchor at hit pose to preserve wall orientation
                                        hitResult.createAnchor()
                                    } else {
                                        // For horizontal planes, use simple translation
                                        val pose = Pose.makeTranslation(worldPos.x, worldPos.y, worldPos.z)
                                        session.createAnchor(pose)
                                    }
                                } else {
                                    // Fallback: simple translation anchor
                                    val pose = Pose.makeTranslation(worldPos.x, worldPos.y, worldPos.z)
                                    session.createAnchor(pose)
                                }
                                
                                // Update the anchor node
                                val anchorRec = record.anchorId?.let { anchorRecords[it] }
                                if (anchorRec != null) {
                                    anchorRec.anchor.detach()
                                    anchorRec.anchor = newAnchor
                                    anchorRec.node.anchor = newAnchor
                                    
                                    // Reset ModelNode to center of new anchor
                                    record.node.position = Position(0f, 0f, 0f)
                                    
                                    val planeTypeStr = record.currentPlaneType?.let {
                                        if (it == Plane.Type.VERTICAL) "VERTICAL (wall)" else "HORIZONTAL"
                                    } ?: "unknown"
                                    Log.d(TAG, "✅ Created new anchor at (${worldPos.x}, ${worldPos.y}, ${worldPos.z}) on $planeTypeStr surface")
                                }
                                
                                // Reset the tracked plane type
                                record.currentPlaneType = null
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
                        // Check tracking state - don't start rotation if tracking is compromised
                        val trackingState = try { 
                            sceneView.frame?.camera?.trackingState 
                        } catch (_: Exception) { 
                            null 
                        }
                        
                        if (trackingState != null && trackingState != TrackingState.TRACKING) {
                            Log.w(TAG, "⚠️ Ignoring rotation start - tracking state is $trackingState")
                        } else {
                            // 🔥 CRITICAL: Set rotation active flag BEFORE storing scale
                            isRotationActive = true
                            
                            // Store initial LOCAL scale (not world scale!) for interference detection
                            // World scale changes during rotation due to parent transform hierarchy
                            rotationStartScale = node.scale  // LOCAL scale stays constant
                            rotationStartWorldY = node.worldPosition.y
                            currentlyRotatingNode = node  // Track for per-frame enforcement
                            
                            // 🔍 DEBUG: Log parent scale too to see if anchor is being scaled
                            val parentScale = node.parent?.scale
                            Log.d(
                                TAG,
                                "🔄 onRotateBegin for node: ${node.name}, isRotationEditable: ${node.isRotationEditable}, " +
                                "worldPos=(${node.worldPosition.x.format()}, ${node.worldPosition.y.format()}, ${node.worldPosition.z.format()}), " +
                                "localScale=(${node.scale.x.format()}, ${node.scale.y.format()}, ${node.scale.z.format()}), " +
                                "parentScale=${parentScale?.let { "(${it.x.format()}, ${it.y.format()}, ${it.z.format()})" } ?: "null"}"
                            )
                            handleGestureEvent("onRotationStart", node)
                        }
                    }
                },
                onRotate = { _: RotateGestureDetector, _: MotionEvent, node: Node? ->
                    val record = node?.let(::findNodeRecord)
                    if (node != null && record?.enableRotation == true) {
                        // 🔥 CRITICAL: ALWAYS protect scale during rotation - regardless of enableScale setting
                        // Scale should NEVER change during rotation gesture
                        rotationStartScale?.let { startScale ->
                            val currentScale = node.scale  // LOCAL scale
                            val scaleChanged = abs(currentScale.x - startScale.x) > 0.001f ||
                                              abs(currentScale.y - startScale.y) > 0.001f ||
                                              abs(currentScale.z - startScale.z) > 0.001f
                            if (scaleChanged) {
                                node.scale = startScale  // Reset LOCAL scale
                                Log.w(TAG, "🔄 Scale drift during rotation! Reset to $startScale (was $currentScale)")
                            }
                        }
                        
                        // CRITICAL: Force reset Y position if it changed during rotation
                        rotationStartWorldY?.let { startY ->
                            val currentY = node.worldPosition.y
                            if (abs(currentY - startY) > 0.005f) {  // More than 5mm drift
                                node.worldPosition = Position(node.worldPosition.x, startY, node.worldPosition.z)
                            }
                        }
                        
                        handleGestureEvent("onRotationChange", node)
                    }
                },
                onRotateEnd = { _: RotateGestureDetector, _: MotionEvent, node: Node? ->
                    val record = node?.let(::findNodeRecord)
                    if (node != null && record?.enableRotation == true) {
                        // Check LOCAL scale - should NEVER change during pure rotation
                        val finalScale = node.scale  // LOCAL scale
                        val finalWorldY = node.worldPosition.y
                        
                        val scaleChanged = rotationStartScale?.let { startScale ->
                            abs(finalScale.x - startScale.x) > 0.01f ||
                            abs(finalScale.y - startScale.y) > 0.01f ||
                            abs(finalScale.z - startScale.z) > 0.01f
                        } ?: false
                        
                        val yPositionChanged = rotationStartWorldY?.let { startY ->
                            abs(finalWorldY - startY) > 0.01f  // More than 1cm change
                        } ?: false
                        
                        if (scaleChanged) {
                            Log.w(TAG, "⚠️ ROTATION-SCALE INTERFERENCE DETECTED! Local scale changed from $rotationStartScale to $finalScale")
                            // RESTORE original LOCAL scale
                            rotationStartScale?.let { node.scale = it }
                            Log.d(TAG, "🔧 Restored local scale to: $rotationStartScale")
                        }
                        if (yPositionChanged) {
                            Log.w(TAG, "⚠️ Y-JUMP DETECTED during rotation! Y changed from $rotationStartWorldY to $finalWorldY (delta: ${finalWorldY - (rotationStartWorldY ?: 0f)})")
                            // RESTORE original Y position
                            rotationStartWorldY?.let { startY ->
                                node.worldPosition = Position(node.worldPosition.x, startY, node.worldPosition.z)
                            }
                            Log.d(TAG, "🔧 Restored Y position to: $rotationStartWorldY")
                        }
                        
                        // 🔍 DEBUG: Log parent scale too to see if anchor is being scaled
                        val parentScale = node.parent?.scale
                        val worldScale = node.worldScale
                        Log.d(
                            TAG,
                            "🔄 onRotateEnd for node: ${node.name}, " +
                            "finalPos=(${node.worldPosition.x.format()}, ${node.worldPosition.y.format()}, ${node.worldPosition.z.format()}), " +
                            "finalLocalScale=(${finalScale.x.format()}, ${finalScale.y.format()}, ${finalScale.z.format()}), " +
                            "worldScale=(${worldScale.x.format()}, ${worldScale.y.format()}, ${worldScale.z.format()}), " +
                            "parentScale=${parentScale?.let { "(${it.x.format()}, ${it.y.format()}, ${it.z.format()})" } ?: "null"}"
                        )
                        
                        // 🔥 CRITICAL: Also reset parent scale if it changed!
                        node.parent?.let { parent ->
                            val parentScaleVal = parent.scale
                            if (abs(parentScaleVal.x - 1f) > 0.01f ||
                                abs(parentScaleVal.y - 1f) > 0.01f ||
                                abs(parentScaleVal.z - 1f) > 0.01f) {
                                Log.w(TAG, "⚠️ PARENT SCALE CHANGED! Resetting from $parentScaleVal to (1,1,1)")
                                parent.scale = Scale(1f, 1f, 1f)
                            }
                        }
                        
                        // 🔥 CRITICAL: Final scale correction - force restore scale multiple times
                        // SceneView may apply scale changes AFTER our callback returns
                        val savedNode = node
                        val savedScale = rotationStartScale
                        
                        rotationStartScale?.let { targetScale ->
                            node.scale = targetScale
                            Log.d(TAG, "🔒 Final scale lock applied: $targetScale")
                        }
                        
                        // 🔥 AGGRESSIVE DELAYED SCALE LOCK: Force scale many times over 1 second
                        // This catches any delayed SceneView scale application
                        savedScale?.let { targetScale ->
                            // Multiple rapid resets in the first 100ms
                            for (delay in listOf(16L, 32L, 50L, 66L, 83L, 100L)) {
                                uiHandler.postDelayed({
                                    if (!isDisposed && savedNode.parent != null) {
                                        savedNode.scale = targetScale
                                    }
                                }, delay)
                            }
                            // Slower resets over the next second
                            for (delay in listOf(150L, 200L, 300L, 500L, 750L, 1000L)) {
                                uiHandler.postDelayed({
                                    if (!isDisposed && savedNode.parent != null) {
                                        val currentScale = savedNode.scale
                                        val needsReset = abs(currentScale.x - targetScale.x) > 0.001f ||
                                                        abs(currentScale.y - targetScale.y) > 0.001f ||
                                                        abs(currentScale.z - targetScale.z) > 0.001f
                                        if (needsReset) {
                                            savedNode.scale = targetScale
                                            Log.w(TAG, "🚨 Scale drift detected at ${delay}ms - reset to $targetScale (was $currentScale)")
                                        }
                                    }
                                }, delay)
                            }
                        }
                        
                        // Clear tracking variables
                        isRotationActive = false  // Clear rotation flag
                        currentlyRotatingNode = null  // Stop per-frame enforcement
                        rotationStartScale = null
                        rotationStartWorldY = null
                        
                        handleGestureEnd("onRotationEnd", node)
                    }
                },
                onScaleBegin = { _: ScaleGestureDetector, _: MotionEvent, node: Node? ->
                    // 🔥 CRITICAL: ALWAYS reject scale during rotation
                    if (isRotationActive) {
                        Log.w(TAG, "🚫 BLOCKED scale begin - rotation is active!")
                        // Force restore scale immediately
                        currentlyRotatingNode?.let { rotNode ->
                            rotationStartScale?.let { targetScale ->
                                rotNode.scale = targetScale
                            }
                        }
                        false  // Reject scale gesture completely
                    } else {
                        val record = node?.let(::findNodeRecord)
                        if (isDisposed) {
                            false
                        } else if (record?.enableScale == true) {
                            Log.d(TAG, "📏 Scale gesture allowed on node: ${node?.name}")
                            true  // Accept and allow scaling
                        } else {
                            // CRITICAL: Store original LOCAL scale when blocking gesture
                            node?.let {
                                originalScaleWhenBlocked = it.scale  // LOCAL scale
                            }
                            false  // Reject gesture - do not process scale
                        }
                    }
                },
                onScale = { detector: ScaleGestureDetector, _: MotionEvent, node: Node? ->
                    // 🔥 CRITICAL: ALWAYS reject scale during rotation
                    if (isRotationActive) {
                        // Force restore scale immediately
                        currentlyRotatingNode?.let { rotNode ->
                            rotationStartScale?.let { targetScale ->
                                rotNode.scale = targetScale
                            }
                        }
                        false  // Reject scale gesture completely
                    } else {
                        val record = node?.let(::findNodeRecord)
                        if (isDisposed) {
                            false
                        } else if (record?.enableScale == true) {
                            true  // Continue processing scale
                        } else {
                            // FORCE reset LOCAL scale if it changed despite being disabled
                            node?.let {
                                if (originalScaleWhenBlocked != null) {
                                    it.scale = originalScaleWhenBlocked!!  // LOCAL scale
                                }
                            }
                            false  // Reject scale updates
                        }
                    }
                },
                onScaleEnd = { _: ScaleGestureDetector, _: MotionEvent, node: Node? ->
                    // 🔥 CRITICAL: Always force reset scale at end if rotation was active
                    if (isRotationActive) {
                        currentlyRotatingNode?.let { rotNode ->
                            rotationStartScale?.let { targetScale ->
                                rotNode.scale = targetScale
                                Log.w(TAG, "🔒 Scale forced to $targetScale on scale end (rotation active)")
                            }
                        }
                        false
                    } else {
                        val record = node?.let(::findNodeRecord)
                        if (isDisposed) {
                            false
                        } else if (record?.enableScale == true) {
                            Log.d(TAG, "📏 Scale gesture ended on node: ${node?.name}")
                            originalScaleWhenBlocked = null  // Clear stored scale
                            true
                        } else {
                            // Final reset to ensure LOCAL scale didn't change
                            node?.let {
                                if (originalScaleWhenBlocked != null) {
                                    it.scale = originalScaleWhenBlocked!!  // LOCAL scale
                                }
                            }
                            originalScaleWhenBlocked = null  // Clear stored scale
                            false
                        }
                    }
                }
            )
        }

        // Environment loading will be handled lazily on first frame update to ensure
        // proper thread context and lifecycle state
        // DO NOT load environment here to avoid Filament threading issues

        container.addView(sceneView)
        
        // Setup touch listener for gesture coordinate tracking
        // This is extracted to a method so it can be re-applied after session resume
        setupTouchListener()

        sessionChannel.setMethodCallHandler(::handleSessionMethod)
        objectChannel.setMethodCallHandler(::handleObjectMethod)
        anchorChannel.setMethodCallHandler(::handleAnchorMethod)
    }

    // ------------------------------------------------------------------------
    // PlatformView contract
    // ------------------------------------------------------------------------

    override fun getView(): View = container

    /**
     * Force synchronous disposal of AR resources.
     * Called by ArSessionCoordinator before creating a new AR view.
     * This ensures all camera/session resources are fully released.
     * 
     * CRITICAL: All operations must handle the case where the camera session
     * is already closed due to race conditions in Camera2 API background threads.
     */
    fun forceDisposeSync() {
        if (isDisposed) return
        isDisposed = true
        
        Log.d(TAG, "🧹 FORCE SYNC DISPOSE - starting immediate cleanup")
        
        try {
            // Cancel method handlers immediately
            sessionChannel.setMethodCallHandler(null)
            objectChannel.setMethodCallHandler(null)
            anchorChannel.setMethodCallHandler(null)
            
            // Cancel coroutine scope FIRST to stop any background operations
            // This is critical to prevent in-flight coroutines from accessing disposed resources
            runCatching { 
                scope.cancel()
                Log.d(TAG, "🧹 Coroutine scope cancelled")
            }
            
            // Stop touch listener
            sceneView.setOnTouchListener(null)
            
            // Clear rotation tracking state
            currentlyRotatingNode = null
            rotationStartScale = null
            rotationStartWorldY = null
            isRotationActive = false
            
            // CRITICAL: Pause session SYNCHRONOUSLY with defensive exception handling
            // The Camera2 API may throw IllegalStateException if session is already closed
            // by background cleanup threads - this is expected and safe to ignore
            // CRITICAL FIX: Check view attachment AND engine validity to prevent SIGABRT on destroyed EGL
            if (!sessionDestroyed) {
                try {
                    Log.d(TAG, "🧹 SYNC Phase 1: Pausing AR session")
                    val session = sceneView.session
                    if (session != null) {
                        // CRITICAL: Check view attachment first - detached = EGL context destroyed
                        val isViewAttached = sceneView.isAttachedToWindow
                        val isEngineValid = isViewAttached && runCatching { sceneView.renderer != null }.getOrDefault(false)
                        if (isEngineValid) {
                            session.pause()
                            Log.d(TAG, "✅ Session paused successfully")
                        } else {
                            Log.w(TAG, "⚠️ Engine/EGL already destroyed (attached=$isViewAttached), skipping session pause")
                            sessionDestroyed = true
                        }
                    } else {
                        Log.d(TAG, "ℹ️ Session was already null")
                    }
                } catch (e: IllegalStateException) {
                    // Expected when session is already closed by Camera2 background threads
                    Log.w(TAG, "⚠️ Session pause threw IllegalStateException (expected): ${e.message}")
                    sessionDestroyed = true
                } catch (e: Exception) {
                    Log.w(TAG, "⚠️ Session pause threw unexpected exception: ${e.message}")
                    sessionDestroyed = true
                }
            } else {
                Log.w(TAG, "🧹 SYNC Phase 1: Skipping session pause (already destroyed)")
            }
            
            // Clear nodes synchronously
            Log.d(TAG, "🧹 SYNC Phase 2: Clearing nodes and anchors")
            nodeRecords.values.forEach { record ->
                runCatching { record.node.destroy() }
            }
            nodeRecords.clear()
            
            // Clear anchors synchronously
            anchorRecords.values.forEach { record ->
                runCatching { 
                    record.anchor.detach()
                    record.node.destroy()
                }
            }
            anchorRecords.clear()
            
            // Destroy SceneView synchronously with defensive exception handling
            Log.d(TAG, "🧹 SYNC Phase 3: Destroying SceneView")
            try {
                sceneView.destroy()
                Log.d(TAG, "✅ SceneView destroyed successfully")
            } catch (e: IllegalStateException) {
                // May occur if camera session was already closed
                Log.w(TAG, "⚠️ SceneView destroy threw IllegalStateException (expected): ${e.message}")
            } catch (e: Exception) {
                Log.w(TAG, "⚠️ SceneView destroy threw exception: ${e.message}")
            }
            
            // Unregister from coordinator
            ArSessionCoordinator.unregisterView(this)
            
            Log.d(TAG, "✅ FORCE SYNC DISPOSE complete")
            
        } catch (t: Throwable) {
            Log.e(TAG, "❌ Error during force sync dispose", t)
        } finally {
            // Signal the cleanup gate in prepareForNewView() regardless of success/failure.
            // This ensures the waiting thread is never stuck for the full timeout.
            ArSessionCoordinator.signalCleanupComplete()
        }
    }
    
    /**
     * Pause the session only - keep resources allocated.
     * Used for soft dispose during background transitions.
     * 
     * CRITICAL: Handle IllegalStateException gracefully as the camera session
     * may already be closed by Camera2 API background threads.
     */
    fun pauseSessionOnly() {
        Log.d(TAG, "⏸️ Pausing session only (keeping resources)")

        // CRITICAL FIX: Check session validity before pausing
        if (sessionDestroyed) {
            Log.w(TAG, "⚠️ Session already destroyed, skipping pause")
            return
        }

        // CRITICAL FIX: If the SurfaceView has been detached, EGL context is destroyed.
        if (!sceneView.isAttachedToWindow) {
            Log.w(TAG, "⚠️ SceneView detached from window - skipping session pause (EGL destroyed)")
            sessionDestroyed = true
            return
        }

        try {
            val session = sceneView.session
            if (session != null) {
                // Check engine validity
                val isEngineValid = runCatching { sceneView.renderer != null }.getOrDefault(false)
                if (!isEngineValid) {
                    Log.w(TAG, "⚠️ Engine destroyed, skipping session pause")
                    sessionDestroyed = true
                    return
                }

                session.pause()
                Log.d(TAG, "✅ Session paused")
            } else {
                Log.d(TAG, "ℹ️ Session was already null")
            }
        } catch (e: IllegalStateException) {
            Log.w(TAG, "⚠️ Session pause failed (expected if already closed): ${e.message}")
            sessionDestroyed = true
        } catch (e: Exception) {
            Log.w(TAG, "⚠️ Session pause threw unexpected exception: ${e.message}")
            sessionDestroyed = true
        }
    }
    
    /**
     * Resume the session after a soft dispose.
     * Used when app comes back from background.
     * 
     * CRITICAL: Handle exceptions gracefully as the session may be in an
     * inconsistent state after background transitions.
     */
    fun resumeSessionOnly() {
        Log.d(TAG, "▶️ Resuming session")
        try {
            val session = sceneView.session
            if (session != null) {
                session.resume()
                Log.d(TAG, "✅ Session resumed")
            } else {
                Log.w(TAG, "⚠️ Cannot resume - session is null")
            }
        } catch (e: IllegalStateException) {
            Log.e(TAG, "❌ Session resume failed (session may be closed): ${e.message}")
            notifySessionError("Session resume failed: ${e.message}")
        } catch (e: android.hardware.camera2.CameraAccessException) {
            Log.e(TAG, "❌ Session resume CameraAccessException: ${e.message}")
            notifySessionError("Camera access error resuming AR session: ${e.message}")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Session resume threw unexpected exception: ${e.message}")
            notifySessionError("AR session error: ${e.message}")
        }
    }

    /**
     * Send an error message to Flutter via the session channel.
     * Uses the existing \"onError\" method call already handled by ARSessionManager.
     * Must be called from any thread — posts to the main thread automatically.
     */
    private fun notifySessionError(message: String) {
        uiHandler.post {
            try {
                if (!isDisposed) {
                    sessionChannel.invokeMethod("onError", listOf(message))
                }
            } catch (e: Exception) {
                Log.w(TAG, "⚠️ Failed to send session error to Flutter: ${e.message}")
            }
        }
    }

    /**
     * Set the creation sequence number for this view.
     * Used to detect stale dispose calls from old views.
     */
    fun setCreationSequence(sequence: Long) {
        creationSequence = sequence
        Log.d(TAG, "📝 View creation sequence set to: $sequence")
    }
    
    /**
     * Check if this is a recoverable dispose (can cache SceneView for reuse).
     * A dispose is recoverable if:
     * - Activity is NOT finishing (user navigated away)
     * - We're not already disposed
     * - No new view is actively being created
     */
    private fun isRecoverableDispose(): Boolean {
        val activityFinishing = activity?.isFinishing ?: false
        val activityDestroyed = activity?.isDestroyed ?: false

        Log.d(TAG, "🔍 isRecoverableDispose check: finishing=$activityFinishing, destroyed=$activityDestroyed")

        // If activity is finishing or destroyed, this is NOT recoverable - full cleanup needed
        if (activityFinishing || activityDestroyed) {
            return false
        }

        // CRITICAL FIX: If the SceneView is already detached from the window, the Filament
        // engine and EGL context are already destroyed. This happens during Flutter route
        // navigation (activity is NOT finishing, so the old check missed this). Attempting
        // session.pause() in this state causes a native SIGABRT.
        if (!sceneView.isAttachedToWindow) {
            Log.d(TAG, "🔍 SceneView already detached from window - NOT recoverable (engine destroyed)")
            return false
        }

        // If the native session/engine was already destroyed (flagged by the attach listener
        // or a previous exception), treat as non-recoverable to avoid a double-pause attempt.
        if (sessionDestroyed) {
            Log.d(TAG, "🔍 sessionDestroyed flag set - NOT recoverable")
            return false
        }

        // Check if we're reusing a cached view - if so, we shouldn't re-cache
        if (isReusingCachedView) {
            Log.d(TAG, "🔍 Already using a cached view, can re-cache")
        }

        // Otherwise, this is likely a background transition - recoverable!
        return true
    }

    override fun dispose() {
        if (isDisposed) return
        
        Log.d(TAG, "📞 dispose() called - starting decision logic")
        
        // Check if a new view is being created - if so, skip disposal entirely
        // The new view will handle everything
        val newViewBeingCreated = ArSessionCoordinator.isNewViewBeingCreated()
        
        // Also check if we're still the active view - if not, a new view has taken over
        val isStillActiveView = ArSessionCoordinator.isActiveView(this)
        
        // Check if our creation sequence is stale (a newer view was created)
        val currentSequence = ArSessionCoordinator.getCurrentCreationSequence()
        val isStaleView = creationSequence > 0 && creationSequence < currentSequence
        
        if (newViewBeingCreated || !isStillActiveView || isStaleView) {
            Log.d(TAG, "🚫 Skipping destructive dispose - newViewBeingCreated: $newViewBeingCreated, isStillActiveView: $isStillActiveView, isStaleView: $isStaleView (our seq: $creationSequence, current: $currentSequence)")
            isDisposed = true  // Mark as disposed to prevent future calls
            
            // Just cleanup handlers but DON'T destroy SceneView or session
            sessionChannel.setMethodCallHandler(null)
            objectChannel.setMethodCallHandler(null)
            anchorChannel.setMethodCallHandler(null)
            runCatching { scope.cancel() }
            sceneView.setOnTouchListener(null)
            
            // Unregister but don't destroy
            ArSessionCoordinator.unregisterView(this)
            Log.d(TAG, "✅ Non-destructive dispose complete (new view owns resources)")
            return
        }
        
        // Check if this is a recoverable dispose (can cache for reuse)
        val isRecoverable = isRecoverableDispose()
        
        Log.d(TAG, "🧹 DISPOSE CALLED - isRecoverable: $isRecoverable, activity.isFinishing: ${activity?.isFinishing}")
        
        if (isRecoverable) {
            // CRITICAL: This is just a background transition - DON'T destroy anything!
            // Just pause the session and mark as disposed
            Log.d(TAG, "📦 Recoverable dispose - pausing session but keeping everything alive")
            
            isDisposed = true  // Mark as disposed to prevent re-entry
            
            // CRITICAL FIX: Safely pause session with validity checks to prevent SIGSEGV
            // The session may have been destroyed by Filament/SceneView cleanup (e.g., after corrupted model load)
            safelyPauseSession("recoverable dispose")
            
            // DON'T cleanup anything else - keep the SceneView, nodes, anchors, everything!
            // When app returns to foreground, session will resume automatically via lifecycle
            
            Log.d(TAG, "✅ Recoverable dispose complete - session paused, resources preserved")
            return
        }
        
        // NOT recoverable - remove the state saving code since we're doing full cleanup anyway
        
        // Full dispose - this is a real navigation away
        isDisposed = true
        
        Log.d(TAG, "🧹 Full dispose - starting cleanup")
        
        // Unregister from coordinator immediately
        ArSessionCoordinator.unregisterView(this)
        
        // Remove lifecycle observer
        lifecycleObserver?.let { observer ->
            runCatching { lifecycle.removeObserver(observer) }
        }
        lifecycleObserver = null
        
        try {
            // Cancel method handlers immediately to prevent new calls
            sessionChannel.setMethodCallHandler(null)
            objectChannel.setMethodCallHandler(null)
            anchorChannel.setMethodCallHandler(null)
            
            // Cancel coroutine scope FIRST to stop background operations
            // This prevents in-flight coroutines from accessing disposed resources
            try {
                scope.cancel()
                Log.d(TAG, "🧹 Coroutine scope cancelled")
            } catch (e: Exception) {
                Log.w(TAG, "⚠️ Error cancelling coroutine scope: ${e.message}")
            }
            
            // Stop touch listener immediately to prevent gesture callbacks
            sceneView.setOnTouchListener(null)
            
            // Clear rotation tracking state
            currentlyRotatingNode = null
            rotationStartScale = null
            rotationStartWorldY = null
            isRotationActive = false
            
            // CRITICAL FIX: Pause session with defensive exception handling
            // Camera2 API may throw IllegalStateException if session is already closed
            // Also check engine validity and view attachment to prevent SIGABRT on destroyed EGL context
            if (!sessionDestroyed) {
                try {
                    Log.d(TAG, "🧹 Phase 1: Pausing AR session")
                    val session = sceneView.session
                    if (session != null) {
                        // CRITICAL: Check view attachment first - detached = EGL context destroyed
                        val isViewAttached = sceneView.isAttachedToWindow
                        val isEngineValid = isViewAttached && runCatching { sceneView.renderer != null }.getOrDefault(false)
                        if (isEngineValid) {
                            session.pause()
                            Log.d(TAG, "✅ Session paused")
                        } else {
                            Log.w(TAG, "⚠️ Engine/EGL already destroyed (attached=$isViewAttached), skipping session pause")
                            sessionDestroyed = true
                        }
                    }
                } catch (e: IllegalStateException) {
                    Log.w(TAG, "⚠️ Session pause threw IllegalStateException (expected): ${e.message}")
                    sessionDestroyed = true
                } catch (e: Exception) {
                    Log.w(TAG, "⚠️ Session pause threw exception: ${e.message}")
                    sessionDestroyed = true
                }
            } else {
                Log.d(TAG, "🧹 Phase 1: Skipping session pause (already destroyed)")
            }
            
            // Use handler for cleanup but with defensive checks
            uiHandler.post {
                if (isDisposed) {
                    try {
                        Log.d(TAG, "🧹 Phase 2: Clearing nodes and anchors")
                        
                        // Clear nodes first (children before parents) - with defensive try/catch
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
                        
                        // Finally destroy the scene view with defensive exception handling
                        // Camera may already be disconnected by Camera2 background threads
                        try {
                            sceneView.destroy()
                            Log.d(TAG, "✅ SceneView destroyed")
                        } catch (e: IllegalStateException) {
                            Log.w(TAG, "⚠️ SceneView destroy threw IllegalStateException (expected): ${e.message}")
                        } catch (e: Exception) {
                            Log.w(TAG, "⚠️ SceneView destroy threw exception: ${e.message}")
                        }
                        
                        Log.d(TAG, "✅ Disposal complete - all resources cleaned up")
                        
                    } catch (t: Throwable) {
                        Log.e(TAG, "❌ Error during scene cleanup", t)
                    }
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
                // Notify coordinator that view is fully initialized
                ArSessionCoordinator.viewInitialized()
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
            "pause" -> {
                // Explicit pause method - call this before dispose to prevent EGL crashes
                Log.d(TAG, "⏸️ Received pause request from Flutter")
                pauseSession()
                result.success(true)
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
            // Permission dialog methods - no longer needed (keeping for API compatibility)
            "notifyPermissionDialogShowing" -> {
                Log.d(TAG, "🔔 Flutter notified: permission dialog showing (no-op)")
                result.success(true)
            }
            "notifyPermissionDialogDismissed" -> {
                Log.d(TAG, "🔔 Flutter notified: permission dialog dismissed (no-op)")
                // Attempt to resume session in case it was paused
                resumeSession()
                result.success(true)
            }
            "forceResumeSession" -> {
                Log.d(TAG, "🔄 Force resume session requested from Flutter")
                resumeSession()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun configureSession(arguments: Map<*, *>?) {
        val showPlanes = arguments?.get("showPlanes") as? Boolean ?: true
        val planeDetectionIndex = (arguments?.get("planeDetectionConfig") as? Number)?.toInt()
        val showFeaturePoints = arguments?.get("showFeaturePoints") as? Boolean ?: false
        val showAnimatedGuide = arguments?.get("showAnimatedGuide") as? Boolean ?: false
        
        // Parse gesture configuration (set once at init)
        debugGesturesEnabled = arguments?.get("debugGestures") as? Boolean ?: false
        maxPanDistanceMeters = (arguments?.get("maxPanDistance") as? Number)?.toFloat() ?: 5.0f
        
        Log.i(TAG, "🛠️ configureSession called:")
        Log.i(TAG, "   planeDetectionIndex = $planeDetectionIndex")
        Log.i(TAG, "   showPlanes = $showPlanes")
        Log.i(TAG, "   showFeaturePoints = $showFeaturePoints")
        Log.i(TAG, "   debugGestures = $debugGesturesEnabled")
        
        if (debugGesturesEnabled) {
            Log.i(TAG, "🔧 Gesture debug mode ENABLED")
            Log.i(TAG, "🔧 Max pan distance: ${maxPanDistanceMeters}m")
        }

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
            
            Log.i(TAG, "✅ Session configured: planeFindingMode = ${config.planeFindingMode}")
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

    private var isPaused = false

    /**
     * Pause the AR session gracefully.
     * This stops camera capture and rendering without destroying resources.
     * IMPORTANT: Call this before dispose() to prevent EGL context crashes.
     */
    private fun pauseSession() {
        if (isDisposed || isPaused) return
        isPaused = true
        
        Log.d(TAG, "⏸️ Pausing AR session gracefully")
        try {
            // Stop touch interactions first
            sceneView.setOnTouchListener(null)
            
            // CRITICAL FIX: Use safe pause with validity checks
            safelyPauseSession("pauseSession")
        } catch (e: Exception) {
            Log.e(TAG, "⚠️ Error pausing AR session: ${e.message}")
        }
    }
    
    /**
     * CRITICAL FIX: Safely pause the AR session with validity checks.
     * Prevents SIGSEGV crashes when the native session/engine has already been destroyed
     * (e.g., after a corrupted 3D model fails to load and Filament cleans up prematurely).
     * 
     * @param caller The calling context for logging purposes
     */
    private fun safelyPauseSession(caller: String) {
        // Check if session was already marked as destroyed
        if (sessionDestroyed) {
            Log.w(TAG, "⚠️ [$caller] Session already destroyed, skipping pause")
            return
        }

        // CRITICAL FIX: If the SurfaceView has been detached from the window, the Filament
        // engine and EGL context are already destroyed. Calling session.pause() now would
        // trigger a native SIGABRT (Check failed: client_egl_state_.has_value()).
        if (!sceneView.isAttachedToWindow) {
            Log.w(TAG, "⚠️ [$caller] SceneView detached from window - skipping session pause (EGL destroyed)")
            sessionDestroyed = true
            return
        }

        try {
            val session = sceneView.session
            if (session == null) {
                Log.w(TAG, "⚠️ [$caller] Session is null, skipping pause")
                return
            }

            // Additional safety: check if SceneView's renderer is still valid
            // If the engine was destroyed (e.g., by Filament cleanup after corrupted model),
            // we shouldn't try to pause as it will cause a native crash
            val isEngineValid = try {
                sceneView.renderer != null
            } catch (e: Exception) {
                Log.w(TAG, "⚠️ [$caller] Engine check threw exception: ${e.message}")
                false
            }

            if (!isEngineValid) {
                Log.w(TAG, "⚠️ [$caller] Engine already destroyed, skipping session pause")
                sessionDestroyed = true  // Mark for future calls
                return
            }

            // Session and engine are valid, safe to pause
            session.pause()
            Log.d(TAG, "⏸️ [$caller] AR session paused successfully")

        } catch (e: IllegalStateException) {
            // Session was already closed/destroyed - this is expected in some cases
            Log.w(TAG, "⚠️ [$caller] Session pause threw IllegalStateException (expected): ${e.message}")
            sessionDestroyed = true  // Mark for future calls
        } catch (e: Exception) {
            Log.e(TAG, "❌ [$caller] Session pause threw unexpected exception: ${e.message}")
            // Mark as destroyed to prevent future crash attempts
            sessionDestroyed = true
        }
    }

    /**
     * Resume the AR session after being paused.
     * Restores camera, tracking, and touch interactions.
     */
    private fun resumeSession() {
        if (isDisposed) {
            Log.w(TAG, "⚠️ Cannot resume - view is disposed")
            return
        }
        
        if (!isPaused) {
            Log.d(TAG, "ℹ️ Session not paused, checking if resume needed anyway...")
            // Even if not paused by our code, try to ensure session is running
            // This handles cases where SceneView may have internally paused
            try {
                val session = sceneView.session
                if (session != null) {
                    // Check if session needs resuming
                    runCatching { session.resume() }
                }
            } catch (e: Exception) {
                Log.w(TAG, "⚠️ Session resume check failed: ${e.message}")
            }
            return
        }
        
        isPaused = false
        
        Log.d(TAG, "▶️ Resuming AR session")
        try {
            // Resume the AR session
            sceneView.session?.resume()
            
            // Re-setup touch listener for gesture tracking
            setupTouchListener()
            
            Log.d(TAG, "✅ AR session resumed successfully with touch listener")
        } catch (e: Exception) {
            Log.e(TAG, "⚠️ Error resuming AR session: ${e.message}")
        }
    }
    
    /**
     * Setup touch listener for gesture coordinate tracking.
     * This is called during init and after resume to restore functionality.
     */
    private fun setupTouchListener() {
        sceneView.setOnTouchListener { view, event ->
            // Prevent touch processing during disposal
            if (isDisposed) return@setOnTouchListener false
            
            // Track pointer count for multi-touch detection
            activePointerCount = event.pointerCount
            
            when (event.actionMasked) {
                android.view.MotionEvent.ACTION_DOWN -> {
                    currentTouchX = event.x
                    currentTouchY = event.y
                    if (debugGesturesEnabled) {
                        Log.d(TAG, "🖐️ Touch DOWN: ($currentTouchX, $currentTouchY)")
                    }
                }
                android.view.MotionEvent.ACTION_POINTER_DOWN -> {
                    // Second finger down - if we're rotating, force scale reset
                    if (isRotationActive && activePointerCount >= 2) {
                        if (debugGesturesEnabled) {
                            Log.w(TAG, "⚠️ Multi-touch detected during rotation! Pointers: $activePointerCount")
                        }
                        currentlyRotatingNode?.let { node ->
                            rotationStartScale?.let { targetScale ->
                                node.scale = targetScale
                            }
                        }
                    }
                }
                android.view.MotionEvent.ACTION_MOVE -> {
                    currentTouchX = event.x
                    currentTouchY = event.y
                    
                    // If rotation is active with 2+ fingers, reset scale on every move
                    if (isRotationActive && activePointerCount >= 2) {
                        currentlyRotatingNode?.let { node ->
                            rotationStartScale?.let { targetScale ->
                                val currentScale = node.scale
                                val scaleChanged = abs(currentScale.x - targetScale.x) > 0.001f ||
                                                  abs(currentScale.y - targetScale.y) > 0.001f ||
                                                  abs(currentScale.z - targetScale.z) > 0.001f
                                if (scaleChanged) {
                                    node.scale = targetScale
                                    if (debugGesturesEnabled) {
                                        Log.w(TAG, "🚨 BLOCKED scale during rotation! Reset to $targetScale (was $currentScale)")
                                    }
                                }
                            }
                        }
                    }
                }
                android.view.MotionEvent.ACTION_UP, android.view.MotionEvent.ACTION_POINTER_UP -> {
                    // Recalculate pointer count after release
                    activePointerCount = maxOf(0, event.pointerCount - 1)
                }
            }
            false // NEVER consume - let SceneView's gesture detectors work normally
        }
    }

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
        val enableScale = nodeMap["enableScaleGestures"] as? Boolean ?: false  // Default: false (disabled)
        val centerOriginOnLoad = nodeMap["centerOriginOnLoad"] as? Boolean ?: true  // Default: true (fixes rotation jump)

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
                
                // 🔥 CRITICAL FIX: Do NOT enable isRotationEditable on AnchorNode!
                // When AnchorNode rotates with a child ModelNode at an offset,
                // the ModelNode orbits around the anchor origin (0,0,0), causing
                // unwanted Z-axis (height) changes that look like objects "jumping up".
                // Instead, we enable rotation on the ModelNode itself below.
                isRotationEditable = false  // Always false, child ModelNode handles rotation
                
                Log.d(TAG, "✅ AnchorNode '${this.name}' configured: pan=$enablePan (manual), rotation=$enableRotation (delegated to child ModelNode)")
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
                    
                    // For anchored nodes, position should be (0,0,0) relative to anchor
                    // The anchor provides the world position
                    if (anchorRecord != null) {
                        this.position = Position(0f, 0f, 0f)  // Zero position - anchor handles world placement
                        this.quaternion = rotation
                        this.scale = scale
                        
                        // NOTE: We do NOT call centerOrigin() here anymore!
                        // centerOrigin() was causing scale distortion and position jumps.
                        // The rotation is now handled on ModelNode (not AnchorNode), which
                        // rotates around its own origin. For most models this works correctly.
                        // If the model's origin is not at center, the rotation may appear
                        // slightly off-center, but it won't cause the Y-jump issue.
                        Log.d(TAG, "🎯 Model attached to anchor at (0,0,0) with scale=${scale}, rotation applied to ModelNode")
                    } else {
                        // Apply position from transform for standalone nodes
                        this.position = position
                        this.quaternion = rotation
                        this.scale = scale
                        Log.d(TAG, "🎯 Standalone model at position=$position with scale=$scale")
                    }
                }

                // Add to scene on main thread
                if (anchorRecord != null) {
                    // Configure ModelNode - must be editable to receive touch events
                    // ModelNode now handles rotation (not parent AnchorNode) to avoid orbit effect
                    modelNode.apply {
                        isEditable = enablePan || enableRotation || enableScale  // Must be true to detect touches
                        isPositionEditable = false  // Delegate position to parent
                        isRotationEditable = enableRotation  // ← FIXED: ModelNode handles rotation, not parent
                        // 🔥 NUCLEAR FIX: ALWAYS disable scale at the node level
                        // SceneView's internal scale gesture interferes with rotation even when we block callbacks
                        isScaleEditable = false  // ALWAYS false - we'll handle scale programmatically if needed
                        // 🔥 DISABLE smooth transforms - may be causing jitter
                        isSmoothTransformEnabled = false
                    }
                    
                    // Just add the child node
                    anchorRecord.node.addChildNode(modelNode)
                    
                    Log.d(TAG, "✅ Configured model on anchor - AnchorNode: pos=$enablePan,rot=false | ModelNode: rot=$enableRotation, scale=DISABLED (nuclear fix), centerOrigin=$centerOriginOnLoad")
                } else {
                    // Standalone node (no anchor) - ModelNode handles all gestures
                    modelNode.apply {
                        isEditable = isTransformable || enablePan || enableRotation || enableScale
                        isPositionEditable = enablePan
                        isRotationEditable = enableRotation
                        // 🔥 NUCLEAR FIX: ALWAYS disable scale at the node level
                        isScaleEditable = false  // ALWAYS false - prevents scale interference
                    }
                    sceneView.addChildNode(modelNode)
                    
                    Log.d(TAG, "Standalone ModelNode $nodeId - pan=$enablePan, rotation=$enableRotation, scale=DISABLED (nuclear fix)")
                }

                val nodeRecord = NodeRecord(
                    id = nodeId,
                    node = modelNode,
                    anchorId = anchorRecord?.id,
                    uri = uri,  // Store URI for session restoration
                    isTransformable = isTransformable,
                    enablePan = enablePan,
                    enableRotation = enableRotation,
                    enableScale = enableScale  // Store scale gesture setting
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
        
        // Clear any active gesture state if this node was being manipulated
        if (currentlyRotatingNode === record.node) {
            currentlyRotatingNode = null
            isRotationActive = false
            rotationStartScale = null
            rotationStartWorldY = null
        }
        
        // Defer destruction to ensure any in-flight gesture events complete
        sceneView?.post {
            runCatching {
                record.node.destroy()
            }.onFailure { e ->
                Log.w(TAG, "⚠️ Exception during node destroy (may be expected if gesture was active): ${e.message}")
            }
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
        
        // Clear any active gesture state if this node was being manipulated
        if (currentlyRotatingNode === record.node) {
            currentlyRotatingNode = null
            isRotationActive = false
            rotationStartScale = null
            rotationStartWorldY = null
            Log.d(TAG, "🔄 Cleared gesture state for removed node")
        }
        
        // Defer destruction to ensure any in-flight gesture events complete
        sceneView?.post {
            try {
                // Destroy the node (SceneView handles resource cleanup)
                record.node.destroy()
                Log.d(TAG, "✅ Node destroyed: $nodeId")
            } catch (t: Throwable) {
                Log.w(TAG, "⚠️ Exception during node destroy (may be expected if gesture was active): ${t.message}")
            }
        } ?: run {
            // Fallback if sceneView is null - destroy directly
            runCatching { record.node.destroy() }
        }
        
        Log.d(TAG, "✅ Node removed from records: $nodeId")
        return true
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
        
        // 🔥 CRITICAL: Per-frame scale enforcement during rotation
        // SceneView applies scale changes AFTER our gesture callbacks, so we must
        // enforce scale on every frame while rotation is active
        currentlyRotatingNode?.let { node ->
            // Check if we've lost tracking - abort rotation protection if tracking fails
            val trackingState = frame.camera.trackingState
            if (trackingState != TrackingState.TRACKING) {
                Log.w(TAG, "⚠️ Tracking lost during rotation! State: $trackingState - restoring scale and clearing rotation state")
                rotationStartScale?.let { targetScale ->
                    node.scale = targetScale  // Force restore original scale
                }
                currentlyRotatingNode = null
                rotationStartScale = null
                rotationStartWorldY = null
                return@let
            }
            
            rotationStartScale?.let { targetScale ->
                val currentScale = node.scale
                val scaleChanged = abs(currentScale.x - targetScale.x) > 0.0001f ||
                                  abs(currentScale.y - targetScale.y) > 0.0001f ||
                                  abs(currentScale.z - targetScale.z) > 0.0001f
                if (scaleChanged) {
                    node.scale = targetScale
                    Log.w(TAG, "📐 handleFrame scale correction: $currentScale -> $targetScale")
                }
                
                // 🔥 CRITICAL: Also check and reset PARENT (anchor) scale every frame!
                node.parent?.let { parent ->
                    val parentScale = parent.scale
                    if (abs(parentScale.x - 1f) > 0.0001f ||
                        abs(parentScale.y - 1f) > 0.0001f ||
                        abs(parentScale.z - 1f) > 0.0001f) {
                        Log.w(TAG, "📐 handleFrame PARENT scale correction: $parentScale -> (1,1,1)")
                        parent.scale = Scale(1f, 1f, 1f)
                    }
                }
                
                // Also protect Y position during rotation
                rotationStartWorldY?.let { startY ->
                    val currentY = node.worldPosition.y
                    if (abs(currentY - startY) > 0.002f) {  // More than 2mm drift
                        node.worldPosition = Position(node.worldPosition.x, startY, node.worldPosition.z)
                    }
                }
            }
        }
        
        sendPlaneUpdates(frame)
        sendLightingUpdate(frame)
        capLightIntensities()
    }

    /**
     * Caps the per-frame light intensities produced by ARCore's ENVIRONMENTAL_HDR estimator.
     *
     * SceneView's ARLightEstimator writes [indirectLightEstimated] (IBL / spherical harmonics)
     * and [mainLightEstimatedNode] (directional sun light) on every rendered frame.  In bright
     * environments the estimator can push these past 100,000 lux, causing the top surfaces of
     * models to blow out to solid white (#fff) and producing pink/purple fringing on metallic
     * materials.  Capping here keeps ENVIRONMENTAL_HDR active and realistic while preventing
     * overexposure.
     */
    private fun capLightIntensities() {
        // Throttle: skip frames to reduce Filament state-write overhead
        if (lightCapFrameCount++ % LIGHT_CAP_FRAME_INTERVAL != 0) return

        // 1. Cap IBL (ambient / indirect) light from ARCore spherical harmonics.
        //    sceneView.indirectLightEstimated is the ENVIRONMENTAL_HDR-updated object;
        //    sceneView.indirectLight is the static fallback we set from pdp-model-viewer.hdr.
        sceneView.indirectLightEstimated?.let { ibl ->
            if (ibl.intensity > MAX_INDIRECT_LIGHT_INTENSITY) {
                ibl.intensity = MAX_INDIRECT_LIGHT_INTENSITY
            }
        }

        // 2. Cap main directional / sun light from ARCore's main light estimate.
        //    Upper model surfaces appear pure-white when this exceeds ~40,000 lux because
        //    the directional light hits top-facing normals most directly.
        sceneView.mainLightEstimatedNode?.let { lightNode ->
            if (lightNode.intensity > MAX_DIRECTIONAL_LIGHT_INTENSITY) {
                lightNode.intensity = MAX_DIRECTIONAL_LIGHT_INTENSITY
            }
        }
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
                // Load HDR environment with reduced intensity for softer, more natural lighting
                // The old Sceneform implementation used AMBIENT_INTENSITY which was softer.
                // We use a neutral HDR environment (pdp-model-viewer) instead of evening_meadow
                // which had a blue/cool color cast from outdoor evening lighting.
                val environment = loader.createHDREnvironment(
                    assetFileLocation = "pdp-model-viewer.hdr",  // Neutral lighting, no blue tint
                    createSkybox = false  // Don't create skybox for AR (we want camera feed)
                )
                
                environment?.let { env ->
                    // Set static HDR as the initial fallback environment for the first few frames
                    // before ARCore's ENVIRONMENTAL_HDR estimator provides valid data.
                    // SceneView will progressively replace this with live ARCore environment probes.
                    sceneView.environment = env

                    // Set a warmup intensity on the static IBL.  The sustained cap is applied
                    // every frame in capLightIntensities() against indirectLightEstimated, which
                    // is the ENVIRONMENTAL_HDR-updated object (separate from this static one).
                    sceneView.indirectLight?.let { light ->
                        light.setIntensity(MAX_INDIRECT_LIGHT_INTENSITY)
                    }

                    // Configure fixed camera exposure to prevent Filament's auto-exposure from
                    // contributing to overbrightness on top of the light caps.
                    // f/16 · 1/125 s · ISO 100 ≈ EV 14.6 — balanced for indoor and outdoor AR.
                    runCatching {
                        sceneView.cameraNode.setExposure(16f, 1f / 125f, 100f)
                    }

                    Log.d(TAG, "✅ HDR environment loaded (warmup); per-frame caps active at IBL=${MAX_INDIRECT_LIGHT_INTENSITY} dir=${MAX_DIRECTIONAL_LIGHT_INTENSITY} lux")
                }
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
        val width = sceneView.width
        val height = sceneView.height

        if (width <= 0 || height <= 0) {
            result.error("SNAPSHOT_ERROR", "View has invalid dimensions", null)
            return
        }

        // Use Filament's readPixels to capture the fully composited AR frame,
        // including the camera background rendered by ARCameraStream.
        // PixelCopy on a Filament SurfaceView does not capture the camera background.
        val buffer = ByteBuffer.allocateDirect(width * height * 4)
        val descriptor = Texture.PixelBufferDescriptor(
            buffer,
            Texture.Format.RGBA,
            Texture.Type.UBYTE
        )
        // uiHandler delivers the callback on the main thread so result can be returned safely.
        descriptor.setCallback(uiHandler, Runnable {
            buffer.rewind()
            // Filament readPixels uses bottom-left origin (OpenGL convention).
            // Flip vertically to produce an image with Android's top-left origin.
            val intArray = IntArray(width * height)
            for (row in 0 until height) {
                val srcRow = height - 1 - row
                for (col in 0 until width) {
                    val pixelIdx = (srcRow * width + col) * 4
                    val r = buffer.get(pixelIdx).toInt() and 0xFF
                    val g = buffer.get(pixelIdx + 1).toInt() and 0xFF
                    val b = buffer.get(pixelIdx + 2).toInt() and 0xFF
                    val a = buffer.get(pixelIdx + 3).toInt() and 0xFF
                    intArray[row * width + col] = (a shl 24) or (r shl 16) or (g shl 8) or b
                }
            }
            val bitmap = Bitmap.createBitmap(intArray, width, height, Bitmap.Config.ARGB_8888)
            result.success(bitmapToByteArray(bitmap))
            bitmap.recycle()
        })

        sceneView.renderer.readPixels(0, 0, width, height, descriptor)
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
                    // CRITICAL FIX: Use safe pause to prevent SIGSEGV if session is destroyed
                    if (!sessionDestroyed) {
                        try {
                            val session = sceneView.session
                            if (session != null) {
                                val isEngineValid = runCatching { sceneView.renderer != null }.getOrDefault(false)
                                if (isEngineValid) {
                                    session.pause()
                                    session.resume()
                                    Log.d(TAG, "✅ AR tracking reset")
                                } else {
                                    Log.w(TAG, "⚠️ Engine destroyed, skipping tracking reset")
                                    sessionDestroyed = true
                                }
                            }
                        } catch (e: Exception) {
                            Log.w(TAG, "⚠️ Tracking reset failed: ${e.message}")
                            sessionDestroyed = true
                        }
                    } else {
                        Log.w(TAG, "⚠️ Session destroyed, skipping tracking reset")
                    }
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
                    // CRITICAL FIX: Check session validity before pause/resume
                    if (!sessionDestroyed) {
                        try {
                            val session = sceneView.session
                            if (session != null) {
                                val isEngineValid = runCatching { sceneView.renderer != null }.getOrDefault(false)
                                if (isEngineValid) {
                                    session.pause()
                                    session.resume()
                                    Log.d(TAG, "✅ AR session reset")
                                } else {
                                    Log.w(TAG, "⚠️ Engine destroyed, skipping session reset")
                                    sessionDestroyed = true
                                }
                            }
                        } catch (e: Exception) {
                            Log.w(TAG, "⚠️ Session reset failed: ${e.message}")
                            sessionDestroyed = true
                        }
                    } else {
                        Log.w(TAG, "⚠️ Session already destroyed, skipping reset")
                    }
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
        val uri: String,  // Model URI for restoration after session recreation
        val isTransformable: Boolean,
        val enablePan: Boolean,
        val enableRotation: Boolean,
        val enableScale: Boolean,  // Controls pinch/zoom gestures
        var currentPlaneType: Plane.Type? = null  // Tracks current surface type (horizontal/vertical) during pan
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

    /**
     * Restore AR session state after backgrounding.
     * Recreates anchors, reloads models, and restores transforms.
     */
    private suspend fun restoreSessionState(state: SessionStateCache) {
        Log.d(TAG, "🔄 Starting session restoration: ${state.anchors.size} anchors, ${state.nodes.size} nodes")
        
        // Step 1: Restore session configuration
        withContext(Dispatchers.Main) {
            val session = sceneView.session
            val config = session?.config
            
            if (config != null) {
                try {
                    // Restore plane finding mode
                    config.planeFindingMode = com.google.ar.core.Config.PlaneFindingMode.values()[state.config.planeFindingMode]
                    
                    // Restore depth mode
                    config.depthMode = com.google.ar.core.Config.DepthMode.values()[state.config.depthMode]
                    
                    // Restore light estimation mode
                    config.lightEstimationMode = com.google.ar.core.Config.LightEstimationMode.values()[state.config.lightEstimationMode]
                    
                    session.configure(config)
                    Log.d(TAG, "✅ Session config restored")
                } catch (e: Exception) {
                    Log.w(TAG, "⚠️ Could not restore session config", e)
                }
            }
        }
        
        // Step 2: Recreate anchors at saved poses
        val restoredAnchors = mutableMapOf<String, AnchorRecord>()
        
        for (anchorState in state.anchors) {
            try {
                withContext(Dispatchers.Main) {
                    val session = sceneView.session ?: throw IllegalStateException("Session not available")
                    
                    // Create pose from saved translation and quaternion
                    val pose = com.google.ar.core.Pose(
                        anchorState.translation,  // [x, y, z]
                        anchorState.quaternion    // [x, y, z, w]
                    )
                    
                    // Create anchor at the saved pose
                    val anchor = session.createAnchor(pose)
                    
                    // Create AnchorNode
                    val anchorNode = AnchorNode(sceneView.engine, anchor)
                    sceneView.addChildNode(anchorNode)
                    
                    // Store in records
                    val anchorRecord = AnchorRecord(
                        id = anchorState.id,
                        anchor = anchor,
                        node = anchorNode
                    )
                    restoredAnchors[anchorState.id] = anchorRecord
                    anchorRecords[anchorState.id] = anchorRecord
                    
                    Log.d(TAG, "✅ Restored anchor: ${anchorState.id}")
                }
            } catch (e: Exception) {
                Log.e(TAG, "❌ Failed to restore anchor ${anchorState.id}", e)
                // Continue with other anchors even if one fails
            }
        }
        
        // Step 3: Reload models and restore nodes
        for (nodeState in state.nodes) {
            try {
                withContext(Dispatchers.Main) {
                    // Try to get cached model first (fast path)
                    var modelInstance = ArSessionCoordinator.getCachedModel(nodeState.uri)
                    
                    if (modelInstance == null) {
                        // Load model from URI (slow path)
                        Log.d(TAG, "📥 Loading model from URI: ${nodeState.uri}")
                        modelInstance = sceneView.modelLoader.loadModelInstance(nodeState.uri)
                            ?: throw IllegalArgumentException("Unable to load model: ${nodeState.uri}")
                        
                        // Cache for future use
                        ArSessionCoordinator.cacheModel(nodeState.uri, modelInstance)
                    } else {
                        Log.d(TAG, "♻️ Using cached model: ${nodeState.uri}")
                    }
                    
                    // Create ModelNode
                    val modelNode = ModelNode(modelInstance).apply {
                        name = nodeState.id
                        
                        // Parse transform from saved matrix
                        val (position, rotation, scale) = parseTransform(nodeState.transform, null)
                        
                        // Find anchor if this node was anchored
                        val anchorRecord = nodeState.anchorId?.let { restoredAnchors[it] }
                        
                        if (anchorRecord != null) {
                            // Anchored node - position relative to anchor
                            this.position = Position(0f, 0f, 0f)
                            this.quaternion = rotation
                            this.scale = scale
                            
                            // Configure gestures on ModelNode
                            isEditable = nodeState.enablePan || nodeState.enableRotation || nodeState.enableScale
                            isPositionEditable = false  // Delegate to parent
                            isRotationEditable = nodeState.enableRotation
                            isScaleEditable = false  // Always disabled (nuclear fix)
                            isSmoothTransformEnabled = false
                            
                            // Add to anchor
                            anchorRecord.node.addChildNode(this)
                            
                            // Configure anchor gestures
                            anchorRecord.node.apply {
                                isEditable = true
                                isPositionEditable = false  // Manual pan
                                isRotationEditable = false  // Delegated to child
                            }
                        } else {
                            // Standalone node
                            this.position = position
                            this.quaternion = rotation
                            this.scale = scale
                            
                            isEditable = nodeState.isTransformable || nodeState.enablePan || nodeState.enableRotation || nodeState.enableScale
                            isPositionEditable = nodeState.enablePan
                            isRotationEditable = nodeState.enableRotation
                            isScaleEditable = false  // Always disabled
                            
                            // Add to scene
                            sceneView.addChildNode(this)
                        }
                    }
                    
                    // Store in records
                    val nodeRecord = NodeRecord(
                        id = nodeState.id,
                        node = modelNode,
                        anchorId = nodeState.anchorId,
                        uri = nodeState.uri,
                        isTransformable = nodeState.isTransformable,
                        enablePan = nodeState.enablePan,
                        enableRotation = nodeState.enableRotation,
                        enableScale = nodeState.enableScale
                    )
                    nodeRecords[nodeState.id] = nodeRecord
                    
                    Log.d(TAG, "✅ Restored node: ${nodeState.id} (anchored: ${nodeState.anchorId != null})")
                }
            } catch (e: Exception) {
                Log.e(TAG, "❌ Failed to restore node ${nodeState.id}", e)
                // Continue with other nodes even if one fails
            }
        }
        
        Log.d(TAG, "🎉 Session restoration complete: ${anchorRecords.size}/${state.anchors.size} anchors, ${nodeRecords.size}/${state.nodes.size} nodes")
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
            
            if (debugGesturesEnabled) {
                Log.d(TAG, "📐 normX=${"%.3f".format(normX)}, normY=${"%.3f".format(normY)} | touch=($touchX, $touchY)")
            }
            
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
            
            if (debugGesturesEnabled) {
                Log.d(TAG, "🎥 right=(${"%.2f".format(rightX)}, ${"%.2f".format(rightY)}, ${"%.2f".format(rightZ)})")
                Log.d(TAG, "🎥 up=(${"%.2f".format(upX)}, ${"%.2f".format(upY)}, ${"%.2f".format(upZ)})")
                Log.d(TAG, "🎥 forward=(${"%.2f".format(forwardX)}, ${"%.2f".format(forwardY)}, ${"%.2f".format(forwardZ)})")
            }
            
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

    // Helper extension to format Float for logging
    private fun Float.format(): String = String.format("%.3f", this)
}

