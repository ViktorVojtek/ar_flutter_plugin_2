# iOS Depth Occlusion - Important Limitation ⚠️

## The Problem You're Experiencing

You have an **iPhone 13 Pro** with LiDAR, and the depth API is enabled, but you're not seeing occlusion effects. Here's why:

## Root Cause

**ARSCNView (SceneKit) does NOT automatically support depth-based occlusion**, even when scene depth is available.

### What We Have ✅
- ✅ Depth data from LiDAR (`ARFrame.sceneDepth`)
- ✅ Configuration enabled (`.frameSemantics.sceneDepth`)
- ✅ API methods working (`isDepthSupported`, `acquireDepthImage`)

### What's Missing ❌
- ❌ **Automatic occlusion rendering** (SceneKit doesn't do this)
- ❌ **Depth-based object hiding** (requires custom Metal shaders)

## Why This Happens

| Framework | Depth Occlusion Support |
|-----------|------------------------|
| **RealityKit** | ✅ Automatic depth occlusion built-in |
| **SceneKit (ARSCNView)** | ❌ NO automatic occlusion - requires custom implementation |
| **Android SceneView** | ✅ Automatic depth occlusion built-in |

**Your plugin uses ARSCNView (SceneKit)**, which is Apple's older AR framework. It provides depth DATA but not depth RENDERING.

## Solutions

### Option 1: Migrate to RealityKit (Recommended) ⭐
RealityKit provides automatic depth occlusion just like Android's SceneView.

**Pros:**
- ✅ Automatic depth occlusion (works immediately)
- ✅ Better performance
- ✅ Modern Apple AR framework
- ✅ Matches Android behavior

**Cons:**
- ❌ Requires significant plugin rewrite
- ❌ iOS 13.0+ only (but depth requires iOS 14.0+ anyway)
- ❌ Different API from SceneKit

### Option 2: Implement Custom Metal Shaders (Complex)
Write Metal shaders that sample the depth buffer and occlude virtual objects.

**Pros:**
- ✅ Keeps current SceneKit architecture
- ✅ Full control over occlusion rendering

**Cons:**
- ❌ Very complex implementation (hundreds of lines of Metal code)
- ❌ Requires deep graphics programming knowledge
- ❌ Performance overhead
- ❌ Maintenance burden

### Option 3: Use Plane-Based Occlusion (Current Workaround)
Make detected planes act as occluders (invisible geometry that blocks virtual objects).

**Pros:**
- ✅ Simple to implement
- ✅ Works with current SceneKit setup
- ✅ Some occlusion effect

**Cons:**
- ❌ Only occludes at plane surfaces (tables, floors)
- ❌ Doesn't occlude arbitrary geometry (walls, furniture edges)
- ❌ Not true depth occlusion

### Option 4: Document the Limitation (Easiest)
Clearly document that iOS depth occlusion requires RealityKit.

**Pros:**
- ✅ No code changes needed
- ✅ Sets clear expectations

**Cons:**
- ❌ No actual occlusion on iOS
- ❌ Platform inconsistency with Android

## Technical Details

### Why Android Works But iOS Doesn't

**Android (SceneView + Filament):**
```kotlin
// This ONE line enables full depth occlusion
config.depthMode = Config.DepthMode.AUTOMATIC

// SceneView's Filament renderer automatically:
// 1. Reads depth data
// 2. Creates occlusion geometry
// 3. Renders depth buffer writes
// 4. Occludes virtual objects
```

**iOS (SceneKit):**
```swift
// This enables depth DATA but not depth RENDERING
configuration.frameSemantics.insert(.sceneDepth)

// SceneKit does NOT automatically:
// ❌ Create occlusion geometry
// ❌ Write depth to render buffer
// ❌ Occlude virtual objects

// You must manually implement occlusion via:
// - Custom Metal shaders
// - ARMatteGenerator (people only)
// - Or migrate to RealityKit
```

### What Apple Recommends

From Apple's documentation:

> **For depth-based occlusion, use RealityKit.** RealityKit automatically renders virtual content with proper occlusion when you enable scene depth in ARWorldTrackingConfiguration.

> **SceneKit does not automatically use scene depth for occlusion.** If you need occlusion in SceneKit, you must implement custom rendering using Metal.

## Recommendation for Your Plugin

Given that:
1. You already have RealityKit-like behavior on Android
2. iOS users expect feature parity
3. RealityKit is Apple's modern AR framework
4. Custom Metal shaders are very complex

**I recommend migrating the iOS implementation from SceneKit to RealityKit.**

This would provide:
- ✅ True depth occlusion on iOS (matching Android)
- ✅ Better performance
- ✅ Future-proof architecture
- ✅ Consistent cross-platform behavior

## Current Status Summary

### Android ✅
```
Depth Data: ✅ Available
Depth Occlusion: ✅ Working
Implementation: SceneView + Filament (handles everything)
```

### iOS ⚠️
```
Depth Data: ✅ Available (LiDAR)
Depth Occlusion: ❌ Not Working
Implementation: ARSCNView + SceneKit (depth data only, no rendering)
Solution Needed: Migrate to RealityKit OR implement Metal shaders
```

## Testing the Current iOS Implementation

Even though full occlusion doesn't work, you can verify depth data is available:

```dart
// This should return true on iPhone 13 Pro
bool supported = await arSessionManager.isDepthSupported();
print('Depth supported: $supported'); // Should print: true

// This should return depth data
Map<String, dynamic>? depthImage = await arSessionManager.acquireDepthImage();
print('Depth data: ${depthImage?['width']}x${depthImage?['height']}');
// Should print: Depth data: 256x192 (or similar)
```

The depth DATA is there - it's just not being RENDERED for occlusion.

## Next Steps

**Choose your path:**

1. **Quick Fix:** Document that iOS occlusion requires RealityKit (set expectations)
2. **Medium Fix:** Implement plane-based occlusion (partial occlusion on flat surfaces)
3. **Full Fix:** Migrate iOS implementation to RealityKit (matches Android behavior)
4. **Complex Fix:** Implement custom Metal depth shaders (keep SceneKit, add occlusion)

**My recommendation:** Option 3 (RealityKit migration) for the best long-term solution.

Would you like me to:
- A) Start implementing RealityKit migration
- B) Implement plane-based occlusion as a temporary workaround
- C) Document the limitation and move on
- D) Research Metal shader implementation (complex)

Let me know which direction you'd like to take!

---
**Platform:** iOS 14.0+ with LiDAR
**Framework Limitation:** ARSCNView (SceneKit) 
**Status:** Depth data available, occlusion rendering not implemented
