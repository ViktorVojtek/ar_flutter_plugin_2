# Depth API & Occlusion Guide

## Overview

The AR Flutter Plugin 2 now supports **ARCore Depth API** for realistic occlusion! This allows your 3D models to be **hidden behind real-world objects** like furniture, walls, or people, creating incredibly immersive AR experiences.

<img src="https://developers.google.com/static/ar/develop/depth/images/depth-values-diagram.png" alt="Depth API Visualization" width="600"/>

## What is Depth Occlusion?

**Depth occlusion** makes virtual objects appear realistically in the real world by:
- ✅ **Hiding virtual objects behind real objects** (e.g., a virtual character walks behind a real couch)
- ✅ **Showing virtual objects in front of real objects** (e.g., a virtual ball appears in front of a real table)
- ✅ **Creating depth-aware interactions** (e.g., virtual objects can't pass through real walls)

### Without Occlusion ❌
Virtual objects appear "flat" and always render on top of everything, breaking immersion.

### With Occlusion ✅
Virtual objects correctly appear behind or in front of real-world objects based on actual depth!

---

## Features

| Feature | Status | Description |
|---------|--------|-------------|
| **Automatic Depth Mode** | ✅ Enabled | ARCore automatically calculates depth |
| **Depth Occlusion** | ✅ Enabled by Default | Virtual objects occluded by real objects |
| **Depth Image Access** | ✅ Available | Get raw depth data for custom use cases |
| **Device Compatibility Check** | ✅ Available | Check if device supports depth |
| **ToF Sensor Support** | ✅ Automatic | Uses ToF sensor if available, motion-based otherwise |

---

## How It Works

### Android (ARCore)

ARCore calculates depth using:
1. **Motion-based depth** - Analyzes camera movement and feature points (works on ALL ARCore devices)
2. **ToF sensor** - If available, combines hardware depth sensor data for improved accuracy

The plugin **automatically enables depth occlusion** when you initialize the AR session!

### iOS (ARKit)

iOS depth features coming soon! ARKit has similar depth capabilities through LiDAR sensors.

---

## Quick Start

### 1. Enable Depth Occlusion (Already Enabled by Default!)

Depth occlusion is **automatically enabled** when you initialize your AR session:

```dart
void onARViewCreated(
  ARSessionManager sessionManager,
  ARObjectManager objectManager,
  ARAnchorManager anchorManager,
  ARLocationManager locationManager,
) {
  arSessionManager = sessionManager;
  
  // Initialize AR - depth occlusion is enabled automatically!
  arSessionManager!.onInitialize(
    showPlanes: true,
    handleTaps: true,
  );
  
  // That's it! Your models will now be occluded by real objects
  print("✅ Depth occlusion enabled automatically");
}
```

### 2. Check Device Support

```dart
Future<void> checkDepthSupport() async {
  bool supported = await arSessionManager!.isDepthSupported();
  
  if (supported) {
    print("✅ This device supports depth occlusion!");
  } else {
    print("❌ Depth not supported on this device");
  }
}
```

### 3. Toggle Occlusion On/Off

```dart
// Enable occlusion
await arSessionManager!.enableDepthOcclusion(true);
print("🔍 Depth occlusion ENABLED");

// Disable occlusion (objects always render on top)
await arSessionManager!.enableDepthOcclusion(false);
print("🔍 Depth occlusion DISABLED");

// Check current status
bool isEnabled = await arSessionManager!.isDepthOcclusionEnabled();
print("Occlusion status: $isEnabled");
```

---

## API Reference

### Check Depth Support

```dart
Future<bool> isDepthSupported()
```

Check if the device supports the Depth API.

**Returns:**
- `true` if depth is supported
- `false` otherwise

**Example:**
```dart
bool supported = await sessionManager.isDepthSupported();
if (!supported) {
  showDialog(
    context: context,
    builder: (_) => AlertDialog(
      title: Text('Depth Not Supported'),
      content: Text('This device does not support depth occlusion.'),
    ),
  );
}
```

---

### Enable/Disable Depth Occlusion

```dart
Future<bool> enableDepthOcclusion(bool enable)
```

Enable or disable depth-based occlusion.

**Parameters:**
- `enable` - Set to `true` to enable, `false` to disable

**Returns:**
- `true` if operation succeeded
- `false` otherwise

**Example:**
```dart
// Enable realistic occlusion
bool success = await sessionManager.enableDepthOcclusion(true);
if (success) {
  print("✅ Objects will now be hidden behind real objects");
}

// Disable occlusion (for debugging or performance)
await sessionManager.enableDepthOcclusion(false);
```

---

### Check Occlusion Status

```dart
Future<bool> isDepthOcclusionEnabled()
```

Check if depth occlusion is currently enabled.

**Returns:**
- `true` if enabled
- `false` if disabled

**Example:**
```dart
bool enabled = await sessionManager.isDepthOcclusionEnabled();
print("Occlusion is ${enabled ? 'ON' : 'OFF'}");
```

---

### Get Raw Depth Image

```dart
Future<Map<String, dynamic>?> acquireDepthImage()
```

Acquire the current depth image for custom depth processing.

**Returns:**
A map containing:
- `width` - Width of depth image (pixels)
- `height` - Height of depth image (pixels)
- `depthData` - List of depth values (millimeters)
- `format` - "millimeters"

Returns `null` if depth data is not yet available.

**Example:**
```dart
final depthImage = await sessionManager.acquireDepthImage();

if (depthImage != null) {
  int width = depthImage['width'];
  int height = depthImage['height'];
  List<int> depths = depthImage['depthData'];
  
  print("Depth image: ${width}x${height}");
  print("First pixel depth: ${depths[0]}mm = ${depths[0] / 1000}m");
  
  // Find closest point
  int minDepth = depths.reduce((a, b) => a < b ? a : b);
  print("Closest object: ${minDepth}mm away");
} else {
  print("Depth data not available yet - keep moving device");
}
```

---

## Complete Example

```dart
import 'package:flutter/material.dart';
import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';

class DepthOcclusionExample extends StatefulWidget {
  @override
  _DepthOcclusionExampleState createState() => _DepthOcclusionExampleState();
}

class _DepthOcclusionExampleState extends State<DepthOcclusionExample> {
  ARSessionManager? arSessionManager;
  ARObjectManager? arObjectManager;
  
  bool _depthSupported = false;
  bool _occlusionEnabled = true;
  String _depthInfo = "Checking...";
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Depth Occlusion Demo')),
      body: Stack(
        children: [
          ARView(
            onARViewCreated: onARViewCreated,
            planeDetectionConfig: PlaneDetectionConfig.horizontal,
          ),
          
          // Depth status overlay
          Positioned(
            top: 60,
            left: 20,
            right: 20,
            child: Container(
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.8),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '🔍 Depth API Status',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Device Support: ${_depthSupported ? "✅ Yes" : "❌ No"}',
                    style: TextStyle(color: Colors.white),
                  ),
                  Text(
                    'Occlusion: ${_occlusionEnabled ? "✅ Enabled" : "❌ Disabled"}',
                    style: TextStyle(color: Colors.white),
                  ),
                  Text(
                    _depthInfo,
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          
          // Toggle button
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Center(
              child: ElevatedButton(
                onPressed: _toggleOcclusion,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _occlusionEnabled ? Colors.green : Colors.grey,
                  padding: EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                ),
                child: Text(
                  _occlusionEnabled ? 'Occlusion: ON' : 'Occlusion: OFF',
                  style: TextStyle(fontSize: 16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  void onARViewCreated(
    ARSessionManager sessionManager,
    ARObjectManager objectManager,
    ARAnchorManager anchorManager,
    ARLocationManager locationManager,
  ) async {
    arSessionManager = sessionManager;
    arObjectManager = objectManager;
    
    // Initialize AR
    await arSessionManager!.onInitialize(
      showPlanes: true,
      handleTaps: true,
    );
    await arObjectManager!.onInitialize();
    
    // Check depth support
    bool supported = await arSessionManager!.isDepthSupported();
    bool enabled = await arSessionManager!.isDepthOcclusionEnabled();
    
    setState(() {
      _depthSupported = supported;
      _occlusionEnabled = enabled;
      _depthInfo = supported 
        ? "Tap to place objects - they'll be hidden behind real objects!"
        : "Depth not supported - objects always render on top";
    });
    
    // Periodically check depth image availability
    _monitorDepthData();
    
    // Set up tap handler
    arSessionManager!.onPlaneOrPointTap = _onPlaneTapped;
  }
  
  void _monitorDepthData() {
    Future.delayed(Duration(seconds: 2), () async {
      if (arSessionManager != null) {
        final depthImage = await arSessionManager!.acquireDepthImage();
        if (depthImage != null) {
          int width = depthImage['width'];
          int height = depthImage['height'];
          setState(() {
            _depthInfo = "Depth image: ${width}x${height} pixels";
          });
        }
        _monitorDepthData(); // Check again
      }
    });
  }
  
  Future<void> _toggleOcclusion() async {
    bool newState = !_occlusionEnabled;
    bool success = await arSessionManager!.enableDepthOcclusion(newState);
    
    if (success) {
      setState(() {
        _occlusionEnabled = newState;
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            newState 
              ? '✅ Occlusion enabled - objects hidden behind real objects'
              : '❌ Occlusion disabled - objects always visible'
          ),
          backgroundColor: newState ? Colors.green : Colors.orange,
        ),
      );
    }
  }
  
  Future<void> _onPlaneTapped(List<ARHitTestResult> hits) async {
    if (hits.isEmpty) return;
    
    // Place a 3D model (example using Duck model)
    // Your model placement code here...
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _occlusionEnabled
            ? "🦆 Duck placed! Try moving behind real objects"
            : "🦆 Duck placed (occlusion disabled)"
        ),
      ),
    );
  }
}
```

---

## Device Compatibility

### Supported Devices

ARCore Depth API is supported on:
- ✅ **All ARCore-compatible devices** (motion-based depth)
- ✅ **ToF sensor devices** (enhanced accuracy) - including:
  - Samsung Galaxy S20+ / S20 Ultra / S21 Ultra
  - Samsung Galaxy Note 10+ / Note 20 Ultra
  - Huawei P30 Pro / Mate 30 Pro
  - And more! See [ARCore supported devices](https://developers.google.com/ar/discover/supported-devices)

### Checking at Runtime

```dart
bool supported = await sessionManager.isDepthSupported();
if (!supported) {
  // Show fallback UI or disable depth features
  print("Depth not available - gracefully degrading experience");
}
```

---

## Performance Considerations

### Battery Impact
- Depth calculation uses additional CPU/GPU
- Consider allowing users to toggle occlusion on/off
- Most modern ARCore devices handle this efficiently

### When to Enable/Disable

**Enable occlusion when:**
- ✅ Realistic rendering is critical
- ✅ Objects need to interact with real environment
- ✅ Professional/commercial applications

**Disable occlusion when:**
- ❌ Simple AR experiences
- ❌ Battery life is critical
- ❌ Performance is constrained
- ❌ Objects should always be visible (e.g., UI elements)

---

## Troubleshooting

### Depth Data Not Available

**Problem:** `acquireDepthImage()` returns null

**Solutions:**
1. **Move the device** - Depth requires motion and feature points
2. **Wait a few seconds** - Depth calculation takes time to initialize
3. **Check device support** - Use `isDepthSupported()`
4. **Ensure good lighting** - Poor lighting affects depth calculation

```dart
final depthImage = await sessionManager.acquireDepthImage();
if (depthImage == null) {
  print("⚠️ Depth not available yet:");
  print("  • Move device slowly");
  print("  • Ensure good lighting");
  print("  • Wait for feature point tracking");
}
```

### Occlusion Not Working

**Problem:** Objects don't appear behind real objects

**Solutions:**
1. **Check if enabled:**
   ```dart
   bool enabled = await sessionManager.isDepthOcclusionEnabled();
   if (!enabled) {
     await sessionManager.enableDepthOcclusion(true);
   }
   ```

2. **Verify device support:**
   ```dart
   bool supported = await sessionManager.isDepthSupported();
   ```

3. **Wait for depth data:**
   - Depth calculation takes 1-2 seconds after AR starts
   - Requires camera movement and feature points

### Poor Occlusion Quality

**Problem:** Objects flicker or occlusion is inaccurate

**Solutions:**
1. **Improve lighting** - Depth works best in well-lit environments
2. **Move slowly** - Rapid movement reduces depth quality
3. **Scan the environment** - Move device to build better depth map
4. **Check distance** - Depth quality decreases at far distances (>8m)

---

## Advanced Usage

### Custom Depth Processing

```dart
Future<void> analyzeDepth() async {
  final depthImage = await sessionManager.acquireDepthImage();
  
  if (depthImage != null) {
    List<int> depths = depthImage['depthData'];
    int width = depthImage['width'];
    int height = depthImage['height'];
    
    // Find average depth
    double avgDepth = depths.reduce((a, b) => a + b) / depths.length;
    print("Average scene depth: ${avgDepth}mm = ${avgDepth / 1000}m");
    
    // Find closest and farthest points
    int minDepth = depths.reduce((a, b) => a < b ? a : b);
    int maxDepth = depths.reduce((a, b) => a > b ? a : b);
    print("Depth range: ${minDepth}mm to ${maxDepth}mm");
    
    // Analyze specific region (center of image)
    int centerX = width ~/ 2;
    int centerY = height ~/ 2;
    int centerIndex = centerY * width + centerX;
    int centerDepth = depths[centerIndex];
    print("Center point depth: ${centerDepth}mm");
  }
}
```

### Depth-Based Object Placement

```dart
Future<void> placeObjectAtDepth(double targetDepthMeters) async {
  final depthImage = await sessionManager.acquireDepthImage();
  
  if (depthImage != null) {
    List<int> depths = depthImage['depthData'];
    int targetMm = (targetDepthMeters * 1000).round();
    
    // Find pixel closest to target depth
    int closestIndex = 0;
    int closestDiff = (depths[0] - targetMm).abs();
    
    for (int i = 1; i < depths.length; i++) {
      int diff = (depths[i] - targetMm).abs();
      if (diff < closestDiff) {
        closestDiff = diff;
        closestIndex = i;
      }
    }
    
    int width = depthImage['width'];
    int pixelX = closestIndex % width;
    int pixelY = closestIndex ~/ width;
    
    print("Place object at pixel ($pixelX, $pixelY) - depth: ${depths[closestIndex]}mm");
    // Use pixel coordinates for hit testing...
  }
}
```

---

## Related Documentation

- 📖 [HDR Lighting Guide](HDR_LIGHTING_GUIDE.md) - Combine with depth for ultra-realistic rendering
- 📖 [Light Estimation Guide](LIGHT_ESTIMATION_GUIDE.md) - Adaptive lighting based on environment
- 📖 [Official ARCore Depth Guide](https://developers.google.com/ar/develop/java/depth/developer-guide)

---

## Summary

✅ **Depth occlusion is ENABLED BY DEFAULT** - no configuration needed!  
✅ Works on **all ARCore devices** (motion-based)  
✅ Enhanced on **ToF sensor devices**  
✅ Toggle on/off anytime with `enableDepthOcclusion()`  
✅ Access raw depth data with `acquireDepthImage()`  
✅ Check device support with `isDepthSupported()`  

**Result:** Your AR objects now realistically appear behind or in front of real-world objects! 🎉

---

*Last updated: November 3, 2025*
