# Size-Based Classification System for AR Objects

## Overview
The AR Flutter Plugin now uses a size-based classification system instead of object-type-based classification for optimal placement and interaction. This provides more flexible and predictable behavior for different sized objects.

## Size Types

### SMALL
- **Intended for**: Small objects like grills, decorations, small furniture
- **Optimal placement distance**: 1.5-2.0 meters from user
- **Height offset**: Minimal (0.0-0.1m above ground)
- **Interaction area**: Standard touch detection radius
- **Examples**: Grills, lamps, small decorative items

### MEDIUM (Default)
- **Intended for**: Medium-sized objects like tables, chairs, medium furniture
- **Optimal placement distance**: 2.5-3.0 meters from user
- **Height offset**: Small (0.1-0.2m above ground)
- **Interaction area**: Slightly expanded touch detection
- **Examples**: Tables, chairs, medium appliances

### BIG
- **Intended for**: Large objects like pergolas, gazebos, large structures
- **Optimal placement distance**: 4.0-6.0 meters from user
- **Height offset**: Moderate (0.2-0.3m above ground)
- **Interaction area**: Significantly expanded touch detection
- **Examples**: Pergolas, gazebos, large furniture, structures

## Implementation

### Smart Placement
```dart
// Use the new addNodeWithSmartPlacement method
String? result = await arObjectManager.addNodeWithSmartPlacement(
  node,
  sizeType: "BIG", // SMALL, MEDIUM, or BIG
);
```

### Core Components

#### AR Placement Utils (`lib/utils/ar_placement_utils.dart`)
- `calculateOptimalPlacement()` - Calculates optimal position based on size type
- Size-specific distance and height calculations
- Camera orientation awareness

#### AR Object Manager (`lib/managers/ar_object_manager.dart`)
- `addNodeWithSmartPlacement()` - Enhanced placement method with size awareness
- Passes size information to native platforms for collision detection

#### Android Enhancement (`android/.../ArCoreCompatView.kt`)
- `calculateOptimalCollisionSize()` - Dynamic collision box sizing
- Size-aware collision detection
- Improved interaction for large objects

#### iOS Enhancement (`ios/Classes/IosARView.swift`)
- `detectNodeHitsEnhanced()` - Expanded touch detection areas
- Size-based interaction prioritization
- Better gesture handling for large objects

## Usage Examples

### Pergola Placement Example
```dart
// Place a large pergola with optimal positioning
ARNode pergola = ARNode(
  type: NodeType.webGLB,
  uri: "https://storage.googleapis.com/vd_ar_bucket/Pergola_Eva_450cm_pivottest_1-d02c09c2-bcec-490f-9452-feca8da064e5.glb",
  name: "pergola_main",
  scale: Vector3(1.0, 1.0, 1.0),
  isTransformable: true,
  enablePanGestures: true,
  enableRotationGestures: true,
);

String? result = await arObjectManager.addNodeWithSmartPlacement(
  pergola,
  sizeType: "BIG",
);
```

### Smart Placement Demo
The `examples/smart_placement_demo.dart` demonstrates all three size types with different objects and scales.

## Migration from Object Types

### Old System
```dart
// Before: Object-type based
objectType: "pergola"    // Too specific
objectType: "grill"      // Limited flexibility
objectType: "furniture"  // Too generic
```

### New System
```dart
// After: Size-based
sizeType: "BIG"     // Clear size indication
sizeType: "SMALL"   // Flexible for any small object
sizeType: "MEDIUM"  // Default for most objects
```

## Benefits

1. **Flexibility**: Same size type works for different object categories
2. **Predictability**: Size directly correlates with placement behavior
3. **Simplicity**: Only three classifications to remember
4. **Extensibility**: Easy to add new size types if needed
5. **Cross-platform**: Consistent behavior on Android and iOS

## Best Practices

1. **Choose size based on actual object dimensions**, not object type
2. **Use MEDIUM as default** for most standard objects
3. **Reserve BIG for objects larger than 2-3 meters** in any dimension
4. **Use SMALL for objects smaller than 1 meter** in all dimensions
5. **Test placement in real AR environment** to verify optimal distances

## Configuration

All placement calculations are configurable in `ar_placement_utils.dart`:

```dart
// Distance calculations
double baseDistance = sizeType == "SMALL" ? 1.5 : 
                     sizeType == "MEDIUM" ? 2.5 : 4.0;

// Height offsets
double heightOffset = sizeType == "SMALL" ? 0.05 : 
                     sizeType == "MEDIUM" ? 0.1 : 0.2;
```

Adjust these values based on your specific use case and user testing feedback.
