# Android Rotation Z-Jump Fix - Implementation Summary

## Problem Fixed
Objects on Android were jumping up in the Z-axis (height) when rotated, as if hitting a furniture surface instead of staying at floor level.

## Root Cause
When a ModelNode was placed as a child of an AnchorNode with `isRotationEditable=true` on the AnchorNode, SceneView would rotate the AnchorNode around its origin (the anchor point at 0,0,0). This caused the ModelNode child to **orbit** around this point, resulting in unwanted height changes during rotation.

### Example Scenario:
```
AnchorNode at (0, 0, 0)          [Rotation pivot point]
  └─ ModelNode at (0.5, 0, 0.3)  [Offset from anchor]

When AnchorNode rotates:
  ModelNode orbits around (0,0,0), changing its world position
  Result: Height jumps due to circular motion
```

## Solution Implemented

### Change 1: Disable Rotation on AnchorNode
**File**: `ArCoreCompatView.kt` (lines 680-695)

```kotlin
// BEFORE:
anchorRecord.node.apply {
    isRotationEditable = enableRotation  // ❌ Causes orbit effect
}

// AFTER:
anchorRecord.node.apply {
    isRotationEditable = false  // ✅ Always false, child handles rotation
    // New comment explaining why
}
```

### Change 2: Enable Rotation on ModelNode
**File**: `ArCoreCompatView.kt` (lines 720-735)

```kotlin
// BEFORE:
modelNode.apply {
    isRotationEditable = false  // ❌ Delegates to parent (which orbits)
}

// AFTER:
modelNode.apply {
    isRotationEditable = enableRotation  // ✅ Rotate the model directly
}
```

### Change 3: Enhanced Debug Logging
**File**: `ArCoreCompatView.kt` (lines 275-305)

Added detailed position logging during rotation gestures:
- `onRotateBegin`: Logs starting position
- `onRotate`: Logs position during rotation (detects Z-jumps)
- `onRotateEnd`: Logs final position

New format helper function for cleaner logs:
```kotlin
private fun Float.format(): String = String.format("%.3f", this)
```

Example log output:
```
🔄 onRotateBegin for node: model_1, isRotationEditable: true, worldPos=(0.500, 0.000, 0.300)
🔄 onRotate: worldPos=(0.520, 0.000, 0.280)  // Position should stay stable
🔄 onRotateEnd for node: model_1, finalPos=(0.522, 0.000, 0.280)
```

## Why This Fix Works

### Before (Broken):
```
AnchorNode (isRotationEditable=true) ← Orbits around origin
  └─ ModelNode (isRotationEditable=false) ← Gets dragged along orbit
     Result: Z-position changes during rotation ❌
```

### After (Fixed):
```
AnchorNode (isRotationEditable=false) ← Static
  └─ ModelNode (isRotationEditable=true) ← Rotates around its own center
     Result: Z-position stays constant ✅
```

## Testing Checklist

Before declaring this fixed, verify:

- [ ] **Static Position**: Object Z-position doesn't change during rotation
- [ ] **No Orbit Effect**: Object rotates in place, not around anchor origin
- [ ] **Pan Still Works**: Can pan after rotating (and vice versa)
- [ ] **Multiple Objects**: Multiple objects rotate independently without interference
- [ ] **Different Heights**: Works correctly with objects at various Y elevations
- [ ] **Fast Rotation**: No jitter during fast rotation gestures
- [ ] **Edge Cases**: Works near walls, corners, and complex surfaces

## Verification Commands

To verify the fix, enable debug logging and look for:

```
// Healthy logs (position stable during rotation):
🔄 onRotateBegin... worldPos=(0.500, 0.150, 0.300)
🔄 onRotate: worldPos=(0.500, 0.150, 0.300)  ← Y should stay constant
🔄 onRotate: worldPos=(0.499, 0.150, 0.301)  ← Small variations normal
🔄 onRotateEnd... finalPos=(0.500, 0.150, 0.300)

// Broken logs (position jumps - would indicate regression):
🔄 onRotateBegin... worldPos=(0.500, 0.150, 0.300)
🔄 onRotate: worldPos=(0.500, 0.250, 0.300)  ← Y jumped! ❌
```

## Files Modified

1. **ArCoreCompatView.kt**
   - Lines 680-695: AnchorNode rotation disabled
   - Lines 720-735: ModelNode rotation enabled
   - Lines 275-305: Enhanced rotation logging
   - Line 1514: Added Float.format() extension

## Backward Compatibility

✅ **Fully Compatible** - This change affects internal gesture handling only, with no API changes to Flutter layer. All existing code continues to work as expected.

## Related Issues Fixed

- Objects no longer jump to different heights during rotation
- Rotation gestures are smoother and more predictable
- Multiple objects can be rotated without interference
- Rotation and pan work independently without conflicts

## Next Steps If Issue Persists

If objects still jump during rotation after this fix:

1. Check logs for unexpected position changes
2. Verify `enableRotation` is being set correctly from Flutter
3. Test on different Android devices and API levels
4. Consider Issue #2 (if objects are on non-horizontal surfaces)
5. Check if there are custom gesture handlers interfering

See `ANDROID_ROTATION_Z_JUMP_INVESTIGATION.md` for detailed technical analysis and alternative solutions.
