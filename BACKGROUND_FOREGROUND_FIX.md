# Background/Foreground AR Session Fix

## Problem
When the app goes to background and returns to foreground, the AR session shows a black screen.

## Root Cause Analysis
The issue involves multiple layers:

1. **Flutter PlatformView lifecycle**: When app goes to background, Flutter may call `dispose()` on the platform view
2. **Android Activity lifecycle**: Activity receives ON_PAUSE → ON_STOP when going to background
3. **SceneView behavior**: SceneView destroys AR resources on ON_STOP, which can't be easily recreated

## Solution Implemented

### 1. PermissionAwareLifecycle - Suppress ON_STOP for Background
Modified `PermissionAwareLifecycle.kt` to NOT propagate ON_STOP to SceneView when the app is just going to background (not navigating away):

```kotlin
// ON_STOP is only propagated if activity.isFinishing is true
// For background-only transitions, only ON_PAUSE is sent
if (isActivityFinishing) {
    lifecycleRegistry.handleLifecycleEvent(Lifecycle.Event.ON_STOP)
} else {
    Log.d(TAG, "Background only - NOT propagating ON_STOP")
    suppressedStop = true
}
```

This keeps SceneView's AR resources alive during background transitions.

### 2. ArCoreCompatView - Soft Dispose for Background
Modified `dispose()` to detect if the app is in background and use soft dispose:

```kotlin
override fun dispose() {
    val isBackgroundDispose = isActivityStopped()
    
    if (isBackgroundDispose) {
        // Soft dispose - just pause, don't destroy
        ArSessionCoordinator.performSoftDispose(this)
        return  // Don't destroy anything
    }
    
    // Full dispose for real navigation
    isDisposed = true
    // ... full cleanup
}
```

### 3. ArSessionCoordinator - Delayed Disposal
Added soft dispose mechanism that:
- Pauses the session but keeps resources allocated
- Sets a 5-second timer for full disposal
- Cancels the timer if the session is restored
- Properly cleans up if a new view is created

### Key Changes

**PermissionAwareLifecycle.kt**:
- Added `suppressedStop` flag to track suppressed ON_STOP events
- Only propagate ON_STOP when `activity.isFinishing` is true
- ON_PAUSE is always propagated (pauses session/camera)

**ArCoreCompatView.kt**:
- Added `pauseSessionOnly()` and `resumeSessionOnly()` methods
- Added `isActivityStopped()` check in dispose()
- Enhanced logging to track lifecycle states

**ArViewFactory.kt**:
- Added `performSoftDispose()` for pausing without destroying
- Added `cancelSoftDisposedSession()` for cleanup before new view
- Added delayed disposal mechanism (5 second window)

## Testing

1. Open AR view with objects placed
2. Put app in background (home button)
3. Wait 2-3 seconds
4. Return to app
5. AR session should resume with camera working

## Debug Logs to Look For

When going to background:
```
⏹️ Background only - NOT propagating ON_STOP (preserving AR resources)
🧹 DISPOSE CALLED - isBackgroundDispose: true
🔄 Background dispose detected - using soft dispose
⏸️ Pausing session only (keeping resources)
```

When returning:
```
▶️ ON_START after suppressed ON_STOP - restoring AR session
```

## Limitations

- If user stays in background > 5 seconds, full disposal occurs
- New view creation will dispose soft-disposed session
- Objects may need to be re-placed after full disposal
