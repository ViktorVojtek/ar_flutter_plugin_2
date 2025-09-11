# Node Restoration System Test Guide

## Overview
The AR plugin now includes a comprehensive node restoration system to prevent objects from disappearing during gesture operations and hierarchy corruption issues.

## Test Scenarios

### 1. Basic Multi-Object Test
1. Launch the example app
2. Add 2-3 objects to the AR scene
3. Try panning each object multiple times
4. Verify all objects remain visible and functional

### 2. Restoration Trigger Test
1. Add multiple objects to scene
2. Perform rapid gesture operations on different objects
3. Tap on empty areas between gestures
4. Check console logs for restoration messages:
   ```
   Restored node to scene: NodeName
   Node hierarchy verification complete
   ```

### 3. Hierarchy Corruption Recovery
1. Add 3+ objects with complex positioning
2. Perform pan, rotate, and scale gestures rapidly
3. Switch between objects frequently
4. Verify no objects disappear even during intensive operations

## Expected Behavior

### Successful Restoration
- Objects remain visible throughout all interactions
- Gesture functionality preserved across all objects
- Console shows proactive restoration when needed
- No "TransformableNode must have an AnchorNode as a parent" errors

### Key Improvements
1. **Proactive Detection**: System checks for disappeared nodes during every tap
2. **Proper Re-parenting**: Uses virtual anchors with correct hierarchy
3. **Scene Validation**: Recursive checking of node-scene relationships
4. **Safe Detachment**: Proper parent removal before re-attachment

## Debug Information
Monitor console for these restoration system messages:
- `"Checking for disappeared nodes..."`
- `"Found disappeared node: [NodeName]"`
- `"Successfully restored node to scene"`
- `"Node hierarchy verification complete"`

## Troubleshooting
If objects still disappear:
1. Check for `restoreDisappearedNodes()` calls in logs
2. Verify virtual anchor creation messages
3. Look for hierarchy validation errors
4. Test with single object first, then multiple

## Success Criteria
✅ All objects remain visible during gesture operations
✅ Pan functionality works for all objects, not just the first
✅ No hierarchy corruption errors in logs
✅ Restoration system activates when needed
✅ Gesture performance remains smooth
