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
 */
object ArSessionCoordinator {
    private const val TAG = "ArSessionCoordinator"
    
    @Volatile
    private var activeView: ArCoreCompatView? = null
    
    @Volatile
    private var isDisposing = false
    
    @Volatile
    private var suppressCameraExceptions = false
    
    private val lock = Object()
    
    // Original exception handler
    private var originalHandler: Thread.UncaughtExceptionHandler? = null
    
    /**
     * Install a global exception handler that catches camera-related exceptions
     * during AR view transitions. These exceptions are expected and safe to ignore.
     */
    fun installExceptionHandler() {
        if (originalHandler != null) return // Already installed
        
        originalHandler = Thread.getDefaultUncaughtExceptionHandler()
        
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            // Check if this is an expected camera exception during disposal
            if (suppressCameraExceptions && isCameraSessionException(throwable)) {
                Log.w(TAG, "🔇 Suppressing expected camera exception during AR transition: ${throwable.message}")
                // Don't crash - this is expected during AR view transitions
                return@setDefaultUncaughtExceptionHandler
            }
            
            // Otherwise, forward to original handler
            originalHandler?.uncaughtException(thread, throwable)
        }
        
        Log.d(TAG, "✅ Installed AR exception handler")
    }
    
    /**
     * Check if the exception is a camera session closure exception (expected during disposal)
     */
    private fun isCameraSessionException(throwable: Throwable): Boolean {
        val message = throwable.message ?: ""
        val stackTrace = throwable.stackTraceToString()
        
        return (throwable is IllegalStateException && 
                (message.contains("Session has been closed") ||
                 message.contains("session already closed") ||
                 message.contains("CameraCaptureSession"))) ||
               stackTrace.contains("CameraCaptureSession") ||
               stackTrace.contains("stopRepeating")
    }
    
    /**
     * Called before creating a new AR view.
     * Ensures any existing view is fully disposed before allowing new creation.
     */
    fun prepareForNewView(): Boolean {
        synchronized(lock) {
            Log.d(TAG, "🔄 Preparing for new AR view...")
            
            val existing = activeView
            if (existing != null) {
                Log.d(TAG, "⚠️ Found existing AR view - disposing first")
                isDisposing = true
                suppressCameraExceptions = true  // Start suppressing camera exceptions
                
                try {
                    // Force dispose the existing view synchronously
                    existing.forceDisposeSync()
                    
                    // Longer delay to let camera resources fully release and coroutines complete
                    Thread.sleep(500)
                    
                } catch (e: Exception) {
                    Log.e(TAG, "Error disposing existing view", e)
                } finally {
                    activeView = null
                    isDisposing = false
                    // Keep suppressing exceptions for a bit longer as background coroutines may still be running
                }
                
                Log.d(TAG, "✅ Previous view disposed")
            } else {
                Log.d(TAG, "ℹ️ No existing AR view found")
            }
            
            return true
        }
    }
    
    /**
     * Called after new view is fully initialized to stop suppressing exceptions
     */
    fun viewInitialized() {
        suppressCameraExceptions = false
        Log.d(TAG, "✅ View initialized, exception suppression disabled")
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
        
        // CRITICAL: Ensure any existing AR view is disposed before creating new one
        ArSessionCoordinator.prepareForNewView()
        
        val componentActivity = when {
            activity is ComponentActivity -> activity as ComponentActivity
            context is ComponentActivity -> context
            else -> null
        }

        if (componentActivity == null) {
            Log.w(TAG, "Using ARSceneView without ComponentActivity host; lifecycle features may be limited.")
        }

        val view = ArCoreCompatView(context, messenger, viewId, componentActivity, lifecycle)
        
        // Register the new view with the coordinator
        ArSessionCoordinator.registerView(view)
        
        Log.d(TAG, "✅ AR view created and registered")
        return view
    }
}
