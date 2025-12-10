package com.uhg0.ar_flutter_plugin_2

import android.app.Activity
import android.util.Log
import android.content.Context
import androidx.activity.ComponentActivity
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import androidx.lifecycle.Lifecycle
import io.flutter.plugin.common.BinaryMessenger
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineExceptionHandler

/**
 * Global AR Session Coordinator - ensures only one AR session exists at a time.
 * This prevents race conditions when navigating between AR screens.
 * 
 * Also handles background/foreground transitions by implementing view caching:
 * - When app goes to background, Flutter disposes the platform view
 * - Instead of destroying the SceneView, we cache it
 * - When app returns from background, we reuse the SAME SceneView
 * - This prevents the black screen issue because SceneView never loses its Surface
 */
/**
 * Data classes for session state serialization during backgrounding
 */
data class SessionConfigData(
    val planeFindingMode: Int,
    val depthMode: Int,
    val lightEstimationMode: Int
)

data class AnchorStateData(
    val id: String,
    val translation: FloatArray,  // [x, y, z]
    val quaternion: FloatArray    // [x, y, z, w]
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false
        other as AnchorStateData
        if (id != other.id) return false
        if (!translation.contentEquals(other.translation)) return false
        if (!quaternion.contentEquals(other.quaternion)) return false
        return true
    }
    override fun hashCode(): Int {
        var result = id.hashCode()
        result = 31 * result + translation.contentHashCode()
        result = 31 * result + quaternion.contentHashCode()
        return result
    }
}

data class NodeStateData(
    val id: String,
    val uri: String,
    val transform: FloatArray,  // [16] full transform matrix
    val anchorId: String?,
    val isTransformable: Boolean,
    val enablePan: Boolean,
    val enableRotation: Boolean,
    val enableScale: Boolean
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false
        other as NodeStateData
        if (id != other.id) return false
        if (uri != other.uri) return false
        if (!transform.contentEquals(other.transform)) return false
        if (anchorId != other.anchorId) return false
        if (isTransformable != other.isTransformable) return false
        if (enablePan != other.enablePan) return false
        if (enableRotation != other.enableRotation) return false
        if (enableScale != other.enableScale) return false
        return true
    }
    override fun hashCode(): Int {
        var result = id.hashCode()
        result = 31 * result + uri.hashCode()
        result = 31 * result + transform.contentHashCode()
        result = 31 * result + (anchorId?.hashCode() ?: 0)
        result = 31 * result + isTransformable.hashCode()
        result = 31 * result + enablePan.hashCode()
        result = 31 * result + enableRotation.hashCode()
        result = 31 * result + enableScale.hashCode()
        return result
    }
}

data class SessionStateCache(
    val config: SessionConfigData,
    val anchors: List<AnchorStateData>,
    val nodes: List<NodeStateData>
)

object ArSessionCoordinator {
    private const val TAG = "ArSessionCoordinator"
    
    // How long to keep cached view alive after dispose
    private const val CACHE_EXPIRY_MS = 10000L
    
    // LRU cache for loaded model instances (reduces restoration time)
    private const val MODEL_CACHE_SIZE = 10
    private val modelCache = androidx.collection.LruCache<String, io.github.sceneview.model.ModelInstance>(MODEL_CACHE_SIZE)
    
    // Session state cache for restoration after backgrounding
    @Volatile
    private var sessionStateCache: SessionStateCache? = null
    
    @Volatile
    private var activeView: ArCoreCompatView? = null
    
    @Volatile
    private var pendingSoftDisposeView: ArCoreCompatView? = null
    
    @Volatile
    private var isDisposing = false
    
    @Volatile
    private var isCreatingNewView = false
    
    @Volatile
    private var isSoftDisposed = false
    
    @Volatile
    private var suppressCameraExceptions = false
    
    // Track creation sequence to detect stale dispose calls
    @Volatile
    private var currentCreationSequence = 0L
    
    // CRITICAL: Cache the SceneView itself to survive Flutter platform view recreation
    @Volatile
    private var cachedSceneView: io.github.sceneview.ar.ARSceneView? = null
    
    @Volatile
    private var cachedViewTimestamp = 0L
    
    // Hidden holder to keep SceneView attached to window (Surface stays alive)
    private var hiddenHolder: android.widget.FrameLayout? = null
    private var holderActivity: android.app.Activity? = null
    
    private val lock = Object()
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    
    // Original exception handler
    private var originalHandler: Thread.UncaughtExceptionHandler? = null
    
    // Runnable for delayed cache expiry
    private val cacheExpiryRunnable = Runnable {
        synchronized(lock) {
            if (cachedSceneView != null && 
                System.currentTimeMillis() - cachedViewTimestamp > CACHE_EXPIRY_MS) {
                Log.d(TAG, "⏰ Cached SceneView expired - destroying")
                destroyCachedSceneView()
            }
        }
    }
    
    /**
     * Get or create a hidden holder attached to the activity's window.
     * This keeps the SceneView's Surface alive even when the Flutter PlatformView is disposed.
     */
    private fun getHiddenHolder(activity: android.app.Activity): android.widget.FrameLayout {
        synchronized(lock) {
            // If we have a holder for a different activity, remove it
            if (holderActivity != null && holderActivity !== activity) {
                hiddenHolder?.let { holder ->
                    (holder.parent as? android.view.ViewGroup)?.removeView(holder)
                }
                hiddenHolder = null
            }
            
            // Create holder if needed
            if (hiddenHolder == null) {
                val holder = android.widget.FrameLayout(activity).apply {
                    layoutParams = android.widget.FrameLayout.LayoutParams(1, 1)  // Tiny but not 0 (Surface needs size)
                    visibility = android.view.View.INVISIBLE  // Invisible but still renders
                    // Position off-screen
                    translationX = -1000f
                    translationY = -1000f
                }
                
                // Add to activity's content view
                val contentView = activity.findViewById<android.view.ViewGroup>(android.R.id.content)
                contentView.addView(holder)
                
                hiddenHolder = holder
                holderActivity = activity
                Log.d(TAG, "🏠 Created hidden holder for SceneView caching")
            }
            
            return hiddenHolder!!
        }
    }
    
    /**
     * Save session state to cache for restoration after backgrounding.
     */
    fun saveSessionState(state: SessionStateCache) {
        synchronized(lock) {
            sessionStateCache = state
            Log.d(TAG, "📸 Cached session state: ${state.anchors.size} anchors, ${state.nodes.size} nodes")
        }
    }
    
    /**
     * Get cached session state for restoration.
     */
    fun getSessionStateCache(): SessionStateCache? {
        synchronized(lock) {
            return sessionStateCache
        }
    }
    
    /**
     * Clear cached session state (after successful restoration or failure).
     */
    fun clearSessionStateCache() {
        synchronized(lock) {
            sessionStateCache = null
            Log.d(TAG, "🗑️ Cleared session state cache")
        }
    }
    
    /**
     * Get a cached model instance if available.
     */
    fun getCachedModel(uri: String): io.github.sceneview.model.ModelInstance? {
        return modelCache.get(uri)?.also {
            Log.d(TAG, "♻️ Retrieved cached model: $uri")
        }
    }
    
    /**
     * Cache a loaded model instance for reuse.
     */
    fun cacheModel(uri: String, model: io.github.sceneview.model.ModelInstance) {
        modelCache.put(uri, model)
        Log.d(TAG, "📦 Cached model: $uri (cache size: ${modelCache.size()})")
    }
    
    /**
     * Cache a SceneView for reuse after background transition.
     * Moves SceneView to a hidden holder to keep its Surface alive.
     */
    fun cacheSceneView(sceneView: io.github.sceneview.ar.ARSceneView, activity: android.app.Activity) {
        synchronized(lock) {
            // First destroy any existing cached view
            destroyCachedSceneView()
            
            // Get the hidden holder
            val holder = getHiddenHolder(activity)
            
            // Remove from current parent
            (sceneView.parent as? android.view.ViewGroup)?.removeView(sceneView)
            
            // Add to hidden holder - this keeps the Surface alive!
            sceneView.layoutParams = android.widget.FrameLayout.LayoutParams(
                android.widget.FrameLayout.LayoutParams.MATCH_PARENT,
                android.widget.FrameLayout.LayoutParams.MATCH_PARENT
            )
            holder.addView(sceneView)
            
            cachedSceneView = sceneView
            cachedViewTimestamp = System.currentTimeMillis()
            
            Log.d(TAG, "📦 SceneView moved to hidden holder and cached for reuse")
            
            // Schedule cache expiry
            mainHandler.removeCallbacks(cacheExpiryRunnable)
            mainHandler.postDelayed(cacheExpiryRunnable, CACHE_EXPIRY_MS)
        }
    }
    
    /**
     * Try to get a cached SceneView for reuse.
     * Returns null if no valid cached view exists.
     */
    fun getCachedSceneView(): io.github.sceneview.ar.ARSceneView? {
        synchronized(lock) {
            val cached = cachedSceneView
            if (cached != null) {
                // Cancel expiry timer
                mainHandler.removeCallbacks(cacheExpiryRunnable)
                
                // Clear cache reference (it's being adopted)
                cachedSceneView = null
                cachedViewTimestamp = 0L
                
                Log.d(TAG, "♻️ Reusing cached SceneView!")
                return cached
            }
            return null
        }
    }
    
    /**
     * Destroy any cached SceneView.
     */
    private fun destroyCachedSceneView() {
        val cached = cachedSceneView
        if (cached != null) {
            Log.d(TAG, "🗑️ Destroying cached SceneView")
            try {
                // Remove from hidden holder first
                (cached.parent as? android.view.ViewGroup)?.removeView(cached)
                cached.destroy()
            } catch (e: Exception) {
                Log.e(TAG, "Error destroying cached SceneView", e)
            }
            cachedSceneView = null
            cachedViewTimestamp = 0L
        }
    }
    
    /**
     * Check if we have a cached SceneView available for reuse.
     */
    fun hasCachedSceneView(): Boolean {
        synchronized(lock) {
            return cachedSceneView != null
        }
    }
    
    // Runnable for delayed full disposal after soft dispose
    private val delayedFullDisposeRunnable = Runnable {
        synchronized(lock) {
            val viewToDispose = pendingSoftDisposeView
            if (viewToDispose != null && isSoftDisposed) {
                Log.d(TAG, "⏰ Delayed dispose timeout - performing full cleanup")
                performFullDispose(viewToDispose)
                pendingSoftDisposeView = null
                isSoftDisposed = false
            }
        }
    }
    
    /**
     * Install a global exception handler that catches camera-related exceptions
     * during AR view transitions. These exceptions are expected and safe to ignore.
     * 
     * CRITICAL FIX: Always handle camera session closure exceptions gracefully,
     * even when suppressCameraExceptions is false. These exceptions can occur
     * due to race conditions in the Camera2 API that are outside our control.
     */
    fun installExceptionHandler() {
        if (originalHandler != null) return // Already installed
        
        originalHandler = Thread.getDefaultUncaughtExceptionHandler()
        
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            // CRITICAL FIX: Always catch camera session closure exceptions
            // These can occur due to race conditions even when we're not actively disposing
            // The Camera2 API background threads can call stopRepeating() after the session
            // is already closed by another thread - this is a known Android behavior
            if (isCameraSessionException(throwable)) {
                Log.w(TAG, "🔇 Suppressing camera session exception (expected during AR lifecycle): ${throwable.message}")
                Log.w(TAG, "   Thread: ${thread.name}, suppressCameraExceptions=$suppressCameraExceptions")
                // Log stack trace for debugging but don't crash
                Log.d(TAG, "   Stack trace: ${throwable.stackTraceToString().take(500)}...")
                // Don't crash - this is expected during AR view transitions and background cleanup
                return@setDefaultUncaughtExceptionHandler
            }
            
            // Otherwise, forward to original handler
            originalHandler?.uncaughtException(thread, throwable)
        }
        
        Log.d(TAG, "✅ Installed AR exception handler")
    }
    
    /**
     * Check if the exception is a camera session closure exception (expected during disposal)
     * 
     * CRITICAL: This check is comprehensive to catch all variants of camera session
     * closure exceptions from the Camera2 API. These exceptions are benign and occur
     * due to race conditions in Android's camera subsystem.
     */
    private fun isCameraSessionException(throwable: Throwable): Boolean {
        val message = throwable.message?.lowercase() ?: ""
        val stackTrace = throwable.stackTraceToString()
        
        // Check for IllegalStateException with camera-related messages
        if (throwable is IllegalStateException) {
            if (message.contains("session has been closed") ||
                message.contains("session already closed") ||
                message.contains("cameracapturesession") ||
                message.contains("camera") && message.contains("closed") ||
                message.contains("further changes are illegal")) {
                return true
            }
        }
        
        // Check stack trace for Camera2 API components
        if (stackTrace.contains("CameraCaptureSession") ||
            stackTrace.contains("CameraDevice") ||
            stackTrace.contains("stopRepeating") ||
            stackTrace.contains("checkNotClosed") ||
            stackTrace.contains("camera2") ||
            // Also catch SceneView internal camera handling
            stackTrace.contains("ARSceneView") && message.contains("session")) {
            return true
        }
        
        return false
    }
    
    /**
     * Called before creating a new AR view.
     * First checks if there's a soft-disposed session that can be restored.
     * Otherwise ensures any existing view is fully disposed before allowing new creation.
     * 
     * Returns: true if should create new view, false if restored soft-disposed session
     */
    fun prepareForNewView(): Boolean {
        synchronized(lock) {
            Log.d(TAG, "🔄 Preparing for new AR view...")
            
            // First, check if we have a soft-disposed session we can restore
            if (hasSoftDisposedSession()) {
                Log.d(TAG, "♻️ Found soft-disposed session - cleaning up first")
                cancelSoftDisposedSession()
            }
            
            val existing = activeView
            if (existing != null) {
                Log.d(TAG, "⚠️ Found existing AR view - disposing first")
                isDisposing = true
                suppressCameraExceptions = true  // Start suppressing camera exceptions
                
                try {
                    // Force dispose the existing view synchronously
                    existing.forceDisposeSync()
                    
                    // Longer delay to let camera resources fully release
                    // Camera release can take 500-1000ms on some devices
                    // CRITICAL: This must be long enough for Camera2 API background threads
                    // to finish their stopRepeating() calls
                    Log.d(TAG, "⏳ Waiting for AR session to fully release...")
                    Thread.sleep(1200)  // Increased from 800ms to 1200ms for safer cleanup
                    
                } catch (e: Exception) {
                    Log.e(TAG, "Error disposing existing view", e)
                } finally {
                    activeView = null
                    isDisposing = false
                }
                
                Log.d(TAG, "✅ Previous view disposed")
            } else {
                Log.d(TAG, "ℹ️ No existing AR view found")
            }
            
            return true
        }
    }
    
    /**
     * Called after new view is fully initialized to stop suppressing exceptions.
     * We keep isCreatingNewView true for a bit longer to protect against late dispose calls.
     * 
     * NOTE: We keep suppressCameraExceptions true for longer since background camera
     * cleanup threads can still be running well after the new view is initialized.
     */
    fun viewInitialized() {
        Log.d(TAG, "✅ View initialized")
        
        // Delay clearing the creating flag to protect against late dispose calls
        // This is critical because Flutter may call dispose() on the OLD view
        // after the new view has already started
        mainHandler.postDelayed({
            isCreatingNewView = false
            Log.d(TAG, "✅ New view creation protection window closed")
        }, 2000)  // Keep protection for 2 seconds
        
        // Keep exception suppression enabled even longer since background camera
        // threads can continue running for several seconds after session transitions
        mainHandler.postDelayed({
            suppressCameraExceptions = false
            Log.d(TAG, "✅ Camera exception suppression disabled")
        }, 5000)  // Keep suppression for 5 seconds to cover async camera cleanup
    }
    
    /**
     * Check if a new view is currently being created.
     * Used by old views to skip destructive disposal.
     */
    fun isNewViewBeingCreated(): Boolean {
        return isCreatingNewView
    }
    
    /**
     * Mark that a new view is being created.
     * This prevents old views from doing destructive cleanup.
     * Returns the creation sequence number for this view.
     */
    fun markCreatingNewView(): Long {
        synchronized(lock) {
            isCreatingNewView = true
            suppressCameraExceptions = true
            currentCreationSequence++
            Log.d(TAG, "🚧 Marked: new view creation in progress (sequence: $currentCreationSequence)")
            return currentCreationSequence
        }
    }
    
    /**
     * Get the current creation sequence number.
     * Views created with an older sequence should not do destructive cleanup.
     */
    fun getCurrentCreationSequence(): Long {
        return currentCreationSequence
    }
    
    /**
     * Perform soft dispose - pause the session but keep resources.
     * Used when app goes to background (Flutter disposes platform view).
     * Resources will be fully cleaned up after CACHE_EXPIRY_MS
     * unless a new view requests to reuse them.
     * 
     * NOTE: This is now secondary to SceneView caching, but kept for compatibility.
     */
    fun performSoftDispose(view: ArCoreCompatView) {
        synchronized(lock) {
            Log.d(TAG, "🔄 Soft dispose requested - pausing session but keeping resources")
            
            // Cancel any pending delayed dispose
            mainHandler.removeCallbacks(delayedFullDisposeRunnable)
            
            // Store the view for potential reuse
            pendingSoftDisposeView = view
            isSoftDisposed = true
            
            // Pause the session (keeps camera/resources allocated)
            try {
                view.pauseSessionOnly()
                Log.d(TAG, "⏸️ Session paused - waiting for potential resume")
            } catch (e: Exception) {
                Log.e(TAG, "Error pausing session during soft dispose", e)
            }
            
            // Schedule delayed full disposal
            mainHandler.postDelayed(delayedFullDisposeRunnable, CACHE_EXPIRY_MS)
            
            // Clear active view reference
            if (activeView === view) {
                activeView = null
            }
        }
    }
    
    /**
     * Check if there's a soft-disposed session that can be reused.
     */
    fun hasSoftDisposedSession(): Boolean {
        synchronized(lock) {
            return isSoftDisposed && pendingSoftDisposeView != null
        }
    }
    
    /**
     * Cancel any soft-disposed session and do full disposal.
     * Called when creating a new view to ensure only one session exists.
     */
    fun cancelSoftDisposedSession() {
        synchronized(lock) {
            if (!isSoftDisposed || pendingSoftDisposeView == null) {
                return
            }
            
            Log.d(TAG, "🗑️ Canceling soft-disposed session before creating new view")
            
            // Cancel the delayed full dispose
            mainHandler.removeCallbacks(delayedFullDisposeRunnable)
            
            val view = pendingSoftDisposeView
            pendingSoftDisposeView = null
            isSoftDisposed = false
            
            // Perform full dispose on the old view
            view?.let { performFullDispose(it) }
        }
    }
    
    /**
     * Try to restore a soft-disposed session for reuse.
     * Returns the view if successful, null otherwise.
     */
    fun tryRestoreSoftDisposedSession(): ArCoreCompatView? {
        synchronized(lock) {
            if (!isSoftDisposed || pendingSoftDisposeView == null) {
                return null
            }
            
            Log.d(TAG, "♻️ Restoring soft-disposed session!")
            
            // Cancel the delayed full dispose
            mainHandler.removeCallbacks(delayedFullDisposeRunnable)
            
            val view = pendingSoftDisposeView
            pendingSoftDisposeView = null
            isSoftDisposed = false
            
            // Resume the session
            try {
                view?.resumeSessionOnly()
                Log.d(TAG, "▶️ Session resumed successfully!")
            } catch (e: Exception) {
                Log.e(TAG, "Error resuming session", e)
                // If resume fails, we can't reuse - do full dispose
                view?.let { performFullDispose(it) }
                return null
            }
            
            return view
        }
    }
    
    /**
     * Perform full dispose - completely destroy all resources.
     */
    private fun performFullDispose(view: ArCoreCompatView) {
        Log.d(TAG, "🗑️ Performing full dispose of AR resources")
        suppressCameraExceptions = true
        
        try {
            view.forceDisposeSync()
        } catch (e: Exception) {
            Log.e(TAG, "Error during full dispose", e)
        } finally {
            // Delay turning off exception suppression
            mainHandler.postDelayed({
                suppressCameraExceptions = false
            }, 1000)
        }
    }
    
    /**
     * Register a new active AR view.
     */
    fun registerView(view: ArCoreCompatView) {
        synchronized(lock) {
            Log.d(TAG, "📝 Registering new AR view")
            activeView = view
        }
    }
    
    /**
     * Check if the given view is the currently active view.
     * Used to determine if a view should do destructive cleanup.
     */
    fun isActiveView(view: ArCoreCompatView): Boolean {
        synchronized(lock) {
            return activeView === view
        }
    }
    
    /**
     * Unregister an AR view when it's disposed.
     */
    fun unregisterView(view: ArCoreCompatView) {
        synchronized(lock) {
            if (activeView === view) {
                Log.d(TAG, "📝 Unregistering AR view")
                activeView = null
            }
        }
    }
}

class ArViewFactory(
    private val messenger: BinaryMessenger,
    private val activity: Activity,
    private val lifecycle: Lifecycle
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    companion object {
        private const val TAG = "ArViewFactory"
    }

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        Log.d(TAG, "🏭 Creating new AR view with id: $viewId")
        
        // Mark that we're creating a new view - this prevents old views from doing destructive cleanup
        // Store the sequence number to assign to the new view
        val creationSequence = ArSessionCoordinator.markCreatingNewView()
        
        // CRITICAL: Check if we have a cached SceneView from a background transition
        // If so, we reuse it instead of creating a new one (preserving the AR session!)
        val cachedSceneView = ArSessionCoordinator.getCachedSceneView()
        
        if (cachedSceneView != null) {
            Log.d(TAG, "♻️ Found cached SceneView - reusing to preserve AR session!")
        } else {
            // No cached view - need to do normal cleanup
            // Check if there's a soft-disposed session - if so, fully dispose it first
            // This prevents having two AR sessions at once
            ArSessionCoordinator.cancelSoftDisposedSession()
            
            // CRITICAL: Ensure any existing AR view is disposed before creating new one
            // This blocks until the old view is fully cleaned up
            ArSessionCoordinator.prepareForNewView()
            
            // Extra delay to ensure camera resources are fully released
            // This is necessary because camera release is async and may still be in progress
            try {
                Log.d(TAG, "⏳ Waiting for camera resources to fully release...")
                Thread.sleep(300)
            } catch (e: InterruptedException) {
                // Ignore
            }
        }
        
        // Flutter passes context, we need to extract the ComponentActivity from it
        // The context might be wrapped, so we need to unwrap it
        val componentActivity = when {
            context is ComponentActivity -> {
                Log.d(TAG, "✅ Got ComponentActivity directly from context: ${context.javaClass.name}")
                context
            }
            activity is ComponentActivity -> {
                Log.d(TAG, "✅ Got ComponentActivity from activity field: ${activity.javaClass.name}")
                activity as ComponentActivity
            }
            context is android.content.ContextWrapper -> {
                // Flutter wraps the activity, need to unwrap it
                var unwrapped: android.content.Context? = (context as android.content.ContextWrapper).baseContext
                Log.d(TAG, "🔍 Context is ContextWrapper, unwrapping... baseContext=${unwrapped?.javaClass?.name}")
                while (unwrapped is android.content.ContextWrapper && unwrapped !is ComponentActivity) {
                    unwrapped = unwrapped.baseContext
                    Log.d(TAG, "   🔍 Unwrapping further... now=${unwrapped?.javaClass?.name}")
                }
                if (unwrapped is ComponentActivity) {
                    Log.d(TAG, "✅ Got ComponentActivity from unwrapped context: ${unwrapped.javaClass.name}")
                    unwrapped
                } else {
                    Log.w(TAG, "⚠️ Unwrapped context is not ComponentActivity: ${unwrapped?.javaClass?.name}")
                    null
                }
            }
            else -> {
                Log.w(TAG, "⚠️ Could not get ComponentActivity - context=${context.javaClass.name}, activity=${activity?.javaClass?.name}")
                null
            }
        }

        if (componentActivity == null) {
            Log.e(TAG, "❌ CRITICAL: Using ARSceneView without ComponentActivity! Background caching will NOT work!")
        }

        // Create view, passing cached SceneView if available
        val view = ArCoreCompatView(
            context = context, 
            messenger = messenger, 
            viewId = viewId, 
            activity = componentActivity, 
            lifecycle = lifecycle,
            cachedSceneViewArg = cachedSceneView
        )
        
        // Set the creation sequence so the view knows its position in the sequence
        view.setCreationSequence(creationSequence)
        
        // Register the new view with the coordinator
        ArSessionCoordinator.registerView(view)
        
        // Clear the creating flag (view initialized will be called separately)
        ArSessionCoordinator.viewInitialized()
        
        Log.d(TAG, "✅ AR view created and registered")
        return view
    }
}
