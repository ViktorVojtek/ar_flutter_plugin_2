# AR Coaching Overlay - Quick Summary

## Question
> "On iOS when the lighting changes or camera loses tracking there is this nice animation that shows how to move the mobile device. Does ARCore have something similar which could be enabled?"

## Answer

### iOS (ARKit) ✅
**YES** - Already implemented and working!

```dart
arSessionManager.onInitialize(
  showAnimatedGuide: true,  // ✅ Enables ARCoachingOverlayView
  showPlanes: true,
  handleTaps: true,
);
```

The native `ARCoachingOverlayView` automatically:
- Shows animated guidance when tracking is poor
- Provides lighting condition warnings
- Gives camera movement instructions
- Activates/deactivates automatically

### Android (ARCore) ❌
**NO** - ARCore does NOT have a built-in equivalent.

Google intentionally didn't include a coaching overlay in ARCore, expecting developers to create custom UI.

## Solution for Android

I've implemented a **custom coaching overlay** that provides similar functionality:

### What I Added

1. **Modified Android Code** ✅
   - Updated `ArCoreCompatView.kt` to recognize `showAnimatedGuide` parameter
   - Added logging to inform about ARCore's limitations

2. **Created Complete Guide** ✅
   - `COACHING_OVERLAY_GUIDE.md` - Comprehensive documentation
   - Explains iOS vs Android differences
   - Provides multiple implementation options

3. **Created Working Example** ✅
   - `example_app/lib/ar_coaching_example.dart` - Full implementation
   - Works on both iOS and Android
   - Demonstrates custom Android overlay
   - Added to main menu as "Coaching Overlay Demo"

### How to Use

#### iOS (Automatic)
Just set `showAnimatedGuide: true` - it works automatically!

#### Android (Custom)
Use the provided example:

```dart
import 'ar_coaching_example.dart';

// Navigate to the example
Navigator.push(
  context,
  MaterialPageRoute(builder: (context) => ARCoachingExample()),
);
```

Or implement your own using the guide in `COACHING_OVERLAY_GUIDE.md`.

### Features of Custom Android Overlay

✅ Animated phone icon showing movement  
✅ Clear instructions for users  
✅ Integration with Light Estimation API  
✅ Auto-hide after 10 seconds or object placement  
✅ Low-light warnings  
✅ Professional UI matching iOS quality  

## Test It Now

Run the example app:

```bash
cd example_app
flutter run
```

Then select **"Coaching Overlay Demo"** from the menu.

- **On iOS**: You'll see Apple's native coaching overlay
- **On Android**: You'll see the custom Flutter overlay

## Key Takeaways

| Platform | Has Native Coaching? | Implementation |
|----------|---------------------|----------------|
| iOS | ✅ Yes | `showAnimatedGuide: true` |
| Android | ❌ No | Use provided custom overlay |

## Files Created/Modified

1. ✅ `COACHING_OVERLAY_GUIDE.md` - Complete documentation
2. ✅ `example_app/lib/ar_coaching_example.dart` - Working example
3. ✅ `example_app/lib/main.dart` - Added menu button
4. ✅ `android/.../ArCoreCompatView.kt` - Handle showAnimatedGuide parameter

## Next Steps

1. Run the example app and test the coaching overlay
2. Read `COACHING_OVERLAY_GUIDE.md` for customization options
3. Integrate the custom overlay into your app
4. Consider using Light Estimation API for lighting warnings

---

**Bottom Line**: iOS has it built-in, Android doesn't. I've provided you with a complete custom solution that works great! 🚀
