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
                config.depthMode = if (session.isDepthModeSupported(Config.DepthMode.AUTOMATIC)) {
                    Config.DepthMode.AUTOMATIC
                } else {
                    Config.DepthMode.DISABLED
                }
                config.planeFindingMode = Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL
                config.lightEstimationMode = Config.LightEstimationMode.ENVIRONMENTAL_HDR
                config.instantPlacementMode = Config.InstantPlacementMode.LOCAL_Y_UP
            }

            onSessionUpdated = { _, frame ->
                handleFrame(frame)
            }

            setOnGestureListener(
                onSingleTapConfirmed = { event, node ->
                    if (node != null) {
                        handleNodeTap(node)
                    } else {
                        handleHitTest(event.x, event.y)
                    }
                },
                onMoveBegin = { _: MoveGestureDetector, _: MotionEvent, node: Node? ->
                    node?.let { handleGestureEvent("onPanStart", it) }
                },
                onMove = { _: MoveGestureDetector, _: MotionEvent, node: Node? ->
                    node?.let { handleGestureEvent("onPanChange", it) }
                },
                onMoveEnd = { _: MoveGestureDetector, _: MotionEvent, node: Node? ->
                    node?.let { handleGestureEnd("onPanEnd", it) }
                },
                onRotateBegin = { _: RotateGestureDetector, _: MotionEvent, node: Node? ->
                    node?.let { handleGestureEvent("onRotationStart", it) }
                },
                onRotate = { _: RotateGestureDetector, _: MotionEvent, node: Node? ->
                    node?.let { handleGestureEvent("onRotationChange", it) }
                },
                onRotateEnd = { _: RotateGestureDetector, _: MotionEvent, node: Node? ->
                    node?.let { handleGestureEnd("onRotationEnd", it) }
                }
            )
        }

        // Environment loading will be handled lazily on first frame update to ensure
        // proper thread context and lifecycle state
        // DO NOT load environment here to avoid Filament threading issues

        container.addView(sceneView)

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
        
        try {
            sessionChannel.setMethodCallHandler(null)
            objectChannel.setMethodCallHandler(null)
            anchorChannel.setMethodCallHandler(null)
            scope.cancel()
            
            // Clean up nodes and anchors before destroying scene
            uiHandler.post {
                try {
                    nodeRecords.values.forEach { record ->
                        runCatching { record.node.destroy() }
                    }
                    nodeRecords.clear()
                    
                    anchorRecords.values.forEach { record ->
                        runCatching { record.node.destroy() }
                    }
                    anchorRecords.clear()
                    
                    sceneView.destroy()
                } catch (t: Throwable) {
                    Log.w(TAG, "Error during scene cleanup", t)
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "Error during dispose", t)
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
            "softResetSession",
            "ar#nukeAll",
            "ar#nukeAllNonBlocking",
            "removeAllObjects",
            "ar#getPluginState" -> {
                // TODO: Port advanced memory / cleanup routines from previous implementation.
                result.success(false)
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
            "transformationChanged" -> {
                val args = call.arguments as? Map<*, *>
                handleTransformationChanged(args)
                result.success(null)
            }
            else -> {
                // TODO: Port remaining advanced APIs (gestures, caching, memory diagnostics, etc.)
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

                    isEditable = isTransformable
                    isPositionEditable = isTransformable && enablePan
                    isRotationEditable = isTransformable && enableRotation
                }

                // Add to scene on main thread
                if (anchorRecord != null) {
                    anchorRecord.node.isEditable = true
                    if (enablePan) {
                        anchorRecord.node.isPositionEditable = true
                    }
                    anchorRecord.node.addChildNode(modelNode)
                } else {
                    sceneView.addChildNode(modelNode)
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
                }
                sceneView.addChildNode(anchorNode)
                anchorRecords[name] = AnchorRecord(name, anchor, anchorNode)
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
    // Data classes & helpers
    // ------------------------------------------------------------------------

    private data class AnchorRecord(
        val id: String,
        val anchor: Anchor,
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
}
