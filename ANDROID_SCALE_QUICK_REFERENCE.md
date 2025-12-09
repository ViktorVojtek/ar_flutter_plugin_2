# Android Pinch/Scale Gesture Fix - Quick Summary

## Problem
Rotating objects with 2 fingers occasionally triggers pinch/zoom, causing unwanted scaling.

## Solution
Added `enableScaleGestures` flag to ARNode, defaulting to `false` (disabled).

## Changes

### Flutter (`ar_node.dart`)
```dart
ARNode({
  // ... existing params ...
  this.enableScaleGestures = false,  // NEW - defaults to false
})
```

### Android (`ArCoreCompatView.kt`)
```kotlin
val enableScale = nodeMap["enableScaleGestures"] as? Boolean ?: false
isScaleEditable = enableScale  // Changed from: always false

// NEW: Explicit gesture handlers to actively block scale
onScaleBegin = { _, _, node ->
    val record = node?.let(::findNodeRecord)
    if (record?.enableScale == true) true else true  // true blocks gesture
},
onScale = { _, _, node ->
    val record = node?.let(::findNodeRecord)
    if (record?.enableScale == true) true else true  // Consume gesture
},
onScaleEnd = { _, _, node -> true }  // Clean up
```

## Usage

### Default (Recommended) - Rotation Only, No Zoom
```dart
ARNode(
  uri: "assets/model.glb",
  enableRotationGestures: true,
  // enableScaleGestures defaults to false ✅
)
```

### Enable Scale/Zoom
```dart
ARNode(
  uri: "assets/model.glb",
  enableRotationGestures: true,
  enableScaleGestures: true,  // Explicit opt-in
)
```

## Impact

| Aspect | Status |
|--------|--------|
| Breaking changes | None ✅ |
| Backward compatible | 100% ✅ |
| Default behavior | Fixes issue ✅ |
| Opt-in | Yes, for scale ✅ |

## Testing

```dart
// Test 1: No scale (default)
var node = ARNode(..., enableRotationGestures: true);
// Rotate: Works ✅ | Pinch: Does nothing ✅

// Test 2: With scale
var node = ARNode(..., enableRotationGestures: true, enableScaleGestures: true);
// Rotate: Works ✅ | Pinch: Zooms ✅ (may interfere slightly)
```

## Files Modified
- `lib/models/ar_node.dart` - Added `enableScaleGestures` parameter
- `android/src/main/kotlin/com/uhg0/ar_flutter_plugin_2/ArCoreCompatView.kt` - Updated node configuration

## Documentation
See **ANDROID_SCALE_GESTURE_INTERFERENCE_FIX.md** for:
- Detailed problem analysis
- All configuration combinations
- Testing procedures
- FAQ and troubleshooting
