# AR Occlusion Guide

This guide explains how to enable occlusion in your AR Flutter apps so real-world objects appear **in front of** AR objects.

## Quick Start

Add this after initializing your AR session:

```dart
void onARViewCreated(
  ARSessionManager arSessionManager,
  ARObjectManager arObjectManager,
  ARAnchorManager arAnchorManager,
  ARLocationManager arLocationManager,
) async {
  // Initialize session
  await arSessionManager.onInitialize(...);
  await arObjectManager.onInitialize();
  
  // Enable occlusion
  await _enableOcclusion(arSessionManager);
}

Future<void> _enableOcclusion(ARSessionManager arSessionManager) async {
  // 1. People Occlusion (recommended - works on most modern iPhones)
  if (await arSessionManager.isPeopleOcclusionSupported()) {
    await arSessionManager.enablePeopleOcclusion(true);
    print("👤 People occlusion enabled");
  }
  
  // 2. Depth/Object Occlusion (requires LiDAR - iPhone 12 Pro and later)
  if (await arSessionManager.isDepthSupported()) {
    await arSessionManager.enableDepthOcclusion(true);
    print("🔍 Depth occlusion enabled");
  }
}
```

## Occlusion Types

### 1. People Occlusion
- **What it does:** Real people appear in front of AR objects
- **How it works:** Machine learning segments people from the camera feed
- **Requirements:** iOS 13+, A12 chip or later
- **Supported devices:** iPhone XS/XR and newer (including non-Pro models)

```dart
// Check support
bool supported = await arSessionManager.isPeopleOcclusionSupported();

// Enable
await arSessionManager.enablePeopleOcclusion(true);

// Disable
await arSessionManager.enablePeopleOcclusion(false);

// Check if currently enabled
bool enabled = await arSessionManager.isPeopleOcclusionEnabled();
```

### 2. Depth/Object Occlusion (LiDAR)
- **What it does:** ALL real objects (walls, furniture, etc.) appear in front of AR objects
- **How it works:** LiDAR builds a 3D mesh of your environment
- **Requirements:** iOS 14+, LiDAR sensor
- **Supported devices:** iPhone 12 Pro, 13 Pro, 14 Pro, 15 Pro, iPad Pro (2020+)

```dart
// Check support
bool supported = await arSessionManager.isDepthSupported();

// Enable
await arSessionManager.enableDepthOcclusion(true);

// Disable
await arSessionManager.enableDepthOcclusion(false);

// Check if currently enabled
bool enabled = await arSessionManager.isDepthOcclusionEnabled();
```

## Recommended Setup

For best results, enable **both** occlusion types when available:

```dart
Future<void> enableOcclusion(ARSessionManager session) async {
  try {
    // People occlusion - reliable, works on more devices
    if (await session.isPeopleOcclusionSupported()) {
      bool success = await session.enablePeopleOcclusion(true);
      if (success) print("👤 People occlusion enabled");
    }
    
    // Depth occlusion - best quality on LiDAR devices
    if (await session.isDepthSupported()) {
      bool success = await session.enableDepthOcclusion(true);
      if (success) print("🔍 Depth occlusion enabled");
    }
  } catch (e) {
    print("Occlusion error: $e");
  }
}
```

## Debug Mesh Visualization

To see exactly what the LiDAR is reconstructing (useful for debugging):

```dart
// Show the LiDAR mesh wireframe
await arSessionManager.showDebugMesh(true);

// Hide when done
await arSessionManager.showDebugMesh(false);
```

## Device Compatibility

| Device | People Occlusion | Depth/LiDAR Occlusion |
|--------|-----------------|----------------------|
| iPhone 15 Pro/Pro Max | ✅ | ✅ |
| iPhone 15/Plus | ✅ | ❌ |
| iPhone 14 Pro/Pro Max | ✅ | ✅ |
| iPhone 14/Plus | ✅ | ❌ |
| iPhone 13 Pro/Pro Max | ✅ | ✅ |
| iPhone 13/Mini | ✅ | ❌ |
| iPhone 12 Pro/Pro Max | ✅ | ✅ |
| iPhone 12/Mini | ✅ | ❌ |
| iPhone 11/Pro/Pro Max | ✅ | ❌ |
| iPhone XS/XR | ✅ | ❌ |
| iPhone X and older | ❌ | ❌ |
| iPad Pro 2020+ | ✅ | ✅ |

## Best Practices

1. **Always check support first** - Not all devices support occlusion
2. **People occlusion is more reliable** - LiDAR mesh can have artifacts
3. **Give LiDAR time to scan** - Wait 5-10 seconds for mesh to build
4. **Good lighting helps** - LiDAR works better in well-lit environments
5. **Avoid reflective surfaces** - Glass, mirrors, shiny floors cause artifacts

## Troubleshooting

### Occlusion not working?
1. Check device compatibility (see table above)
2. Ensure you're calling enable methods **after** `arSessionManager.onInitialize()`
3. Check console logs for support status

### LiDAR artifacts (holes in objects)?
- Use only people occlusion: `enableDepthOcclusion(false)`
- Or wait longer for LiDAR to build complete mesh
- Avoid reflective/transparent surfaces

### Performance issues?
- Occlusion uses extra GPU/CPU
- On older devices, consider using only people occlusion
- Disable occlusion for simple AR experiences

## Platform Notes

- **iOS only** - These features use ARKit/RealityKit
- **Android** - ARCore has limited occlusion support (not yet implemented in this plugin)
