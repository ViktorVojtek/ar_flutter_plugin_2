package com.uhg0.ar_flutter_plugin_2

import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.PixelCopy
import android.view.ScaleGestureDetector
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.lifecycle.Lifecycle
import com.google.ar.core.Anchor.CloudAnchorState
import com.google.ar.core.Config
import com.google.ar.core.Frame
import com.google.ar.core.Plane
import com.google.ar.core.Pose
import com.google.ar.core.TrackingState
import com.uhg0.ar_flutter_plugin_2.Serialization.deserializeMatrix4
import com.uhg0.ar_flutter_plugin_2.Serialization.serializeHitResult
import com.uhg0.ar_flutter_plugin_2.Serialization.serializeARCoreHitResult
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import io.github.sceneview.ar.ARSceneView
import io.github.sceneview.ar.arcore.canHostCloudAnchor
import io.github.sceneview.ar.arcore.fps
import io.github.sceneview.ar.node.AnchorNode
import io.github.sceneview.ar.node.CloudAnchorNode
import io.github.sceneview.ar.node.HitResultNode
import io.github.sceneview.gesture.MoveGestureDetector
import io.github.sceneview.gesture.RotateGestureDetector
import io.github.sceneview.math.Position
import io.github.sceneview.math.Transform
import io.github.sceneview.model.ModelInstance
import io.github.sceneview.node.ModelNode
import io.github.sceneview.node.Node
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import io.github.sceneview.math.Position as ScenePosition
import io.github.sceneview.math.Rotation as SceneRotation
import io.github.sceneview.math.Scale as SceneScale
import io.github.sceneview.texture.ImageTexture
import io.github.sceneview.material.setTexture
import io.github.sceneview.ar.scene.PlaneRenderer
import io.flutter.FlutterInjector
import io.github.sceneview.node.CylinderNode
import io.github.sceneview.math.Direction
import io.github.sceneview.math.Rotation
import io.github.sceneview.math.Scale
import io.github.sceneview.math.colorOf
import io.github.sceneview.loaders.MaterialLoader
import com.google.ar.core.exceptions.SessionPausedException
import kotlin.math.sqrt
import kotlin.math.atan2

class ArView(
    context: Context,
    private val activity: Activity,
    private val lifecycle: Lifecycle,
    messenger: BinaryMessenger,
    id: Int,
) : PlatformView {
    private val TAG: String = ArView::class.java.name
    private val viewContext: Context = context
    private var sceneView: ARSceneView
    private val mainScope = CoroutineScope(Dispatchers.Main)
    private var worldOriginNode: Node? = null

    private val rootLayout: ViewGroup = FrameLayout(context)

    private val sessionChannel: MethodChannel = MethodChannel(messenger, "arsession_$id")
    private val objectChannel: MethodChannel = MethodChannel(messenger, "arobjects_$id")
    private val anchorChannel: MethodChannel = MethodChannel(messenger, "aranchors_$id")
    private val nodesMap = mutableMapOf<String, ModelNode>()
    private var planeCount = 0
    private var selectedNode: Node? = null
    private val detectedPlanes = mutableSetOf<Plane>()
    private val anchorNodesMap = mutableMapOf<String, AnchorNode>()
    private var showAnimatedGuide = true
    private var showFeaturePoints = false
    private val pointCloudNodes = mutableListOf<PointCloudNode>()
    private var lastPointCloudTimestamp: Long? = null
    private var lastPointCloudFrame: Frame? = null
    private var pointCloudModelInstances = mutableListOf<ModelInstance>()
    private var handleTaps = true
    private var handlePans = false  
    private var handleRotation = false
    private var isSessionPaused = false
    private var detectedPlaneY: Float? = null // Y coordinate of the detected plane for constraining object movement
    private var lastRotationAngle: Float = 0f // Track last rotation angle for delta calculation
    
    // Rotation gesture tracking variables
    private var gestureStartRotation: Float? = null
    private var lastDetectorRotation: Float? = null
    private var lastAppliedRotation: Float = 0f
    private var accumulatedRotationDelta: Float = 0f

    private class PointCloudNode(
        modelInstance: ModelInstance,
        var id: Int,
        var confidence: Float,
    ) : ModelNode(modelInstance)

    /**
     * Calculate incremental rotation delta handling 360° wraparound
     */
    private fun calculateIncrementalRotationDelta(currentRotation: Float, lastRotation: Float): Float {
        var delta = currentRotation - lastRotation
        // Handle 360° wraparound
        if (delta > Math.PI) delta -= (2 * Math.PI).toFloat()
        else if (delta < -Math.PI) delta += (2 * Math.PI).toFloat()
        return delta
    }

    private val onSessionMethodCall =
        MethodChannel.MethodCallHandler { call, result ->
            when (call.method) {
                "init" -> handleInit(call, result)
                "showPlanes" -> handleShowPlanes(call, result)
                "dispose" -> dispose()
                "getAnchorPose" -> handleGetAnchorPose(call, result)
                "getCameraPose" -> handleGetCameraPose(result)
                "snapshot" -> handleSnapshot(result)
                "disableCamera" -> handleDisableCamera(result)
                "enableCamera" -> handleEnableCamera(result)
                else -> result.notImplemented()
            }
        }
    private fun handleDisableCamera(result: MethodChannel.Result) {
        try {
            isSessionPaused = true
            sceneView.session?.pause()
            result.success(null)
        } catch (e: Exception) {
            result.error("DISABLE_CAMERA_ERROR", e.message, null)
        }
    }
    private fun handleEnableCamera(result: MethodChannel.Result) {
        try {
            isSessionPaused = false
            sceneView.session?.resume()
            result.success(null)
        } catch (e: Exception) {
            result.error("ENABLE_CAMERA_ERROR", e.message, null)
        }
    }
    private val onObjectMethodCall =
        MethodChannel.MethodCallHandler { call, result ->
            when (call.method) {
                "init" -> {
                    // Initialize the AR object manager
                    result.success(null)
                }
                "addNode" -> {
                    val nodeData = call.arguments as? Map<String, Any>
                    nodeData?.let {
                        handleAddNode(it, result)
                    } ?: result.error("INVALID_ARGUMENTS", "Node data is required", null)
                }
                "addNodeToPlaneAnchor" -> handleAddNodeToPlaneAnchor(call, result)
                "addNodeToScreenPosition" -> handleAddNodeToScreenPosition(call, result)
                "removeNode" -> {
                    handleRemoveNode(call, result)
                }
                "transformationChanged" -> {
                    handleTransformNode(call, result)
                }
                else -> result.notImplemented()
            }
        }

    private val onAnchorMethodCall =
        MethodChannel.MethodCallHandler { call, result ->
            when (call.method) {
                "addAnchor" -> handleAddAnchor(call, result)
                "removeAnchor" -> {
                    val anchorName = call.argument<String>("name")
                    handleRemoveAnchor(anchorName, result)
                }
                "initGoogleCloudAnchorMode" -> handleInitGoogleCloudAnchorMode(result)
                "uploadAnchor" -> handleUploadAnchor(call, result)
                "downloadAnchor" -> handleDownloadAnchor(call, result)
                else -> result.notImplemented()
            }
        }

    init {
        sceneView = ARSceneView(
            context = viewContext,
            sharedLifecycle = lifecycle,
            sessionConfiguration = { session, config ->
                config.apply {
                    depthMode = Config.DepthMode.DISABLED
                    instantPlacementMode = Config.InstantPlacementMode.DISABLED
                    lightEstimationMode = Config.LightEstimationMode.DISABLED // .ENVIRONMENTAL_HDR
                    focusMode = Config.FocusMode.AUTO
                    planeFindingMode = Config.PlaneFindingMode.DISABLED
                }
            }
        ).apply {
            // Note: ARSceneView doesn't have isGestureEnabled property
            // Gesture handling is configured through setOnGestureListener
            Log.d("ArView", "SceneView created with gesture handling via setOnGestureListener")
        }
        
        rootLayout.addView(sceneView)

        sessionChannel.setMethodCallHandler(onSessionMethodCall)
        objectChannel.setMethodCallHandler(onObjectMethodCall)
        anchorChannel.setMethodCallHandler(onAnchorMethodCall)
    }

    

    private suspend fun buildModelNode(nodeData: Map<String, Any>): ModelNode? {
        var fileLocation = nodeData["uri"] as? String ?: return null
        when (nodeData["type"] as Int) {
                0 -> { // GLTF2 Model from Flutter asset folder
                    // Get path to given Flutter asset
                    val loader = FlutterInjector.instance().flutterLoader()
                    fileLocation = loader.getLookupKeyForAsset(fileLocation)
                }
                1 -> { // GLB Model from the web
                    fileLocation = fileLocation
                }
                2 -> { // fileSystemAppFolderGLB
                    // Fix: Add proper path resolution for GLB files from app documents directory
                    val documentsPath = viewContext.getApplicationInfo().dataDir
                    fileLocation = documentsPath + "/app_flutter/" + nodeData["uri"] as String
                    Log.d(TAG, "Loading GLB from filesystem: $fileLocation")
                }
                3 -> { //fileSystemAppFolderGLTF2
                    val documentsPath = viewContext.getApplicationInfo().dataDir
                    fileLocation = documentsPath + "/app_flutter/" + nodeData["uri"] as String
                    Log.d(TAG, "Loading GLTF2 from filesystem: $fileLocation")
                }
                else -> {
                    return null
                }
        }
        
        if (fileLocation == null) {
            Log.e(TAG, "File location is null for node type: ${nodeData["type"]}")
            return null
        }
        
        // Check if file exists for filesystem types
        val nodeType = nodeData["type"] as Int
        if (nodeType == 2 || nodeType == 3) {
            val file = java.io.File(fileLocation)
            if (!file.exists()) {
                Log.e(TAG, "File does not exist: $fileLocation")
                Log.d(TAG, "File absolute path: ${file.absolutePath}")
                Log.d(TAG, "File parent directory: ${file.parentFile?.absolutePath}")
                Log.d(TAG, "Parent directory exists: ${file.parentFile?.exists()}")
                if (file.parentFile?.exists() == true) {
                    Log.d(TAG, "Files in parent directory: ${file.parentFile?.listFiles()?.joinToString { it.name }}")
                }
                return null
            } else {
                Log.d(TAG, "File exists: $fileLocation (${file.length()} bytes)")
            }
        }
        
        val transformation = nodeData["transformation"] as? ArrayList<Double>
        if (transformation == null) {
            return null
        }

        return try {
            sceneView.modelLoader.loadModelInstance(fileLocation)?.let { modelInstance ->
                object : ModelNode(
                    modelInstance = modelInstance,
                    scaleToUnits = transformation.first().toFloat(),
                ) {
                    init {
                        // Apply the full transformation matrix to properly position the node
                        if (transformation.size >= 16) {
                            val matrix = transformation.map { it.toFloat() }.toFloatArray()
                            
                            // Extract position from transformation matrix (column 4: indices 12, 13, 14)
                            val position = ScenePosition(
                                x = matrix[12],
                                y = matrix[13], 
                                z = matrix[14]
                            )
                            
                            // Extract scale from transformation matrix
                            val scaleX = sqrt(matrix[0] * matrix[0] + matrix[1] * matrix[1] + matrix[2] * matrix[2])
                            val scaleY = sqrt(matrix[4] * matrix[4] + matrix[5] * matrix[5] + matrix[6] * matrix[6])
                            val scaleZ = sqrt(matrix[8] * matrix[8] + matrix[9] * matrix[9] + matrix[10] * matrix[10])
                            val scale = SceneScale(x = scaleX, y = scaleY, z = scaleZ)
                            
                            // Extract rotation from transformation matrix
                            val rotation = SceneRotation(
                                x = atan2(matrix[6], matrix[10]),
                                y = atan2(-matrix[2], sqrt(matrix[6] * matrix[6] + matrix[10] * matrix[10])),
                                z = atan2(matrix[1], matrix[0])
                            )
                            
                            // Apply the transformation to the node
                            transform = Transform(
                                position = position,
                                rotation = rotation,
                                scale = scale
                            )
                            
                            Log.d("ArView", "Applied transformation to node $name - Position: (${position.x}, ${position.y}, ${position.z})")
                        } else {
                            Log.w("ArView", "Invalid transformation matrix size: ${transformation.size}, expected 16")
                        }
                        
                        // Set node properties
                        name = nodeData["name"] as? String
                        
                        // CRITICAL FIX: Set gesture properties based on current gesture settings
                        isPositionEditable = this@ArView.handlePans
                        isRotationEditable = this@ArView.handleRotation
                        isTouchable = true
                        
                        Log.d("ArView", "ModelNode init complete - name: $name, isPositionEditable: $isPositionEditable, isRotationEditable: $isRotationEditable, isTouchable: $isTouchable")
                        Log.d("ArView", "Current ArView settings - handlePans: ${this@ArView.handlePans}, handleRotation: ${this@ArView.handleRotation}")
                    }
                }
            } ?: run {
                null
            }
        } catch (e: Exception) {
            e.printStackTrace()
            null
        }
    }

    private fun handleAddNodeToPlaneAnchor(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        try {
            val nodeData = call.arguments as? Map<String, Any>
            val dict_node = nodeData?.get("node") as? Map<String, Any>
            val dict_anchor = nodeData?.get("anchor") as? Map<String, Any>
            if (dict_node == null || dict_anchor == null) {
                result.success(null) // Return null instead of false
                return
            }

            val anchorName = dict_anchor["name"] as? String
            val anchorNode = anchorNodesMap[anchorName]
            if (anchorNode != null) {
                mainScope.launch {
                    try {
                        buildModelNode(dict_node)?.let { node ->
                            // For gesture-enabled nodes, don't add to anchor - add directly to scene
                            if (this@ArView.handlePans || this@ArView.handleRotation) {
                                Log.d("ArView", "Adding gesture-enabled node directly to scene (bypassing anchor)")
                                sceneView.addChildNode(node)
                                
                                // Apply anchor's world position to the node instead of parenting it
                                val anchorWorldPosition = anchorNode.worldPosition
                                node.transform = Transform(
                                    position = anchorWorldPosition,
                                    rotation = node.transform.rotation,
                                    scale = node.transform.scale
                                )
                                Log.d("ArView", "Applied anchor world position to node: (${anchorWorldPosition.x}, ${anchorWorldPosition.y}, ${anchorWorldPosition.z})")
                            } else {
                                // For non-gesture nodes, use normal anchor parenting
                                Log.d("ArView", "Adding non-gesture node to anchor normally")
                                anchorNode.addChildNode(node)
                                sceneView.addChildNode(anchorNode)
                            }
                            
                            node.name?.let { nodeName ->
                                nodesMap[nodeName] = node
                                Log.d("ArView", "Added ModelNode to nodesMap: $nodeName, total nodes: ${nodesMap.size}")
                                Log.d("ArView", "All nodes in map: ${nodesMap.keys}")
                                Log.d("ArView", "Node properties - isPositionEditable: ${node.isPositionEditable}, isTouchable: ${node.isTouchable}")
                                
                                // Update gesture properties after adding node
                                updateNodeGestureProperties()
                                debugGestureConfiguration() // Debug after adding node
                                
                                result.success(nodeName) // Return node name instead of boolean
                            } ?: result.success(null) // Return null if no node name
                        } ?: result.success(null) // Return null instead of false
                    } catch (e: Exception) {
                        Log.e("ArView", "Error building node: ${e.message}")
                        result.success(null) // Return null instead of false
                    }
                }
            } else {
                Log.e("ArView", "Anchor node not found: $anchorName")
                result.success(null) // Return null instead of false
            }
        } catch (e: Exception) {
            result.success(null) // Return null instead of false
        }
    }

    private fun handleAddNodeToScreenPosition(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        try {
            val nodeData = call.arguments as? Map<String, Any>
            val screenPosition = call.argument<Map<String, Double>>("screenPosition")

            if (nodeData == null || screenPosition == null) {
                result.error("INVALID_ARGUMENT", "Node data or screen position is null", null)
                return
            }

            mainScope.launch {
                val node = buildModelNode(nodeData) ?: run {
                    result.success(null)
                    return@launch
                }
                val hitResultNode =
                    HitResultNode(
                        engine = sceneView.engine,
                        xPx = screenPosition["x"]?.toFloat() ?: 0f,
                        yPx = screenPosition["y"]?.toFloat() ?: 0f,
                    ).apply {
                        addChildNode(node)
                    }

                sceneView.addChildNode(hitResultNode)
                // Return the node name if available, otherwise null
                node.name?.let { nodeName ->
                    nodesMap[nodeName] = node
                    Log.d("ArView", "Added ModelNode to nodesMap (screen position): $nodeName, total nodes: ${nodesMap.size}")
                    
                    // Update gesture properties after adding node
                    updateNodeGestureProperties()
                    
                    result.success(nodeName)
                } ?: result.success(null)
            }
        } catch (e: Exception) {
            result.error("ADD_NODE_TO_SCREEN_ERROR", e.message, null)
        }
    }

    private fun debugGestureConfiguration() {
        Log.d("ArView", "=== GESTURE CONFIGURATION DEBUG ===")
        Log.d("ArView", "handleTaps: $handleTaps")
        Log.d("ArView", "handlePans: $handlePans") 
        Log.d("ArView", "handleRotation: $handleRotation")
        Log.d("ArView", "Total nodes in map: ${nodesMap.size}")
        Log.d("ArView", "Node names: ${nodesMap.keys}")
        nodesMap.forEach { (name, node) ->
            Log.d("ArView", "Node $name - isPositionEditable: ${node.isPositionEditable}, isRotationEditable: ${node.isRotationEditable}, isTouchable: ${node.isTouchable}")
        }
        Log.d("ArView", "SceneView gesture handling configured via setOnGestureListener")
        Log.d("ArView", "=== END GESTURE DEBUG ===")
    }

    private fun updateNodeGestureProperties() {
        Log.d("ArView", "=== UPDATING NODE GESTURE PROPERTIES ===")
        Log.d("ArView", "Current gesture settings - handlePans: $handlePans, handleRotation: $handleRotation")
        
        nodesMap.forEach { (name, node) ->
            val oldPositionEditable = node.isPositionEditable
            val oldRotationEditable = node.isRotationEditable
            
            node.isPositionEditable = handlePans
            node.isRotationEditable = handleRotation
            node.isTouchable = true
            
            Log.d("ArView", "Updated node $name - isPositionEditable: $oldPositionEditable -> ${node.isPositionEditable}, isRotationEditable: $oldRotationEditable -> ${node.isRotationEditable}")
        }
        Log.d("ArView", "=== FINISHED UPDATING NODE PROPERTIES ===")
    }

    private fun handleInit(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        try {
            Log.d("ArView", "=== FLUTTER ARGUMENTS DEBUG ===")
            Log.d("ArView", "Raw handleTaps argument: ${call.argument<Boolean>("handleTaps")}")
            Log.d("ArView", "Raw handlePans argument: ${call.argument<Boolean>("handlePans")}")
            Log.d("ArView", "Raw handleRotation argument: ${call.argument<Boolean>("handleRotation")}")
            Log.d("ArView", "Raw planeDetectionConfig argument: ${call.argument<Int>("planeDetectionConfig")}")
            Log.d("ArView", "=== END FLUTTER ARGUMENTS DEBUG ===")
            
            val argShowAnimatedGuide = call.argument<Boolean>("showAnimatedGuide") ?: true
            val argShowFeaturePoints = call.argument<Boolean>("showFeaturePoints") ?: false
            val argPlaneDetectionConfig: Int? = call.argument<Int>("planeDetectionConfig")
            val argShowPlanes = call.argument<Boolean>("showPlanes") ?: true
            val customPlaneTexturePath = call.argument<String>("customPlaneTexturePath")
            val showWorldOrigin = call.argument<Boolean>("showWorldOrigin") ?: false
            // CRITICAL FIX: Properly set the instance variables, don't create local variables
            this.handleTaps = call.argument<Boolean>("handleTaps") ?: true
            this.handlePans = call.argument<Boolean>("handlePans") ?: false
            this.handleRotation = call.argument<Boolean>("handleRotation") ?: false
            
            Log.d("ArView", "Session initialized with gesture settings - handleTaps: ${this.handleTaps}, handlePans: ${this.handlePans}, handleRotation: ${this.handleRotation}")

            sceneView.session?.let { session ->
                session.configure(session.config.apply {
                    depthMode = when (session.isDepthModeSupported(Config.DepthMode.AUTOMATIC)) {
                        true -> Config.DepthMode.AUTOMATIC
                        else -> Config.DepthMode.DISABLED
                    }
                    planeFindingMode = when (argPlaneDetectionConfig) {
                        1 -> Config.PlaneFindingMode.HORIZONTAL
                        2 -> Config.PlaneFindingMode.VERTICAL
                        3 -> Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL
                        else -> Config.PlaneFindingMode.DISABLED
                    }
                    Log.d("ArView", "AR Session configured - planeFindingMode: $planeFindingMode, depthMode: $depthMode")
                    Log.d("ArView", "argPlaneDetectionConfig received: $argPlaneDetectionConfig")
                })
            }

            handleShowWorldOrigin(showWorldOrigin)
            
            sceneView.apply {
                // No HDR environment loaded
                lightEstimationEnabled = false

                environment.intensity = 2.5f // Set a default intensity for the environment light

                addChildNode(
                    AmbientLight(
                    color     = colorOf(1f, 1f, 1f, 1f),
                    intensity = 5_000f
                    )
                )

                planeRenderer.isEnabled = argShowPlanes
                planeRenderer.isVisible = argShowPlanes
                planeRenderer.planeRendererMode = PlaneRenderer.PlaneRendererMode.RENDER_ALL

                onTrackingFailureChanged = { reason ->
                    mainScope.launch {
                        sessionChannel.invokeMethod("onTrackingFailure", reason?.name)
                    }
                }

                if (argShowFeaturePoints == true) {
                    showFeaturePoints = true
                } else {
                    showFeaturePoints = false
                    pointCloudNodes.toList().forEach { removePointCloudNode(it) }
                }

                onFrame = { frameTime ->
                    try {
                        if (!isSessionPaused) {
                            session?.update()?.let { frame ->
                                if (showAnimatedGuide) {
                                    frame.getUpdatedTrackables(Plane::class.java).forEach { plane ->
                                        if (plane.trackingState == TrackingState.TRACKING) {
                                            rootLayout.findViewWithTag<View>("hand_motion_layout")?.let { handMotionLayout ->
                                                rootLayout.removeView(handMotionLayout)
                                                showAnimatedGuide = false
                                            }
                                        }
                                    }
                                }

                                if (showFeaturePoints) {
                                    val currentFps = frame.fps(lastPointCloudFrame)
                                    if (currentFps < 10) {
                                        frame.acquirePointCloud()?.let { pointCloud ->
                                            if (pointCloud.timestamp != lastPointCloudTimestamp) {
                                                lastPointCloudFrame = frame
                                                lastPointCloudTimestamp = pointCloud.timestamp

                                                val pointsSize = pointCloud.ids?.limit() ?: 0

                                                if (pointCloudNodes.isNotEmpty()) {
                                                }
                                                pointCloudNodes.toList().forEach { removePointCloudNode(it) }

                                                val pointsBuffer = pointCloud.points
                                                for (index in 0 until pointsSize) {
                                                    val pointIndex = index * 4
                                                    val position =
                                                        Position(
                                                            pointsBuffer[pointIndex],
                                                            pointsBuffer[pointIndex + 1],
                                                            pointsBuffer[pointIndex + 2],
                                                        )
                                                    val confidence = pointsBuffer[pointIndex + 3]
                                                    addPointCloudNode(index, position, confidence)
                                                }

                                                pointCloud.release()
                                            }
                                        }
                                    }
                                }

                                frame.getUpdatedTrackables(Plane::class.java).forEach { plane ->
                                    if (plane.trackingState == TrackingState.TRACKING &&
                                        !detectedPlanes.contains(plane)
                                    ) {
                                        detectedPlanes.add(plane)
                                        
                                        // Capture the first plane's Y coordinate for constraining object movement
                                        if (detectedPlaneY == null) {
                                            val centerPose = plane.centerPose
                                            detectedPlaneY = centerPose.translation[1] // Y coordinate
                                            Log.d("ArView", "🎯 Captured plane Y coordinate: $detectedPlaneY for movement constraint")
                                        }
                                        
                                        mainScope.launch {
                                            sessionChannel.invokeMethod("onPlaneDetected", detectedPlanes.size)
                                        }
                                    }
                                }
                            }
                        }
                    } catch (e: Exception) {
                        when (e) {
                            is SessionPausedException -> {
                                // Ignorer silencieusement cette exception quand la session est en pause
                                Log.d(TAG, "Session paused, skipping frame update")
                            }
                            else -> {
                                Log.e(TAG, "Error during frame update", e)
                                e.printStackTrace()
                            }
                        }
                    }
                }

                // Set up gesture handling - Use the current SceneView 2.2.1 API
                setOnGestureListener(
                    onSingleTapConfirmed = { motionEvent, node ->
                        Log.d("ArView", "SceneView onSingleTapConfirmed - handleTaps: ${this@ArView.handleTaps}, node: ${node?.name}")
                        
                        // Debug gesture configuration when a node is tapped
                        if (node != null) {
                            debugGestureConfiguration()
                        }
                        
                        if (node != null) {
                            Log.d("ArView", "Tap detected on node: ${node.name}, type: ${node.javaClass.simpleName}")
                            
                            // First, try to find a ModelNode (3D object) that was tapped
                            var modelNodeName: String? = null
                            var currentNode: Node? = node
                            
                            // Traverse up the node hierarchy to find a ModelNode
                            while (currentNode != null) {
                                if (currentNode is ModelNode && currentNode.name != null) {
                                    // Check if this ModelNode is in our managed nodes map
                                    if (nodesMap.containsKey(currentNode.name)) {
                                        modelNodeName = currentNode.name
                                        Log.d("ArView", "Found ModelNode: $modelNodeName")
                                        break
                                    }
                                }
                                currentNode = currentNode.parent
                            }
                            
                            // If we found a ModelNode, report it as tapped
                            if (modelNodeName != null && this@ArView.handleTaps) {
                                Log.d("ArView", "Reporting ModelNode tap: $modelNodeName")
                                objectChannel.invokeMethod("onNodeTap", listOf(modelNodeName))
                                return@setOnGestureListener
                            }
                            
                            // Fallback: look for anchor names (for backward compatibility)
                            var anchorName: String? = null
                            currentNode = node
                            while (currentNode != null) {
                                anchorNodesMap.forEach { (name, anchorNode) ->
                                    if (currentNode == anchorNode) {
                                        anchorName = name
                                        return@forEach
                                    }
                                }
                                if (anchorName != null) break
                                currentNode = currentNode.parent
                            }
                            
                            if (anchorName != null && this@ArView.handleTaps) {
                                Log.d("ArView", "Reporting anchor tap: $anchorName")
                                objectChannel.invokeMethod("onNodeTap", listOf(anchorName))
                            }
                        } else {
                            Log.d("ArView", "Tap detected on empty space (no node hit)")
                            try {
                                // Get current frame to avoid "old frame" errors
                                val currentFrame = sceneView.session?.update()
                                if (currentFrame != null) {
                                    val hitResults = currentFrame.hitTest(motionEvent)
                                    Log.d("ArView", "Hit Results count: ${hitResults.size}")

                                    val serializedResults = hitResults.map { hitResult ->
                                        serializeARCoreHitResult(hitResult)
                                    }
                                    
                                    if (this@ArView.handleTaps) {
                                        notifyPlaneOrPointTap(serializedResults)
                                    }
                                } else {
                                    Log.w("ArView", "No current frame available for hit testing")
                                }
                            } catch (e: Exception) {
                                Log.e("ArView", "Error during hit testing: ${e.message}")
                            }
                        }
                    },
                    onScroll = { e1, e2, node, distance ->
                        // Handle pan gestures for nodes
                        if (node != null && this@ArView.handlePans) {
                            Log.d("ArView", "Scroll detected on node: ${node.name} - handlePans: ${this@ArView.handlePans}")
                            
                            // Find the managed ModelNode
                            var modelNode: ModelNode? = null
                            var currentNode: Node? = node
                            
                            while (currentNode != null) {
                                Log.d("ArView", "Checking node: ${currentNode.name}, type: ${currentNode.javaClass.simpleName}")
                                if (currentNode is ModelNode && currentNode.name != null) {
                                    Log.d("ArView", "Found ModelNode: ${currentNode.name}, in nodesMap: ${nodesMap.containsKey(currentNode.name)}")
                                    if (nodesMap.containsKey(currentNode.name)) {
                                        modelNode = currentNode
                                        break
                                    }
                                }
                                currentNode = currentNode.parent
                            }
                            
                            if (modelNode != null) {
                                // CRITICAL FIX: Force properties and proceed with movement regardless of property check
                                Log.d("ArView", "Gesture detected on node ${modelNode.name}, original isPositionEditable: ${modelNode.isPositionEditable}")
                                
                                // Force enable properties
                                modelNode.isPositionEditable = true
                                modelNode.isTouchable = true
                                
                                // Immediately apply the pan movement - don't wait or check properties again
                                val deltaX = -distance.x * 0.001f // Scale and invert for natural movement
                                val deltaZ = -distance.y * 0.001f // Forward/backward movement (Y gesture maps to Z world coordinate)
                                
                                // Move in camera space
                                val currentPosition = modelNode.position
                                val newPosition = Position(
                                    currentPosition.x + deltaX,
                                    detectedPlaneY ?: currentPosition.y, // Lock to plane Y or keep current Y if no plane detected
                                    currentPosition.z + deltaZ // Allow forward/backward movement
                                )
                                modelNode.position = newPosition
                                
                                Log.d("ArView", "✅ SUCCESSFULLY updated node ${modelNode.name} position from ${currentPosition} to: ${newPosition}")
                                
                                // Notify Flutter with just the node name (Flutter expects String, not Map)
                                objectChannel.invokeMethod("onPanChange", modelNode.name ?: "")
                            } else {
                                Log.w("ArView", "❌ No ModelNode found for gesture")
                            }
                        }
                    },
                    onRotate = { detector, e, node ->
                        Log.d("ArView", "🔄 Native onRotate called - action: ${e.action}, node: ${node?.name}, handleRotation: ${this@ArView.handleRotation}")
                        if (node != null && this@ArView.handleRotation) {
                            // Find the ModelNode we’re managing
                            var modelNode: ModelNode? = null
                            var currentNode: Node? = node
                            while (currentNode != null) {
                                if (currentNode is ModelNode 
                                    && currentNode.name != null 
                                    && nodesMap.containsKey(currentNode.name)) {
                                    modelNode = currentNode
                                    break
                                }
                                currentNode = currentNode.parent
                            }
                            modelNode?.let { mn ->
                                // Enable rotation on the fly
                                mn.isRotationEditable = true
                                mn.isTouchable       = true

                                // Read the raw gesture rotation in radians
                                val rot = detector.rotation

                                // On first event, initialize tracking
                                if (gestureStartRotation == null) {
                                    gestureStartRotation   = rot
                                    lastDetectorRotation   = rot
                                    lastAppliedRotation    = mn.rotation.y
                                    accumulatedRotationDelta = 0f
                                } else {
                                    // Compute the small delta since last frame (handles 360° wrap)
                                    val delta = calculateIncrementalRotationDelta(rot, lastDetectorRotation!!)
                                    accumulatedRotationDelta += delta
                                    lastDetectorRotation = rot
                                }

                                // Scale and apply to the node’s yaw
                                val newYaw = lastAppliedRotation + accumulatedRotationDelta * 1.5f
                                mn.rotation = Rotation(mn.rotation.x, newYaw, mn.rotation.z)

                                // Notify Flutter
                                objectChannel.invokeMethod("onRotationChange", mn.name ?: "")

                                // On gesture end, commit the rotation so next drag starts from here
                                if (e.action == MotionEvent.ACTION_UP || e.action == MotionEvent.ACTION_CANCEL) {
                                    lastAppliedRotation       = newYaw
                                    gestureStartRotation      = null
                                    lastDetectorRotation      = null
                                    accumulatedRotationDelta  = 0f
                                }
                            }
                        }
                        // Return false so other gestures (e.g. pan) aren’t blocked
                        false
                    }
                )

                if (argShowAnimatedGuide == true && showAnimatedGuide == true) {
                    val handMotionLayout =
                        LayoutInflater
                            .from(context)
                            .inflate(R.layout.sceneform_hand_layout, rootLayout, false)
                            .apply {
                                tag = "hand_motion_layout"
                            }
                    rootLayout.addView(handMotionLayout)
                }

                if (customPlaneTexturePath != null) {
                    try {
                        val loader = FlutterInjector.instance().flutterLoader()
                        val assetKey = loader.getLookupKeyForAsset(customPlaneTexturePath)
                        val customPlaneTexture =
                            ImageTexture
                                .Builder()
                                .bitmap(materialLoader.assets, assetKey)
                                .build(engine)
                        planeRenderer.planeMaterial.defaultInstance.apply {
                            setTexture(PlaneRenderer.MATERIAL_TEXTURE, customPlaneTexture)
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "❌ Erreur lors de l'application de la texture personnalisée: ${e.message}")
                        Log.e(TAG, "Stack trace:", e)
                    }
                } else {
                    Log.i(TAG, "ℹ️ Utilisation de la texture par défaut")
                }
            }
            
            // Debug gesture configuration IMMEDIATELY after setting values
            Log.d("ArView", "=== IMMEDIATE GESTURE CONFIGURATION ===")
            Log.d("ArView", "handleTaps: ${this.handleTaps}")
            Log.d("ArView", "handlePans: ${this.handlePans}") 
            Log.d("ArView", "handleRotation: ${this.handleRotation}")
            Log.d("ArView", "=== END IMMEDIATE DEBUG ===")
            
            // Update all existing nodes with current gesture settings
            updateNodeGestureProperties()
            
            debugGestureConfiguration()
            
            result.success(null)
        } catch (e: Exception) {
            result.error("AR_VIEW_ERROR", e.message, null)
        }
    }

    private fun handleAddNode(
        nodeData: Map<String, Any>,
        result: MethodChannel.Result,
    ) {
        try {
            Log.d("ArView", "=== ADDING NODE ===")
            Log.d("ArView", "Current gesture settings - handlePans: $handlePans, handleTaps: $handleTaps")
            
            mainScope.launch {
                val node = buildModelNode(nodeData)
                if (node != null) {
                    sceneView.addChildNode(node)
                    node.name?.let { nodeName ->
                        nodesMap[nodeName] = node
                        Log.d("ArView", "Added ModelNode to nodesMap (direct): $nodeName, total nodes: ${nodesMap.size}")
                        Log.d("ArView", "Node properties - isPositionEditable: ${node.isPositionEditable}, isTouchable: ${node.isTouchable}")
                        
                        // Update gesture properties after adding node
                        updateNodeGestureProperties()
                        debugGestureConfiguration() // Debug after adding node
                        
                        result.success(nodeName) // Return node name instead of boolean
                    } ?: result.success(null) // Return null if no node name
                } else {
                    Log.e("ArView", "Failed to build ModelNode")
                    result.success(null) // Return null instead of false
                }
            }
        } catch (e: Exception) {
            Log.e("ArView", "Error in handleAddNode: ${e.message}")
            result.success(null) // Return null instead of false
        }
    }

    private fun handleRemoveNode(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        try {
            val nodeData = call.arguments as? Map<String, Any>
            val nodeName = nodeData?.get("name") as? String
            
            if (nodeName == null) {
                result.error("INVALID_ARGUMENT", "Node name is required", null)
                return
            }
            
            Log.d(TAG, "Attempting to remove node with name: $nodeName")
            Log.d(TAG, "Current nodes in map: ${nodesMap.keys}")
            
            nodesMap[nodeName]?.let { node ->
                // Détacher d'abord le nœud de son parent s'il en a un
                node.parent?.removeChildNode(node)
                // Puis le retirer de la scène principale
                sceneView.removeChildNode(node)
                // Nettoyer les ressources du nœud
                node.destroy()
                // Enfin le retirer de notre Map
                nodesMap.remove(nodeName)
                
                Log.d(TAG, "Node removed successfully and destroyed")
                result.success(nodeName)
            } ?: run {
                Log.e(TAG, "Node not found in nodesMap")
                result.error("NODE_NOT_FOUND", "Node with name $nodeName not found", null)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error removing node", e)
            result.error("REMOVE_NODE_ERROR", e.message, null)
        }
    }

    private fun handleTransformNode(
    call: MethodCall,
    result: MethodChannel.Result,
) {
    try {
        if (this.handlePans || this.handleRotation) {
            val name = call.argument<String>("name")
            val newTransformation: ArrayList<Double>? = call.argument<ArrayList<Double>>("transformation")

            if (name == null) {
                result.error("INVALID_ARGUMENT", "Node name is required", null)
                return
            }
            nodesMap[name]?.let { node ->
                newTransformation?.let { transform ->
                    if (transform.size != 16) {
                        result.error("INVALID_TRANSFORMATION", "Transformation must be a 4x4 matrix (16 values)", null)
                        return
                    }

                    node.apply {
                        transform(
                            position = ScenePosition(
                                x = transform[12].toFloat(),
                                y = transform[13].toFloat(),
                                z = transform[14].toFloat()
                            ),
                            rotation = SceneRotation(
                                x = atan2(transform[6].toFloat(), transform[10].toFloat()),
                                y = atan2(-transform[2].toFloat(), 
                                    sqrt(transform[6].toFloat() * transform[6].toFloat() + 
                                    transform[10].toFloat() * transform[10].toFloat())),
                                z = atan2(transform[1].toFloat(), transform[0].toFloat())
                            ),
                            scale = SceneScale(
                                x = sqrt((transform[0] * transform[0] + transform[1] * transform[1] + transform[2] * transform[2]).toFloat()),
                                y = sqrt((transform[4] * transform[4] + transform[5] * transform[5] + transform[6] * transform[6]).toFloat()),
                                z = sqrt((transform[8] * transform[8] + transform[9] * transform[9] + transform[10] * transform[10]).toFloat())
                            )
                        )
                    }
                    result.success(null)
                } ?: result.error("INVALID_TRANSFORMATION", "Transformation is required", null)
            } ?: result.error("NODE_NOT_FOUND", "Node with name $name not found", null)
        }
    } catch (e: Exception) {
        result.error("TRANSFORM_NODE_ERROR", e.message, null)
    }
}

    private fun handleHostCloudAnchor(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        try {
            val anchorId = call.argument<String>("anchorId")
            if (anchorId == null) {
                result.error("INVALID_ARGUMENT", "Anchor ID is required", null)
                return
            }

            val session = sceneView.session
            if (session == null) {
                result.error("SESSION_ERROR", "AR Session is not available", null)
                return
            }

            if (!session.canHostCloudAnchor(sceneView.cameraNode)) {
                result.error("HOSTING_ERROR", "Insufficient visual data to host", null)
                return
            }

            val anchor = session.allAnchors.find { it.cloudAnchorId == anchorId }
            if (anchor == null) {
                result.error("ANCHOR_NOT_FOUND", "Anchor with ID $anchorId not found", null)
                return
            }

            val cloudAnchorNode = CloudAnchorNode(sceneView.engine, anchor)
            cloudAnchorNode.host(session) { cloudAnchorId, state ->
                if (state == CloudAnchorState.SUCCESS && cloudAnchorId != null) {
                    result.success(cloudAnchorId)
                } else {
                    result.error("HOSTING_ERROR", "Failed to host cloud anchor: $state", null)
                }
            }
            sceneView.addChildNode(cloudAnchorNode)
        } catch (e: Exception) {
            result.error("HOST_CLOUD_ANCHOR_ERROR", e.message, null)
        }
    }

    private fun handleResolveCloudAnchor(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        try {
            val cloudAnchorId = call.argument<String>("cloudAnchorId")
            if (cloudAnchorId == null) {
                result.error("INVALID_ARGUMENT", "Cloud Anchor ID is required", null)
                return
            }

            val session = sceneView.session
            if (session == null) {
                result.error("SESSION_ERROR", "AR Session is not available", null)
                return
            }

            CloudAnchorNode.resolve(
                sceneView.engine,
                session,
                cloudAnchorId,
            ) { state, node ->
                if (!state.isError && node != null) {
                    sceneView.addChildNode(node)
                    result.success(null)
                } else {
                    result.error("RESOLVE_ERROR", "Failed to resolve cloud anchor: $state", null)
                }
            }
        } catch (e: Exception) {
            result.error("RESOLVE_CLOUD_ANCHOR_ERROR", e.message, null)
        }
    }

    private fun handleRemoveAnchor(
        anchorName: String?,
        result: MethodChannel.Result,
    ) {
        try {
            if (anchorName == null) {
                result.error("INVALID_ARGUMENT", "Anchor name is required", null)
                return
            }

            val anchor = anchorNodesMap[anchorName]
            if (anchor != null) {
                sceneView.removeChildNode(anchor)
                anchor.anchor?.detach()
                result.success(null)
            } else {
                result.error("ANCHOR_NOT_FOUND", "Anchor with name $anchorName not found", null)
            }
        } catch (e: Exception) {
            result.error("REMOVE_ANCHOR_ERROR", e.message, null)
        }
    }

    private fun handleGetCameraPose(result: MethodChannel.Result) {
        try {
            val frame = sceneView.session?.update()
            val cameraPose = frame?.camera?.pose
            if (cameraPose != null) {
                val poseData =
                    mapOf(
                        "position" to
                            mapOf(
                                "x" to cameraPose.tx(),
                                "y" to cameraPose.ty(),
                                "z" to cameraPose.tz(),
                            ),
                        "rotation" to
                            mapOf(
                                "x" to cameraPose.rotationQuaternion[0],
                                "y" to cameraPose.rotationQuaternion[1],
                                "z" to cameraPose.rotationQuaternion[2],
                                "w" to cameraPose.rotationQuaternion[3],
                            ),
                    )
                result.success(poseData)
            } else {
                result.error("NO_CAMERA_POSE", "Camera pose is not available", null)
            }
        } catch (e: Exception) {
            result.error("CAMERA_POSE_ERROR", e.message, null)
        }
    }

    private fun handleGetAnchorPose(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        try {
            val anchorId = call.argument<String>("anchorId")
            if (anchorId == null) {
                result.error("INVALID_ARGUMENT", "Anchor ID is required", null)
                return
            }

            val anchor = sceneView.session?.allAnchors?.find { it.cloudAnchorId == anchorId }
            if (anchor != null) {
                val anchorPose = anchor.pose
                val poseData =
                    mapOf(
                        "position" to
                            mapOf(
                                "x" to anchorPose.tx(),
                                "y" to anchorPose.ty(),
                                "z" to anchorPose.tz(),
                            ),
                        "rotation" to
                            mapOf(
                                "x" to anchorPose.rotationQuaternion[0],
                                "y" to anchorPose.rotationQuaternion[1],
                                "z" to anchorPose.rotationQuaternion[2],
                                "w" to anchorPose.rotationQuaternion[3],
                            ),
                    )
                result.success(poseData)
            } else {
                result.error("ANCHOR_NOT_FOUND", "Anchor with ID $anchorId not found", null)
            }
        } catch (e: Exception) {
            result.error("ANCHOR_POSE_ERROR", e.message, null)
        }
    }

    private fun handleSnapshot(result: MethodChannel.Result) {
        try {
            mainScope.launch {
                val bitmap =
                    withContext(Dispatchers.Main) {
                        val bitmap =
                            Bitmap.createBitmap(
                                sceneView.width,
                                sceneView.height,
                                Bitmap.Config.ARGB_8888,
                            )

                        try {
                            val listener =
                                PixelCopy.OnPixelCopyFinishedListener { copyResult ->
                                    if (copyResult == PixelCopy.SUCCESS) {
                                        val byteStream = java.io.ByteArrayOutputStream()
                                        bitmap.compress(Bitmap.CompressFormat.PNG, 100, byteStream)
                                        val byteArray = byteStream.toByteArray()
                                        result.success(byteArray)
                                    } else {
                                        result.error("SNAPSHOT_ERROR", "Failed to capture snapshot", null)
                                    }
                                }

                            PixelCopy.request(
                                sceneView,
                                bitmap,
                                listener,
                                Handler(Looper.getMainLooper()),
                            )
                        } catch (e: Exception) {
                            result.error("SNAPSHOT_ERROR", e.message, null)
                        }
                    }
            }
        } catch (e: Exception) {
            result.error("SNAPSHOT_ERROR", e.message, null)
        }
    }

    private fun handleShowPlanes(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        try {
            val showPlanes = call.argument<Boolean>("showPlanes") ?: false
            sceneView.apply {
                planeRenderer.isEnabled = showPlanes
            }
            result.success(null)
        } catch (e: Exception) {
            result.error("SHOW_PLANES_ERROR", e.message, null)
        }
    }

    private fun handleAddAnchor(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        try {
            val anchorType = call.argument<Int>("type")
            if (anchorType == 0) { // Plane Anchor
                val transform = call.argument<ArrayList<Double>>("transformation")
                val name = call.argument<String>("name")

                if (name != null && transform != null) {
                    try {
                        // Décomposer la matrice de transformation
                        val (position, rotation) = deserializeMatrix4(transform)

                        val pose =
                            Pose(
                                floatArrayOf(position.x, position.y, position.z),
                                floatArrayOf(rotation.x, rotation.y, rotation.z, 1f),
                            )

                        val anchor = sceneView.session?.createAnchor(pose)
                        if (anchor != null) {
                            val anchorNode = AnchorNode(sceneView.engine, anchor)
                            try {
                                anchorNode.transform =
                                    Transform(
                                        position = position,
                                        rotation = rotation,
                                    )
                            } catch (e: Exception) {
                                Log.w(TAG, "Transform warning suppressed: ${e.message}")
                            }

                            sceneView.addChildNode(anchorNode)
                            anchorNodesMap[name] = anchorNode
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Error in transform calculation: ${e.message}")
                        result.success(false)
                    }
                } else {
                    result.success(false)
                }
            } else {
                result.success(false)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error in handleAddAnchor: ${e.message}")
            e.printStackTrace()
            result.success(false)
        }
    }

    private fun handleInitGoogleCloudAnchorMode(result: MethodChannel.Result) {
        try {
            Log.d(TAG, "🔄 Initialisation du mode Cloud Anchor...")
            sceneView.session?.let { session ->
                session.configure(session.config.apply {
                    cloudAnchorMode = Config.CloudAnchorMode.ENABLED
                })
            }
            result.success(null)
        } catch (e: Exception) {
            Log.e(TAG, "❌ Erreur lors de l'initialisation du mode Cloud Anchor", e)
            mainScope.launch {
                sessionChannel.invokeMethod("onError", listOf("Error initializing cloud anchor mode: ${e.message}"))
            }
            result.error("CLOUD_ANCHOR_INIT_ERROR", e.message, null)
        }
    }

    private fun handleUploadAnchor(call: MethodCall, result: MethodChannel.Result) {
        try {
            val anchorName = call.argument<String>("name")
            Log.d(TAG, "⚓ Début de l'upload de l'ancre: $anchorName")
            
            // Vérifier si le mode Cloud Anchor est initialisé
            val session = sceneView.session
            if (session == null) {
                Log.e(TAG, "❌ Erreur: session AR non disponible")
                result.error("SESSION_ERROR", "AR Session is not available", null)
                return
            }

            // Vérifier et initialiser le mode Cloud Anchor si nécessaire
            Log.d(TAG, "🔄 Vérification de la configuration Cloud Anchor...")
            try {
                sceneView.configureSession { session, config ->
                    config.cloudAnchorMode = Config.CloudAnchorMode.ENABLED
                    config.updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE
                }
                Log.d(TAG, "✅ Mode Cloud Anchor configuré avec succès")
            } catch (e: Exception) {
                Log.e(TAG, "❌ Erreur lors de la configuration du mode Cloud Anchor", e)
                result.error("CLOUD_ANCHOR_CONFIG_ERROR", e.message, null)
                return
            }

            // Continuer avec le reste du code existant...
            if (anchorName == null) {
                Log.e(TAG, "❌ Erreur: nom de l'ancre manquant")
                result.error("INVALID_ARGUMENT", "Anchor name is required", null)
                return
            }

            Log.d(TAG, "📱 Vérification de la capacité à héberger l'ancre cloud...")
            if (!session.canHostCloudAnchor(sceneView.cameraNode)) {
                Log.e(TAG, "❌ Erreur: données visuelles insuffisantes pour héberger l'ancre cloud")
                result.error("HOSTING_ERROR", "Insufficient visual data to host", null)
                return
            }

            val anchorNode = anchorNodesMap[anchorName]
            if (anchorNode == null) {
                Log.e(TAG, "❌ Erreur: ancre non trouvée: $anchorName")
                Log.d(TAG, "📍 Ancres disponibles: ${anchorNodesMap.keys}")
                result.error("ANCHOR_NOT_FOUND", "Anchor not found: $anchorName", null)
                return
            }

            Log.d(TAG, "🔄 Création du CloudAnchorNode...")
            val cloudAnchorNode = CloudAnchorNode(sceneView.engine, anchorNode.anchor!!)
            
            Log.d(TAG, "☁️ Début de l'hébergement de l'ancre cloud...")
            cloudAnchorNode.host(session) { cloudAnchorId, state ->
                Log.d(TAG, "📡 État de l'hébergement: $state, ID: $cloudAnchorId")
                mainScope.launch {
                    if (state == CloudAnchorState.SUCCESS && cloudAnchorId != null) {
                        Log.d(TAG, "✅ Ancre cloud hébergée avec succès: $cloudAnchorId")
                        val args = mapOf(
                            "name" to anchorName,
                            "cloudanchorid" to cloudAnchorId
                        )
                        anchorChannel.invokeMethod("onCloudAnchorUploaded", args)
                        result.success(true)
                    } else {
                        Log.e(TAG, "❌ Échec de l'hébergement de l'ancre cloud: $state")
                        sessionChannel.invokeMethod("onError", listOf("Failed to host cloud anchor: $state"))
                        result.error("HOSTING_ERROR", "Failed to host cloud anchor: $state", null)
                    }
                }
            }
            
            Log.d(TAG, "➕ Ajout du CloudAnchorNode à la scène...")
            sceneView.addChildNode(cloudAnchorNode)
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Exception lors de l'upload de l'ancre", e)
            Log.e(TAG, "Stack trace:", e)
            result.error("UPLOAD_ANCHOR_ERROR", e.message, null)
        }
    }

    private fun handleDownloadAnchor(call: MethodCall, result: MethodChannel.Result) {
        try {
            val cloudAnchorId = call.argument<String>("cloudanchorid")
            if (cloudAnchorId == null) {
                mainScope.launch {
                    sessionChannel.invokeMethod("onError", listOf("Cloud Anchor ID is required"))
                }
                result.error("INVALID_ARGUMENT", "Cloud Anchor ID is required", null)
                return
            }

            val session = sceneView.session
            if (session == null) {
                mainScope.launch {
                    sessionChannel.invokeMethod("onError", listOf("AR Session is not available"))
                }
                result.error("SESSION_ERROR", "AR Session is not available", null)
                return
            }

            CloudAnchorNode.resolve(
                sceneView.engine,
                session,
                cloudAnchorId
            ) { state, node ->
                mainScope.launch {
                    if (!state.isError && node != null) {
                        sceneView.addChildNode(node)
                        val anchorData = mapOf(
                            "type" to 0,
                            "cloudanchorid" to cloudAnchorId
                        )
                        anchorChannel.invokeMethod(
                            "onAnchorDownloadSuccess",
                            anchorData,
                            object : MethodChannel.Result {
                                override fun success(result: Any?) {
                                    val anchorName = result.toString()
                                    anchorNodesMap[anchorName] = node
                                }

                                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                                    sessionChannel.invokeMethod("onError", listOf("Error registering downloaded anchor: $errorMessage"))
                                }

                                override fun notImplemented() {
                                    sessionChannel.invokeMethod("onError", listOf("Error registering downloaded anchor: not implemented"))
                                }
                            }
                        )
                        result.success(true)
                    } else {
                        sessionChannel.invokeMethod("onError", listOf("Failed to resolve cloud anchor: $state"))
                        result.error("RESOLVE_ERROR", "Failed to resolve cloud anchor: $state", null)
                    }
                }
            }
        } catch (e: Exception) {
            mainScope.launch {
                sessionChannel.invokeMethod("onError", listOf("Error downloading anchor: ${e.message}"))
            }
            result.error("DOWNLOAD_ANCHOR_ERROR", e.message, null)
        }
    }

    override fun getView(): View = rootLayout

    override fun dispose() {
        Log.i(TAG, "dispose")
        sessionChannel.setMethodCallHandler(null)
        objectChannel.setMethodCallHandler(null)
        anchorChannel.setMethodCallHandler(null)
        nodesMap.clear()
        sceneView.destroy()
        pointCloudNodes.toList().forEach { removePointCloudNode(it) }
        pointCloudModelInstances.clear()
    }

    private fun notifyError(error: String) {
        mainScope.launch {
            sessionChannel.invokeMethod("onError", listOf(error))
        }
    }

    private fun notifyCloudAnchorUploaded(args: Map<String, Any>) {
        mainScope.launch {
            anchorChannel.invokeMethod("onCloudAnchorUploaded", args)
        }
    }

    private fun notifyAnchorDownloadSuccess(
        anchorData: Map<String, Any>,
        result: MethodChannel.Result,
    ) {
        mainScope.launch {
            anchorChannel.invokeMethod(
                "onAnchorDownloadSuccess",
                anchorData,
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        val anchorName = result.toString()
                        // Mettre à jour l'ancre avec le nom reçu
                    }

                    override fun error(
                        errorCode: String,
                        errorMessage: String?,
                        errorDetails: Any?,
                    ) {
                        notifyError("Error while registering downloaded anchor: $errorMessage")
                    }

                    override fun notImplemented() {
                        notifyError("Error while registering downloaded anchor")
                    }
                },
            )
        }
    }

    private fun notifyPlaneOrPointTap(hitResults: List<Map<String, Any>>) {
        mainScope.launch {
            try {
                val serializedResults = ArrayList<HashMap<String, Any>>()
                hitResults.forEach { hit ->
                    serializedResults.add(serializeHitResult(hit))
                }
                sessionChannel.invokeMethod("onPlaneOrPointTap", serializedResults)
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    private fun getPointCloudModelInstance(): ModelInstance? {
        if (pointCloudModelInstances.isEmpty()) {
            pointCloudModelInstances =
                sceneView.modelLoader
                    .createInstancedModel(
                        assetFileLocation = "models/point_cloud.glb",
                        count = 1000,
                    ).toMutableList()
        }
        return pointCloudModelInstances.removeLastOrNull()
    }

    private fun addPointCloudNode(
        id: Int,
        position: Position,
        confidence: Float,
    ) {
        if (pointCloudNodes.size < 1000) { // Limite max de points
            getPointCloudModelInstance()?.let { modelInstance ->
                val pointCloudNode =
                    PointCloudNode(
                        modelInstance = modelInstance,
                        id = id,
                        confidence = confidence,
                    ).apply {
                        this.position = position
                    }
                pointCloudNodes += pointCloudNode
                sceneView.addChildNode(pointCloudNode)
            }
        }
    }

    private fun removePointCloudNode(pointCloudNode: PointCloudNode) {
        pointCloudNodes -= pointCloudNode
        sceneView.removeChildNode(pointCloudNode)
        pointCloudNode.destroy()
    }

    private fun makeWorldOriginNode(context: Context): Node {
        val axisSize = 0.1f
        val axisRadius = 0.005f
        
        // Utilisation de l'engine de sceneView
        val engine = sceneView.engine
        val materialLoader = MaterialLoader(engine, context)
        
        // Création du noeud racine
        val rootNode = Node(engine = engine)
        
        // Création des cylindres avec leurs matériaux respectifs
        val xNode = CylinderNode(
            engine = engine,
            radius = axisRadius,
            height = axisSize,
            materialInstance = materialLoader.createColorInstance(
                color = colorOf(1f, 0f, 0f, 1f),
                metallic = 0.0f,
                roughness = 0.4f
            )
        )
        
        val yNode = CylinderNode(
            engine = engine,
            radius = axisRadius,
            height = axisSize,
            materialInstance = materialLoader.createColorInstance(
                color = colorOf(0f, 1f, 0f, 1f),
                metallic = 0.0f,
                roughness = 0.4f
            )
        )
        
        val zNode = CylinderNode(
            engine = engine,
            radius = axisRadius,
            height = axisSize,
            materialInstance = materialLoader.createColorInstance(
                color = colorOf(0f, 0f, 1f, 1f),
                metallic = 0.0f,
                roughness = 0.4f
            )
        )

        rootNode.addChildNode(xNode)
        rootNode.addChildNode(yNode)
        rootNode.addChildNode(zNode)

        // Positionnement des axes
        xNode.position = Position(axisSize / 2, 0f, 0f)
        xNode.rotation = Rotation(0f, 0f, 90f)  // Rotation autour de l'axe Z

        yNode.position = Position(0f, axisSize / 2, 0f)
        // Pas besoin de rotation pour l'axe Y car il est déjà orienté correctement

        zNode.position = Position(0f, 0f, axisSize / 2)
        zNode.rotation = Rotation(90f, 0f, 0f)  // Rotation autour de l'axe X

        return rootNode
    }

    private fun handleShowWorldOrigin(show: Boolean) {
        if (show) {
            // Création du nouveau node seulement si nécessaire
            if (worldOriginNode == null) {
                worldOriginNode = makeWorldOriginNode(viewContext)
            }
            // Utilisation du safe call operator
            worldOriginNode?.let { node ->
                sceneView.addChildNode(node)
            }
        } else {
            // Utilisation du safe call operator
            worldOriginNode?.let { node ->
                sceneView.removeChildNode(node)
            }
            // Optionnel : remettre à null après suppression
            worldOriginNode = null
        }
    }

    
}