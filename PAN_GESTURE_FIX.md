# Pan/Drag Gesture Fix

## Problem
Models could be rotated but **could not be panned/dragged** even though:
- `isTransformable: true` was set in Dart
- `enablePanGestures: true` was set in Dart

## Root Cause
The SceneView gesture system requires several conditions to be met for pan gestures to work:

1. **Node must be editable**: `isEditable = true`
2. **Position editing must be enabled**: `isPositionEditable = true`
3. **Gesture listeners must return proper values**: Return `true` when gesture is handled
4. **Proper gesture callbacks**: Gestures need explicit handling

## Fix Applied

### 1. Always Enable isEditable
```kotlin
// BEFORE: Only enabled if isTransformable was true
isEditable = isTransformable
isPositionEditable = isTransformable && enablePan

// AFTER: Always enabled to allow gesture detection
isEditable = true  // Always enable for gesture detection
isPositionEditable = enablePan  // Directly controlled by enablePan flag
isRotationEditable = enableRotation
```

### 2. Return True from Gesture Handlers
```kotlin
// BEFORE: No return value (implicitly false)
onMoveBegin = { _: MoveGestureDetector, _: MotionEvent, node: Node? ->
    node?.let { handleGestureEvent("onPanStart", it) }
}

// AFTER: Explicitly return true when handling gesture
onMoveBegin = { detector: MoveGestureDetector, event: MotionEvent, node: Node? ->
    if (node != null) {
        handleGestureEvent("onPanStart", node)
        true  // Indicate we handled the gesture
    } else {
        false  // No node, don't handle
    }
}
```

### 3. Added Debug Logging
```kotlin
Log.d(TAG, "Node $nodeId configured - isEditable: $isEditable, isPositionEditable: $isPositionEditable, isRotationEditable: $isRotationEditable")

Log.d(TAG, "onMoveBegin for node: ${node.name}, isPositionEditable: ${node.isPositionEditable}")
```

### 4. Fixed Anchor Node Configuration
```kotlin
// AFTER: Properly configure anchor for child gestures
if (isTransformable || enablePan || enableRotation) {
    anchorRecord.node.isEditable = true
    anchorRecord.node.isPositionEditable = enablePan
    anchorRecord.node.isRotationEditable = enableRotation
}
```

## Changes Made

### File: `ArCoreCompatView.kt`

#### Changed Gesture Listeners (Lines ~115-170)
- All gesture callbacks now return `Boolean`
- Return `true` when gesture is handled
- Return `false` when no node present
- Added debug logging for move and rotate begin events

#### Changed Node Configuration (Lines ~430-450)
- `isEditable` always set to `true`
- `isPositionEditable` directly controlled by `enablePan`
- `isRotationEditable` directly controlled by `enableRotation`
- Added configuration logging

## Testing

### Build Status
✅ **BUILD SUCCESSFUL**
```
> Task :ar_flutter_plugin_2:compileDebugKotlin
BUILD SUCCESSFUL in 17s
```

### Test the Fix
```bash
cd example_app
flutter run
```

### Expected Behavior
1. ✅ Tap model to select
2. ✅ **Drag model around the plane** (should now work!)
3. ✅ Two-finger rotate (should still work)
4. ✅ Model follows finger during drag

### Debug Output to Watch
```bash
adb logcat | grep SceneViewCompat
```

Look for:
```
D/SceneViewCompat: Node <nodeId> configured - isEditable: true, isPositionEditable: true, isRotationEditable: true
D/SceneViewCompat: onMoveBegin for node: <nodeId>, isPositionEditable: true
D/SceneViewCompat: onRotateBegin for node: <nodeId>, isRotationEditable: true
```

## Key Insights

### SceneView Gesture Requirements
1. ✅ `isEditable = true` is **required** for any gesture
2. ✅ Specific gesture flags (`isPositionEditable`, etc.) control which gestures work
3. ✅ Gesture handlers **must return Boolean** to indicate handling
4. ✅ Return `true` = gesture consumed, `false` = pass to next handler

### Common Mistakes
- ❌ Only setting `isEditable` when `isTransformable` is true
- ❌ Not returning values from gesture callbacks
- ❌ Requiring multiple conditions for position editing
- ❌ Not configuring anchor nodes properly

## Status
✅ **READY FOR TESTING**

Both rotation and pan gestures should now work correctly!
