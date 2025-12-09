# Android Rotation Z-Jump Fix - Visual Diagrams

## Problem Visualization

### Scenario: Object at table height (Y=0.8m)

#### What Users Were Seeing ❌

```
Side View:
                                    
Camera                              Frame 3:
  |---                              Object jumped up!
  |   \                             at Y=1.0m ↑
  |    \                            
  |     \      Frame 1:             Frame 2:
  |      \     Object at            Object orbited
  |       \    Y=0.0m (floor)        up to Y=0.5m
  |        \   ◻️                    ◻️
  |_________|_____________          
           Floor         Table
           (0m)          (0.8m)


What was happening:
  User rotates → AnchorNode rotates → ModelNode orbits origin
  Result: Height changes from 0.8 → 0.9 → 0.7 → 0.8...
  Looks like: Object "bouncing" or "hitting" something above
```

### Technical Diagram of the Problem

```
BEFORE FIX (Broken):

AnchorNode at (0, 0, 0)
  ↓
  └─ ModelNode at offset (0.5, 0.1, 0.3)
     ↓
     └─ Model geometry (cube/GLB)

When AnchorNode rotates 45°:
  Rotation matrix applied to AnchorNode
  └─ ModelNode must follow parent's transform
  └─ Applies circular translation motion
  └─ Net result: ModelNode moves in orbit around (0,0,0)
  └─ Y-coordinate increases as it orbits upward
  └─ Visual: Object appears to "jump up"

Analogy: Like a satellite orbiting Earth - as it rotates,
         its altitude changes if the origin isn't at its center!
```

---

## Solution Visualization

### The Fix ✅

```
AFTER FIX (Correct):

AnchorNode at (0, 0, 0)  [No rotation, only translation]
  ↓
  └─ ModelNode at offset (0.5, 0.1, 0.3)  [Handles rotation]
     ↓
     └─ Model geometry (cube/GLB)

When user rotates:
  Rotation matrix applied directly to ModelNode
  └─ ModelNode rotates around its own center
  └─ Center stays at (0.5, 0.1, 0.3)
  └─ Geometry spins around that center point
  └─ No orbital motion
  └─ Y-coordinate stays constant at 0.1
  └─ Visual: Object rotates smoothly in place

Analogy: Like a dancer spinning in place, not orbiting around
         a point far away. Only the orientation changes, not position!
```

---

## Hierarchy Comparison

### Before Fix ❌
```
Touch Input (2-finger rotation gesture)
    ↓
SceneView Gesture Detector
    ↓
AnchorNode.isRotationEditable = true  ← PROBLEM!
    ↓
Rotation applied to parent
    ↓
    └─ ModelNode (child) must follow
       └─ Inherits parent's rotation
       └─ At offset position → orbits parent origin
       └─ Height changes!  ← Z-JUMP OCCURS HERE
```

### After Fix ✅
```
Touch Input (2-finger rotation gesture)
    ↓
SceneView Gesture Detector
    ↓
AnchorNode.isRotationEditable = false  ← FIXED!
    ↓
ModelNode.isRotationEditable = true  ← NOW HANDLES IT
    ↓
Rotation applied to child
    ↓
    └─ ModelNode rotates around its own center
       └─ Position offset from parent doesn't matter
       └─ Height stays constant  ← NO Z-JUMP!
```

---

## Position Tracking During Rotation

### Before Fix (Broken) ❌

```
Timeline of Model Y-Position During 360° Rotation:

Y
^
|     
1.2 |     ╱╲╱╲╱╲   ← Oscillates!
|    ╱  ╲╱  ╲╱  ╲
1.0 |  ╱      ╲
|  ╱          ╲
0.8 |╱____________╲
|
0.6 |
|
0.4 |
|
0.2 |
|
0.0 |__________________|_____→ Time
    Start    90°   180°   270°  360°
    (Jump!)

Notice: Y bounces up and down!
        Object appears to "jump" at around 90° and 270°
```

### After Fix (Correct) ✅

```
Timeline of Model Y-Position During 360° Rotation:

Y
^
|
0.8 |═══════════════════════════════════════
|
0.7 |
|
0.6 |
|
0.5 |
|
0.4 |
|
0.3 |
|
0.2 |
|
0.1 |
|
0.0 |__________________|_____→ Time
    Start    90°   180°   270°  360°
    (Stable!)

Notice: Y stays constant at 0.8m!
        Object rotates smoothly without height change
```

---

## Code Change Visualization

### Configuration Change Summary

```
NODE CONFIGURATION MATRIX:

                    BEFORE FIX      AFTER FIX
                    ──────────      ──────────
AnchorNode:
  isEditable              true          true      (no change)
  isPositionEditable      false         false     (no change)
  isRotationEditable      ✗ true        ✓ false   (CHANGED)
  
ModelNode (anchored):
  isEditable              true          true      (no change)
  isPositionEditable      false         false     (no change)
  isRotationEditable      ✗ false       ✓ true    (CHANGED)
  isScaleEditable         false         false     (no change)

ModelNode (standalone):
  isEditable              true          true      (no change)
  isPositionEditable      true          true      (no change)
  isRotationEditable      true          true      (no change - already correct)
  isScaleEditable         false         false     (no change)
```

---

## Gesture Flow Comparison

### Before Fix ❌
```
User's 2-finger rotation
    ↓
SceneView detects rotation gesture
    ↓
Finds AnchorNode (parent) with isRotationEditable=true
    ↓
Applies rotation transform to AnchorNode
    ↓
    └─ Matrix multiplication: AnchorNode.rotation = gesture.angle
    ↓
    └─ Child (ModelNode) inherits transform
    ↓
    └─ Offset position + parent rotation = orbital motion
    ↓
Result: Visual orbit causing Z-jump ❌
```

### After Fix ✅
```
User's 2-finger rotation
    ↓
SceneView detects rotation gesture
    ↓
Finds ModelNode (child) with isRotationEditable=true
    ↓
Applies rotation transform to ModelNode
    ↓
    └─ Matrix multiplication: ModelNode.rotation = gesture.angle
    ↓
    └─ Applied around ModelNode's center (0.5, 0.1, 0.3)
    ↓
    └─ No parent orbit, just child rotation
    ↓
Result: Smooth in-place rotation ✅
```

---

## Mathematical Explanation

### Rotation Matrix Application

#### Before Fix (Wrong) ❌
```
Final Position = AnchorNode.transform * ModelNode.localPosition
              = Rotation(angle) * (0.5, 0.1, 0.3)

When angle = 45°:
Rotation(45°) applied to offset (0.5, 0.1, 0.3)
Result: Circular arc motion around origin
        Produces new Y-coordinate != original 0.1

When angle = 90°:
Result: Different Y-coordinate again
        Y-position changes during rotation!
```

#### After Fix (Correct) ✅
```
Final Position = AnchorNode.position + ModelNode.transform
              = (0, 0, 0) + Identity * Rotation(angle) * geometry
              
Where Rotation(angle) is applied to geometry RELATIVE to ModelNode center

When angle = 45°:
Geometry rotates around ModelNode center (0.5, 0.1, 0.3)
Result: Local rotation, no position change
        Y-coordinate stays at 0.1

When angle = 90°:
Result: Still no position change
        Y-coordinate still at 0.1!
```

---

## Real-World Analogy

### Before Fix ❌ - "Satellite Orbiting Earth"
```
         ┌─────────────┐
         │   Earth     │ ← Rotation pivot point (0,0,0)
         │   (AnchorNode)
         └─────────────┘
              △
              │ Distance = 5000km
              │
         ┌─────────────────┐
         │    Satellite    │ ← ModelNode
         │  (ModelNode)    │
         └─────────────────┘

When Earth rotates:
- Satellite must orbit around it
- Altitude changes as it orbits
- Looks like "bouncing"
```

### After Fix ✅ - "Spinning Top"
```
         ╱─────────────╲
        │   Spinning   │ ← Rotates around own center
        │    Top       │
         ╲─────────────╱
                │
                │ Axis
                ↓
         ═════════════ ← Ground
         
When top spins:
- Rotates around its own center
- Height stays constant
- Looks like "smooth spinning"
```

---

## Step-by-Step Transformation

### Rotation Sequence Before Fix ❌

```
Step 1: Initial State
  AnchorNode at (0, 0, 0)
  ModelNode at (0.5, 0.1, 0.3) relative to anchor
  Absolute position: (0.5, 0.1, 0.3)

Step 2: User applies 45° rotation
  Rotation matrix is computed for gesture angle
  
Step 3: Apply to AnchorNode (WRONG!)
  AnchorNode rotates around its origin (0, 0, 0)
  
Step 4: ModelNode inherits rotation
  Must transform its offset (0.5, 0.1, 0.3)
  New position = Rotation(45°) × (0.5, 0.1, 0.3)
              = (0.35, 0.28, 0.21)  ← Y changed from 0.1 to 0.28!
  
Step 5: Repeat for 90°, 135°, 180°, etc.
  Y keeps changing: 0.1 → 0.28 → 0.35 → 0.28 → 0.1
  Visual: Bouncing up and down! ❌
```

### Rotation Sequence After Fix ✅

```
Step 1: Initial State
  AnchorNode at (0, 0, 0)
  ModelNode at (0.5, 0.1, 0.3) relative to anchor
  Absolute position: (0.5, 0.1, 0.3)

Step 2: User applies 45° rotation
  Rotation matrix is computed for gesture angle
  
Step 3: Apply to ModelNode directly (CORRECT!)
  ModelNode rotates around its own center
  ModelNode position STAYS at (0.5, 0.1, 0.3)
  
Step 4: Only geometry orientation changes
  ModelNode.position = (0.5, 0.1, 0.3)  ← UNCHANGED
  ModelNode.rotation = 45°
  Geometry (cube) spins at that location
  
Step 5: Repeat for 90°, 135°, 180°, etc.
  ModelNode.position = (0.5, 0.1, 0.3)  ← ALWAYS THE SAME
  Y stays constant at 0.1!
  Visual: Smooth spinning in place! ✅
```

---

## Summary Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    THE PROBLEM & FIX                        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  BEFORE (Broken):                                           │
│  ┌──────────────────┐        ┌──────────────────┐          │
│  │  AnchorNode      │        │  During Rotation │          │
│  │  (rotatable)     │        │  orbits around   │          │
│  │  at (0,0,0)      │──────→ │  origin!         │          │
│  └────────▲─────────┘        │  Y-position      │          │
│       ╱   │   ╲              │  changes!        │          │
│      ╱    │    ╲             │  ❌              │          │
│     │   ModelNode│            │                 │          │
│     │   (orbits) │            └──────────────────┘          │
│     │   at 0.5,  │                                          │
│     │   0.1,0.3  │                                          │
│      ╲    │    ╱                                            │
│       ╲   │   ╱                                             │
│        ╲  ▼  ╱                                              │
│         ◻️◻️◻️ (geometry)                                    │
│                                                              │
│  ──────────────────────────────────────────────────         │
│                                                              │
│  AFTER (Fixed):                                             │
│  ┌──────────────────┐        ┌──────────────────┐          │
│  │  AnchorNode      │        │  During Rotation │          │
│  │  (no rotation)   │        │  child rotates   │          │
│  │  at (0,0,0)      │        │  around its own  │          │
│  │  ═════════════   │        │  center!         │          │
│  │  │              │        │  Y-position      │          │
│  │  │              │        │  STAYS same!     │          │
│  │  ▼              │        │  ✅              │          │
│  │ ModelNode       │──────→ │                  │          │
│  │ (rotatable)     │        └──────────────────┘          │
│  │ at (0.5,0.1,0.3)│                                       │
│  │  ╱  │  ╲        │                                       │
│  │ ╱   │   ╲       │                                       │
│  │◻️RotatingGeom◻️  │                                       │
│  │ ╲   │   ╱       │                                       │
│  │  ╲  │  ╱        │                                       │
│  └──────────────────┘                                       │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## Key Insight

The key insight: **Rotation pivots matter!**

- **Rotate parent** (AnchorNode) → children orbit around parent's origin
- **Rotate child** (ModelNode) → child rotates around its own center

For objects with position offset from their parent, always rotate the child, not the parent!

This is similar to:
- Don't rotate a tree at its roots (trunk orbits)
- Rotate branches at their branch joints (natural rotation)

Same principle in 3D graphics! ✅
