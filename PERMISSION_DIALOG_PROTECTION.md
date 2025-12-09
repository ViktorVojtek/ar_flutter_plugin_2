# AR Session Permission Dialog Protection

## Problem

On Android, when a permission dialog (e.g., storage permission for screenshots) is shown:

1. The activity loses window focus (`onWindowFocusChanged hasWindowFocus false`)
2. Android may trigger lifecycle `ON_PAUSE` events
3. SceneView's ARSceneView interprets this as a signal to destroy the AR session
4. The AR session is completely destroyed (not just paused)
5. When the permission dialog closes, the AR session is gone
6. Result: **Permanent black screen** that never recovers

### Logs showing the problem:
```
DecorView onWindowFocusChanged hasWindowFocus false
I/native: Entering Session::Pause.
I/native: Deleting ArSession...
D/Sceneview: CameraStream destroyed
D/Sceneview: Engine destroyed
E/native: session was passed NULL
```

## Solution

The plugin now includes `PermissionAwareLifecycle`, a lifecycle wrapper that:

1. **Detects permission dialogs** - Uses heuristics to identify when a pause is caused by a permission dialog vs. real navigation
2. **Delays lifecycle events** - Holds off on propagating `ON_PAUSE`/`ON_STOP` during suspected permission dialogs
3. **Auto-recovers** - Cancels delayed events when the app regains focus
4. **Provides manual controls** - Flutter API for explicit protection when needed

## Usage

### Automatic Protection (Default)

The `PermissionAwareLifecycle` is automatically used on Android. It will detect most permission dialog scenarios and protect the session without any code changes.

### Explicit Protection (Recommended for reliability)

For guaranteed protection, wrap permission requests with the provided methods:

```dart
// Option 1: Use the convenience wrapper
await arSessionManager.withPermissionProtection(() async {
  final status = await Permission.storage.request();
  if (status.isGranted) {
    await saveScreenshot();
  }
});

// Option 2: Manual notification calls
await arSessionManager.notifyPermissionDialogShowing();
try {
  final status = await Permission.storage.request();
  // Handle permission result...
} finally {
  await arSessionManager.notifyPermissionDialogDismissed();
}
```

### Recovery from Black Screen

If the AR session is already showing a black screen (e.g., automatic detection failed):

```dart
// Force resume the AR session
await arSessionManager.forceResumeSession();
```

## API Reference

### `ARSessionManager` Methods

#### `notifyPermissionDialogShowing()`
Call BEFORE requesting any permission that will show a system dialog.

```dart
Future<bool> notifyPermissionDialogShowing()
```

#### `notifyPermissionDialogDismissed()`
Call AFTER the permission dialog is dismissed (granted or denied).

```dart
Future<bool> notifyPermissionDialogDismissed()
```

#### `forceResumeSession()`
Force resume the AR session after it may have been incorrectly paused.

```dart
Future<bool> forceResumeSession()
```

#### `withPermissionProtection<T>()`
Convenience wrapper that handles notifications automatically.

```dart
Future<T> withPermissionProtection<T>(Future<T> Function() action)
```

## Complete Example: Screenshot with Storage Permission

```dart
import 'package:permission_handler/permission_handler.dart';

Future<void> takeAndSaveScreenshot() async {
  // Protect the AR session during permission request
  await arSessionManager?.withPermissionProtection(() async {
    // Request storage permission
    final status = await Permission.storage.request();
    
    if (status.isGranted) {
      // Take screenshot (AR session is safe)
      final imageProvider = await arSessionManager?.snapshot();
      
      if (imageProvider != null) {
        // Save to gallery...
        await saveImageToGallery(imageProvider);
      }
    } else if (status.isPermanentlyDenied) {
      // Show settings dialog
      openAppSettings();
    }
  });
}
```

## Technical Details

### How Detection Works

The `PermissionAwareLifecycle` uses these heuristics to detect permission dialogs:

1. **Window focus loss** - Activity doesn't have window focus
2. **Not finishing** - `activity.isFinishing` is false
3. **Not configuration change** - `activity.isChangingConfigurations` is false

If all three conditions are met when `ON_PAUSE` is received, it's likely a permission dialog.

### Grace Period

- **Pause delay**: 1500ms - Time to wait before propagating `ON_PAUSE`
- **Stop delay**: 3000ms - Time to wait before propagating `ON_STOP`

These delays give the permission dialog time to be dismissed and the app to resume.

### Window Focus Listener

The lifecycle also monitors `ViewTreeObserver.OnWindowFocusChangeListener` to detect when the app regains focus, which cancels any pending lifecycle transitions.

## Troubleshooting

### AR session still destroyed

1. Ensure you're using the latest plugin version
2. Try explicit notification calls with `notifyPermissionDialogShowing()`/`notifyPermissionDialogDismissed()`
3. Call `forceResumeSession()` after the permission dialog

### Delayed black screen

If the AR session works briefly after permission dialog but then goes black:

1. The grace period may have expired - increase `PAUSE_GRACE_PERIOD_MS` in native code if needed
2. Another lifecycle event may have occurred - check logs for additional pause/stop events

### Debug Logging

The `PermissionAwareLifecycle` logs important events with the tag `PermissionAwareLifecycle`:

```
🔔 Permission dialog showing notification received
📢 Received lifecycle event: ON_PAUSE (permissionDialogActive=true)
⏸️ PAUSE detected - looks like permission dialog, delaying propagation
🪟 Window focus changed: hasFocus=true
✅ Window focus restored after permission dialog
```

Filter logs with: `adb logcat -s PermissionAwareLifecycle SceneViewCompat`
