# Testing Guide for Filament Threading Fix

## What Was Fixed
Fixed critical Filament threading issue causing crashes with error:
```
E/Filament: reason: This thread has not been adopted.
F/libc: Fatal signal 6 (SIGABRT)
```

## Testing Steps

### 1. Clean Build
```bash
cd /Users/viktorvojtek/Projects/ar_flutter_plugin_2/example_app
flutter clean
cd android
./gradlew clean
cd ..
flutter pub get
```

### 2. Rebuild and Run
```bash
flutter run
```

### 3. Critical Test Cases

#### Test 1: Autoplacement Example (Previously Crashing)
1. Launch app
2. Navigate to **Autoplacement Example**
3. **Expected**: App should not crash
4. **Expected**: Camera view should load properly
5. **Expected**: Models should be visible (not black)

#### Test 2: Model Loading
1. In Autoplacement example, tap on a detected plane
2. **Expected**: Model loads and appears with proper materials/textures
3. **Expected**: No threading errors in logcat
4. **Expected**: Model renders in full color (not black)

#### Test 3: Gestures
1. Tap and hold on a placed model
2. Try rotating the model
3. Try moving/panning the model
4. **Expected**: All gestures work smoothly
5. **Expected**: No crashes or freezes

#### Test 4: Rapid Navigation
1. Navigate to Autoplacement
2. Quickly navigate back
3. Navigate to Autoplacement again
4. **Expected**: No crashes on rapid navigation
5. **Expected**: Resources clean up properly

#### Test 5: Multiple Models
1. Place multiple models in the scene
2. Interact with different models
3. **Expected**: All models render properly
4. **Expected**: No memory issues or crashes

### 4. Monitor Logcat

Watch for these previously problematic messages:

#### Before Fix (Should NOT see these anymore):
```
E/Filament: Precondition
E/Filament: reason: This thread has not been adopted.
F/libc: Fatal signal 6 (SIGABRT)
```

#### After Fix (Should see these):
```
I/SceneViewCompat: [Any normal operation logs]
D/BufferQueueConsumer: [Normal graphics logs]
I/native: [ARCore normal logs]
```

### 5. Check for Memory Leaks
```bash
# Monitor memory usage
adb shell dumpsys meminfo com.example.example_app

# Watch for growing memory during repeated operations
```

## Expected Behaviors After Fix

### ✅ What Should Work Now
- [x] App launches without crashes
- [x] Autoplacement example loads successfully
- [x] Models render with proper materials/textures (not black)
- [x] Rotation gestures work
- [x] Pan gestures work (if enabled)
- [x] Environment lighting is applied
- [x] Clean disposal when navigating away
- [x] No Filament threading errors

### ⚠️ Known Remaining Issues
The fix addresses **threading issues only**. The following were mentioned in your initial description and may still need attention:

1. **Black models** - Should be fixed by proper environment loading
2. **Panning gesture** - Should work now with proper thread safety
3. **Material/texture loading** - Should be fixed by thread-safe model loading

## If Issues Persist

### Check Logcat For:
```bash
adb logcat | grep -E "(Filament|SceneViewCompat|FATAL)"
```

### Common Issues and Solutions

#### Models Still Black
- Check that HDR environment file exists: `android/src/main/assets/environments/evening_meadow_2k.hdr`
- Verify model files have embedded materials
- Check logcat for environment loading errors

#### Gestures Not Working
- Verify `isTransformable`, `enablePanGestures`, `enableRotationGestures` are set correctly in Dart code
- Check that models are being made editable

#### App Still Crashes
- Get full crash stack trace: `adb logcat *:E`
- Check for other threading issues in custom code
- Verify SceneView version compatibility

## Success Criteria
The fix is successful if:
1. ✅ No Filament "thread has not been adopted" errors
2. ✅ Autoplacement example loads without crashing
3. ✅ Models render with proper appearance
4. ✅ Gestures work smoothly
5. ✅ No memory leaks or resource issues

## Reporting Issues
If problems persist, collect:
1. Full logcat output: `adb logcat > crash.log`
2. Steps to reproduce
3. Device model and Android version
4. Screenshot of the issue (if visual)
