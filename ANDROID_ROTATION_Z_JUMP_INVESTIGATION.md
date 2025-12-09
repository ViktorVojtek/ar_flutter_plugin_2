# Android Rotation Z-Jump Investigation

## Problem Summary
When rotating an object on Android, it sometimes jumps up in the Z-axis (or Y-axis in world space), snapping to a higher elevation as if hitting a table or furniture surface instead of staying at floor level.

## Root Cause Analysis

### Issue 1: AnchorNode Rotation with ModelNode Child
**Location**: `ArCoreCompatView.kt` lines 680-730

The current implementation has a hierarchical setup:
```
AnchorNode (rotation enabled when enableRotation=true)
  └─ ModelNode (isRotationEditable=false, delegates to parent)
```

**The Problem**:
When `isRotationEditable=true` is set on the AnchorNode, SceneView's gesture detector applies rotation transformations to the AnchorNode. However, **the pivot point for rotation at the AnchorNode level is at the anchor's position (0, 0, 0)**, not at the model's center.

This creates a **circular orbit effect**:
- ModelNode at position (0.5, 0.1, 0.3) relative to anchor
- When AnchorNode rotates, the ModelNode orbits around (0,0,0)
- The ModelNode's Y-coordinate changes as it rotates around the anchor origin
- Result: Object appears to "jump up" during rotation

### Issue 2: Pivot Point Mismatch
When a child node orbits around its parent's anchor point during rotation, any offset from the anchor causes unwanted translation. This is especially noticeable when:
- Model is placed offset from anchor (e.g., on a furniture surface)
- User performs 2-finger rotation gesture
- The rotation happens around the anchor origin, not the model's center

### Issue 3: SceneView's isRotationEditable Behavior
SceneView applies rotations in world space when `isRotationEditable=true`. When the node has a position offset, rotation causes it to orbit rather than rotate in place.

## Current Code Configuration

### AnchorNode Setup (lines 680-686)
```kotlin
anchorRecord.node.apply {
    isEditable = true
    isPositionEditable = false  // Manual pan only
    isRotationEditable = enableRotation  // ← THIS IS THE PROBLEM
    Log.d(TAG, "✅ AnchorNode configured: pan=$enablePan, rotation=$enableRotation")
}
```

### ModelNode Setup (lines 718-727)
```kotlin
modelNode.apply {
    isEditable = enablePan || enableRotation
    isPositionEditable = false  // Delegate to parent
    isRotationEditable = false   // Delegate to parent ← CORRECT
    isScaleEditable = false
    isSmoothTransformEnabled = false
}
```

## Solution

### Option A: Rotate ModelNode Instead of AnchorNode (RECOMMENDED)
Move rotation responsibility from AnchorNode to ModelNode:

```kotlin
// AnchorNode: only pan gestures
if (anchorRecord != null) {
    anchorRecord.node.apply {
        isEditable = true
        isPositionEditable = false   // Manual pan
        isRotationEditable = false   // ← CHANGE: Don't rotate anchor
        Log.d(TAG, "✅ AnchorNode configured: pan=$enablePan, rotation disabled")
    }
}

// ModelNode: handles both pan and rotation
if (anchorRecord != null) {
    modelNode.apply {
        isEditable = enablePan || enableRotation
        isPositionEditable = false        // Parent handles pan
        isRotationEditable = enableRotation  // ← CHANGE: Rotate the model
        isScaleEditable = false
        isSmoothTransformEnabled = false
    }
    anchorRecord.node.addChildNode(modelNode)
} else {
    // Standalone: already correct
    modelNode.apply {
        isEditable = isTransformable || enablePan || enableRotation
        isPositionEditable = enablePan
        isRotationEditable = enableRotation
        isScaleEditable = false
    }
    sceneView.addChildNode(modelNode)
}
```

**Why this works**:
- ModelNode rotates around its own center, not the anchor origin
- Anchor position remains unchanged during rotation
- Pan and rotate gestures work independently
- Model stays at its intended position

### Option B: Offset Rotation Pivot Point
If Option A doesn't work, calculate and set the rotation pivot point:

```kotlin
// Calculate pivot point as center of model's local bounds
val pivotOffset = calculateModelCenter(modelInstance)
modelNode.position = pivotOffset
// Apply rotation around this offset point
```

### Option C: Use Custom Rotation Handler
Instead of relying on SceneView's `isRotationEditable`, handle rotation manually in the gesture callbacks (similar to how pan is handled):

```kotlin
private var rotationStartQuaternion: Quaternion? = null

onRotateBegin = { detector, event, node ->
    val record = node?.let(::findNodeRecord)
    if (node != null && record?.enableRotation == true) {
        rotationStartQuaternion = node.quaternion
        handleGestureEvent("onRotationStart", node)
        true
    } else false
},

onRotate = { detector, event, node ->
    val record = node?.let(::findNodeRecord)
    if (node != null && record?.enableRotation == true) {
        val angle = detector.angle  // Rotation angle in radians
        // Apply rotation around Y-axis (up vector) only
        val yAxisRotation = Quaternion.fromAxisAngle(Vector3(0f, 1f, 0f), angle)
        node.quaternion = yAxisRotation * rotationStartQuaternion
        handleGestureEvent("onRotationChange", node)
        true
    } else false
}
```

## Verification Steps

1. **Before Fix**: 
   - Place object on floor/table
   - Enable rotation gestures
   - Perform 2-finger rotation
   - Observe: Object jumps up/down

2. **After Fix (Option A)**:
   - Same steps
   - Observe: Object rotates in place, Y-position stays constant

3. **Logging to Add**:
   ```kotlin
   Log.d(TAG, "🔄 Rotation: node.position before=${node.worldPosition}")
   // ... apply rotation ...
   Log.d(TAG, "🔄 Rotation: node.position after=${node.worldPosition}")
   ```

## Testing Recommendations

- Test on objects at different Y-heights (floor, table, elevated)
- Test rotation speed (fast vs slow)
- Test rotation direction (clockwise, counterclockwise)
- Test with pan+rotate combinations
- Verify pan still works after rotation
- Check multi-object scenarios

## Implementation Priority
1. **IMMEDIATE**: Apply Option A (Move rotation from AnchorNode to ModelNode)
2. **FOLLOW-UP**: Add detailed logging to track rotation pivot points
3. **VERIFY**: Test on multiple Android devices at different API levels
