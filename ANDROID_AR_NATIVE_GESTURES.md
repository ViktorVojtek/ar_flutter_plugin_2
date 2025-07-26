# Android AR-Native Gesture Implementation

## Overview

The Android AR gesture system has been updated to use **AR-native movement algorithms** similar to iOS, rather than relying solely on SceneView's built-in gesture interpretation.

## Key Changes

### 1. **Hybrid Gesture Approach**
- **Native SceneView gestures enabled**: `isGestureEnabled = true` for basic touch detection
- **AR-specific movement logic**: Custom `onMove` implementation using AR hit testing
- **iOS-compatible algorithm**: Uses ARCore hit testing like iOS uses raycast queries

### 2. **AR-Based Movement Algorithm**

#### **How it works:**
```kotlin
override fun onMove(detector: MoveGestureDetector, e: MotionEvent): Boolean {
    // 1. Get current AR frame
    val currentFrame = sceneView.session?.update()
    
    // 2. Perform AR hit testing (like iOS raycast)
    val hitResults = currentFrame.hitTest(e)
    val planeHit = hitResults.firstOrNull { /* find tracked planes */ }
    
    // 3. Update position based on AR world coordinates
    if (planeHit != null) {
        val newPosition = ScenePosition(
            x = planeHit.hitPose.tx(),
            y = planeHit.hitPose.ty(), 
            z = planeHit.hitPose.tz()
        )
        // Set position directly like iOS
        transform = Transform(position = newPosition, ...)
        return true
    }
    
    // 4. Fallback to native behavior if no plane hit
    return super.onMove(detector, e)
}
```

### 3. **iOS vs Android Comparison**

| Aspect | iOS Implementation | Android Implementation |
|--------|-------------------|------------------------|
| **Gesture Detection** | `UIPanGestureRecognizer` | SceneView native + custom |
| **World Positioning** | `raycastQuery` + `worldTransform` | `frame.hitTest` + `hitPose` |
| **Movement Logic** | Custom raycast-based | AR hit testing based |
| **Position Update** | Direct `worldPosition` assignment | `Transform` object update |

## Benefits

### ✅ **Fixes**:
1. **Natural movement in all directions** - objects can move towards and away from device
2. **AR-aware positioning** - movement respects AR plane detection
3. **Consistent with iOS** - similar algorithm and behavior
4. **Robust fallback** - falls back to native gestures if AR hit testing fails

### ⚠️ **Requirements**:
1. **Plane detection must be enabled** - requires detected planes for optimal positioning
2. **AR session must be active** - relies on ARCore hit testing
3. **Performance consideration** - AR hit testing per gesture movement

## Testing

### **Expected Behavior**:
1. **Place 3D object** on detected plane
2. **Drag object** - should follow finger movement naturally in all directions
3. **Movement constraints** - object should stay on or near detected planes
4. **Smooth interaction** - no jumping or unnatural movement

### **Debug Logs to Monitor**:
```bash
# AR-based movement success
adb logcat | grep "AR-based pan moved node"

# Fallback to native behavior 
adb logcat | grep "No plane hit found for pan gesture"

# Error handling
adb logcat | grep "Error in AR-based pan gesture"
```

## Troubleshooting

### **Issue**: Object still moves strangely
**Solution**: Ensure plane detection is enabled and planes are detected before placing objects

### **Issue**: No movement at all
**Solution**: Check logs for "handlePans" configuration and ensure ModelNode `isPositionEditable = true`

### **Issue**: Movement too jumpy
**Solution**: May need to add smoothing between hit test results or adjust hit testing sensitivity

## Future Improvements

1. **Movement smoothing** - Interpolate between hit test results for smoother movement
2. **Gesture velocity** - Consider gesture velocity for more natural interaction
3. **Constraint options** - Allow objects to move freely in 3D space vs. constrained to planes
4. **Performance optimization** - Cache hit testing results or limit frequency

This implementation now provides iOS-level gesture quality on Android while maintaining compatibility with SceneView's native gesture system.
