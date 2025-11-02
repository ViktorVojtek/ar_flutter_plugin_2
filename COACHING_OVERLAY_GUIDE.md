# AR Coaching Overlay Guide

## Overview

This guide explains the coaching/guidance overlays for **iOS (ARKit)** and **Android (ARCore)** in the AR Flutter Plugin 2, and how to enable similar functionality on both platforms.

---

## iOS (ARKit) - ARCoachingOverlayView ✅

iOS has **native built-in support** for coaching overlays through Apple's `ARCoachingOverlayView`. This is **already implemented** in the plugin.

### Features
- ✅ **Automatic activation** when tracking is poor
- ✅ **Beautiful animated guidance** showing how to move the device
- ✅ **Lighting condition warnings** (move to brighter area)
- ✅ **Camera tracking loss recovery** instructions
- ✅ **Plane detection guidance** (horizontal/vertical)

### How to Enable on iOS

```dart
void onARViewCreated(
  ARSessionManager sessionManager,
  ARObjectManager objectManager,
  ARAnchorManager anchorManager,
  ARLocationManager locationManager,
) {
  sessionManager.onInitialize(
    showAnimatedGuide: true, // ✅ Enable coaching overlay on iOS
    showPlanes: true,
    handleTaps: true,
  );
}
```

When `showAnimatedGuide: true`:
- The coaching overlay automatically appears when needed
- Shows animations to guide user movement
- Activates on tracking loss or poor lighting
- Disappears once tracking improves

### iOS Implementation Details

The iOS implementation uses Apple's native `ARCoachingOverlayView`:

```swift
// From ios/Classes/IosARView.swift
let coachingView: ARCoachingOverlayView

// Configuration
self.coachingView.session = self.sceneView.session
self.coachingView.activatesAutomatically = true
self.coachingView.goal = .horizontalPlane // or .verticalPlane
```

---

## Android (ARCore) - Custom Implementation ⚠️

**IMPORTANT**: ARCore (Android) does **NOT** have a built-in equivalent to iOS's `ARCoachingOverlayView`.

### Current State
- ❌ ARCore has no native coaching overlay
- ⚠️ The `showAnimatedGuide` parameter is **parsed but not used** on Android
- 💡 You need to implement custom guidance

### Why No Native Support?

Google's ARCore team decided **not to include** a coaching overlay component in their SDK. This was a conscious design decision - they expect developers to create custom UI that fits their app's design.

### Available Options for Android

#### Option 1: Custom Flutter Overlay (Recommended) ✅

Create your own coaching overlay using Flutter widgets that monitor tracking state:

```dart
class ARCoachingOverlay extends StatefulWidget {
  final ARSessionManager sessionManager;
  
  @override
  _ARCoachingOverlayState createState() => _ARCoachingOverlayState();
}

class _ARCoachingOverlayState extends State<ARCoachingOverlay> {
  bool _showCoaching = true;
  String _coachingMessage = "Move your device slowly to scan the area";
  Timer? _trackingTimer;
  
  @override
  void initState() {
    super.initState();
    _startTrackingMonitoring();
  }
  
  void _startTrackingMonitoring() {
    // Monitor tracking state every second
    _trackingTimer = Timer.periodic(Duration(seconds: 1), (timer) async {
      // Check if planes are detected
      bool planesDetected = await _checkPlanesDetected();
      
      setState(() {
        if (planesDetected) {
          _showCoaching = false;
        } else {
          _showCoaching = true;
          _coachingMessage = "Keep moving your device to find surfaces";
        }
      });
    });
  }
  
  Future<bool> _checkPlanesDetected() async {
    // You can implement plane detection checking here
    // For now, use a simple timer-based approach
    return false; // Placeholder
  }
  
  @override
  void dispose() {
    _trackingTimer?.cancel();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    if (!_showCoaching) return SizedBox.shrink();
    
    return Container(
      alignment: Alignment.center,
      child: Container(
        padding: EdgeInsets.all(24),
        margin: EdgeInsets.all(40),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.8),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Animated phone icon showing movement
            TweenAnimationBuilder(
              duration: Duration(seconds: 2),
              tween: Tween<double>(begin: -10, end: 10),
              builder: (context, double value, child) {
                return Transform.translate(
                  offset: Offset(value, 0),
                  child: Icon(
                    Icons.phone_android,
                    color: Colors.white,
                    size: 48,
                  ),
                );
              },
              onEnd: () => setState(() {}), // Loop animation
            ),
            SizedBox(height: 16),
            Text(
              _coachingMessage,
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 8),
            Text(
              "📱 Point at a flat surface and move slowly",
              style: TextStyle(
                color: Colors.white70,
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
```

**Usage:**

```dart
@override
Widget build(BuildContext context) {
  return Scaffold(
    body: Stack(
      children: [
        ARView(
          onARViewCreated: onARViewCreated,
          planeDetectionConfig: PlaneDetectionConfig.horizontal,
        ),
        // Add custom coaching overlay
        if (Platform.isAndroid)
          ARCoachingOverlay(sessionManager: arSessionManager!),
      ],
    ),
  );
}
```

#### Option 2: Monitor Tracking State ⚙️

ARCore provides tracking state information that you can use:

```dart
// Monitor camera tracking state
void _monitorTrackingState() {
  Timer.periodic(Duration(milliseconds: 500), (timer) async {
    if (arSessionManager != null) {
      // Get current camera pose
      try {
        var pose = await arSessionManager!.getCameraPose();
        if (pose != null) {
          // Camera is tracking - hide coaching
          setState(() {
            _showCoaching = false;
          });
        } else {
          // No camera pose - show coaching
          setState(() {
            _showCoaching = true;
            _coachingMessage = "Move device slowly to initialize tracking";
          });
        }
      } catch (e) {
        print("Error checking tracking state: $e");
      }
    }
  });
}
```

#### Option 3: Use Light Estimation 💡

The plugin already has light estimation - use it for lighting warnings:

```dart
void onARViewCreated(...) {
  // Set up lighting monitoring
  sessionManager.onLightingConditionChanged = (lightData) {
    bool isLowLight = lightData['isLowLight'] ?? false;
    
    if (isLowLight) {
      setState(() {
        _coachingMessage = "⚠️ Low light detected - move to a brighter area";
        _showCoaching = true;
      });
    }
  };
  
  // Start monitoring
  sessionManager.enableLightingMonitoring(enable: true, intervalMs: 1000);
}
```

#### Option 4: HandMotionView (Basic) 📱

The plugin has a basic `HandMotionView` class for plane scanning guidance, but it's **not currently connected**. To use it, you'd need to:

1. Add HandMotionView to the Android layout
2. Show/hide it based on plane detection
3. Animate it to guide user movement

However, **Option 1 (Custom Flutter Overlay)** is much more flexible and recommended.

---

## Complete Example: Cross-Platform Coaching

Here's a complete example that works on both iOS and Android:

```dart
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';

class ARScreenWithCoaching extends StatefulWidget {
  @override
  _ARScreenWithCoachingState createState() => _ARScreenWithCoachingState();
}

class _ARScreenWithCoachingState extends State<ARScreenWithCoaching> {
  ARSessionManager? arSessionManager;
  ARObjectManager? arObjectManager;
  
  bool _showCoaching = true;
  String _coachingMessage = "Move your device to scan the area";
  Timer? _coachingTimer;
  
  @override
  void dispose() {
    _coachingTimer?.cancel();
    arSessionManager?.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('AR with Coaching')),
      body: Stack(
        children: [
          ARView(
            onARViewCreated: onARViewCreated,
            planeDetectionConfig: PlaneDetectionConfig.horizontal,
          ),
          
          // Custom coaching overlay for Android
          // iOS uses native ARCoachingOverlayView
          if (Platform.isAndroid && _showCoaching)
            _buildAndroidCoachingOverlay(),
        ],
      ),
    );
  }
  
  Widget _buildAndroidCoachingOverlay() {
    return Container(
      color: Colors.black.withOpacity(0.7),
      child: Center(
        child: Container(
          padding: EdgeInsets.all(32),
          margin: EdgeInsets.all(40),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TweenAnimationBuilder<double>(
                duration: Duration(seconds: 2),
                tween: Tween(begin: -15, end: 15),
                curve: Curves.easeInOut,
                builder: (context, value, child) {
                  return Transform.translate(
                    offset: Offset(value, 0),
                    child: Icon(
                      Icons.phone_android,
                      size: 60,
                      color: Colors.blue,
                    ),
                  );
                },
                onEnd: () {
                  if (mounted) setState(() {}); // Loop animation
                },
              ),
              SizedBox(height: 24),
              Text(
                _coachingMessage,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 12),
              Text(
                "Point at a flat surface\nMove slowly from side to side",
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.black54,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  void onARViewCreated(
    ARSessionManager sessionManager,
    ARObjectManager objectManager,
    ARAnchorManager anchorManager,
    ARLocationManager locationManager,
  ) {
    arSessionManager = sessionManager;
    arObjectManager = objectManager;
    
    // Initialize AR
    arSessionManager!.onInitialize(
      showAnimatedGuide: true, // Works on iOS automatically
      showPlanes: true,
      handleTaps: true,
    );
    
    // On Android, manually monitor and hide coaching overlay
    if (Platform.isAndroid) {
      _startAndroidCoachingMonitoring();
    }
    
    // Monitor lighting on both platforms
    arSessionManager!.onLightingConditionChanged = (lightData) {
      bool isLowLight = lightData['isLowLight'] ?? false;
      if (isLowLight && mounted) {
        setState(() {
          _coachingMessage = "⚠️ Low light - move to brighter area";
          _showCoaching = true;
        });
      }
    };
    arSessionManager!.enableLightingMonitoring(enable: true);
    
    // Hide coaching when user taps to place object
    arSessionManager!.onPlaneOrPointTap = (hitResults) {
      if (hitResults.isNotEmpty && mounted) {
        setState(() {
          _showCoaching = false;
        });
      }
    };
  }
  
  void _startAndroidCoachingMonitoring() {
    // Auto-hide coaching after 10 seconds of scanning
    _coachingTimer = Timer(Duration(seconds: 10), () {
      if (mounted) {
        setState(() {
          _showCoaching = false;
        });
      }
    });
  }
}
```

---

## Summary

| Feature | iOS (ARKit) | Android (ARCore) |
|---------|------------|------------------|
| **Native Coaching Overlay** | ✅ Yes (`ARCoachingOverlayView`) | ❌ No |
| **Enabled by** | `showAnimatedGuide: true` | Custom implementation |
| **Tracking Loss Detection** | ✅ Automatic | ⚙️ Manual monitoring |
| **Lighting Warnings** | ✅ Built-in + Light Estimation | 💡 Light Estimation API |
| **Plane Detection Guidance** | ✅ Automatic | 🛠️ Custom UI needed |
| **Implementation Effort** | None (already done) | Medium (custom Flutter overlay) |

---

## Recommendations

1. **iOS**: Just use `showAnimatedGuide: true` - it works perfectly ✅

2. **Android**: Implement a custom Flutter overlay as shown in Option 1 above 🛠️

3. **Both Platforms**: Use the Light Estimation API for lighting warnings 💡

4. **Best Practice**: Hide coaching overlay once user successfully places first object 🎯

---

## Related Documentation

- 📖 [Light Estimation Guide](LIGHT_ESTIMATION_GUIDE.md)
- 📖 [Light Estimation Quick Reference](LIGHT_ESTIMATION_QUICK_REF.md)
- 📝 [Light Estimation Example](examples/light_estimation_example.dart)

---

## Need Help?

If you implement a custom coaching overlay for Android, consider:
- Using the Light Estimation API for lighting warnings
- Monitoring camera pose for tracking state
- Auto-hiding after successful plane detection
- Providing clear, animated visual guidance

The iOS coaching overlay sets a high standard - try to match that experience on Android with custom Flutter UI! 🚀
