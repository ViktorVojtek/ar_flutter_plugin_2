# Light Estimation - Quick Reference

## Setup (One-Time)

```dart
void _onARViewCreated(ARSessionManager sessionManager, ...) {
  // 1. Set callback
  sessionManager.onLightingConditionChanged = (lightData) {
    final isLowLight = lightData['isLowLight'] ?? false;
    // Handle lighting change
  };
  
  // 2. Start monitoring
  sessionManager.enableLightingMonitoring(enable: true);
}
```

## Methods

| Method | Description | Example |
|--------|-------------|---------|
| `getLightEstimate()` | Get current light data | `await sessionManager.getLightEstimate()` |
| `enableLightingMonitoring()` | Start/stop monitoring | `await sessionManager.enableLightingMonitoring(enable: true, intervalMs: 1000)` |

## Data Fields

| Platform | Field | Type | Range |
|----------|-------|------|-------|
| Android | `pixelIntensity` | double | 0.0 - 1.0+ |
| Android | `colorCorrection` | List<double> | RGBA [0-1] |
| iOS | `normalizedIntensity` | double | 0.0 - 1.0 |
| iOS | `ambientIntensity` | double | 0 - 2000+ lumens |
| iOS | `ambientColorTemperature` | double | Kelvin |
| Both | `isLowLight` | bool | true if < 0.3 |
| Both | `isVeryLowLight` | bool | true if < 0.15 |
| Both | `timestamp` | int | milliseconds |

## Get Cross-Platform Intensity

```dart
final intensity = lightData['pixelIntensity'] ??        // Android
                 lightData['normalizedIntensity'] ??   // iOS
                 0.0;
```

## Common Patterns

### Show Low Light Warning
```dart
if (lightData['isLowLight'] ?? false) {
  showSnackBar('⚠️ Low light detected - move to brighter area');
}
```

### Visual Indicator
```dart
Color getStatusColor(Map<String, dynamic> lightData) {
  if (lightData['isVeryLowLight'] ?? false) return Colors.red;
  if (lightData['isLowLight'] ?? false) return Colors.orange;
  return Colors.green;
}
```

### Monitoring Control
```dart
// Start
await sessionManager.enableLightingMonitoring(
  enable: true,
  intervalMs: 1000, // Check every second
);

// Stop
await sessionManager.enableLightingMonitoring(enable: false);
```

## Cleanup

```dart
@override
void dispose() {
  arSessionManager?.enableLightingMonitoring(enable: false);
  arSessionManager?.dispose();
  super.dispose();
}
```

## Thresholds

- **Good:** ≥ 30% intensity
- **Low:** < 30% intensity  
- **Very Low:** < 15% intensity

## See Also

- Full guide: `LIGHT_ESTIMATION_GUIDE.md`
- Complete example: `examples/light_estimation_example.dart`
- Simple example: `examples/simple_light_estimation.dart`
