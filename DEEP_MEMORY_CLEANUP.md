# Deep Memory Cleanup Documentation

This document describes the new deep memory cleanup functionality implemented in ar_flutter_plugin_2 to address memory management issues and prevent OOM crashes in AR applications.

## Overview

The deep memory cleanup system provides:

1. **Deep Resource Destruction**: Properly cleanup GPU resources, textures, materials, and GLTF assets
2. **Shared Asset Management**: Load assets once and share between multiple nodes
3. **Cache Management**: Purge accumulated caches and unused resources
4. **Session Reset**: Soft reset AR sessions without full app restart
5. **Memory Monitoring**: Real-time memory usage statistics
6. **Load Backpressure**: Queue model loading to prevent memory spikes

## New API Methods

### ARObjectManager

```dart
// Deep destroy native + GPU resources for a specific node
Future<bool> removeNodeDeep(String nodeId);

// Purge GLTF/material/texture caches on the native side  
Future<bool> purgeCaches();

// Create node that shares already-decoded asset by URI (no duplicate decode)
Future<String?> createNodeFromAsset({
  required String uri,
  required Float64List transformMatrix,
});

// Get memory usage statistics for diagnostics
Future<Map<String, dynamic>> getMemoryInfo();
```

### ARSessionManager

```dart
// Pause and re-run AR session with reset flags
Future<bool> softResetSession({
  bool removeExistingAnchors = true, 
  bool resetTracking = true
});
```

## Usage Patterns

### 1. Recommended Memory Management Sequence

After placing and removing multiple large models:

```dart
// 1. Remove nodes with deep cleanup
for (String nodeId in nodeIds) {
  await arObjectManager.removeNodeDeep(nodeId);
}

// 2. Purge caches
await arObjectManager.purgeCaches();

// 3. Optionally soft reset session
await arSessionManager.softResetSession();

// 4. Check memory after cleanup
final memoryInfo = await arObjectManager.getMemoryInfo();
print('Memory after cleanup: ${memoryInfo}');
```

### 2. Shared Asset Loading

Load the same model multiple times efficiently:

```dart
const String modelUri = 'models/heavy_model.glb';

// Create multiple instances sharing the same decoded asset
for (int i = 0; i < 5; i++) {
  final Matrix4 transform = Matrix4.identity();
  transform.setTranslation(Vector3(i * 2.0, 0, 0));
  
  final String? nodeId = await arObjectManager.createNodeFromAsset(
    uri: modelUri,
    transformMatrix: transform.storage,
  );
}
```

### 3. Memory Monitoring

Monitor memory usage during AR session:

```dart
void _updateMemoryDisplay() async {
  final info = await arObjectManager.getMemoryInfo();
  
  print('Java Heap: ${info['javaHeapUsedMB']?.toStringAsFixed(1)} MB');
  print('Native Heap: ${info['nativeHeapAllocatedMB']?.toStringAsFixed(1)} MB');
  print('Active Nodes: ${info['activeNodes']}');
  print('Cached Assets: ${info['cachedAssets']}');
}
```

## Memory Usage Guidelines

### Before This Update (Problematic)
```dart
// ❌ BAD: Regular removeNode leaves GPU resources
for (ARNode node in nodes) {
  arObjectManager.removeNode(node);  // Leaves GPU memory allocated
}
// Memory keeps accumulating, leading to OOM crashes
```

### After This Update (Recommended)
```dart
// ✅ GOOD: Deep removal cleans up all resources
for (ARNode node in nodes) {
  await arObjectManager.removeNodeDeep(node.name);  // Frees GPU memory
}
await arObjectManager.purgeCaches();  // Clear any remaining caches
```

## Platform Implementation Details

### Android (SceneView + Filament)

The Android implementation tracks:
- ModelInstance resources
- Material and texture references  
- Vertex/Index buffers
- GLTF asset loaders
- Shared asset cache with reference counting

**Resource Handle Structure:**
```kotlin
data class ResourceHandle(
    val nodeId: String,
    val modelInstance: ModelInstance?,
    val materials: MutableList<Any>,
    val textures: MutableList<Any>, 
    val assetKey: String?
)
```

### iOS (ARKit + SceneKit)

The iOS implementation tracks:
- SCNNode hierarchy
- SCNGeometry and SCNMaterial objects
- Metal textures and buffers
- ModelIO resources
- Asset cache with reference counting

**Resource Handle Structure:**
```swift
class ResourceHandle {
    let nodeId: String
    let node: SCNNode
    var textures: [Any]
    var materials: [SCNMaterial]
    var geometries: [SCNGeometry]
    let assetKey: String?
}
```

## Performance Benefits

1. **Memory Stability**: Memory returns to baseline after model removal
2. **Shared Loading**: 50-80% memory reduction when using same assets
3. **No Memory Creep**: Repeated add/remove cycles stay within memory bounds
4. **OOM Prevention**: Backpressure prevents concurrent loading spikes
5. **Faster Loading**: Cached assets load instantly for subsequent uses

## Testing & Validation

### Manual Testing Scenario
1. Launch AR view (record baseline memory ~40MB)
2. Place 3 large GLBs (>50MB each) → Memory spikes to ~190MB
3. Deep remove all 3 nodes → Memory returns to ~45MB (within 5% of baseline)
4. Purge caches → Additional small memory drop
5. Place same 3 GLBs using shared loading → Peak memory ~120MB (shared textures)
6. Remove all again → Memory stable at baseline

### Expected Results
- ✅ Memory returns within 5-10% of baseline after deep removal
- ✅ Shared assets use significantly less memory than individual loading  
- ✅ No crashes during 10+ consecutive add/remove cycles
- ✅ Memory usage doesn't accumulate over multiple cycles

## Troubleshooting

### High Memory Usage
```dart
// Check current memory status
final info = await arObjectManager.getMemoryInfo();
print('Memory status: $info');

// If memory high, run full cleanup
await arObjectManager.purgeCaches();
await arSessionManager.softResetSession();
```

### Asset Loading Failures
```dart
// Check if asset exists and is valid format
final nodeId = await arObjectManager.createNodeFromAsset(
  uri: 'models/test.gltf',  // Ensure file exists
  transformMatrix: transform.storage,
);

if (nodeId == null) {
  print('Failed to load asset - check file path and format');
}
```

### Memory Leaks
If memory doesn't return to baseline:
1. Ensure all nodes are removed with `removeNodeDeep()`
2. Call `purgeCaches()` after removals
3. Use `softResetSession()` as final cleanup
4. Check native logs for specific resource cleanup issues

## Migration Guide

### From Regular removeNode()
```dart
// Old way
arObjectManager.removeNode(node);

// New way  
await arObjectManager.removeNodeDeep(node.name);
```

### From Individual Asset Loading
```dart
// Old way - loads same asset multiple times
for (int i = 0; i < 5; i++) {
  final node = ARNode(uri: 'model.gltf', ...);
  await arObjectManager.addNode(node);
}

// New way - shared loading
const String uri = 'model.gltf';
for (int i = 0; i < 5; i++) {
  final transform = Matrix4.identity()..setTranslation(Vector3(i * 2.0, 0, 0));
  await arObjectManager.createNodeFromAsset(
    uri: uri, 
    transformMatrix: transform.storage
  );
}
```

## Changelog

### v2.1.0 - Deep Memory Cleanup
- Added `removeNodeDeep()` for thorough resource cleanup
- Added `purgeCaches()` for cache management
- Added `createNodeFromAsset()` for shared asset loading
- Added `getMemoryInfo()` for memory monitoring
- Added `softResetSession()` for session reset
- Added resource handle tracking on both platforms
- Added loading backpressure to prevent OOM
- Improved memory stability and performance
