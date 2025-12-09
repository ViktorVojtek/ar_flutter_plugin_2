package com.uhg0.ar_flutter_plugin_2

import android.app.Activity
import android.util.Log
import android.view.View
import android.view.ViewTreeObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry

/**
 * A lifecycle wrapper that prevents AR session destruction during temporary focus losses.
 * 
 * Problem: When Android permission dialogs appear, the activity loses window focus and 
 * may trigger lifecycle events. SceneView's ARSceneView interprets ON_PAUSE/ON_STOP as 
 * signals to destroy the AR session, causing permanent black screens.
 * 
 * Solution: This wrapper intercepts lifecycle events and delays PAUSE/STOP propagation 
 * when the focus loss appears to be temporary (permission dialogs, popups, etc.).
 * 
 * Key behaviors:
 * - Normal navigation (user leaving screen): Lifecycle events pass through immediately
 * - Permission dialogs: PAUSE is delayed and only sent if activity doesn't resume quickly
 * - Window focus loss without activity pause: Ignored (common for system dialogs)
 * - Background/foreground: PAUSE/STOP pass through, RESUME restores session
 */
class PermissionAwareLifecycle(
    private val activity: Activity,
    private val realLifecycle: Lifecycle
) : LifecycleOwner {

    companion object {
        private const val TAG = "PermissionAwareLifecycle"
        
        // Grace period to wait before propagating PAUSE event
        // Permission dialogs typically return focus within 100-500ms after grant/deny
        private const val PAUSE_GRACE_PERIOD_MS = 1500L
        
        // If activity is paused longer than this, it's likely real navigation
        private const val DESTROY_GRACE_PERIOD_MS = 3000L
        
        // Time window to detect if ON_STOP follows ON_PAUSE (indicates background, not dialog)
        private const val STOP_DETECTION_WINDOW_MS = 300L
    }

    private val lifecycleRegistry = LifecycleRegistry(this)
    
    @Volatile
    private var isPendingPause = false
    
    @Volatile
    private var isPendingStop = false
    
    @Volatile
    private var isPermissionDialogActive = false
    
    @Volatile
    private var lastPauseTime = 0L
    
    @Volatile
    private var waitingForStopCheck = false
    
    @Volatile
    private var suppressedStop = false  // Track if we suppressed ON_STOP for background
    
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    
    private var windowFocusListener: ViewTreeObserver.OnWindowFocusChangeListener? = null
    
    // Runnable to execute delayed PAUSE
    private val delayedPauseRunnable: Runnable = object : Runnable {
        override fun run() {
            if (isPendingPause && !isPermissionDialogActive) {
                Log.d(TAG, "⏸️ Grace period expired - propagating PAUSE")
                isPendingPause = false
                lifecycleRegistry.currentState = Lifecycle.State.STARTED
            } else if (isPendingPause) {
                Log.d(TAG, "⏸️ Permission dialog still active - extending grace period")
                // Re-schedule check
                mainHandler.postDelayed(this, PAUSE_GRACE_PERIOD_MS)
            }
        }
    }
    
    // Runnable to execute delayed STOP
    private val delayedStopRunnable: Runnable = Runnable {
        if (isPendingStop && !isPermissionDialogActive) {
            Log.d(TAG, "⏹️ Grace period expired - propagating STOP")
            isPendingStop = false
            lifecycleRegistry.currentState = Lifecycle.State.CREATED
        }
    }
    
    private val lifecycleObserver = object : androidx.lifecycle.LifecycleEventObserver {
        override fun onStateChanged(source: LifecycleOwner, event: Lifecycle.Event) {
            Log.d(TAG, "📢 Received lifecycle event: $event (permissionDialogActive=$isPermissionDialogActive, waitingForStopCheck=$waitingForStopCheck)")
            
            when (event) {
                Lifecycle.Event.ON_CREATE -> {
                    lifecycleRegistry.handleLifecycleEvent(event)
                }
                
                Lifecycle.Event.ON_START -> {
                    // Cancel any pending pause/stop
                    cancelPendingTransitions()
                    waitingForStopCheck = false
                    
                    // If we suppressed ON_STOP during background, we need to handle ON_START
                    // to restore the lifecycle state properly
                    if (suppressedStop) {
                        Log.d(TAG, "▶️ ON_START after suppressed ON_STOP - restoring AR session")
                        suppressedStop = false
                    }
                    
                    lifecycleRegistry.handleLifecycleEvent(event)
                }
                
                Lifecycle.Event.ON_RESUME -> {
                    // Activity resumed - cancel any pending transitions and restore state
                    cancelPendingTransitions()
                    isPermissionDialogActive = false
                    waitingForStopCheck = false
                    lifecycleRegistry.handleLifecycleEvent(event)
                    Log.d(TAG, "✅ Activity resumed - AR session safe")
                }
                
                Lifecycle.Event.ON_PAUSE -> {
                    lastPauseTime = System.currentTimeMillis()
                    
                    // Check if this looks like a permission dialog scenario
                    // Key insight: Permission dialogs cause ON_PAUSE but NOT ON_STOP
                    // Background causes ON_PAUSE followed quickly by ON_STOP
                    if (looksLikePermissionDialog()) {
                        Log.d(TAG, "⏸️ PAUSE detected - might be permission dialog, waiting to see if STOP follows")
                        isPendingPause = true
                        waitingForStopCheck = true
                        
                        // Wait briefly to see if ON_STOP comes (indicates background, not dialog)
                        mainHandler.postDelayed({
                            if (waitingForStopCheck && isPendingPause) {
                                // No ON_STOP came within window - this is likely a permission dialog
                                Log.d(TAG, "⏸️ No ON_STOP received - treating as permission dialog, keeping session alive")
                                isPermissionDialogActive = true
                                waitingForStopCheck = false
                                // Don't propagate PAUSE - keep AR session running
                                // Schedule a longer timeout in case dialog takes a while
                                mainHandler.postDelayed(delayedPauseRunnable, PAUSE_GRACE_PERIOD_MS)
                            }
                        }, STOP_DETECTION_WINDOW_MS)
                    } else {
                        // Normal pause (activity finishing or config change) - propagate immediately
                        Log.d(TAG, "⏸️ Normal PAUSE (finishing or config change) - propagating immediately")
                        lifecycleRegistry.handleLifecycleEvent(event)
                    }
                }
                
                Lifecycle.Event.ON_STOP -> {
                    // ON_STOP means app is going to background or being destroyed
                    // 
                    // CRITICAL: For SceneView/ARCore, we should NOT propagate ON_STOP
                    // for background transitions. ON_STOP causes SceneView to destroy
                    // resources that can't be easily recreated. ON_PAUSE is sufficient
                    // to pause the session and release camera.
                    //
                    // We only propagate ON_STOP if the activity is finishing (navigation away).
                    
                    val isActivityFinishing = activity.isFinishing
                    
                    if (waitingForStopCheck) {
                        // ON_STOP came quickly after ON_PAUSE - this is background, not dialog
                        Log.d(TAG, "⏹️ ON_STOP after ON_PAUSE - background detected (finishing=$isActivityFinishing)")
                        waitingForStopCheck = false
                        isPermissionDialogActive = false
                        
                        // Cancel any pending pause delays
                        cancelPendingTransitions()
                        
                        // Propagate PAUSE
                        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_PAUSE)
                        
                        // Only propagate STOP if activity is finishing (user navigated away)
                        if (isActivityFinishing) {
                            Log.d(TAG, "⏹️ Activity finishing - propagating ON_STOP")
                            suppressedStop = false
                            lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_STOP)
                        } else {
                            Log.d(TAG, "⏹️ Background only - NOT propagating ON_STOP (preserving AR resources)")
                            suppressedStop = true
                        }
                    } else if (isPermissionDialogActive || isPendingPause) {
                        // We thought it was a permission dialog but now getting STOP
                        Log.d(TAG, "⏹️ Unexpected ON_STOP during permission dialog (finishing=$isActivityFinishing)")
                        cancelPendingTransitions()
                        isPermissionDialogActive = false
                        lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_PAUSE)
                        
                        if (isActivityFinishing) {
                            suppressedStop = false
                            lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_STOP)
                        } else {
                            suppressedStop = true
                        }
                    } else {
                        // Normal STOP - check if activity is finishing
                        if (isActivityFinishing) {
                            Log.d(TAG, "⏹️ Normal ON_STOP (activity finishing) - propagating")
                            suppressedStop = false
                            lifecycleRegistry.handleLifecycleEvent(event)
                        } else {
                            Log.d(TAG, "⏹️ Normal ON_STOP (background only) - NOT propagating to preserve AR")
                            suppressedStop = true
                        }
                    }
                }
                
                Lifecycle.Event.ON_DESTROY -> {
                    // Always propagate destroy
                    cancelPendingTransitions()
                    waitingForStopCheck = false
                    lifecycleRegistry.handleLifecycleEvent(event)
                }
                
                else -> {
                    lifecycleRegistry.handleLifecycleEvent(event)
                }
            }
        }
    }
    
    init {
        // Start in INITIALIZED state
        lifecycleRegistry.currentState = Lifecycle.State.INITIALIZED
        
        // Observe real lifecycle
        realLifecycle.addObserver(lifecycleObserver)
        
        // Match current state
        lifecycleRegistry.currentState = realLifecycle.currentState
        
        // Setup window focus listener to detect permission dialogs
        setupWindowFocusListener()
        
        Log.d(TAG, "✅ PermissionAwareLifecycle initialized, current state: ${realLifecycle.currentState}")
    }
    
    private fun setupWindowFocusListener() {
        val decorView = activity.window?.decorView ?: return
        
        windowFocusListener = ViewTreeObserver.OnWindowFocusChangeListener { hasFocus ->
            Log.d(TAG, "🪟 Window focus changed: hasFocus=$hasFocus")
            
            if (!hasFocus) {
                // Window lost focus - could be permission dialog
                // Don't mark as permission dialog here - wait for lifecycle PAUSE
            } else {
                // Window regained focus
                if (isPermissionDialogActive) {
                    Log.d(TAG, "✅ Window focus restored after permission dialog")
                    // Permission dialog likely dismissed - cancel pending transitions
                    cancelPendingTransitions()
                    isPermissionDialogActive = false
                    
                    // Ensure we're in RESUMED state
                    if (realLifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) {
                        lifecycleRegistry.currentState = Lifecycle.State.RESUMED
                    }
                }
            }
        }
        
        decorView.viewTreeObserver.addOnWindowFocusChangeListener(windowFocusListener)
    }
    
    /**
     * Heuristic to detect if the current pause is likely from a permission dialog
     */
    private fun looksLikePermissionDialog(): Boolean {
        // Check if window has focus - permission dialogs take focus away
        val hasWindowFocus = activity.hasWindowFocus()
        
        // Check if activity is still in foreground (finishing = user navigated away)
        val isFinishing = activity.isFinishing
        
        // Check if activity is changing configurations (rotation, etc.)
        val isChangingConfigurations = activity.isChangingConfigurations
        
        Log.d(TAG, "🔍 Checking pause type: hasWindowFocus=$hasWindowFocus, isFinishing=$isFinishing, isChangingConfigurations=$isChangingConfigurations")
        
        // If we don't have window focus but activity isn't finishing or changing config,
        // it's likely a permission dialog or system popup
        return !hasWindowFocus && !isFinishing && !isChangingConfigurations
    }
    
    private fun cancelPendingTransitions() {
        if (isPendingPause || isPendingStop || waitingForStopCheck) {
            Log.d(TAG, "🚫 Canceling pending lifecycle transitions")
        }
        isPendingPause = false
        isPendingStop = false
        waitingForStopCheck = false
        // Note: Don't reset suppressedStop here - it's managed by ON_START/ON_STOP flow
        mainHandler.removeCallbacks(delayedPauseRunnable)
        mainHandler.removeCallbacks(delayedStopRunnable)
    }
    
    /**
     * Call this before showing a permission dialog to preemptively protect the session
     */
    fun notifyPermissionDialogShowing() {
        Log.d(TAG, "🔔 Permission dialog showing notification received")
        isPermissionDialogActive = true
    }
    
    /**
     * Call this after permission dialog is dismissed
     */
    fun notifyPermissionDialogDismissed() {
        Log.d(TAG, "🔔 Permission dialog dismissed notification received")
        isPermissionDialogActive = false
        cancelPendingTransitions()
    }
    
    /**
     * Manually trigger session resume (useful after permission dialogs)
     */
    fun forceResume() {
        Log.d(TAG, "🔄 Force resume requested")
        cancelPendingTransitions()
        isPermissionDialogActive = false
        
        // Ensure lifecycle is in RESUMED state if activity is resumed
        if (realLifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) {
            lifecycleRegistry.currentState = Lifecycle.State.RESUMED
            Log.d(TAG, "✅ Forced to RESUMED state")
        }
    }
    
    /**
     * Cleanup when AR view is disposed
     */
    fun dispose() {
        Log.d(TAG, "🧹 Disposing PermissionAwareLifecycle")
        cancelPendingTransitions()
        realLifecycle.removeObserver(lifecycleObserver)
        
        // Remove window focus listener
        windowFocusListener?.let { listener ->
            activity.window?.decorView?.viewTreeObserver?.removeOnWindowFocusChangeListener(listener)
        }
        windowFocusListener = null
    }
    
    override val lifecycle: Lifecycle
        get() = lifecycleRegistry
}
