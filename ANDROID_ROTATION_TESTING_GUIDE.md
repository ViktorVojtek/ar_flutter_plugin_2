# Android Rotation Z-Jump Fix - Testing & Verification Guide

## Quick Summary of Fix
**Problem**: Objects jump up (change Z position) when rotated  
**Root Cause**: AnchorNode rotation caused child ModelNode to orbit around anchor origin  
**Solution**: Moved rotation responsibility from AnchorNode to ModelNode  
**Files Changed**: `ArCoreCompatView.kt` (3 locations + logging)

---

## Testing Procedure

### Prerequisites
- Android device with ARCore support
- Flutter app with rotation gestures enabled
- Logcat filtered to `SceneViewCompat` tag
- Objects placed at various heights (floor, table, TV stand, etc.)

### Test 1: Basic Rotation at Floor Level
**Expected**: Object stays at same Z position while rotating

1. Place object on floor
2. Enable rotation gestures (`enableRotationGestures: true`)
3. Perform 2-finger rotation gesture
4. **Verify**: Y coordinate in logs stays constant

**Log output should show**:
```
🔄 onRotateBegin for node: object_1, isRotationEditable: true, worldPos=(1.500, 0.000, 2.300)
🔄 onRotate: worldPos=(1.500, 0.000, 2.300)
🔄 onRotate: worldPos=(1.502, 0.000, 2.298)  ← Small changes OK, no Y change
🔄 onRotate: worldPos=(1.505, 0.000, 2.295)
🔄 onRotateEnd for node: object_1, finalPos=(1.505, 0.000, 2.295)
```

**✅ PASS**: Y coordinate (height) never changes  
**❌ FAIL**: Y coordinate changes significantly (e.g., 0.000 → 0.200)

---

### Test 2: Rotation at Table Height
**Expected**: Object stays at table height, no jumping to different elevation

1. Place object on virtual table (Y=0.8m)
2. Rotate object 360 degrees
3. **Verify**: 
   - Y position stays at ~0.8 throughout
   - No sudden jumps to 0.0 or 1.5m
   - Final position same as start position

**Sample expected output**:
```
🔄 onRotateBegin... worldPos=(0.500, 0.800, 0.300)
🔄 onRotate: worldPos=(0.520, 0.800, 0.310)  ← Y stable
🔄 onRotate: worldPos=(0.480, 0.800, 0.350)  ← Y stable
🔄 onRotateEnd... finalPos=(0.495, 0.800, 0.305)  ← Back to ~same height
```

**✅ PASS**: Always at Y=0.800  
**❌ FAIL**: Y changes to different values (0.9, 0.7, 0.5, etc.)

---

### Test 3: Pan + Rotate Combination
**Expected**: Can pan, then rotate (and vice versa) without interaction

1. Place object on floor
2. Pan object to new location
3. Rotate object
4. Pan object again
5. Verify: Both gestures work smoothly without conflicts

**Log check**:
```
🔥 Pan started - Y=0.000...
🎯 Hit-test pan → World Pos: (2.000, 0.000, 1.000)
✅ Created new anchor at (2.000, 0.000, 1.000)
🔄 onRotateBegin... worldPos=(2.000, 0.000, 1.000)  ← Rotate works after pan
🔄 onRotate: worldPos=(2.010, 0.000, 1.005)
🔄 onRotateEnd... finalPos=(2.010, 0.000, 1.005)
🔥 Pan started - Y=0.000...  ← Pan works after rotate
```

**✅ PASS**: Both gestures work, no Y jumps  
**❌ FAIL**: Y changes during rotation, or gestures interfere

---

### Test 4: Multiple Objects
**Expected**: Each object maintains its height when rotated independently

1. Place 3 objects at different heights (Y=0.0, 0.5, 1.5)
2. Rotate object 1 (at Y=0.0)
3. Check logs: Y stays at 0.0
4. Rotate object 2 (at Y=0.5)
5. Check logs: Y stays at 0.5
6. Rotate object 3 (at Y=1.5)
7. Check logs: Y stays at 1.5

**Sample output**:
```
🔄 onRotateBegin for node: obj_floor, worldPos=(1.0, 0.0, 0.0)
🔄 onRotate: worldPos=(1.01, 0.0, 0.01)
🔄 onRotateEnd... finalPos=(1.01, 0.0, 0.02)

🔄 onRotateBegin for node: obj_table, worldPos=(2.0, 0.5, 0.0)
🔄 onRotate: worldPos=(2.01, 0.5, 0.01)
🔄 onRotateEnd... finalPos=(2.01, 0.5, 0.02)

🔄 onRotateBegin for node: obj_high, worldPos=(0.0, 1.5, 0.0)
🔄 onRotate: worldPos=(0.01, 1.5, 0.01)
🔄 onRotateEnd... finalPos=(0.01, 1.5, 0.02)
```

**✅ PASS**: Each object maintains its Y position  
**❌ FAIL**: Objects jump to same height or different heights

---

### Test 5: Edge Cases

#### 5a: Fast Rotation
1. Quickly do 2-finger rotation gesture (fast movement)
2. Verify: Y position doesn't jump suddenly

#### 5b: Slow Rotation  
1. Do slow, deliberate 2-finger rotation
2. Verify: Smooth motion, stable height

#### 5c: Rotation Near Boundaries
1. Place object near room edge
2. Rotate it
3. Verify: No unexpected Z changes

#### 5d: Very Close to Camera
1. Place object very close to camera
2. Rotate it
3. Verify: Works without artifacts

---

## Debug Logging Setup

### Enable Detailed Logging
Add this to your Flutter initialization:

```dart
import 'package:ar_flutter_plugin_2/ar_flutter_plugin_2.dart';

ARView(
  // ... other config ...
  onARViewCreated: (arViewId) {
    _arSessionManager = ARSessionManager(arViewId);
    // Logs will appear automatically
  },
)
```

### Monitor Logs
```bash
# Filter for our rotation logs
adb logcat | grep "🔄"

# Full view with context
adb logcat | grep "SceneViewCompat"

# Pipe to file for analysis
adb logcat | grep "SceneViewCompat" > rotation_test.log

# Watch real-time
adb logcat -s "SceneViewCompat"
```

---

## Success Criteria

| Criteria | Status | Evidence |
|----------|--------|----------|
| Y position stable during rotation | ✓/✗ | Logs show constant Y ± 0.01m |
| No orbit effect observed | ✓/✗ | Object rotates in place visually |
| Pan + rotate work independently | ✓/✗ | Can do both without conflicts |
| Multiple objects work correctly | ✓/✗ | Each maintains its height |
| No crashes or exceptions | ✓/✗ | Clean logcat output |
| Smooth gesture response | ✓/✗ | No stuttering or jitter |

---

## Regression Testing

### Before and After Comparison
Keep logs from before the fix and after. Compare:

```
BEFORE (Broken):
🔄 onRotateBegin... worldPos=(1.000, 0.000, 1.000)
🔄 onRotate: worldPos=(1.100, 0.500, 1.000)  ← Y JUMPED!
🔄 onRotateEnd... finalPos=(1.050, 0.200, 1.000)  ← Wrong height

AFTER (Fixed):
🔄 onRotateBegin... worldPos=(1.000, 0.000, 1.000)
🔄 onRotate: worldPos=(1.100, 0.000, 1.000)  ← Y STABLE
🔄 onRotateEnd... finalPos=(1.050, 0.000, 1.000)  ← Correct height
```

---

## Troubleshooting

### Issue: Y position still changes
**Check**:
1. Is `isRotationEditable` set to `false` on AnchorNode? (Line 694)
2. Is `isRotationEditable` set to `true` on ModelNode? (Line 733)
3. Are you testing with `enableRotationGestures: true`?

### Issue: Rotation not working at all
**Check**:
1. Is `enableRotation` true in node config?
2. Is `isEditable` true on ModelNode?
3. Are gesture callbacks being called? (Check logs)

### Issue: Objects orbit instead of rotating in place
**Cause**: Likely regression where AnchorNode has `isRotationEditable=true`
**Fix**: Verify lines 680-695 set it to `false`

### Issue: Pan and rotate conflict
**Cause**: Both handlers are active on same node
**Fix**: Check that pan is manual (line 181-240) and rotate is on ModelNode (line 733)

---

## Performance Considerations

- Logging adds ~2-5% CPU overhead per gesture
- Remove `🔄` logs from production builds to improve performance
- Monitor memory usage with multiple objects

---

## Next Steps After Passing Tests

1. ✅ Run full test suite
2. ✅ Test on multiple Android devices (API 24-35)
3. ✅ Test with different model formats (GLB, GLTF, FBX)
4. ✅ Test with complex scene hierarchies
5. ✅ Release to beta testers
6. ✅ Monitor crash reports and logs from production

---

## Contact & Support

If issues persist after verifying all tests pass:
1. Collect logs: `adb logcat -s "SceneViewCompat" > debug.log`
2. Record video of the behavior
3. Check `ANDROID_ROTATION_Z_JUMP_INVESTIGATION.md` for alternative solutions
4. Consider custom rotation handler (Option C in investigation doc)
