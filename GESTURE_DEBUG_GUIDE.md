# AR Gesture Control & Node Removal Fixes - Debugging Guide

## 🔍 **Issues Addressed**

### 1. **Intermittent Gesture Selection Problem**
- **Symptom**: "I could sometimes select and pan the right object, but sometimes it is being stuck on one object even I want to pan the other one"
- **Root Cause**: Node ID synchronization mismatch between Flutter tracking and Android `nodesMap`
- **Fix**: Enhanced logging and node ID validation

### 2. **Remove All Objects Bug**  
- **Symptom**: "When I have one object selected, and I try to remove this object all objects are being removed"
- **Root Cause**: Incorrect node tracking or Android-side removal affecting multiple nodes
- **Fix**: Enhanced removal logging and safety checks

## 🛠️ **Implemented Fixes**

### **Android Side Enhancements (`ArCoreCompatView.kt`)**

1. **Enhanced `handleRemoveNodeDeep()` Method**:
   ```kotlin
   // Added comprehensive logging
   Log.d(TAG, "🗑️ REMOVE NODE DEEP: Request to remove nodeId: $nodeId")
   Log.d(TAG, "🗑️ REMOVE NODE DEEP: Current nodesMap keys: ${nodesMap.keys}")
   
   // Enhanced cleanup sequence:
   // - Deselect from TransformationSystem first
   // - Disable TransformableNode properties
   // - Remove from scene graph  
   // - Remove associated anchor nodes
   // - Remove from tracking map
   ```

2. **Enhanced Gesture Control Methods**:
   ```kotlin
   // Added detailed node lookup logging
   Log.d(TAG, "🎯 ENABLE TRANSFORM: Available nodes: ${nodesMap.keys}")
   Log.d(TAG, "🎯 ENABLE TRANSFORM: Node type: ${node?.javaClass?.simpleName ?: "null"}")
   ```

### **Flutter Side Enhancements (`vd_app_ar_screen.dart`)**

1. **Enhanced `_enableTransformForNode()` Method**:
   ```dart
   // Added node ID validation
   if (!nodeCreationOrder.contains(nodeId)) {
     debugPrint('AR Screen: ⚠️ ENABLE TRANSFORM: Node $nodeId not found in nodeCreationOrder');
     // Try to recover from persistent models
     for (var model in _modelManager.getAllPersistentModels()) {
       if (model.activeNodeId == nodeId) {
         nodeCreationOrder.add(nodeId);
         break;
       }
     }
   }
   ```

2. **Enhanced `_removeSelectedModel()` Method**:
   ```dart
   // Added comprehensive removal tracking
   debugPrint('AR Screen: 🗑️ REMOVE: selectedNode: $selectedNode');
   debugPrint('AR Screen: 🗑️ REMOVE: Current nodeCreationOrder: $nodeCreationOrder');
   
   // Added before/after state logging
   List<String> originalNodeOrder = List.from(nodeCreationOrder);
   List<ARNode> originalNodes = List.from(nodes);
   // ... perform removal ...
   debugPrint('AR Screen: 🗑️ REMOVE: Before removal - nodes: ${originalNodes.length}');
   debugPrint('AR Screen: 🗑️ REMOVE: After removal - nodes: ${nodes.length}');
   ```

## 🧪 **Testing Instructions**

### **Test 1: Multi-Object Gesture Selection**

1. **Setup**: Place 2-3 objects in AR scene
2. **Test Steps**:
   ```
   a) Select object 1 → Pan it (should work)
   b) Select object 2 → Pan it (should move object 2, NOT object 1)
   c) Switch back to object 1 → Pan it (should work)
   d) Repeat switching between objects multiple times
   ```
3. **Watch Debug Logs**:
   ```
   🔵 ENABLE TRANSFORM: Starting for node: [specific_node_id]
   🔵 ENABLE TRANSFORM: Current nodeCreationOrder: [list_of_nodes]
   🎯 ENABLE TRANSFORM: Available nodes: [android_nodesMap_keys]
   ✅ ENABLE TRANSFORM: Native transform enable successful for node: [node_id]
   ```

### **Test 2: Single Object Removal**

1. **Setup**: Place 3 objects in AR scene
2. **Test Steps**:
   ```
   a) Select object 2 (middle object)
   b) Tap delete button
   c) Verify only object 2 is removed
   d) Verify objects 1 and 3 remain in scene
   e) Verify nodeCreationOrder shows correct remaining nodes
   ```
3. **Watch Debug Logs**:
   ```
   🗑️ REMOVE: selectedNode: [node_id_being_removed]
   🗑️ REMOVE: Before removal - nodes: 3, order: 3
   🗑️ REMOVE: After removal - nodes: 2, order: 2
   🗑️ REMOVE: Final nodeCreationOrder: [remaining_nodes]
   ```

### **Debug Log Categories**

- **🔵 ENABLE TRANSFORM**: Node gesture enablement process
- **🔴 DISABLE TRANSFORM**: Node gesture disablement process  
- **🗑️ REMOVE**: Object removal process
- **🎯 ANDROID GESTURE**: Android-side gesture control
- **⚠️ WARNING**: Potential issues (node ID mismatches, etc.)
- **❌ ERROR**: Critical failures
- **✅ SUCCESS**: Successful operations

## 🔧 **Key Debugging Points**

### **Node ID Synchronization Issues**

**Look for these warning patterns**:
```
⚠️ ENABLE TRANSFORM: Node [node_id] not found in nodeCreationOrder
⚠️ ENABLE TRANSFORM: This could indicate nodeId mismatch between Flutter and Android
🎯 ENABLE TRANSFORM: Available nodes: [android_keys_vs_flutter_tracking]
```

**If you see mismatches**:
1. Flutter tracks nodes in `nodeCreationOrder: [node1, node2, node3]`
2. Android tracks nodes in `nodesMap keys: [different_node_ids]`
3. The mismatch causes gesture calls to fail

### **Remove All Objects Bug**

**Look for these patterns**:
```
🗑️ REMOVE: selectedNode: node_A
🗑️ REMOVE: After removal - nodes: 0, order: 0  # Should be nodes: 2, order: 2
```

**If all objects are removed when removing one**:
1. Check if `selectedIndex` calculation is correct
2. Verify `nodeCreationOrder.indexOf(nodeIdToRemove)` returns expected index
3. Check if Android-side `removeNodeDeep` is affecting multiple nodes

## 📱 **Testing Commands**

Run these in terminal to see live debug output:
```bash
# Flutter logs (verbose)
cd /Users/viktorvojtek/Projects/ar_flutter_plugin_2/example_app
flutter run --verbose

# Android logs (filtered for AR)
adb logcat | grep -E "(AR_|ENABLE TRANSFORM|DISABLE TRANSFORM|REMOVE NODE)"
```

## ✅ **Success Criteria**

### **Gesture Selection Fix**:
- [ ] Object 1 selected → only Object 1 moves during gestures
- [ ] Object 2 selected → only Object 2 moves during gestures  
- [ ] No cross-object interference
- [ ] Debug logs show successful node ID matches between Flutter/Android

### **Single Object Removal Fix**:
- [ ] Select object A → delete → only object A removed
- [ ] Other objects remain in scene and functional
- [ ] `nodeCreationOrder` correctly updated to reflect remaining objects
- [ ] Debug logs show correct before/after node counts

---

**Status**: 🛠️ **Debug-Ready** - Enhanced logging implemented  
**Next Step**: 📱 **Live Testing** - Run app and monitor debug logs  
**Focus**: 🔍 **Node ID Synchronization** - Verify Flutter ↔ Android alignment
