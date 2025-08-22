# NUKE ALL - Complete Memory Teardown System

## Overview

The `nukeAll()` method provides deterministic full teardown of AR session, renderer, SwapChains/layers, loaders, caches, and singletons to return memory usage close to cold start levels. This is the strongest cleanup method available in the ar_flutter_plugin_2.

## When to Use

- After placing and removing heavy AR models when you want to reset memory to near cold start levels
- When you experience memory creep after multiple AR sessions
- Before transitioning between different AR scenes or modes
- When you need guaranteed memory cleanup (stronger than `softResetSession()`)

## How It Works

### Phase-Based Teardown

**Android (Kotlin):**
1. **Phase A:** Stop background loading tasks and await completion
2. **Phase B:** Clear all anchors, nodes, and collections
3. **Phase C:** Pause and close ARCore session
4. **Phase D:** Destroy scene content and resource handles
5. **Phase E:** Purge global asset caches and SceneView internal caches
6. **Phase F:** Clear tracking state and reset variables
7. **Phase G:** Force garbage collection
8. **Phase H:** Recreate executor for future operations

**iOS (Swift):**
1. **Phase A:** Stop background loading queue operations
2. **Phase B:** Clear anchors, nodes, and scene content
3. **Phase C:** Pause AR session and clear delegate
4. **Phase D:** Destroy resource handles, textures, materials, geometries
5. **Phase E:** Purge asset caches and renderer caches
6. **Phase F:** Clear gesture and interaction state
7. **Phase G:** Reset view configuration
8. **Phase H:** Force memory cleanup with autoreleasepool

### Memory Cleanup Targets

- **AR Session:** Complete pause and destruction of ARCore/ARKit session
- **Renderer:** SwapChain destruction (Android), CAMetalLayer cleanup (iOS)
- **GPU Resources:** Textures, materials, vertex/index buffers, renderables
- **Asset Caches:** Shared model loading cache, material cache, texture cache  
- **Resource Handles:** All tracked resource references and metadata
- **Background Tasks:** Loading queues, decode operations, async work
- **Singletons:** Engine references, renderer instances, scene objects

## API Usage

### Dart API

```dart
/// Performs a full native teardown of AR session, renderer, caches and GPU resources
Future<bool> nukeAll({
  bool purgeCaches = true,           // Clear all asset and material caches
  bool removeExistingAnchors = true, // Remove all anchors from session
  bool resetTracking = true,         // Reset AR tracking state
}) async
```

### Required Flutter Choreography

**⚠️ CRITICAL:** You must remove the AR PlatformView for at least one frame after calling `nukeAll()` to allow the OS to deallocate surfaces/layers.

```dart
// 1) Call native nuke
final ok = await sessionManager.nukeAll(purgeCaches: true);

if (ok) {
  // 2) Remove AR PlatformView for ≥1 frame
  setState(() => _shouldRenderARView = false);
  
  // 3) Wait for surface/layer deallocation
  await Future.delayed(const Duration(milliseconds: 50));   // Minimum
  await Future.delayed(const Duration(milliseconds: 300));  // Recommended
}

// 4) Recreate AR view when ready
setState(() => _shouldRenderARView = true);
```

### Why Surface Removal is Required

- **Android:** Surface destruction allows SwapChain and GPU contexts to be fully released
- **iOS:** CAMetalLayer and MTKView device references need OS-level cleanup
- **Both:** PlatformView removal ensures native view lifecycle methods are called

## Example Implementation

See `/examples/nuke_all_memory_reset.dart` for a complete working example showing:

- Loading heavy AR models to increase memory usage
- Deep cleanup removal of all objects
- Proper `nukeAll()` choreography with PlatformView removal
- Memory usage monitoring and verification

## Comparison with Other Cleanup Methods

| Method | Scope | Session | Renderer | GPU Resources | Caches | Use Case |
|--------|--------|---------|----------|---------------|---------|----------|
| `removeNode()` | Single node | ✗ | ✗ | Partial | ✗ | Remove one object |
| `removeNodeDeep()` | Single node | ✗ | ✗ | ✓ | ✗ | Deep cleanup one object |
| `purgeCaches()` | Caches only | ✗ | ✗ | ✗ | ✓ | Clear shared caches |
| `softResetSession()` | Session reset | ✓ | ✗ | ✗ | ✗ | Restart tracking |
| `nukeAll()` | **Everything** | ✓ | ✓ | ✓ | ✓ | **Full memory reset** |

## Memory Impact

**Expected Results:**
- After placing and removing heavy models, `nukeAll()` should bring RSS within ~5-15% of cold start
- Re-entering AR creates a fresh session with no cumulative memory creep
- No crashes across 10+ add/remove/nuke cycles

**Verification:**
```dart
// Check memory usage before/after
final memInfo = await arObjectManager.getMemoryInfo();
print('Loaded nodes: ${memInfo['nodeCount']}');
print('Resource handles: ${memInfo['resourceHandles']}');
print('Cache memory: ${memInfo['cacheMemoryMB']} MB');
```

## Platform-Specific Details

### Android Implementation

- Uses `ConcurrentHashMap` for thread-safe resource tracking
- Cancels `loadingExecutor` tasks and awaits completion
- Destroys Filament Engine components in proper order
- Calls `System.gc()` for immediate cleanup
- Recreates executor for future operations

### iOS Implementation  

- Uses `autoreleasepool` for deterministic cleanup
- Cancels `loadingQueue` operations safely
- Clears SceneKit materials and geometries recursively
- Runs CFRunLoop to drain autorelease pool
- Resets gesture recognition state

## Error Handling

All teardown phases are wrapped in `runCatching` (Kotlin) / `do-catch` (Swift) to prevent crashes:

- Individual phase failures are logged but don't stop teardown
- Method returns `false` if critical errors occur
- Partial cleanup is better than crash or memory leak
- Extensive logging helps with debugging

## Testing & Validation

### Manual Testing Recipe

1. Capture baseline RSS memory usage
2. Add 4 heavy GLB models (wait 500ms between each)
3. Remove all using `removeNodeDeep()`
4. Call `nukeAll()` + remove PlatformView for 1 frame  
5. Wait 500-800ms, record RSS → expect within ~5-15% of baseline
6. Recreate AR view, repeat cycle → no cumulative creep

### Debug State Inspection

```dart
// Optional debug method to check plugin state
final state = await getPluginState(); // Hypothetical debug API
print('Engine: ${state['engine']}');          // null after nuke
print('SwapChain: ${state['swapChain']}');    // null after nuke  
print('Handles: ${state['handlesCount']}');   // 0 after nuke
print('Caches: ${state['cacheSizes']}');      // empty after nuke
```

## Common Pitfalls

❌ **Don't do this:**
```dart
// Calling nukeAll() without removing PlatformView
await sessionManager.nukeAll();
// Surface/layer not deallocated → memory not fully reset
```

❌ **Don't do this:**
```dart
// Rebuilding AR view in same frame
setState(() => _shouldRenderARView = false);
setState(() => _shouldRenderARView = true); // Too fast!
```

✅ **Do this:**
```dart
// Proper choreography with timing
await sessionManager.nukeAll();
setState(() => _shouldRenderARView = false);
await Future.delayed(const Duration(milliseconds: 300));
setState(() => _shouldRenderARView = true);
```

## Integration with Existing Code

`nukeAll()` is designed to work alongside existing cleanup methods:

```dart
// Use together for comprehensive cleanup
await arObjectManager.removeNodeDeep(nodeId);  // Deep cleanup specific objects
await arObjectManager.purgeCaches();           // Clear shared caches  
await sessionManager.nukeAll();                // Nuclear option - full reset
```

## Performance Considerations

- **Startup Time:** After `nukeAll()`, AR view creation takes longer (fresh session)
- **Memory Trade-off:** Immediate memory cleanup vs. cache re-warming overhead
- **Background Work:** Loading queue operations are cancelled and must restart
- **Best Practice:** Use `nukeAll()` when transitioning between scenes, not frequently

## Supported Platforms

- ✅ **Android:** ARCore + Filament/SceneView
- ✅ **iOS:** ARKit + SceneKit  
- ❌ **Web:** Not applicable (no native session management)

## Changelog Integration

This feature addresses the most requested memory management issue:
- **[NEW]** Complete memory teardown with `sessionManager.nukeAll()`
- **[NEW]** Phase-based cleanup logging for debugging
- **[NEW]** Cross-platform implementation (Android + iOS)
- **[NEW]** Example app demonstrating proper usage pattern
