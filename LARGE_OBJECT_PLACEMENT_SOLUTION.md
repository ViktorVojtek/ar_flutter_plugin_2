# Large Object Placement & Gesture Solution

## Problem Analysis

### Issues Identified:
1. **Large objects (pergolas) are placed too close/under the user**
   - Current placement logic uses fixed distance (-0.8m to -1.2m from camera)
   - Large objects need to be placed further away for proper visibility and interaction

2. **Android collision boxes don't scale with model size**
   - Currently uses `scaleX * 2.0f` regardless of actual model dimensions
   - Large pergolas have small collision boxes making them hard to select

3. **iOS lacks dynamic collision system**
   - No automatic collision box adjustment
   - Makes large objects difficult to interact with

## Solution Implementation

### 1. Intelligent Object Placement Distance

We'll modify the placement logic to adjust distance based on object scale:

```dart
// Calculate appropriate placement distance based on object scale
Vector3 calculateOptimalPlacement(Vector3 objectScale) {
  // Calculate object size (max dimension)
  double maxDimension = math.max(math.max(objectScale.x, objectScale.y), objectScale.z);
  
  // For large objects (pergolas): place further away
  // For small objects (grills): place closer
  double distance;
  if (maxDimension > 2.0) {
    // Large objects: 3-4 meters away
    distance = -3.0 - (maxDimension * 0.5);
  } else if (maxDimension > 1.0) {
    // Medium objects: 2-3 meters away  
    distance = -2.0 - maxDimension;
  } else {
    // Small objects: 1-2 meters away
    distance = -1.0 - (maxDimension * 0.5);
  }
  
  // Ensure minimum 1 meter above ground level
  double height = math.max(-0.5, -maxDimension * 0.1);
  
  return Vector3(0.0, height, distance);
}
```

### 2. Android: Model-Aware Collision System

Enhance the Android collision box calculation to use actual model dimensions:

```kotlin
// In ArCoreCompatView.kt - Enhanced collision calculation
private fun calculateOptimalCollisionSize(
    renderable: ModelRenderable,
    scaleX: Float,
    scaleY: Float, 
    scaleZ: Float
): Vector3 {
    try {
        // Get model's actual bounding box
        val boundingBox = renderable.collisionShape as? Box
        val modelSize = boundingBox?.size ?: Vector3(1.0f, 1.0f, 1.0f)
        
        // Calculate effective size including scale
        val effectiveSizeX = modelSize.x * scaleX
        val effectiveSizeY = modelSize.y * scaleY
        val effectiveSizeZ = modelSize.z * scaleZ
        
        // For large objects, create larger collision boxes for easier interaction
        val multiplier = when {
            effectiveSizeX > 2.0f || effectiveSizeY > 2.0f || effectiveSizeZ > 2.0f -> 1.5f // Large objects
            effectiveSizeX > 1.0f || effectiveSizeY > 1.0f || effectiveSizeZ > 1.0f -> 1.3f // Medium objects  
            else -> 1.1f // Small objects
        }
        
        return Vector3(
            maxOf(effectiveSizeX * multiplier, 0.5f),
            maxOf(effectiveSizeY * multiplier, 0.5f), 
            maxOf(effectiveSizeZ * multiplier, 0.5f)
        )
    } catch (e: Exception) {
        // Fallback to scale-based calculation
        Log.w(TAG, "Could not get model dimensions, using scale-based collision")
        return Vector3(
            maxOf(scaleX * 2.5f, 1.0f),
            maxOf(scaleY * 2.5f, 1.0f),
            maxOf(scaleZ * 2.5f, 1.0f)
        )
    }
}
```

### 3. iOS: Enhanced Gesture Handling

Implement collision-like behavior for iOS using node bounds:

```swift
// In IosARView.swift - Enhanced node selection
private func isNodeIntersected(by location: CGPoint, node: SCNNode) -> Bool {
    let hitResults = sceneView.hitTest(location, options: [
        SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue,
        SCNHitTestOption.ignoreChildNodes: false,
        SCNHitTestOption.ignoreHiddenNodes: false
    ])
    
    for hitResult in hitResults {
        if hitResult.node == node || hitResult.node.parent == node {
            return true
        }
    }
    
    // Enhanced bounds checking for large objects
    let screenPoint = sceneView.projectPoint(node.position)
    let nodeScreenLocation = CGPoint(x: CGFloat(screenPoint.x), y: CGFloat(screenPoint.y))
    
    // Calculate expanded touch area based on node scale
    let nodeScale = max(node.scale.x, max(node.scale.y, node.scale.z))
    let touchRadius: CGFloat = max(50.0, CGFloat(nodeScale) * 30.0) // Larger radius for large objects
    
    let distance = sqrt(pow(location.x - nodeScreenLocation.x, 2) + pow(location.y - nodeScreenLocation.y, 2))
    return distance <= touchRadius
}
```

## Implementation Files Modified

### Flutter Side (Dart)
- `lib/managers/ar_object_manager.dart` - Add placement distance calculation
- `lib/models/ar_node.dart` - Add size-aware placement helper

### Android Side
- `android/src/main/kotlin/.../ArCoreCompatView.kt` - Enhanced collision system

### iOS Side  
- `ios/Classes/IosARView.swift` - Enhanced gesture handling

## Benefits

1. **Proper large object placement**: Pergolas placed at appropriate distance (3-4m)
2. **Improved gesture interaction**: Larger collision boxes for large objects
3. **Cross-platform consistency**: Similar behavior on both iOS and Android
4. **Scalable solution**: Automatically adapts to any object size

## Testing

Test with:
- Small objects (< 1m): grills, chairs
- Medium objects (1-2m): tables, benches  
- Large objects (> 2m): pergolas, gazebos

Verify:
- Appropriate placement distance
- Easy selection and manipulation
- Smooth pan/rotate gestures
