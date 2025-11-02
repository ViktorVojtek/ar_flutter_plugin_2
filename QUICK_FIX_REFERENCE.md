# Quick Fix Reference - Filament Threading

## The Problem
```
E/Filament: reason: This thread has not been adopted.
F/libc: Fatal signal 6 (SIGABRT)
```
**Cause**: Filament API calls on wrong thread

## The Solution
**All Filament operations MUST run on main thread**

## Code Changes Checklist

### ✅ 1. Disposal Guard
```kotlin
private var isDisposed = false

override fun dispose() {
    if (isDisposed) return
    isDisposed = true
    // ... cleanup
}

// Check in all async operations:
if (isDisposed) return
```

### ✅ 2. Model Loading - Main Thread
```kotlin
// ❌ WRONG
scope.launch {
    sceneView.modelLoader.loadModelInstance(uri)
}

// ✅ CORRECT
scope.launch(Dispatchers.Main) {
    val modelInstance = withContext(Dispatchers.Main) {
        sceneView.modelLoader.loadModelInstance(uri)
    }
}
```

### ✅ 3. Environment Loading - Main Thread
```kotlin
// ❌ WRONG
scope.launch(Dispatchers.IO) {
    loader.createHDREnvironment("env.hdr")
}

// ✅ CORRECT
uiHandler.post {
    if (isDisposed) return@post
    loader.createHDREnvironment("env.hdr")
}
```

### ✅ 4. Frame Handler Protection
```kotlin
private fun handleFrame(frame: Frame) {
    if (isDisposed) return  // Add this guard
    // ... rest of code
}
```

### ✅ 5. Lazy Environment Init
```kotlin
// Remove from init block
// Add to handleFrame:
if (!environmentInitialized) {
    initializeDefaultEnvironment()
}
```

## Golden Rules

### DO ✅
- Use `Dispatchers.Main` for Filament operations
- Use `uiHandler.post {}` for UI thread operations
- Check `isDisposed` before async operations
- Initialize Filament resources lazily
- Clean up on main thread

### DON'T ❌
- Use `Dispatchers.IO` for Filament calls
- Load environments in init block
- Skip disposal checks
- Run Filament operations on background threads
- Forget thread context

## Testing
```bash
# Build
cd example_app
flutter clean && flutter pub get
flutter run

# Monitor
adb logcat | grep -E "(Filament|FATAL)"
```

## Success Indicators
✅ No "thread has not been adopted" errors
✅ Autoplacement example loads
✅ Models render with textures
✅ Gestures work smoothly
✅ No crashes on navigation

## If Still Crashing
1. Check logcat for new error message
2. Verify all Filament calls are on main thread
3. Ensure disposal guards are in place
4. Check model files have materials
5. Verify assets exist

## Modified File
`android/src/main/kotlin/com/uhg0/ar_flutter_plugin_2/ArCoreCompatView.kt`

## Build Status
✅ Compiles successfully
✅ No critical errors
⚠️ One minor warning (defensive check)

---
**Status**: READY FOR TESTING 🚀
