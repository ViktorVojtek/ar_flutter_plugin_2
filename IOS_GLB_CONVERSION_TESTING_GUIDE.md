# iOS GLB Conversion Testing Guide

## Overview
This guide will help you test the new GLTFSceneKit-based GLB to USDZ conversion on your iPhone 13 Pro.

## Prerequisites
- ✅ iPhone 13 Pro with LiDAR
- ✅ iOS 14.0+ (RealityKit + depth occlusion support)
- ✅ GLTFSceneKit integrated via CocoaPods
- ✅ Build successful (31.1MB)

## Test Scenarios

### Test 1: Remote GLB Loading
**Goal:** Verify GLB downloads and converts successfully

**Test URL:**
```
https://storage.googleapis.com/room-bucket/laira-a6e5eaae-09d1-406d-896c-64117a20c10e.glb
```

**Expected Logs:**
```
🔵 Detected remote URL, will download
📥 Downloading remote GLTF/GLB: https://storage.googleapis.com/...
✅ Download complete: /var/mobile/.../laira-....glb
✅ Downloaded file size: XXXXX bytes
🔵 About to load GLB using GLTFSceneKit: laira-....glb
🔵 GLTFSceneSource created, loading SceneKit scene...
🔵 SceneKit scene loaded, exporting to USDZ...
✅ Export to USDZ successful
✅ GLTF/GLB converted and loaded successfully
```

**Success Criteria:**
- ✅ No "MDLErrorDomain error 0" message
- ✅ All log steps complete
- ✅ Model appears in AR scene
- ✅ Conversion completes in <10 seconds

**Failure Indicators:**
- ❌ "Failed to initialize GLTFSceneSource" error
- ❌ "Failed to load GLB as SceneKit scene" error
- ❌ "Failed to export SceneKit scene to USDZ" error
- ❌ App crashes during conversion

---

### Test 2: Depth Occlusion with Converted Model
**Goal:** Verify depth occlusion works with GLB-converted models

**Steps:**
1. Load the GLB model (Test 1)
2. Place model near real furniture/objects
3. Walk around the scene
4. Move hand/object between camera and virtual model

**Expected Behavior:**
- ✅ Virtual model partially hidden behind real objects
- ✅ Real objects appear "in front" of virtual model
- ✅ Occlusion updates smoothly (60 FPS)
- ✅ Depth edges look clean (no significant artifacts)

**Success Criteria:**
- ✅ Depth occlusion clearly visible
- ✅ Performance remains smooth
- ✅ No flickering or Z-fighting

---

### Test 3: Multiple GLB Models
**Goal:** Test memory management and performance with multiple conversions

**Steps:**
1. Load first GLB model
2. Load second GLB model (same or different URL)
3. Load third GLB model
4. Check memory usage and FPS

**Expected Behavior:**
- ✅ All models convert successfully
- ✅ Temporary USDZ files cleaned up after each conversion
- ✅ Memory usage stays reasonable (<500MB)
- ✅ Frame rate remains stable (>30 FPS)

**Success Criteria:**
- ✅ All 3 models visible simultaneously
- ✅ No memory leaks
- ✅ Conversion time consistent for each model

---

### Test 4: Error Handling
**Goal:** Verify graceful error handling for invalid GLB files

**Test Cases:**

#### 4a: Invalid URL
```
https://invalid-url.com/nonexistent.glb
```
**Expected:** Download error with clear message

#### 4b: Non-GLB File (e.g., HTML file)
```
https://example.com/index.html
```
**Expected:** GLTFSceneSource initialization error

#### 4c: Corrupted GLB
Upload a text file renamed as .glb
**Expected:** SceneKit scene loading error

**Success Criteria:**
- ✅ App doesn't crash
- ✅ Error messages clear and informative
- ✅ Flutter channel receives FlutterError
- ✅ User sees error message

---

### Test 5: Large GLB Performance
**Goal:** Test conversion performance with large files

**Test File Sizes:**
- Small: <5MB
- Medium: 5-20MB
- Large: 20-100MB

**Measure:**
- Download time
- Conversion time (GLB → SceneKit → USDZ)
- USDZ loading time
- Total time to display

**Success Criteria:**
- ✅ Small: <3 seconds total
- ✅ Medium: <10 seconds total
- ✅ Large: <30 seconds total
- ✅ No timeout errors
- ✅ Progress visible (download indicator)

---

## Debugging Commands

### View Xcode Console Logs
```bash
# Run app from Xcode with device connected
# View console output in bottom panel
# Filter logs with: 🔵 ✅ ❌
```

### Check Temporary File Cleanup
```swift
// Add this log to verify cleanup:
let tempDir = FileManager.default.temporaryDirectory
let tempFiles = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
print("🗑️ Temp files: \(tempFiles?.count ?? 0)")
```

### Measure Conversion Time
```swift
// Already logged with emoji markers:
// 🔵 = Start step
// ✅ = Complete step
// Check time delta between logs
```

---

## Common Issues & Solutions

### Issue: "No such module 'GLTFSceneKit'"
**Solution:** Run `pod install` in `example_app/ios/` directory
```bash
cd example_app/ios && pod install
```

### Issue: "Download failed"
**Solution:** 
- Check internet connection
- Verify URL is valid
- Check firewall/proxy settings

### Issue: Conversion takes >30 seconds
**Solution:**
- Check GLB file size (may be too large)
- Check device available storage
- Try simpler GLB file

### Issue: Model appears but depth occlusion doesn't work
**Solution:**
- Verify LiDAR is working: `arView.session.currentFrame?.sceneDepth != nil`
- Check depth is enabled: `arView.environment.sceneUnderstanding.options.contains(.occlusion)`
- Ensure good lighting conditions

### Issue: Memory warning or crash
**Solution:**
- Limit number of simultaneous models
- Reduce GLB file size
- Implement model caching/unloading

---

## Performance Benchmarks

### Expected Performance on iPhone 13 Pro:

| Metric | Small GLB | Medium GLB | Large GLB |
|--------|-----------|------------|-----------|
| **Download** | 0.5-2s | 2-5s | 5-15s |
| **GLTFSceneSource** | 0.2-0.5s | 0.5-2s | 2-5s |
| **SceneKit Load** | 0.1-0.3s | 0.5-1s | 1-3s |
| **USDZ Export** | 0.2-0.5s | 0.5-2s | 2-5s |
| **RealityKit Load** | 0.1-0.3s | 0.3-1s | 1-3s |
| **Total Time** | 1-3s | 4-11s | 11-31s |

### Memory Usage:
- **Small GLB:** +20-50MB
- **Medium GLB:** +50-150MB
- **Large GLB:** +150-400MB

---

## Success Checklist

After testing, verify:

- [ ] Remote GLB URL downloads successfully
- [ ] GLTFSceneSource loads GLB without errors
- [ ] SceneKit scene exports to USDZ
- [ ] RealityKit loads USDZ entity
- [ ] Model appears in AR scene
- [ ] Depth occlusion works correctly
- [ ] No "MDLErrorDomain error 0" messages
- [ ] Temporary files cleaned up
- [ ] Memory usage reasonable
- [ ] Frame rate stable (>30 FPS)
- [ ] Multiple models load sequentially
- [ ] Error handling works for invalid files
- [ ] Large files complete in <30 seconds

---

## Reporting Results

### If Successful:
1. Note conversion time for test GLB
2. Capture video of depth occlusion working
3. Report memory usage and FPS
4. Mark implementation as **READY FOR PRODUCTION**

### If Failed:
1. Copy full error message from logs
2. Note which step failed (download, parse, convert, load)
3. Check Xcode console for stack trace
4. Report GLB file URL and size
5. Include device model and iOS version

---

## Next Steps After Testing

### If All Tests Pass:
1. **Update README** with GLB support information
2. **Add caching** for converted USDZ files
3. **Add progress callbacks** for long conversions
4. **Implement preloading** for common models
5. **Add model preview** before placing in AR

### If Tests Fail:
1. Check GLTFSceneKit version compatibility
2. Try different GLB files (simpler structure)
3. Check for GLTF extension compatibility
4. Consider fallback to Reality Converter pre-conversion

---

## Contact & Support

**GLTFSceneKit Issues:**
https://github.com/magicien/GLTFSceneKit/issues

**Plugin Issues:**
Create issue with logs and GLB file details

**Testing Device:**
iPhone 13 Pro, iOS 14.0+, LiDAR enabled
