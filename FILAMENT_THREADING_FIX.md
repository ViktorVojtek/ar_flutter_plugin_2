# Filament Threading Issue Fix

## Problem
The app was crashing with a fatal Filament error when accessing the Autoplacement example:

```
E/Filament(14633): Precondition
E/Filament(14633): in getState:330
E/Filament(14633): reason: This thread has not been adopted.
F/libc    (14633): Fatal signal 6 (SIGABRT), code -1 (SI_QUEUE) in tid 15177 (DefaultDispatch)
```

## Root Cause
Filament requires all threads that make API calls to be properly "adopted" before they can interact with the Filament engine. The crash occurred because:

1. **Asynchronous Environment Loading**: HDR environment was being loaded on a background thread (`Dispatchers.IO`) without proper thread adoption
2. **Model Loading on Wrong Thread**: Models were being loaded in coroutines that might execute on non-main threads
3. **Race Conditions**: Operations were happening after view disposal due to async operations

## Solution

### 1. Main Thread Enforcement
All Filament operations now execute on the main/UI thread:

```kotlin
// Environment loading - now on main thread
uiHandler.post {
    if (isDisposed) return@post
    
    runCatching {
        val environment = loader.createHDREnvironment("environments/evening_meadow_2k.hdr")
        environment?.let { sceneView.environment = it }
        environmentInitialized = true
    }.onFailure { error ->
        Log.w(TAG, "Unable to load default HDR environment: ${error.message}")
        environmentInitialized = true
    }
}

// Model loading - explicitly on Main dispatcher
scope.launch(Dispatchers.Main) {
    val modelInstance = withContext(Dispatchers.Main) {
        sceneView.modelLoader.loadModelInstance(uri)
            ?: throw IllegalArgumentException("Unable to load model: $uri")
    }
    // ... rest of model setup
}
```

### 2. Disposal Guard
Added `isDisposed` flag to prevent operations after view is destroyed:

```kotlin
private var isDisposed = false

override fun dispose() {
    if (isDisposed) return
    isDisposed = true
    // ... cleanup
}
```

All async operations now check `isDisposed` before proceeding.

### 3. Lazy Environment Initialization
Removed eager environment loading from init block. Environment is now initialized lazily on first frame update when AR session is ready:

```kotlin
private fun handleFrame(frame: Frame) {
    if (isDisposed) return
    
    if (!environmentInitialized) {
        initializeDefaultEnvironment()
    }
    // ... rest of frame handling
}
```

### 4. Proper Cleanup Order
Enhanced dispose() to clean up resources in the correct order on the main thread:

```kotlin
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
```

## Key Takeaways

### Filament Threading Rules
1. **All Filament API calls must be on the main/render thread** - Filament is not thread-safe
2. **Threads must be adopted** - If you must use other threads, they need explicit adoption
3. **Synchronous is safer** - Avoid async operations when possible for Filament calls

### Best Practices
1. Always use `Dispatchers.Main` for Filament operations
2. Check disposal state before async operations complete
3. Initialize resources lazily when the render context is ready
4. Clean up in the correct order: channels → coroutines → nodes → scene

## Testing
After applying this fix:
1. Build and run the app
2. Navigate to Autoplacement example
3. Verify no Filament crashes occur
4. Test model loading and rendering
5. Test gesture interactions

## Related Files Modified
- `/android/src/main/kotlin/com/uhg0/ar_flutter_plugin_2/ArCoreCompatView.kt`

## References
- Filament Documentation: https://google.github.io/filament/
- SceneView Documentation: https://github.com/SceneView/sceneview-android
- ARCore Sceneform Migration Guide
