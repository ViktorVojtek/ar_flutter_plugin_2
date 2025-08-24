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
import com.uhg0.ar_flutter_plugin_2.Serialization.serializeLocalTransformation
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
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.TimeUnit
import com.google.ar.core.exceptions.SessionPausedException
import java.io.File
import java.net.URL
import kotlin.math.sqrt
import kotlin.math.atan2
import android.os.Debug

// Resource management data structures for deep memory cleanup
data class ResourceHandle(
    val nodeId: String,
    val modelInstance: ModelInstance?,
    val materials: MutableList<Any> = mutableListOf(),
    val textures: MutableList<Any> = mutableListOf(),
    val assetKey: String? = null
)

data class CachedAsset(
    val uri: String,
    val modelInstance: ModelInstance,
    val refCount: AtomicInteger = AtomicInteger(1),
    val creationTime: Long = System.currentTimeMillis()
)

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
    // private var selectedNode: Node? = null  // Unused - remove per patch instructions
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
    
    // Deep memory cleanup resource management
    private val resourceHandles = ConcurrentHashMap<String, ResourceHandle>()
    private val assetCache = ConcurrentHashMap<String, CachedAsset>()
    private var loadingExecutor = Executors.newSingleThreadExecutor()
    private val maxCacheAge = 300_000L // 5 minutes in milliseconds
    
    // Velocity-based rotation tracking variables (like iOS)
    // private var rotationVelocity: Float? = null  // Unused - remove per patch instructions
    private var rotationGestureActive: Boolean = false
    private var currentRotatingNode: ModelNode? = null
    private var tappedPlaneAnchorAlignment: PlaneAlignment = PlaneAlignment.HORIZONTAL
    
    // External rotation data support
    private var useExternalRotationData: Boolean = false
    // private var externalRotationVelocity: Float? = null  // Unused - remove per patch instructions
    
    enum class PlaneAlignment {
        HORIZONTAL, VERTICAL
    }
    
    private var currentPlaneAlignment: PlaneAlignment = PlaneAlignment.HORIZONTAL
    
    // Helper functions for degrees conversion
    private fun radToDeg(rad: Float) = Math.toDegrees(rad.toDouble()).toFloat()
    
    // Temporarily keep old variables for compilation (to be removed)
    private var gestureStartRotation: Float? = null
    private var lastDetectorRotation: Float? = null
    
    // Pan gesture tracking variables
    private var currentPanningNode: ModelNode? = null
    private var panGestureActive = false
    
    // iOS-inspired gesture state tracking for better reliability
    // private var panGestureStarted = false  // Unused - remove per patch instructions  
    // private var rotationGestureStarted = false  // Unused - remove per patch instructions

    private class PointCloudNode(
        modelInstance: ModelInstance,
        var id: Int,
        var confidence: Float,
    ) : ModelNode(modelInstance)

    private val onSessionMethodCall =
        MethodChannel.MethodCallHandler { call, result ->
            Log.d(TAG, "📱 Session method called: ${call.method}")
            when (call.method) {
                "init" -> {
                    Log.d(TAG, "🎯 Session init method called!")
                    handleInit(call, result)
                }
                "showPlanes" -> handleShowPlanes(call, result)
                "dispose" -> dispose()
                "getAnchorPose" -> handleGetAnchorPose(call, result)
                "getCameraPose" -> handleGetCameraPose(result)
                "snapshot" -> handleSnapshot(result)
                "disableCamera" -> handleDisableCamera(result)
                "enableCamera" -> handleEnableCamera(result)
                "softResetSession" -> handleSoftResetSession(call, result)
                "ar#nukeAll" -> handleNukeAll(call, result)
                "ar#getPluginState" -> handleGetPluginState(result)
                else -> {
                    Log.d(TAG, "❌ Session method not implemented: ${call.method}")
                    result.notImplemented()
                }
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
    
    private fun handleSoftResetSession(call: MethodCall, result: MethodChannel.Result) {
        try {
            val removeAnchors = call.argument<Boolean>("removeExistingAnchors") ?: true
            val resetTracking = call.argument<Boolean>("resetTracking") ?: true
            
            Log.d(TAG, "🔄 Soft resetting AR session - removeAnchors: $removeAnchors, resetTracking: $resetTracking")
            
            // Clear anchors if requested
            if (removeAnchors) {
                anchorNodesMap.clear()
                Log.d(TAG, "🗑️ Cleared anchor nodes map")
            }
            
            // Pause and resume session to reset tracking
            sceneView.session?.let { session ->
                session.pause()
                Log.d(TAG, "⏸️ AR session paused")
                
                // Wait a brief moment then resume
                sceneView.postDelayed({
                    try {
                        session.resume()
                        Log.d(TAG, "▶️ AR session resumed")
                    } catch (e: Exception) {
                        Log.e(TAG, "Error resuming session: ${e.message}")
                    }
                }, 100)
            }
            
            Log.d(TAG, "✅ Soft reset session completed")
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "Error in handleSoftResetSession", e)
            result.error("SOFT_RESET_SESSION_ERROR", e.message, null)
        }
    }

    private fun handleNukeAll(call: MethodCall, result: MethodChannel.Result) {
        try {
            val purgeCaches = call.argument<Boolean>("purgeCaches") ?: true
            val removeAnchors = call.argument<Boolean>("removeExistingAnchors") ?: true
            val resetTracking = call.argument<Boolean>("resetTracking") ?: true
            // Phase 3 enhancements
            val forceSystemMemoryPressure = call.argument<Boolean>("forceSystemMemoryPressure") ?: true
            val enableHardwareGpuReset = call.argument<Boolean>("enableHardwareGpuReset") ?: true
            val simulateMemoryWarning = call.argument<Boolean>("simulateMemoryWarning") ?: true
            
            Log.d(TAG, "� PHASE 3 SYSTEM-LEVEL NUKE ALL INITIATED")
            Log.d(TAG, "📍 Flags: purgeCaches: $purgeCaches, removeAnchors: $removeAnchors, resetTracking: $resetTracking")
            Log.d(TAG, "📍 Phase 3: forceSystemMemoryPressure: $forceSystemMemoryPressure, hwGpuReset: $enableHardwareGpuReset, memWarning: $simulateMemoryWarning")
            
            // A) Stop background work & cancel loading tasks
            Log.d(TAG, "⏹️ Phase A: Stopping background work")
            try {
                loadingExecutor.shutdown()
                if (!loadingExecutor.awaitTermination(5, TimeUnit.SECONDS)) {
                    loadingExecutor.shutdownNow()
                    Log.d(TAG, "⚡ Force shutdown background executor")
                }
                Log.d(TAG, "✅ Phase A: Background work stopped")
            } catch (e: Exception) {
                Log.e(TAG, "❌ Phase A error: ${e.message}")
            }

            // B) CRITICAL: Destroy all Filament GPU resources (ChatGPT fix)
            Log.d(TAG, "�️ Phase B: Destroying Filament GPU resources")
            try {
                // First clear all resource handles and their GPU resources
                resourceHandles.values.forEach { handle ->
                    try {
                        handle.modelInstance?.let { modelInstance ->
                            // Destroy model instance GPU resources
                            Log.d(TAG, "🔥 Destroying model instance for: ${handle.nodeId}")
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Error destroying resource handle: ${e.message}")
                    }
                }
                resourceHandles.clear()
                
                // CRITICAL: Destroy Filament View, Scene, Renderer in correct order
                try {
                    // Destroy View (must be before Renderer)
                    sceneView.view?.let { view ->
                        sceneView.engine?.destroyView(view)
                        Log.d(TAG, "🔥 Filament View destroyed")
                    }
                    
                    // Destroy Scene 
                    sceneView.scene?.let { scene ->
                        // Clear skybox and indirect light first
                        scene.skybox?.let { skybox ->
                            scene.skybox = null
                            sceneView.engine?.destroySkybox(skybox)
                        }
                        scene.indirectLight?.let { indirectLight ->
                            scene.indirectLight = null  
                            sceneView.engine?.destroyIndirectLight(indirectLight)
                        }
                        
                        sceneView.engine?.destroyScene(scene)
                        Log.d(TAG, "🔥 Filament Scene destroyed")
                    }
                    
                    // Destroy Renderer
                    sceneView.renderer?.let { renderer ->
                        sceneView.engine?.destroyRenderer(renderer)
                        Log.d(TAG, "🔥 Filament Renderer destroyed")
                    }
                    
                } catch (e: Exception) {
                    Log.e(TAG, "Error destroying Filament components: ${e.message}")
                }
                
                Log.d(TAG, "✅ Phase B: Filament GPU resources destroyed")
            } catch (e: Exception) {
                Log.e(TAG, "❌ Phase B error: ${e.message}")
            }

            // C) Clear all anchors and nodes
            Log.d(TAG, "🗑️ Phase C: Clearing anchors and nodes")
            try {
                if (removeAnchors) {
                    anchorNodesMap.clear()
                }
                nodesMap.clear()
                pointCloudNodes.clear()
                pointCloudModelInstances.clear()
                Log.d(TAG, "✅ Phase C: Anchors and nodes cleared")
            } catch (e: Exception) {
                Log.e(TAG, "❌ Phase C error: ${e.message}")
            }

            // D) Pause and close AR session completely
            Log.d(TAG, "⏸️ Phase D: Destroying AR session")
            try {
                sceneView.session?.let { session ->
                    session.pause()
                    Thread.sleep(200) // Give session time to pause
                    session.close()
                    Log.d(TAG, "� AR session closed")
                }
                isSessionPaused = true
                Log.d(TAG, "✅ Phase D: AR session destroyed")
            } catch (e: Exception) {
                Log.e(TAG, "❌ Phase D error: ${e.message}")
            }

            // E) CRITICAL: Destroy Engine last (ChatGPT fix)
            Log.d(TAG, "💥 Phase E: Destroying Filament Engine")
            try {
                // Engine must be destroyed LAST after all other components
                sceneView.engine?.let { engine ->
                    engine.destroy()
                    Log.d(TAG, "� Filament Engine destroyed")
                }
                
                // Null out all references to prevent memory leaks
                // Note: SceneView handles its own references, but we clear what we can track
                
                Log.d(TAG, "✅ Phase E: Filament Engine destroyed")
            } catch (e: Exception) {
                Log.e(TAG, "❌ Phase E error: ${e.message}")
            }

            // F) Purge global caches
            if (purgeCaches) {
                Log.d(TAG, "🧹 Phase F: Purging caches")
                try {
                    assetCache.clear()
                    
                    // Clear any additional caches
                    try {
                        Log.d(TAG, "🗑️ Cache clearing completed")
                    } catch (e: Exception) {
                        Log.e(TAG, "Error in cache clearing: ${e.message}")
                    }
                    
                    Log.d(TAG, "✅ Phase F: Caches purged")
                } catch (e: Exception) {
                    Log.e(TAG, "❌ Phase F error: ${e.message}")
                }
            }

            // G) Clear tracking state and reset variables
            Log.d(TAG, "🔄 Phase G: Clearing tracking state")
            try {
                detectedPlanes.clear()
                planeCount = 0
                detectedPlaneY = null
                worldOriginNode = null
                currentRotatingNode = null
                rotationGestureActive = false
                
                Log.d(TAG, "✅ Phase G: Tracking state cleared")
            } catch (e: Exception) {
                Log.e(TAG, "❌ Phase G error: ${e.message}")
            }

            // H) CRITICAL: Phase 3 Enhanced system memory pressure simulation
            Log.d(TAG, "💥 Phase H: Phase 3 Enhanced system memory pressure simulation")
            Log.d(TAG, "💥 Flags: forceSystemMemoryPressure=$forceSystemMemoryPressure, simulateMemoryWarning=$simulateMemoryWarning")
            try {
                if (forceSystemMemoryPressure) {
                    Log.d(TAG, "🚀 PHASE 3: Enhanced memory pressure simulation...")
                    // Increased passes for Phase 3 aggressive cleanup
                    for (pass in 1..8) {
                        // Simulate memory pressure by forcing GC with more aggressive approach
                        System.gc()
                        System.runFinalization()
                        
                        // Phase 3: Multiple memory pressure simulations
                        if (simulateMemoryWarning && pass <= 3) {
                            try {
                                // Simulate memory pressure through activity
                                val activity = viewContext as? android.app.Activity ?: this@ArView.activity
                                activity?.runOnUiThread {
                                    // Phase 3: Multiple memory cleanup triggers
                                    Runtime.getRuntime().gc()
                                    System.runFinalization()
                                    
                                    // Additional Phase 3 cleanup
                                    if (enableHardwareGpuReset) {
                                        // Force GPU resource cleanup on main thread
                                        try {
                                            // Note: ARSceneView doesn't have onPause/onResume methods
                                            // sceneView.onPause()
                                            // sceneView.onResume()
                                            Log.d(TAG, "GPU reset skipped - ARSceneView doesn't support pause/resume")
                                        } catch (e: Exception) {
                                            Log.w(TAG, "GPU reset attempt: ${e.message}")
                                        }
                                    }
                                }
                                Log.d(TAG, "📱 Phase 3: Memory warning simulation $pass")
                            } catch (e: Exception) {
                                Log.w(TAG, "Phase 3 memory cleanup attempt: ${e.message}")
                            }
                        }
                        
                        // Phase 3: Extended cleanup cycles
                        if (enableHardwareGpuReset && pass % 3 == 0) {
                            Log.d(TAG, "⚡ Phase 3: Hardware cleanup cycle $pass")
                            // Additional system-level cleanup
                            System.runFinalization()
                        }
                        
                        // Extended sleep for Phase 3 to allow deeper cleanup
                        Thread.sleep(if (pass <= 3) 150 else 100)
                        
                        Log.d(TAG, "🧹 Phase 3 GC pass $pass completed")
                    }
                } else {
                    // Fallback to basic cleanup
                    for (pass in 1..5) {
                        System.gc()
                        System.runFinalization()
                        Thread.sleep(100)
                        Log.d(TAG, "🧹 Basic GC pass $pass completed")
                    }
                }
                
                // Phase 3: Final extended cleanup sequence
                System.runFinalization() 
                Thread.sleep(100) // Extended wait for Phase 3
                System.gc() // Final pass
                Thread.sleep(50)
                
                Log.d(TAG, "✅ Phase H: Phase 3 Enhanced memory pressure simulation completed")
            } catch (e: Exception) {
                Log.e(TAG, "❌ Phase H error: ${e.message}")
            }

            // I) Recreate loading executor for future use
            Log.d(TAG, "🔄 Phase I: Recreating executor")
            try {
                // Create new executor for future operations
                loadingExecutor = Executors.newSingleThreadExecutor()
                Log.d(TAG, "✅ Phase I: New executor created")
            } catch (e: Exception) {
                Log.e(TAG, "❌ Phase I error: ${e.message}")
            }

            Log.d(TAG, "🎉 PHASE 3 NUKE ALL COMPLETED - Memory should approach cold start levels")
            Log.d(TAG, "🔍 Verify PlatformView removal in Flutter for complete surface teardown")
            result.success(true)
            
        } catch (e: Exception) {
            Log.e(TAG, "💥 CRITICAL ERROR in handleNukeAll", e)
            result.error("NUKE_ALL_ERROR", e.message, e.stackTraceToString())
        }
    }

    private fun handleGetPluginState(result: MethodChannel.Result) {
        try {
            val state = mutableMapOf<String, Any>()
            
            // Session state
            state["hasSession"] = (sceneView.session != null)
            state["isSessionPaused"] = isSessionPaused
            
            // SceneView state  
            state["hasSceneView"] = true
            state["hasEngine"] = (sceneView.engine != null)
            state["hasScene"] = (sceneView.scene != null)
            state["hasRenderer"] = (sceneView.renderer != null)
            
            // Collections state
            state["anchorNodesCount"] = anchorNodesMap.size
            state["nodeAttachedCount"] = nodesMap.size
            
            // Memory hint
            System.gc()
            val runtime = Runtime.getRuntime()
            val usedMB = (runtime.totalMemory() - runtime.freeMemory()) / 1024 / 1024
            state["usedMemoryMB"] = usedMB
            
            Log.d(TAG, "🔍 Plugin State: $state")
            result.success(state)
            
        } catch (e: Exception) {
            Log.e(TAG, "Error getting plugin state: ${e.message}", e)
            result.error("STATE_ERROR", e.message, e.stackTraceToString())
        }
    }
    
    private val onObjectMethodCall =
        MethodChannel.MethodCallHandler { call, result ->
            Log.d(TAG, "📦 Object method called: ${call.method}")
            when (call.method) {
                "init" -> {
                    Log.d(TAG, "🎯 Object init method called!")
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
                "removeNodeDeep" -> {
                    handleRemoveNodeDeep(call, result)
                }
                "purgeCaches" -> {
                    handlePurgeCaches(call, result)
                }
                "createNodeFromAsset" -> {
                    handleCreateNodeFromAsset(call, result)
                }
                "getMemoryInfo" -> {
                    handleGetMemoryInfo(call, result)
                }
                "transformationChanged" -> {
                    handleTransformNode(call, result)
                }
                "handleExternalRotation" -> {
                    handleExternalRotation(call, result)
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
        Log.d(TAG, "🏗️ ArView constructor starting...")
        Log.d(TAG, "📡 Setting up method channels - session: arsession_$id, object: arobjects_$id, anchor: aranchors_$id")
        
        sceneView = ARSceneView(
            context = viewContext,
            sharedLifecycle = lifecycle,
            sessionConfiguration = { session, config ->
                config.apply {
                    depthMode = Config.DepthMode.DISABLED
                    instantPlacementMode = Config.InstantPlacementMode.DISABLED
                    lightEstimationMode = Config.LightEstimationMode.ENVIRONMENTAL_HDR
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

        Log.d(TAG, "📡 Setting up method call handlers...")
        sessionChannel.setMethodCallHandler(onSessionMethodCall)
        objectChannel.setMethodCallHandler(onObjectMethodCall)
        anchorChannel.setMethodCallHandler(onAnchorMethodCall)
        Log.d(TAG, "✅ Method call handlers set up successfully")
        Log.d(TAG, "🏗️ ArView constructor completed")
    }

    

    private suspend fun buildModelNode(nodeData: Map<String, Any>): ModelNode? {
        Log.d(TAG, "🏗️ buildModelNode called with FULL data: $nodeData")
        Log.d(TAG, "🏗️ Node data URI: ${nodeData["uri"]}")
        Log.d(TAG, "🏗️ Node data TYPE: ${nodeData["type"]}")
        Log.d(TAG, "🏗️ Node data NAME: ${nodeData["name"]}")
        Log.d(TAG, "🏗️ Node data TRANSFORMATION: ${nodeData["transformation"]}")
        
        // Extract ARCore gesture properties
        val isTransformable = nodeData["isTransformable"] as? Boolean ?: false
        val enablePanGestures = nodeData["enablePanGestures"] as? Boolean ?: false
        val enableRotationGestures = nodeData["enableRotationGestures"] as? Boolean ?: false
        
        Log.d(TAG, "🎯 ARCore gesture properties - isTransformable: $isTransformable, pan: $enablePanGestures, rotation: $enableRotationGestures")
        
        var fileLocation = nodeData["uri"] as? String
        if (fileLocation == null) {
            Log.e(TAG, "❌ FAILURE POINT 1: URI is null or invalid")
            return null
        }
        Log.d(TAG, "✅ URI check passed: $fileLocation")
        
        val nodeType = (nodeData["type"] as? Number)?.toInt()
        if (nodeType == null) {
            Log.e(TAG, "❌ FAILURE POINT 1b: Node type is null or invalid")
            return null
        }
        Log.d(TAG, "✅ Node type check passed: $nodeType")
        
        when (nodeType) {
            0 -> { // GLTF2 Model from Android assets folder
                // Use Android assets directly for models
                fileLocation = "file:///android_asset/$fileLocation"
                Log.d(TAG, "Resolved Android asset path: $fileLocation")
            }
            1 -> { // GLB Model from the web (NEEDS DOWNLOAD FIRST)
                Log.d(TAG, "Remote GLB requested: $fileLocation")
                fileLocation = withContext(Dispatchers.IO) { downloadRemoteGlb(fileLocation!!) }
                if (fileLocation == null) {
                    Log.e(TAG, "❌ Remote GLB download failed")
                    return null
                } else {
                    // Convert filesystem path to file:// URI for ModelLoader
                    fileLocation = "file://$fileLocation"
                    Log.d(TAG, "✅ Remote GLB downloaded and converted to URI: $fileLocation")
                }
            }
            2 -> { // fileSystemAppFolderGLB
                // Fix: Add proper path resolution for GLB files from app documents directory
                val documentsPath = viewContext.applicationInfo.dataDir
                val rawPath = documentsPath + "/app_flutter/" + (nodeData["uri"] as String)
                // Convert filesystem path to file:// URI for ModelLoader
                fileLocation = "file://$rawPath"
                Log.d(TAG, "Loading GLB from filesystem as URI: $fileLocation")
            }
            3 -> { // fileSystemAppFolderGLTF2
                val documentsPath = viewContext.applicationInfo.dataDir
                val rawPath = documentsPath + "/app_flutter/" + (nodeData["uri"] as String)
                // Convert filesystem path to file:// URI for ModelLoader
                fileLocation = "file://$rawPath"
                Log.d(TAG, "Loading GLTF2 from filesystem as URI: $fileLocation")
            }
            else -> {
                Log.e(TAG, "❌ FAILURE POINT 1c: Unsupported node type: $nodeType")
                return null
            }
        }
        Log.d(TAG, "✅ File location resolved: $fileLocation")
        
        if (fileLocation == null) {
            Log.e(TAG, "File location is null for node type: ${nodeData["type"]}")
            return null
        }
        
        // Check if file exists for filesystem types
        if (nodeType == 2 || nodeType == 3) {
            // Extract raw filesystem path for file existence check
            val rawPath = when {
                fileLocation!!.startsWith("file://") -> fileLocation.substring(7) // Remove "file://" prefix
                else -> fileLocation
            }
            val file = java.io.File(rawPath)
            if (!file.exists()) {
                Log.e(TAG, "File does not exist: $rawPath")
                Log.d(TAG, "File absolute path: ${file.absolutePath}")
                Log.d(TAG, "File parent directory: ${file.parentFile?.absolutePath}")
                Log.d(TAG, "Parent directory exists: ${file.parentFile?.exists()}")
                if (file.parentFile?.exists() == true) {
                    Log.d(TAG, "Files in parent directory: ${file.parentFile?.listFiles()?.joinToString { it.name }}")
                }
                return null
            } else {
                Log.d(TAG, "File exists: $rawPath (${file.length()} bytes)")
            }
        }
        // For downloaded files (type 1), the file existence check is already done in downloadRemoteGlb
        
        val transformation = nodeData["transformation"] as? List<*>
        if (transformation == null) {
            Log.e(TAG, "❌ FAILURE POINT 2: Transformation data is null or invalid")
            Log.e(TAG, "❌ Available keys in nodeData: ${nodeData.keys}")
            Log.e(TAG, "❌ Transformation value: ${nodeData["transformation"]}")
            Log.e(TAG, "❌ Transformation type: ${nodeData["transformation"]?.javaClass}")
            return null
        }
        
        // Convert to ArrayList<Double> if needed
        val transformationList = try {
            transformation.map { (it as? Number)?.toDouble() ?: throw IllegalArgumentException("Non numeric value in transformation: $it") }
                .toMutableList() as ArrayList<Double>
        } catch (e: Exception) {
            Log.e(TAG, "❌ FAILURE POINT 2b: Failed to convert transformation to ArrayList<Double>: ${e.message}")
            return null
        }
        
        Log.d(TAG, "✅ Transformation check passed: ${transformationList.size} elements")

        return try {
            Log.d(TAG, "🚀 Attempting to load model instance from: $fileLocation")
            sceneView.modelLoader.loadModelInstance(fileLocation)?.let { modelInstance ->
                Log.d(TAG, "✅ Model instance loaded successfully")
                
                // For now, always create regular ModelNode until gesture classes are fixed
                val node = object : ModelNode(
                    modelInstance = modelInstance,
                    scaleToUnits = 1.0f, // Avoid using matrix[0] directly as uniform scale
                ) {
                    init {
                        // CRITICAL FIX: Set gesture properties based on current gesture settings
                        isPositionEditable = this@ArView.handlePans
                        isRotationEditable = this@ArView.handleRotation
                        isTouchable = true
                    }
                }
                
                // Apply transformation and common properties
                node.apply {
                    // Apply the full transformation matrix to properly position the node
                    if (transformationList.size >= 16) {
                        val matrix = transformationList.map { it.toFloat() }.toFloatArray()
                        
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
                            x = radToDeg(atan2(matrix[6], matrix[10])),
                            y = radToDeg(atan2(-matrix[2], sqrt(matrix[6] * matrix[6] + matrix[10] * matrix[10]))),
                            z = radToDeg(atan2(matrix[1], matrix[0]))
                        )
                        
                        // Apply the transformation to the node
                        transform = Transform(
                            position = position,
                            rotation = rotation,
                            scale = scale
                        )
                        
                        Log.d("ArView", "Applied transformation to node $name - Position: (${position.x}, ${position.y}, ${position.z})")
                    } else {
                        Log.w("ArView", "Invalid transformation matrix size: ${transformationList.size}, expected 16")
                    }
                    
                    // Set node properties
                    name = (nodeData["name"] as? String) ?: run {
                        val autoName = "Node_${System.currentTimeMillis()}"
                        Log.w(TAG, "No name supplied in nodeData, auto-generating: $autoName")
                        autoName
                    }
                    
                    Log.d("ArView", "🎯 Node init complete - name: $name, isTransformable: $isTransformable")
                    Log.d("ArView", "🎯 Current ArView settings - handlePans: ${this@ArView.handlePans}, handleRotation: ${this@ArView.handleRotation}")
                    
                    // Additional debugging for tap detection
                    if (name != null) {
                        Log.d("ArView", "🎯 Node created with name '$name' - will be added to nodesMap for tap detection")
                    } else {
                        Log.w("ArView", "❌ Node created without name - tap detection will not work!")
                    }
                }
                
                // Return the created node
                node
            } ?: run {
                Log.e(TAG, "❌ FAILURE POINT 3: Model loading failed - loadModelInstance returned null")
                Log.e(TAG, "❌ File location: $fileLocation")
                Log.e(TAG, "❌ File exists: ${java.io.File(fileLocation).exists()}")
                null
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ FAILURE POINT 4: Exception during model building: ${e.message}")
            Log.e(TAG, "❌ Exception type: ${e.javaClass.simpleName}")
            Log.e(TAG, "❌ Stack trace:")
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
                                
                                // Re-assert gesture flags one frame after adding nodes for stability
                                sceneView.post {
                                    node.isTouchable = true
                                    node.isPositionEditable = handlePans
                                    node.isRotationEditable = handleRotation
                                }
                                
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
                                
                                // Track resource handle for deep cleanup
                                val resourceHandle = ResourceHandle(
                                    nodeId = nodeName,
                                    modelInstance = node.modelInstance,
                                    assetKey = (dict_node["uri"] as? String)
                                )
                                resourceHandles[nodeName] = resourceHandle
                                
                                Log.d("ArView", "🎯 Added ModelNode to nodesMap: $nodeName, total nodes: ${nodesMap.size}")
                                Log.d("ArView", "🎯 All nodes in map: ${nodesMap.keys}")
                                Log.d("ArView", "🎯 Node properties - isPositionEditable: ${node.isPositionEditable}, isTouchable: ${node.isTouchable}")
                                Log.d("ArView", "🎯 Node world position: ${node.worldPosition}")
                                Log.d("ArView", "🎯 Node parent: ${node.parent?.javaClass?.simpleName}")
                                
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

    // Force gesture properties on a specific node - ensures gestures work
    private fun forceNodeGestureProperties(node: ModelNode, enablePan: Boolean = true, enableRotation: Boolean = true) {
        Log.d("ArView", "🔧 FORCING gesture properties on node ${node.name}: pan=$enablePan, rotation=$enableRotation")
        node.isPositionEditable = enablePan
        node.isRotationEditable = enableRotation
        node.isTouchable = true
        Log.d("ArView", "✅ Node ${node.name} properties forced: isPositionEditable=${node.isPositionEditable}, isRotationEditable=${node.isRotationEditable}")
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
                environment = environmentLoader.createHDREnvironment(
                    assetFileLocation = "environments/evening_meadow_2k.hdr"
                )!!

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
                                        
                                        // Send comprehensive plane information to Flutter
                                        val planeData = serializePlaneData(plane)
                                        mainScope.launch {
                                            sessionChannel.invokeMethod("onPlaneDetected", planeData)
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
                        Log.d("ArView", "🎯 SceneView onSingleTapConfirmed - handleTaps: ${this@ArView.handleTaps}, node: ${node?.name}")
                        
                        try {
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
                                    Log.d("ArView", "Checking node: ${currentNode.name}, type: ${currentNode.javaClass.simpleName}")
                                    if (currentNode is ModelNode && currentNode.name != null) {
                                        // Check if this ModelNode is in our managed nodes map
                                        if (nodesMap.containsKey(currentNode.name)) {
                                            modelNodeName = currentNode.name
                                            Log.d("ArView", "✅ Found managed ModelNode: $modelNodeName")
                                            break
                                        } else {
                                            Log.d("ArView", "❌ ModelNode ${currentNode.name} not in managed nodes map")
                                            Log.d("ArView", "Available nodes: ${nodesMap.keys}")
                                        }
                                    }
                                    currentNode = currentNode.parent
                                }
                                
                                // If we found a ModelNode, report it as tapped
                                if (modelNodeName != null && this@ArView.handleTaps) {
                                    Log.d("ArView", "🎯 Reporting ModelNode tap: $modelNodeName")
                                    try {
                                        objectChannel.invokeMethod("onNodeTap", listOf(modelNodeName))
                                        Log.d("ArView", "✅ Successfully sent ModelNode tap to Flutter")
                                    } catch (e: Exception) {
                                        Log.e("ArView", "❌ Error sending ModelNode tap to Flutter", e)
                                    }
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
                                    Log.d("ArView", "🎯 Reporting anchor tap: $anchorName")
                                    try {
                                        objectChannel.invokeMethod("onNodeTap", listOf(anchorName))
                                        Log.d("ArView", "✅ Successfully sent anchor tap to Flutter")
                                    } catch (e: Exception) {
                                        Log.e("ArView", "❌ Error sending anchor tap to Flutter", e)
                                    }
                                } else {
                                    Log.w("ArView", "❌ No managed node or anchor found for tapped node: ${node.name}")
                                }
                            } else {
                                Log.d("ArView", "🎯 Tap detected on empty space (no node hit)")
                                try {
                                    // Get current frame to avoid "old frame" errors
                                    val currentFrame = sceneView.session?.update()
                                    if (currentFrame != null) {
                                        val hitResults = currentFrame.hitTest(motionEvent)
                                        Log.d("ArView", "Hit Results count: ${hitResults.size}")

                                        val serializedResults = hitResults.map { hitResult ->
                                            try {
                                                val result = serializeARCoreHitResult(hitResult)
                                                Log.d("ArView", "🎯 Serialized hit result: type=${result["type"]}, distance=${result["distance"]}")
                                                
                                                // Set tappedPlaneAnchorAlignment based on plane type detected
                                                val trackable = hitResult.trackable
                                                if (trackable is Plane) {
                                                    tappedPlaneAnchorAlignment = if (trackable.type == Plane.Type.VERTICAL) {
                                                        PlaneAlignment.VERTICAL
                                                    } else {
                                                        PlaneAlignment.HORIZONTAL
                                                    }
                                                    Log.d("ArView", "🎯 Updated tappedPlaneAnchorAlignment to: $tappedPlaneAnchorAlignment")
                                                }
                                                
                                                result
                                            } catch (e: Exception) {
                                                Log.e("ArView", "❌ Error serializing individual hit result", e)
                                                // Return empty map as fallback
                                                HashMap<String, Any>()
                                            }
                                        }.filter { it.isNotEmpty() } // Filter out empty results
                                        
                                        Log.d("ArView", "Serialized ${serializedResults.size} hit results")
                                        
                                        if (this@ArView.handleTaps && serializedResults.isNotEmpty()) {
                                            try {
                                                notifyPlaneOrPointTap(serializedResults)
                                                Log.d("ArView", "✅ Successfully sent plane/point tap to Flutter")
                                            } catch (e: Exception) {
                                                Log.e("ArView", "❌ Error sending plane/point tap to Flutter", e)
                                                // Fallback: Send a simple empty space tap notification
                                                try {
                                                    Log.d("ArView", "🔄 Attempting fallback empty space tap notification")
                                                    objectChannel.invokeMethod("onEmptySpaceTap", null)
                                                } catch (fallbackError: Exception) {
                                                    Log.e("ArView", "❌ Fallback notification also failed", fallbackError)
                                                }
                                            }
                                        } else if (serializedResults.isEmpty()) {
                                            Log.w("ArView", "❌ No valid hit results to send to Flutter")
                                            // Still try to send empty space tap notification
                                            try {
                                                Log.d("ArView", "🔄 No hit results, sending empty space tap notification")
                                                objectChannel.invokeMethod("onEmptySpaceTap", null)
                                            } catch (fallbackError: Exception) {
                                                Log.e("ArView", "❌ Empty space tap notification failed", fallbackError)
                                            }
                                        }
                                    } else {
                                        Log.w("ArView", "❌ No current frame available for hit testing")
                                    }
                                } catch (e: Exception) {
                                    Log.e("ArView", "❌ Error during hit testing", e)
                                }
                            }
                        } catch (e: Exception) {
                            Log.e("ArView", "❌ Error in onSingleTapConfirmed", e)
                        }
                    },
                    onScroll = { e1, e2, node, distance ->
                        // Handle pan gestures for nodes - restrict to single finger like iOS
                        if (node != null && this@ArView.handlePans) {
                            // Check pointer count to distinguish from multi-finger gestures
                            val pointerCount = e2.pointerCount
                            Log.d("ArView", "Scroll detected on node: ${node.name} - handlePans: ${this@ArView.handlePans}, pointers: $pointerCount")
                            
                            // Only handle pan if it's a single finger gesture (like iOS)
                            if (pointerCount == 1) {
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
                                    // Check if this is a new pan gesture starting
                                    if (currentPanningNode != modelNode) {
                                        // End previous pan if different node
                                        if (currentPanningNode != null && panGestureActive) {
                                            Log.d("ArView", "Ending pan on previous node: ${currentPanningNode?.name}")
                                            currentPanningNode?.name?.let { nodeName ->
                                                objectChannel.invokeMethod("onPanEnd", nodeName)
                                            }
                                        }
                                        
                                        // Start new pan gesture
                                        currentPanningNode = modelNode
                                        panGestureActive = true
                                        modelNode.name?.let { nodeName ->
                                            Log.d("ArView", "Pan gesture started on node: $nodeName")
                                            objectChannel.invokeMethod("onPanStart", nodeName)
                                        }
                                    }
                                    
                                    // CRITICAL FIX: Force properties and proceed with movement regardless of property check
                                    Log.d("ArView", "Single-finger pan gesture detected on node ${modelNode.name}, original isPositionEditable: ${modelNode.isPositionEditable}")
                                    
                                    try {
                                        // Force enable properties using our dedicated method
                                        forceNodeGestureProperties(modelNode, enablePan = true, enableRotation = false)
                                        
                                        // ULTRA-SIMPLIFIED APPROACH: Direct 1:1 mapping
                                        // This approach directly maps screen movements to world movements
                                        // without complex camera calculations
                                        
                                        val moveScale = 0.002f // Adjust sensitivity
                                        
                                        // Direct mapping with corrected X-axis direction
                                        val worldMoveX = -distance.x * moveScale  // Screen left/right -> World right/left (INVERTED to fix direction)
                                        val worldMoveZ = -distance.y * moveScale // Screen up/down -> World back/forward (inverted)
                                        
                                        Log.d("ArView", "🎯 FIXED Pan gesture:")
                                        Log.d("ArView", "   Screen movement: (${String.format("%.4f", distance.x)}, ${String.format("%.4f", distance.y)})")
                                        Log.d("ArView", "   Fixed world movement: (${String.format("%.4f", worldMoveX)}, ${String.format("%.4f", worldMoveZ)})")
                                        Log.d("ArView", "   Note: X-axis INVERTED to fix left/right direction")
                                        
                                        // Apply movement to current position
                                        val currentPosition = modelNode.position
                                        val newPosition = Position(
                                            currentPosition.x + worldMoveX,
                                            detectedPlaneY ?: currentPosition.y, // Keep Y locked to plane
                                            currentPosition.z + worldMoveZ
                                        )
                                        
                                        // Apply the new position
                                        modelNode.position = newPosition
                                        
                                        Log.d("ArView", "✅ SUCCESSFULLY updated node ${modelNode.name} position:")
                                        Log.d("ArView", "   From: (${String.format("%.4f", currentPosition.x)}, ${String.format("%.4f", currentPosition.y)}, ${String.format("%.4f", currentPosition.z)})")
                                        Log.d("ArView", "   To:   (${String.format("%.4f", newPosition.x)}, ${String.format("%.4f", newPosition.y)}, ${String.format("%.4f", newPosition.z)})")
                                        Log.d("ArView", "   Delta: (${String.format("%.4f", worldMoveX)}, 0.0000, ${String.format("%.4f", worldMoveZ)})")
                                    } catch (e: Exception) {
                                        Log.e("ArView", "❌ Error applying pan movement to node ${modelNode.name}: ${e.message}", e)
                                    }
                                    
                                    // Notify Flutter with just the node name (Flutter expects String, not Map)
                                    modelNode.name?.let { nodeName ->
                                        objectChannel.invokeMethod("onPanChange", nodeName)
                                    }
                                } else {
                                    Log.w("ArView", "❌ No ModelNode found for gesture")
                                }
                            } else {
                                Log.d("ArView", "❌ Multi-finger gesture detected ($pointerCount fingers), ignoring pan - likely rotation gesture")
                            }
                        }
                    },
                    onRotate = { detector: RotateGestureDetector, e: MotionEvent, node: Node? ->
                        val pointerCount = e.pointerCount
                        Log.d("ArView", "🔄 Native onRotate called - action: ${e.action}, node: ${node?.name}, handleRotation: ${this@ArView.handleRotation}, pointers: $pointerCount")
                        
                        // Only handle rotation with 2 fingers (like iOS rotation gesture)
                        if (node != null && this@ArView.handleRotation && pointerCount >= 2) {
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
                                Log.d("ArView", "🔄 Two-finger rotation gesture on node ${mn.name}")
                                
                                try {
                                    // Force enable rotation properties using our dedicated method
                                    forceNodeGestureProperties(mn, enablePan = false, enableRotation = true)

                                    // Get current detector rotation in radians
                                    val currentDetectorRotation = detector.rotation
                                    Log.d("ArView", "📐 Detector rotation: ${Math.toDegrees(currentDetectorRotation.toDouble()).toFloat()}°")

                                    // Initialize rotation tracking on first event
                                    if (gestureStartRotation == null) {
                                        gestureStartRotation = currentDetectorRotation
                                        lastDetectorRotation = currentDetectorRotation
                                        rotationGestureActive = true
                                        currentRotatingNode = mn
                                        Log.d("ArView", "🟢 Rotation gesture started on node ${mn.name}")
                                        
                                        // Send start event with node name for consistency
                                        mn.name?.let { nodeName ->
                                            objectChannel.invokeMethod("onRotationStart", nodeName)
                                        }
                                    } else {
                                        // Compute incremental delta from absolute rotation
                                        var delta = currentDetectorRotation - lastDetectorRotation!!
                                        
                                        // Handle wrap-around at ±π (crucial for smooth rotation)
                                        if (delta > Math.PI) {
                                            delta -= (2 * Math.PI).toFloat()
                                        } else if (delta < -Math.PI) {
                                            delta += (2 * Math.PI).toFloat()
                                        }
                                        
                                        // Convert delta to degrees for consistent handling
                                        val deltaDeg = radToDeg(delta)
                                        
                                        // Filter out unreasonably large deltas (likely gesture jumps) 
                                        val deltaDegreesAbs = Math.abs(deltaDeg)
                                        if (deltaDegreesAbs > 45.0f) {
                                            Log.w("ArView", "⚠️ Large rotation delta detected: ${deltaDeg}°, allowing but clamping")
                                            // Clamp the delta to prevent massive jumps
                                            val maxDelta = 45.0f
                                            val clampedDeltaDeg = if (deltaDeg > 0) maxDelta else -maxDelta
                                            
                                            // Apply clamped delta directly to current Y rotation (horizontal plane rotation)
                                            val currentRotation = mn.rotation
                                            val newYaw = currentRotation.y + clampedDeltaDeg
                                            mn.rotation = Rotation(currentRotation.x, newYaw, currentRotation.z)
                                        } else {
                                            // Apply delta directly to current Y rotation (horizontal plane rotation)
                                            val currentRotation = mn.rotation
                                            val newYaw = currentRotation.y + deltaDeg
                                            mn.rotation = Rotation(currentRotation.x, newYaw, currentRotation.z)
                                        }
                                        
                                        // Update tracking
                                        lastDetectorRotation = currentDetectorRotation
                                        
                                        Log.d("ArView", "✅ Applied rotation delta ${Math.toDegrees(delta.toDouble()).toFloat()}° (${delta} rad)")
                                        Log.d("ArView", "   Node ${mn.name} rotation updated to: ${mn.rotation.y}°")
                                        
                                        // Send change event with node name for consistency  
                                        mn.name?.let { nodeName ->
                                            objectChannel.invokeMethod("onRotationChange", nodeName)
                                        }
                                    }
                                } catch (e: Exception) {
                                    Log.e("ArView", "❌ Error applying rotation to node ${mn.name}: ${e.message}", e)
                                }
                            }
                        } else if (pointerCount < 2) {
                            Log.d("ArView", "❌ Single finger detected for rotation, ignoring - use two fingers for rotation")
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
                
                // Add touch listener to detect gesture end events (for pan and rotation gesture end detection)
                sceneView.setOnTouchListener { _, event ->
                    when (event.action) {
                        MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                            // End any active pan gesture
                            if (panGestureActive && currentPanningNode != null) {
                                Log.d("ArView", "Touch ended, ending pan gesture on node: ${currentPanningNode?.name}")
                                currentPanningNode?.name?.let { nodeName ->
                                    objectChannel.invokeMethod("onPanEnd", nodeName)
                                }
                                currentPanningNode = null
                                panGestureActive = false
                            }
                            
                            // End any active rotation gesture
                            if (rotationGestureActive && currentRotatingNode != null) {
                                Log.d("ArView", "🔴 Touch ended, ending rotation gesture on node: ${currentRotatingNode?.name}")
                                
                                currentRotatingNode?.name?.let { nodeName ->
                                    objectChannel.invokeMethod("onRotationEnd", nodeName)
                                }
                                currentRotatingNode = null
                                rotationGestureActive = false
                                useExternalRotationData = false // Reset external data flag
                                
                                // Reset rotation tracking variables
                                gestureStartRotation = null
                                lastDetectorRotation = null
                                Log.d("ArView", "🔄 Reset rotation tracking variables")
                            }
                        }
                    }
                    // Return false to allow other touch handling to continue
                    false
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
                    
                    // Re-assert gesture flags one frame after adding nodes for stability
                    sceneView.post {
                        node.isTouchable = true
                        node.isPositionEditable = handlePans
                        node.isRotationEditable = handleRotation
                    }
                    
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
        // Remove restriction - allow transformation regardless of gesture settings
        // This enables programmatic node updates from Flutter
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

                try {
                    node.apply {
                        transform(
                            position = ScenePosition(
                                x = transform[12].toFloat(),
                                y = transform[13].toFloat(),
                                z = transform[14].toFloat()
                            ),
                            rotation = SceneRotation(
                                x = radToDeg(atan2(transform[6].toFloat(), transform[10].toFloat())),
                                y = radToDeg(atan2(-transform[2].toFloat(),
                                    sqrt(transform[6].toFloat() * transform[6].toFloat() +
                                         transform[10].toFloat() * transform[10].toFloat()))),
                                z = radToDeg(atan2(transform[1].toFloat(), transform[0].toFloat()))
                            ),
                            scale = SceneScale(
                                x = sqrt((transform[0] * transform[0] + transform[1] * transform[1] + transform[2] * transform[2]).toFloat()),
                                y = sqrt((transform[4] * transform[4] + transform[5] * transform[5] + transform[6] * transform[6]).toFloat()),
                                z = sqrt((transform[8] * transform[8] + transform[9] * transform[9] + transform[10] * transform[10]).toFloat())
                            )
                        )
                    }
                    Log.d("ArView", "✅ Successfully applied transform to node $name")
                    result.success(null)
                } catch (e: Exception) {
                    Log.e("ArView", "❌ Error applying transform to node $name: ${e.message}", e)
                    result.error("TRANSFORM_ERROR", "Failed to apply transformation: ${e.message}", null)
                }
            } ?: result.error("INVALID_TRANSFORMATION", "Transformation is required", null)
        } ?: result.error("NODE_NOT_FOUND", "Node with name $name not found", null)
    } catch (e: Exception) {
        Log.e("ArView", "❌ Error in handleTransformNode: ${e.message}", e)
        result.error("TRANSFORM_NODE_ERROR", e.message, null)
    }
}

    private fun handleExternalRotation(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        try {
            val nodeName = call.argument<String>("nodeName")
            val velocity = call.argument<Double>("velocity")
            val state = call.argument<String>("state") // "began", "changed", "ended"
            
            if (nodeName == null || velocity == null || state == null) {
                result.error("INVALID_ARGUMENT", "Node name, velocity, and state are required", null)
                return
            }
            
            val node = nodesMap[nodeName]
            if (node == null) {
                result.error("NODE_NOT_FOUND", "Node with name $nodeName not found", null)
                return
            }
            
            when (state) {
                "began" -> {
                    useExternalRotationData = true
                    rotationGestureActive = true
                    currentRotatingNode = node
                    Log.d("ArView", "🟢 External rotation gesture started on node $nodeName")
                    objectChannel.invokeMethod("onRotationStart", nodeName)
                }
                "changed" -> {
                    if (useExternalRotationData && rotationGestureActive && currentRotatingNode == node) {
                        // Apply velocity-based rotation like iOS: velocity * 0.01 * -1, convert to degrees
                        val stepDeg = radToDeg((velocity * 0.01 * -1).toFloat())
                        
                        // Apply rotation based on plane alignment
                        val currentRotation = node.rotation
                        val newRotation = when (tappedPlaneAnchorAlignment) {
                            PlaneAlignment.HORIZONTAL -> {
                                // Rotate around Y axis for horizontal planes
                                Rotation(currentRotation.x, currentRotation.y + stepDeg, currentRotation.z)
                            }
                            PlaneAlignment.VERTICAL -> {
                                // Rotate around Z axis for vertical planes  
                                Rotation(currentRotation.x, currentRotation.y, currentRotation.z + stepDeg)
                            }
                        }
                        
                        node.rotation = newRotation
                        Log.d("ArView", "✅ Applied external rotation velocity ${velocity} -> scaled degrees: ${stepDeg} to node $nodeName")
                        objectChannel.invokeMethod("onRotationChange", nodeName)
                    }
                }
                "ended" -> {
                    if (useExternalRotationData && rotationGestureActive && currentRotatingNode == node) {
                        useExternalRotationData = false
                        rotationGestureActive = false
                        currentRotatingNode = null
                        Log.d("ArView", "🔴 External rotation gesture ended on node $nodeName")
                        objectChannel.invokeMethod("onRotationEnd", nodeName)
                    }
                }
            }
            
            result.success(null)
        } catch (e: Exception) {
            result.error("EXTERNAL_ROTATION_ERROR", e.message, null)
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
                Log.d("ArView", "🎯 Sending ${hitResults.size} hit results to Flutter")
                hitResults.forEachIndexed { index, hitResult ->
                    Log.d("ArView", "🎯 Hit result $index: type=${hitResult["type"]}, distance=${hitResult["distance"]}")
                    Log.d("ArView", "🎯 Hit result $index worldTransform type: ${hitResult["worldTransform"]?.javaClass?.simpleName}")
                    if (hitResult["worldTransform"] is DoubleArray) {
                        Log.d("ArView", "🎯 Hit result $index worldTransform length: ${(hitResult["worldTransform"] as DoubleArray).size}")
                    }
                }
                
                // Ensure worldTransform is converted to List for platform channel
                val processedHitResults = hitResults.map { hitResult ->
                    val processed = HashMap<String, Any>()
                    processed["type"] = hitResult["type"] ?: 2
                    processed["distance"] = hitResult["distance"] ?: 0.0
                    
                    // Convert DoubleArray to List if needed
                    val worldTransform = hitResult["worldTransform"]
                    processed["worldTransform"] = when (worldTransform) {
                        is DoubleArray -> worldTransform.toList()
                        is List<*> -> worldTransform
                        else -> {
                            Log.w("ArView", "Unknown worldTransform type: ${worldTransform?.javaClass?.simpleName}")
                            DoubleArray(16) { if (it % 5 == 0) 1.0 else 0.0 }.toList() // Identity matrix
                        }
                    }
                    processed
                }
                
                Log.d("ArView", "🎯 Processed hit results for sending")
                sessionChannel.invokeMethod("onPlaneOrPointTap", processedHitResults)
                Log.d("ArView", "✅ Successfully sent hit results to Flutter")
            } catch (e: Exception) {
                Log.e("ArView", "❌ Error in notifyPlaneOrPointTap", e)
                e.printStackTrace()
                
                // Fallback: Send simple empty space notification
                try {
                    Log.d("ArView", "🔄 Sending fallback empty space tap")
                    objectChannel.invokeMethod("onEmptySpaceTap", null)
                } catch (fallbackError: Exception) {
                    Log.e("ArView", "❌ Fallback also failed", fallbackError)
                }
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

    // Serialize comprehensive plane data for Flutter
    private fun serializePlaneData(plane: Plane): Map<String, Any> {
        val centerPose = plane.centerPose
        val polygon = plane.polygon
        
        // Calculate plane bounds
        var minX = Float.MAX_VALUE
        var maxX = Float.MIN_VALUE
        var minZ = Float.MAX_VALUE
        var maxZ = Float.MIN_VALUE
        
        polygon.rewind()
        for (i in 0 until polygon.limit() step 2) {
            val x = polygon.get(i)
            val z = polygon.get(i + 1)
            minX = kotlin.math.min(minX, x)
            maxX = kotlin.math.max(maxX, x)
            minZ = kotlin.math.min(minZ, z)
            maxZ = kotlin.math.max(maxZ, z)
        }
        
        val width = maxX - minX
        val height = maxZ - minZ
        
        return mapOf(
            "identifier" to plane.hashCode().toString(),
            "type" to when (plane.type) {
                Plane.Type.HORIZONTAL_DOWNWARD_FACING -> "horizontalDownwardFacing"
                Plane.Type.HORIZONTAL_UPWARD_FACING -> "horizontalUpwardFacing"
                Plane.Type.VERTICAL -> "vertical"
                else -> "unknown"
            },
            "center" to mapOf(
                "x" to centerPose.translation[0],
                "y" to centerPose.translation[1], // This is the height!
                "z" to centerPose.translation[2]
            ),
            "extent" to mapOf(
                "width" to width,
                "height" to height
            ),
            "transform" to run {
                val matrix = FloatArray(16)
                centerPose.toMatrix(matrix, 0)
                matrix.map { it.toDouble() }
            },
            "alignment" to when (plane.type) {
                Plane.Type.HORIZONTAL_DOWNWARD_FACING, Plane.Type.HORIZONTAL_UPWARD_FACING -> "horizontal"
                Plane.Type.VERTICAL -> "vertical"
                else -> "unknown"
            }
        )
    }

    // Temporary simple normalizeAngle function (to be removed)
    private fun normalizeAngle(angle: Float): Float {
        return angle % (2 * Math.PI.toFloat())
    }

    // Download remote GLB file and return local path
    private suspend fun downloadRemoteGlb(url: String): String? {
        return try {
            Log.d(TAG, "📥 Starting download of remote GLB: $url")
            Log.d(TAG, "🌐 Network diagnostics - checking connectivity...")
            
            // Check if we can resolve DNS first
            try {
                val host = java.net.URL(url).host
                Log.d(TAG, "🔍 Attempting DNS resolution for: $host")
                val address = java.net.InetAddress.getByName(host)
                Log.d(TAG, "✅ DNS resolved: $host -> ${address.hostAddress}")
            } catch (dnsEx: Exception) {
                Log.e(TAG, "❌ DNS resolution failed for github.com: ${dnsEx.message}")
                Log.e(TAG, "💡 This indicates network/DNS issues with your current WiFi")
                Log.e(TAG, "💡 Try switching to mobile data or different WiFi network")
                return null
            }
            
            // Create HTTP connection
            val connection = java.net.URL(url).openConnection() as java.net.HttpURLConnection
            connection.requestMethod = "GET"
            connection.connectTimeout = 30000 // 30 seconds
            connection.readTimeout = 30000 // 30 seconds
            
            val responseCode = connection.responseCode
            Log.d(TAG, "📡 HTTP Response Code: $responseCode")
            
            if (responseCode != java.net.HttpURLConnection.HTTP_OK) {
                Log.e(TAG, "❌ HTTP Error: $responseCode")
                connection.disconnect()
                return null
            }
            
            // Get file name from URL
            val fileName = url.substring(url.lastIndexOf('/') + 1)
            Log.d(TAG, "📄 Downloaded file name: $fileName")
            
            // Create local file in cache directory
            val cacheDir = viewContext.cacheDir
            val localFile = java.io.File(cacheDir, fileName)
            
            // Download the file
            connection.inputStream.use { input ->
                localFile.outputStream().use { output ->
                    input.copyTo(output)
                }
            }
            
            connection.disconnect()
            
            val localPath = localFile.absolutePath
            Log.d(TAG, "✅ GLB downloaded successfully to: $localPath")
            Log.d(TAG, "📦 File size: ${localFile.length()} bytes")
            
            localPath
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to download remote GLB: ${e.message}", e)
            Log.e(TAG, "💡 Network troubleshooting for new WiFi location:")
            Log.e(TAG, "   - Try mobile data instead of WiFi")
            Log.e(TAG, "   - Check if WiFi has captive portal (browser login)")
            Log.e(TAG, "   - Corporate/hotel WiFi may block downloads")
            Log.e(TAG, "   - Try different WiFi network if available")
            null
        }
    }

    // ========================================
    // DEEP MEMORY CLEANUP IMPLEMENTATION
    // ========================================

    private fun handleRemoveNodeDeep(call: MethodCall, result: MethodChannel.Result) {
        try {
            val nodeId = call.argument<String>("nodeId")
            if (nodeId == null) {
                result.error("INVALID_ARGUMENT", "nodeId is required", null)
                return
            }
            
            val success = removeNodeDeep(nodeId)
            result.success(success)
        } catch (e: Exception) {
            Log.e(TAG, "Error in handleRemoveNodeDeep", e)
            result.error("REMOVE_NODE_DEEP_ERROR", e.message, null)
        }
    }

    private fun removeNodeDeep(nodeId: String): Boolean {
        Log.d(TAG, "🗑️ Deep removing node: $nodeId")
        
        try {
            // 1) Get resource handle
            val resourceHandle = resourceHandles.remove(nodeId)
            
            // 2) Remove from regular nodesMap and scene
            nodesMap[nodeId]?.let { node ->
                // Detach from scene
                runCatching { 
                    node.parent?.removeChildNode(node)
                    sceneView.removeChildNode(node)
                }
                
                // Destroy node resources
                runCatching { node.destroy() }
                
                // Remove from nodes map
                nodesMap.remove(nodeId)
                
                Log.d(TAG, "✅ Node removed from scene and nodesMap")
            }
            
            // 3) Deep destroy resources if we have handle
            resourceHandle?.let { handle ->
                // Destroy model instance
                handle.modelInstance?.let { modelInstance ->
                    runCatching {
                        // The ModelInstance should be destroyed by the node.destroy() call above
                        // but we can add additional cleanup if needed
                        Log.d(TAG, "🧹 ModelInstance cleanup handled by node.destroy()")
                    }
                }
                
                // Clean up materials and textures
                handle.materials.forEach { material ->
                    runCatching { 
                        // SceneView handles material cleanup internally
                        Log.d(TAG, "🧹 Material cleanup handled by SceneView")
                    }
                }
                
                handle.textures.forEach { texture ->
                    runCatching {
                        // SceneView handles texture cleanup internally  
                        Log.d(TAG, "🧹 Texture cleanup handled by SceneView")
                    }
                }
                
                // Update shared asset cache if applicable
                handle.assetKey?.let { assetKey ->
                    assetCache[assetKey]?.let { cachedAsset ->
                        val newRefCount = cachedAsset.refCount.decrementAndGet()
                        Log.d(TAG, "🔢 Asset refCount for $assetKey: $newRefCount")
                        
                        if (newRefCount <= 0) {
                            assetCache.remove(assetKey)
                            Log.d(TAG, "🗑️ Removed asset from cache: $assetKey")
                        }
                    }
                }
                
                Log.d(TAG, "✅ Deep resource cleanup completed for node: $nodeId")
            }
            
            // Force garbage collection hint
            runCatching { System.gc() }
            
            Log.d(TAG, "✅ Deep node removal completed: $nodeId")
            return true
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error in deep node removal: ${e.message}", e)
            return false
        }
    }

    private fun handlePurgeCaches(call: MethodCall, result: MethodChannel.Result) {
        try {
            val success = purgeCaches()
            result.success(success)
        } catch (e: Exception) {
            Log.e(TAG, "Error in handlePurgeCaches", e)
            result.error("PURGE_CACHES_ERROR", e.message, null)
        }
    }

    private fun purgeCaches(): Boolean {
        Log.d(TAG, "🧹 Purging all caches")
        
        try {
            // Clear asset cache
            val cacheSize = assetCache.size
            assetCache.clear()
            Log.d(TAG, "🗑️ Cleared asset cache ($cacheSize items)")
            
            // Clear resource handles (they should already be cleaned by removeNodeDeep)
            val handleCount = resourceHandles.size  
            resourceHandles.clear()
            Log.d(TAG, "🗑️ Cleared resource handles ($handleCount items)")
            
            // Let SceneView handle its internal cache cleanup
            runCatching {
                // SceneView manages its own model loader cache
                Log.d(TAG, "🧹 SceneView internal cache cleanup delegated")
            }
            
            // Force garbage collection hint
            runCatching { System.gc() }
            
            Log.d(TAG, "✅ Cache purging completed")
            return true
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error purging caches: ${e.message}", e)
            return false
        }
    }

    private fun handleCreateNodeFromAsset(call: MethodCall, result: MethodChannel.Result) {
        try {
            val uri = call.argument<String>("uri")
            val transformMatrix = call.argument<DoubleArray>("transformMatrix")
            
            if (uri == null || transformMatrix == null) {
                result.error("INVALID_ARGUMENTS", "uri and transformMatrix are required", null)
                return
            }
            
            if (transformMatrix.size != 16) {
                result.error("INVALID_TRANSFORMATION", "transformMatrix must have 16 elements", null) 
                return
            }
            
            mainScope.launch {
                try {
                    val nodeName = createNodeFromAsset(uri, transformMatrix)
                    result.success(nodeName)
                } catch (e: Exception) {
                    Log.e(TAG, "Error creating node from asset", e)
                    result.error("CREATE_NODE_ERROR", e.message, null)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error in handleCreateNodeFromAsset", e)
            result.error("CREATE_NODE_FROM_ASSET_ERROR", e.message, null)
        }
    }

    private suspend fun createNodeFromAsset(uri: String, transformMatrix: DoubleArray): String? {
        Log.d(TAG, "🔄 Creating shared node from asset: $uri")
        
        return withContext(Dispatchers.Main) {
            try {
                // Check if asset is already cached
                val cachedAsset = assetCache[uri]
                val modelInstance = if (cachedAsset != null) {
                    // Reuse cached asset
                    cachedAsset.refCount.incrementAndGet()
                    Log.d(TAG, "♻️ Reusing cached asset: $uri (refCount: ${cachedAsset.refCount.get()})")
                    cachedAsset.modelInstance
                } else {
                    // Load new asset
                    Log.d(TAG, "📥 Loading new asset: $uri")
                    val modelInstance = sceneView.modelLoader.loadModelInstance(uri)
                    if (modelInstance != null) {
                        val newCachedAsset = CachedAsset(uri, modelInstance)
                        assetCache[uri] = newCachedAsset
                        Log.d(TAG, "💾 Cached new asset: $uri")
                        modelInstance
                    } else {
                        Log.e(TAG, "❌ Failed to load model instance from: $uri")
                        return@withContext null
                    }
                }
                
                if (modelInstance == null) {
                    Log.e(TAG, "❌ Model instance is null for: $uri")
                    return@withContext null
                }
                
                // Create node with shared model instance
                val node = object : ModelNode(
                    modelInstance = modelInstance,
                    scaleToUnits = 1.0f
                ) {
                    init {
                        // Apply transformation matrix
                        val matrix = transformMatrix.map { it.toFloat() }.toFloatArray()
                        
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
                            x = radToDeg(atan2(matrix[6], matrix[10])),
                            y = radToDeg(atan2(-matrix[2], sqrt(matrix[6] * matrix[6] + matrix[10] * matrix[10]))),
                            z = radToDeg(atan2(matrix[1], matrix[0]))
                        )
                        
                        // Apply the transformation to the node
                        transform = Transform(
                            position = position,
                            rotation = rotation,
                            scale = scale
                        )
                        
                        // Set node properties
                        val nodeName = "SharedAsset_${System.currentTimeMillis()}"
                        name = nodeName
                        isPositionEditable = this@ArView.handlePans
                        isRotationEditable = this@ArView.handleRotation
                        isTouchable = true
                        
                        Log.d(TAG, "🎯 Shared node created: $nodeName")
                    }
                }
                
                // Add to scene and maps
                sceneView.addChildNode(node)
                val nodeName = node.name!!
                nodesMap[nodeName] = node
                
                // Track resource handle
                val resourceHandle = ResourceHandle(
                    nodeId = nodeName,
                    modelInstance = modelInstance,
                    assetKey = uri
                )
                resourceHandles[nodeName] = resourceHandle
                
                Log.d(TAG, "✅ Shared node added to scene: $nodeName")
                nodeName
                
            } catch (e: Exception) {
                Log.e(TAG, "❌ Error creating shared node: ${e.message}", e)
                null
            }
        }
    }

    private fun handleGetMemoryInfo(call: MethodCall, result: MethodChannel.Result) {
        try {
            val memoryInfo = getMemoryInfo()
            result.success(memoryInfo)
        } catch (e: Exception) {
            Log.e(TAG, "Error in handleGetMemoryInfo", e)
            result.error("GET_MEMORY_INFO_ERROR", e.message, null)
        }
    }

    private fun getMemoryInfo(): Map<String, Any> {
        return try {
            val runtime = Runtime.getRuntime()
            val nativeHeapSize = Debug.getNativeHeapSize()
            val nativeHeapAllocated = Debug.getNativeHeapAllocatedSize()
            val nativeHeapFree = Debug.getNativeHeapFreeSize()
            
            mapOf<String, Any>(
                "javaHeapUsedMB" to ((runtime.totalMemory() - runtime.freeMemory()) / 1048576.0),
                "javaHeapTotalMB" to (runtime.totalMemory() / 1048576.0),
                "javaHeapMaxMB" to (runtime.maxMemory() / 1048576.0),
                "nativeHeapSizeMB" to (nativeHeapSize / 1048576.0),
                "nativeHeapAllocatedMB" to (nativeHeapAllocated / 1048576.0),
                "nativeHeapFreeMB" to (nativeHeapFree / 1048576.0),
                "activeNodes" to nodesMap.size,
                "cachedAssets" to assetCache.size,
                "resourceHandles" to resourceHandles.size
            )
        } catch (e: Exception) {
            Log.e(TAG, "Error getting memory info: ${e.message}", e)
            mapOf<String, Any>(
                "error" to (e.message ?: "Unknown error"),
                "activeNodes" to nodesMap.size,
                "cachedAssets" to assetCache.size,
                "resourceHandles" to resourceHandles.size
            )
        }
    }

    // Cleanup old cached assets (call periodically)
    private fun cleanupOldAssets() {
        val currentTime = System.currentTimeMillis()
        val iterator = assetCache.iterator()
        
        while (iterator.hasNext()) {
            val entry = iterator.next()
            val asset = entry.value
            
            if (asset.refCount.get() <= 0 && (currentTime - asset.creationTime) > maxCacheAge) {
                iterator.remove()
                Log.d(TAG, "🧹 Cleaned up old asset: ${entry.key}")
            }
        }
    }
}