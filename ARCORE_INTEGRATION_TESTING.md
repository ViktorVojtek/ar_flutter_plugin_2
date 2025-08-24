# ARCore Integration Testing Guide

## 🧪 Testing Strategy

### Phase 1: Build & Import Resolution
```bash
# Navigate to example app
cd example_app

# Clean build
flutter clean
flutter pub get

# Build Android to check imports
flutter build apk --debug
```

**Expected Outcome**: Clean build without import errors in ArView.kt

### Phase 2: Basic Gesture Testing

#### Test Case 1: ARCore Gesture Node
```dart
// Add to your test/demo code
final arcoreNode = ARNode(
  type: NodeType.localGLTF2, 
  uri: 'models/test_model.gltf',
  name: 'ARCoreGestureTest',
  isTransformable: true,          // KEY: Enable ARCore gestures
  enablePanGestures: true,
  enableRotationGestures: true,
  position: Vector3(0, 0, -1),
);

// Set up callback to verify gesture events
arObjectManager.onNodeTransformed = (String nodeName) {
  print('✅ ARCore gesture detected on node: $nodeName');
};

// Add node
await arObjectManager.addNode(arcoreNode);
```

**Expected Behavior**: 
- Node uses GestureTransformableNode internally
- Pan and rotation gestures work smoothly
- Callback fires when node is transformed

#### Test Case 2: Legacy Compatibility
```dart
// Test existing nodes still work
final legacyNode = ARNode(
  type: NodeType.localGLTF2,
  uri: 'models/test_model.gltf', 
  name: 'LegacyGestureTest',
  // isTransformable defaults to false - uses SceneView gestures
  position: Vector3(1, 0, -1),
);

await arObjectManager.addNode(legacyNode);
```

**Expected Behavior**:
- Node uses regular ModelNode with SceneView gestures
- Existing gesture behavior unchanged
- No ARCore callback events

### Phase 3: Memory Management Verification

#### Test Case 3: Resource Cleanup
```dart
// Add multiple ARCore nodes
final nodes = <ARNode>[];
for (int i = 0; i < 5; i++) {
  final node = ARNode(
    type: NodeType.localGLTF2,
    uri: 'models/test_model.gltf',
    name: 'ARCoreNode_$i',
    isTransformable: true,
    enablePanGestures: true,
    enableRotationGestures: true,
    position: Vector3(i * 0.5, 0, -1),
  );
  nodes.add(node);
  await arObjectManager.addNode(node);
}

// Test deep cleanup
for (final node in nodes) {
  final success = await arObjectManager.removeNodeDeep(node.name);
  print('Node ${node.name} cleanup: ${success ? "✅" : "❌"}');
}
```

**Expected Behavior**:
- All nodes added successfully using GestureTransformableNode
- Deep cleanup removes all resources properly
- Memory usage returns to baseline

### Phase 4: Gesture Comparison Testing

#### Test Case 4: Side-by-Side Comparison
```dart
// Place two identical models side by side
final sceneViewNode = ARNode(
  type: NodeType.localGLTF2,
  uri: 'models/test_model.gltf',
  name: 'SceneViewGestures',
  isTransformable: false,  // Uses SceneView gestures
  position: Vector3(-0.5, 0, -1),
);

final arcoreNode = ARNode(
  type: NodeType.localGLTF2,
  uri: 'models/test_model.gltf', 
  name: 'ARCoreGestures',
  isTransformable: true,   // Uses ARCore gestures
  enablePanGestures: true,
  enableRotationGestures: true,
  position: Vector3(0.5, 0, -1),
);

await arObjectManager.addNode(sceneViewNode);
await arObjectManager.addNode(arcoreNode);
```

**Expected Comparison**:
- SceneView node: May have pan/rotation issues (original problem)
- ARCore node: Smooth, responsive gestures

## 🔍 Debug Logging

### Key Log Messages to Watch

#### Successful ARCore Integration
```
🎯 ARCore gesture properties - isTransformable: true, pan: true, rotation: true
🎯 Creating GestureTransformableNode for ARCore gestures
✅ GestureTransformableNode initialized with ARCore TransformationSystem
```

#### Backward Compatibility  
```
🎯 ARCore gesture properties - isTransformable: false, pan: false, rotation: false
🎯 Creating regular ModelNode with SceneView gestures
```

#### Gesture Events
```
🎯 GestureTransformableNode: Pan gesture detected
🎯 GestureTransformableNode: Rotation gesture detected  
onNodeTransformed callback: NodeName
```

## 🐛 Troubleshooting

### Issue: Import Errors
**Symptoms**: Build fails with unresolved reference to GestureTransformableNode
**Solution**: 
1. Check file exists: `android/src/main/kotlin/com/uhg0/ar_flutter_plugin_2/models/GestureTransformableNode.kt`
2. Verify import statement in ArView.kt
3. Clean and rebuild project

### Issue: Gestures Not Working
**Symptoms**: ARCore nodes don't respond to touch
**Check**: 
1. Verify `isTransformable: true` is set
2. Check logs for GestureTransformableNode creation
3. Ensure TransformationSystem is properly initialized

### Issue: Callback Not Firing  
**Symptoms**: onNodeTransformed never called
**Check**:
1. Verify callback is set before adding nodes
2. Check Flutter-Android method channel communication
3. Look for objectChannel.invokeMethod calls in logs

## 📊 Success Criteria

### ✅ Integration Success Indicators
- [ ] Clean build without errors
- [ ] ARCore nodes create GestureTransformableNode instances  
- [ ] Legacy nodes continue using regular ModelNode
- [ ] Pan/rotation gestures work smoothly on ARCore nodes
- [ ] onNodeTransformed callback fires correctly
- [ ] Memory cleanup works for both node types
- [ ] No breaking changes to existing API

### ⚠️ Known Limitations
- `createNodeFromAsset()` doesn't yet support gesture properties
- iOS implementation not included (Android-only integration)
- Requires ARCore-compatible device for testing

## 🚀 Next Testing Phase

After successful basic testing:
1. Performance testing with multiple ARCore nodes
2. Complex gesture interaction patterns
3. Integration with anchor systems
4. Cloud anchor compatibility
5. Extended memory stress testing

**Testing Priority**: Focus on gesture responsiveness comparison - this was the original problem that prompted the integration.
