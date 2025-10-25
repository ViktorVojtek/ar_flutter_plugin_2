# Light Estimation Implementation Guide

## Overview

The AR Flutter Plugin now includes comprehensive light estimation capabilities for both **ARCore (Android)** and **ARKit (iOS)**. This feature allows your AR applications to detect and respond to ambient lighting conditions, enhancing user experience by warning users when lighting is insufficient for optimal AR tracking.

## Features

✅ **Real-time Light Monitoring** - Continuous lighting condition tracking  
✅ **On-Demand Queries** - Get current light estimates instantly  
✅ **Low-Light Detection** - Automatic threshold-based warnings  
✅ **Cross-Platform** - Consistent API for both Android and iOS  
✅ **Configurable Intervals** - Adjustable monitoring frequency  
✅ **Automatic Callbacks** - React to lighting changes in real-time  

## Platform-Specific Details

### Android (ARCore)

ARCore provides light estimation through the `LightEstimate` API with the following metrics:

- **Pixel Intensity**: Normalized value (0.0 - 1.0+) representing ambient light
- **Color Correction**: RGBA values for color temperature adjustment
- **State**: Validity of the current estimate

**Configuration**: Light estimation is enabled via `Config.LightEstimationMode.AMBIENT_INTENSITY`

### iOS (ARKit)

ARKit provides light estimation through the `ARLightEstimate` API with:

- **Ambient Intensity**: Raw luminosity in lumens (0 - 2000+)
- **Normalized Intensity**: Calculated ratio (0.0 - 1.0)
- **Ambient Color Temperature**: Color temperature in Kelvin

**Configuration**: Light estimation is enabled via `ARWorldTrackingConfiguration.isLightEstimationEnabled`

## API Reference

### ARSessionManager Methods

#### `Future<Map<String, dynamic>?> getLightEstimate()`

Get the current light estimate from the AR scene.

**Returns:**
```dart
{
  // Android fields
  'pixelIntensity': 0.75,              // 0.0 - 1.0+ (normalized)
  'colorCorrection': [1.0, 1.0, 1.0, 1.0],  // RGBA color correction
  'isLowLight': false,                 // true if < 0.3
  'isVeryLowLight': false,             // true if < 0.15
  'timestamp': 1698163200000,          // milliseconds
  
  // iOS fields (when on iOS)
  'ambientIntensity': 1500.0,          // lumens (0 - 2000+)
  'normalizedIntensity': 0.75,         // 0.0 - 1.0
  'ambientColorTemperature': 6500.0,   // Kelvin
}
```

**Example:**
```dart
git s
if (lightData != null) {
  final intensity = lightData['pixelIntensity'] ?? 
                   lightData['normalizedIntensity'] ?? 0.0;
  print('Current light intensity: ${(intensity * 100).toStringAsFixed(0)}%');
}
```

#### `Future<void> enableLightingMonitoring({bool enable, int intervalMs})`

Enable or disable automatic lighting condition monitoring.

**Parameters:**
- `enable` (bool): Set to true to start monitoring, false to stop. Default: `true`
- `intervalMs` (int): Check interval in milliseconds. Default: `1000` (1 second)

**Example:**
```dart
// Start monitoring every second
await arSessionManager.enableLightingMonitoring(
  enable: true,
  intervalMs: 1000,
);

// Stop monitoring
await arSessionManager.enableLightingMonitoring(enable: false);
```

### Callbacks

#### `onLightingConditionChanged`

Set this callback to receive automatic lighting updates when monitoring is enabled.

**Type:** `LightingConditionHandler` = `void Function(Map<String, dynamic> lightData)`

**Example:**
```dart
arSessionManager.onLightingConditionChanged = (lightData) {
  final isLowLight = lightData['isLowLight'] as bool? ?? false;
  final intensity = lightData['pixelIntensity'] ?? 
                   lightData['normalizedIntensity'] ?? 0.0;
  
  if (isLowLight) {
    // Show warning to user
    showLowLightWarning(intensity);
  }
};
```

## Usage Examples

### Basic Usage

```dart
class ARScreen extends StatefulWidget {
  @override
  _ARScreenState createState() => _ARScreenState();
}

class _ARScreenState extends State<ARScreen> {
  ARSessionManager? arSessionManager;
  bool _isLowLight = false;
  String _lightingStatus = "Checking lighting...";

  void _onARViewCreated(
    ARSessionManager sessionManager,
    ARObjectManager objectManager,
    ARAnchorManager anchorManager,
    ARLocationManager locationManager,
  ) {
    arSessionManager = sessionManager;
    
    // Initialize AR session
    arSessionManager!.onInitialize(
      showPlanes: true,
      handleTaps: true,
    );
    
    // Set up lighting callback
    arSessionManager!.onLightingConditionChanged = (lightData) {
      setState(() {
        _isLowLight = lightData['isLowLight'] as bool? ?? false;
        final intensity = lightData['pixelIntensity'] ?? 
                         lightData['normalizedIntensity'] ?? 0.0;
        
        _lightingStatus = _isLowLight 
            ? "⚠️ Low Light (${(intensity * 100).toStringAsFixed(0)}%)"
            : "✅ Good Lighting (${(intensity * 100).toStringAsFixed(0)}%)";
      });
    };
    
    // Start monitoring
    arSessionManager!.enableLightingMonitoring(
      enable: true,
      intervalMs: 1000,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          ARView(onARViewCreated: _onARViewCreated),
          
          // Lighting warning overlay
          if (_isLowLight)
            Positioned(
              top: 60,
              left: 20,
              right: 20,
              child: Card(
                color: Colors.orange.withOpacity(0.9),
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    _lightingStatus,
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
  
  @override
  void dispose() {
    arSessionManager?.enableLightingMonitoring(enable: false);
    arSessionManager?.dispose();
    super.dispose();
  }
}
```

### Advanced Usage with Custom UI

See [`examples/light_estimation_example.dart`](./examples/light_estimation_example.dart) for a complete example with:
- Visual lighting intensity indicators
- Real-time monitoring controls
- Platform-specific data display
- User-friendly suggestions

### On-Demand Checking

```dart
ElevatedButton(
  onPressed: () async {
    final lightData = await arSessionManager?.getLightEstimate();
    
    if (lightData != null) {
      final intensity = lightData['pixelIntensity'] ?? 
                       lightData['normalizedIntensity'] ?? 0.0;
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Light intensity: ${(intensity * 100).toStringAsFixed(0)}%'),
        ),
      );
    }
  },
  child: Text('Check Lighting'),
)
```

## Thresholds

The following thresholds are used across both platforms:

| Condition | Threshold | Description |
|-----------|-----------|-------------|
| **Good Lighting** | ≥ 0.3 (30%) | Optimal conditions for AR tracking |
| **Low Light** | < 0.3 (30%) | Suboptimal - tracking may be degraded |
| **Very Low Light** | < 0.15 (15%) | Poor conditions - recommend user action |

You can customize these thresholds in your application logic:

```dart
const double LOW_LIGHT_THRESHOLD = 0.3;
const double VERY_LOW_LIGHT_THRESHOLD = 0.15;

void checkLighting(Map<String, dynamic> lightData) {
  final intensity = lightData['pixelIntensity'] ?? 
                   lightData['normalizedIntensity'] ?? 0.0;
  
  if (intensity < VERY_LOW_LIGHT_THRESHOLD) {
    // Critical - show strong warning
  } else if (intensity < LOW_LIGHT_THRESHOLD) {
    // Suboptimal - show suggestion
  } else {
    // Good - no action needed
  }
}
```

## Best Practices

### 1. Enable Monitoring During AR Sessions

```dart
@override
void initState() {
  super.initState();
  // Start monitoring when AR view is created
}

@override
void dispose() {
  // Always stop monitoring when leaving
  arSessionManager?.enableLightingMonitoring(enable: false);
  super.dispose();
}
```

### 2. Provide Clear User Feedback

```dart
if (isVeryLowLight) {
  // Critical warning
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Insufficient Lighting'),
      content: Text('Please move to a brighter area for better AR tracking.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('OK'),
        ),
      ],
    ),
  );
}
```

### 3. Adjust Monitoring Frequency Based on Needs

```dart
// Battery-conscious: Check every 2 seconds
await arSessionManager.enableLightingMonitoring(
  enable: true,
  intervalMs: 2000,
);

// High-precision: Check twice per second
await arSessionManager.enableLightingMonitoring(
  enable: true,
  intervalMs: 500,
);
```

### 4. Handle Platform Differences

```dart
void displayLightingInfo(Map<String, dynamic> lightData) {
  // Use the appropriate field for each platform
  final intensity = lightData['pixelIntensity'] ??       // Android
                   lightData['normalizedIntensity'] ??   // iOS
                   0.0;
  
  // iOS provides additional color temperature data
  if (lightData.containsKey('ambientColorTemperature')) {
    final temp = lightData['ambientColorTemperature'];
    print('Color temperature: $temp K');
  }
  
  // Android provides color correction matrix
  if (lightData.containsKey('colorCorrection')) {
    final correction = lightData['colorCorrection'];
    print('Color correction: $correction');
  }
}
```

## Troubleshooting

### Light Estimate Returns Null

**Possible causes:**
1. AR session not fully initialized
2. Insufficient camera frames processed
3. Device doesn't support light estimation

**Solution:**
```dart
// Wait a moment after AR initialization
await Future.delayed(Duration(milliseconds: 500));
final lightData = await arSessionManager?.getLightEstimate();
```

### Callback Not Triggered

**Check:**
1. Monitoring is enabled: `enableLightingMonitoring(enable: true)`
2. Callback is set before monitoring starts
3. AR session is active

```dart
// Correct order
arSessionManager.onLightingConditionChanged = _handleLighting;
await arSessionManager.enableLightingMonitoring(enable: true);
```

### Intensity Values Seem Wrong

**Remember:**
- Android: `pixelIntensity` is 0.0-1.0+ (can exceed 1.0 in bright conditions)
- iOS: `normalizedIntensity` is calculated as `ambientIntensity / 2000.0`

Both are normalized for consistency, but the underlying measurements differ.

## Performance Considerations

- **Monitoring Interval**: Default 1000ms is recommended. Lower values increase CPU usage.
- **Callback Processing**: Keep callback handlers lightweight to avoid frame drops.
- **Memory**: Light estimation adds minimal memory overhead (~few KB).

## Migration from Previous Versions

If you're upgrading from a version without light estimation:

**Before:**
```dart
// No light estimation available
```

**After:**
```dart
// Add callback
arSessionManager.onLightingConditionChanged = (lightData) {
  // Handle lighting changes
};

// Enable monitoring
await arSessionManager.enableLightingMonitoring(enable: true);
```

No breaking changes - existing code continues to work without modification.

## Platform Support

| Platform | Minimum Version | Status |
|----------|----------------|--------|
| Android (ARCore) | API 24+ | ✅ Fully Supported |
| iOS (ARKit) | iOS 11.0+ | ✅ Fully Supported |

## Implementation Details

### Android Implementation
- Location: `android/src/main/kotlin/com/uhg0/ar_flutter_plugin_2/ArCoreCompatView.kt`
- Uses ARCore's `LightEstimate` with `AMBIENT_INTENSITY` mode
- Handler-based periodic checking on main thread
- Methods: `handleGetLightEstimate()`, `handleEnableLightingMonitoring()`, `checkLightingConditions()`

### iOS Implementation  
- Location: `ios/Classes/IosARView.swift`
- Uses ARKit's `ARLightEstimate` from current frame
- Timer-based periodic checking
- Methods: `getLightEstimate()`, `enableLightingMonitoring()`, `checkLightingConditions()`

### Flutter Implementation
- Location: `lib/managers/ar_session_manager.dart`
- Type-safe callbacks and futures
- Consistent API across platforms
- Methods: `getLightEstimate()`, `enableLightingMonitoring()`

## Contributing

Found a bug or have a suggestion? Please open an issue on GitHub!

## License

This feature is part of the AR Flutter Plugin and follows the same license terms.

---

**Need Help?** Check out the complete example in [`examples/light_estimation_example.dart`](./examples/light_estimation_example.dart)
