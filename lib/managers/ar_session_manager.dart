import 'dart:math' show sqrt;

import 'package:ar_flutter_plugin_2/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin_2/models/ar_anchor.dart';
import 'package:ar_flutter_plugin_2/models/ar_hittest_result.dart';
import 'package:ar_flutter_plugin_2/models/ar_plane.dart';
import 'package:ar_flutter_plugin_2/utils/json_converters.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vector_math/vector_math_64.dart';

// Type definitions to enforce a consistent use of the API
typedef ARHitResultHandler = void Function(List<ARHitTestResult> hits);
typedef ARPlaneResultHandler = void Function(ARPlane plane);
typedef ErrorHandler = void Function(String error);
typedef LightingConditionHandler = void Function(Map<String, dynamic> lightData);

/// Manages the session configuration, parameters and events of an [ARView]
class ARSessionManager {
  /// Platform channel used for communication from and to [ARSessionManager]
  late MethodChannel _channel;

  /// Debugging status flag. If true, all platform calls are printed. Defaults to false.
  final bool debug;

  /// Context of the [ARView] widget that this manager is attributed to
  final BuildContext buildContext;

  /// Determines the types of planes ARCore and ARKit should show
  final PlaneDetectionConfig planeDetectionConfig;

  /// Receives hit results from user taps with tracked planes or feature points
  ARHitResultHandler? onPlaneOrPointTap;

  /// Receives comprehensive plane data when a plane is detected and added to the view
  ARPlaneResultHandler? onPlaneDetected;

  /// Callback that is triggered once error is triggered
  ErrorHandler? onError;

  /// Receives lighting condition updates when monitoring is enabled
  LightingConditionHandler? onLightingConditionChanged;

  ARSessionManager(int id, this.buildContext, this.planeDetectionConfig,
      {this.debug = false}) {
    print("🏗️ ARSessionManager constructor called with id: $id");
    _channel = MethodChannel('arsession_$id');
    _channel.setMethodCallHandler(_platformCallHandler);
    print("📡 Method channel 'arsession_$id' set up");
    if (debug) {
      print("ARSessionManager initialized");
    }
    print("✅ ARSessionManager constructor completed");
  }

  /// Returns the camera pose in Matrix4 format with respect to the world coordinate system of the [ARView]
  Future<Matrix4?> getCameraPose() async {
    try {
      final serializedCameraPose =
          await _channel.invokeMethod<List<dynamic>>('getCameraPose', {});
      return MatrixConverter().fromJson(serializedCameraPose!);
    } catch (e) {
      print('Error caught: ' + e.toString());
      return null;
    }
  }

  /// Returns the given anchor pose in Matrix4 format with respect to the world coordinate system of the [ARView]
  Future<Matrix4?> getPose(ARAnchor anchor) async {
    try {
      if (anchor.name.isEmpty) {
        throw Exception("Anchor can not be resolved. Anchor name is empty.");
      }
      final serializedCameraPose =
          await _channel.invokeMethod<List<dynamic>>('getAnchorPose', {
        "anchorId": anchor.name,
      });
      return MatrixConverter().fromJson(serializedCameraPose!);
    } catch (e) {
      print('Error caught: ' + e.toString());
      return null;
    }
  }

  /// Returns the distance in meters between @anchor1 and @anchor2.
  Future<double?> getDistanceBetweenAnchors(
      ARAnchor anchor1, ARAnchor anchor2) async {
    var anchor1Pose = await getPose(anchor1);
    var anchor2Pose = await getPose(anchor2);
    var anchor1Translation = anchor1Pose?.getTranslation();
    var anchor2Translation = anchor2Pose?.getTranslation();
    if (anchor1Translation != null && anchor2Translation != null) {
      return getDistanceBetweenVectors(anchor1Translation, anchor2Translation);
    } else {
      return null;
    }
  }

  /// Returns the distance in meters between @anchor and device's camera.
  Future<double?> getDistanceFromAnchor(ARAnchor anchor) async {
    Matrix4? cameraPose = await getCameraPose();
    Matrix4? anchorPose = await getPose(anchor);
    Vector3? cameraTranslation = cameraPose?.getTranslation();
    Vector3? anchorTranslation = anchorPose?.getTranslation();
    if (anchorTranslation != null && cameraTranslation != null) {
      return getDistanceBetweenVectors(anchorTranslation, cameraTranslation);
    } else {
      return null;
    }
  }

  /// Returns the distance in meters between @vector1 and @vector2.
  double getDistanceBetweenVectors(Vector3 vector1, Vector3 vector2) {
    num dx = vector1.x - vector2.x;
    num dy = vector1.y - vector2.y;
    num dz = vector1.z - vector2.z;
    double distance = sqrt(dx * dx + dy * dy + dz * dz);
    return distance;
  }

  //Disable Camera
  void disableCamera() {
    _channel.invokeMethod<void>('disableCamera');
  }

  //Enable Camera
  void enableCamera() {
    _channel.invokeMethod<void>('enableCamera');
  }

  //Show or hide planes
  void showPlanes(bool showPlanes){
    _channel.invokeMethod<void>('showPlanes', {
    "showPlanes": showPlanes,
    });
  }

  Future<void> _platformCallHandler(MethodCall call) {
    if (debug) {
      print('_platformCallHandler call ${call.method} ${call.arguments}');
    }
    try {
      switch (call.method) {
        case 'onError':
          if (onError != null) {
            onError!(call.arguments[0]);
            print(call.arguments);
          }
          else{
            ScaffoldMessenger.of(buildContext).showSnackBar(SnackBar(
                content: Text(call.arguments[0]),
                action: SnackBarAction(
                    label: 'HIDE',
                    onPressed:
                    ScaffoldMessenger.of(buildContext).hideCurrentSnackBar)));
          }
          break;
        case 'onPlaneOrPointTap':
          print('🎯🎯🎯 FLUTTER: onPlaneOrPointTap method called!');
          try {
            print('🎯🎯🎯 FLUTTER: Processing callback...');
            // Handle arguments more flexibly to avoid casting issues
            final arguments = call.arguments;
            print('🎯 Received onPlaneOrPointTap arguments: $arguments');
            print('🎯 Arguments type: ${arguments.runtimeType}');
            
            if (arguments != null && arguments is List) {
              final rawHitTestResults = arguments;
              print('🎯 Raw hit test results count: ${rawHitTestResults.length}');
              for (int i = 0; i < rawHitTestResults.length; i++) {
                print('🎯 Hit result $i: ${rawHitTestResults[i]}');
                print('🎯 Hit result $i type: ${rawHitTestResults[i].runtimeType}');
              }
              
              final serializedHitTestResults = rawHitTestResults
                  .map((hitTestResult) {
                    print('🎯 Converting hit result: $hitTestResult');
                    final hitMap = Map<String, dynamic>.from(hitTestResult as Map);
                    
                    // Transform Android data structure to match ARHitTestResult.fromJson expectations
                    final pose = hitMap['pose'];
                    final plane = hitMap['plane'];
                    
                    if (pose != null && plane != null) {
                      final poseMap = Map<String, dynamic>.from(pose as Map);
                      final planeMap = Map<String, dynamic>.from(plane as Map);
                      
                      final matrix = poseMap['matrix'] as List<dynamic>?;
                      final planeType = planeMap['type'] as String?;
                      
                      return {
                        'type': planeType == 'horizontal' ? 1 : 1, // 1 = ARHitTestResultType.plane
                        'distance': 0.0, // We could calculate this from the matrix if needed
                        'worldTransform': matrix,
                      };
                    }
                    
                    // Fallback - return original data
                    return hitMap;
                  })
                  .toList();
                  
              print('🎯 Serialized hit test results: $serializedHitTestResults');
              
              final hitTestResults = serializedHitTestResults.map((e) {
                print('🎯 Creating ARHitTestResult from: $e');
                return ARHitTestResult.fromJson(e);
              }).toList();
              
              print('🎯 Final hit test results count: ${hitTestResults.length}');
              
              if (onPlaneOrPointTap != null) {
                onPlaneOrPointTap!(hitTestResults);
              }
            }
          } catch (e) {
            print('❌ Error in onPlaneOrPointTap: $e');
            print('Arguments: ${call.arguments}');
            print('Arguments type: ${call.arguments.runtimeType}');
          }
          break;
        case 'onPlaneDetected':
          if (onPlaneDetected != null) {
            try {
              final planeData = call.arguments as Map<String, dynamic>;
              final plane = ARPlane.fromMap(planeData);
              onPlaneDetected!(plane);
              if (debug) {
                print('Plane detected: $plane');
              }
            } catch (e) {
              if (debug) {
                print('Error parsing plane data: $e');
                print('Arguments: ${call.arguments}');
              }
            }
          }
          break;
        case 'onLightingConditionChanged':
          // print('💡 Flutter: Received onLightingConditionChanged callback');
          if (onLightingConditionChanged != null) {
            print('💡 Flutter: Callback handler is registered');
            try {
              // Convert Map<Object?, Object?> to Map<String, dynamic>
              final rawData = call.arguments;
              print('💡 Flutter: Raw data type: ${rawData.runtimeType}');
              
              Map<String, dynamic>? lightData;
              if (rawData is Map) {
                lightData = Map<String, dynamic>.from(rawData);
                print('💡 Flutter: Converted light data: $lightData');
              } else {
                lightData = rawData as Map<String, dynamic>?;
              }
              
              if (lightData != null) {
                print('💡 Flutter: Invoking callback with data');
                onLightingConditionChanged!(lightData);
                print('💡 Flutter: Callback invoked successfully');
                if (debug) {
                  print('💡 Lighting condition changed: $lightData');
                }
              } else {
                print('💡 Flutter: Warning - light data is null');
              }
            } catch (e) {
              print('❌ Flutter: Error parsing lighting data: $e');
              print('Arguments: ${call.arguments}');
              print('Arguments type: ${call.arguments.runtimeType}');
              if (debug) {
                print('Error parsing lighting data: $e');
                print('Arguments: ${call.arguments}');
              }
            }
          } else {
            // print('💡 Flutter: Warning - No callback handler registered!');
          }
          break;
        case 'dispose':
          _channel.invokeMethod<void>("dispose");
          break;
        default:
          if (debug) {
            print('Unimplemented method ${call.method} ');
          }
      }
    } catch (e) {
      print('Error caught: ' + e.toString());
    }
    return Future.value();
  }

  /// Function to initialize the platform-specific AR view. Can be used to initially set or update session settings.
  /// [customPlaneTexturePath] refers to flutter assets from the app that is calling this function, NOT to assets within this plugin. Make sure
  /// the assets are correctly registered in the pubspec.yaml of the parent app (e.g. the ./example app in this plugin's repo)
  /// [debugGestures] enables verbose gesture logging for development (default: false for production)
  /// [maxPanDistance] sets the maximum distance in meters that objects can be panned from camera (default: 5.0m)
  onInitialize({
    bool showAnimatedGuide = true,
    bool showFeaturePoints = false,
    bool showPlanes = true,
    String? customPlaneTexturePath,
    bool showWorldOrigin = false,
    bool handleTaps = true,
    bool handlePans = false, // nodes are not draggable by default
    bool handleRotation = false, // nodes can not be rotated by default
    bool debugGestures = false, // enable verbose gesture logging for development
    double maxPanDistance = 5.0, // maximum pan distance from camera in meters
  }) {
    print("🎯 ARSessionManager.onInitialize called");
    print("📤 Calling _channel.invokeMethod('init', ...)");
    _channel.invokeMethod<void>('init', {
      'showAnimatedGuide': showAnimatedGuide,
      'showFeaturePoints': showFeaturePoints,
      'planeDetectionConfig': planeDetectionConfig.index,
      'showPlanes': showPlanes,
      'customPlaneTexturePath': customPlaneTexturePath,
      'showWorldOrigin': showWorldOrigin,
      'handleTaps': handleTaps,
      'handlePans': handlePans,
      'handleRotation': handleRotation,
      'debugGestures': debugGestures,
      'maxPanDistance': maxPanDistance,
    });
    print("📤 ARSessionManager init method call completed");
  }


  /// Dispose the AR view on the platforms to pause the scenes and disconnect the platform handlers.
  /// You should call this before removing the AR view to prevent out of memory erros
  dispose() async {
    try {
      await _channel.invokeMethod<void>("dispose");
    } catch (e) {
      print(e);
    }
  }

  /// Pause the AR session gracefully.
  /// 
  /// This stops camera capture and rendering without destroying resources.
  /// **IMPORTANT:** Call this before [dispose] to prevent EGL context crashes on Android.
  /// 
  /// Recommended usage pattern:
  /// ```dart
  /// await arSessionManager.pause();
  /// await Future.delayed(Duration(milliseconds: 100)); // Give ARCore time to cleanup
  /// await arSessionManager.dispose();
  /// ```
  Future<bool> pause() async {
    try {
      final result = await _channel.invokeMethod<bool>('pause');
      return result ?? false;
    } catch (e) {
      if (debug) {
        print('Error pausing AR session: $e');
      }
      return false;
    }
  }

  /// Pause the AR session, wait briefly, then dispose.
  /// 
  /// This is the recommended way to safely dispose the AR session on Android
  /// to prevent EGL context crashes. The delay gives ARCore time to complete
  /// pause operations before the OpenGL context is destroyed.
  /// 
  /// [delayMs] - milliseconds to wait between pause and dispose (default: 100ms)
  Future<void> safeDispose({int delayMs = 100}) async {
    try {
      if (debug) {
        print('🛑 Safe dispose: pausing AR session...');
      }
      await pause();
      
      if (debug) {
        print('⏳ Safe dispose: waiting ${delayMs}ms for cleanup...');
      }
      await Future.delayed(Duration(milliseconds: delayMs));
      
      if (debug) {
        print('🧹 Safe dispose: disposing AR session...');
      }
      await dispose();
      
      if (debug) {
        print('✅ Safe dispose: complete');
      }
    } catch (e) {
      if (debug) {
        print('❌ Error during safe dispose: $e');
      }
      // Still try to dispose even if pause failed
      await dispose();
    }
  }

  // ============================================================================
  // PERMISSION DIALOG PROTECTION
  // ============================================================================
  // These methods help protect the AR session during permission dialogs on Android.
  // When Android shows a permission dialog, the activity may lose focus and trigger
  // lifecycle events that can destroy the AR session prematurely.
  // ============================================================================

  /// Notify the native layer that a permission dialog is about to be shown.
  /// 
  /// **IMPORTANT:** Call this BEFORE requesting any permissions (storage, location, etc.)
  /// to prevent the AR session from being destroyed when the dialog appears.
  /// 
  /// Usage example:
  /// ```dart
  /// await arSessionManager.notifyPermissionDialogShowing();
  /// final status = await Permission.storage.request();
  /// await arSessionManager.notifyPermissionDialogDismissed();
  /// ```
  Future<bool> notifyPermissionDialogShowing() async {
    try {
      if (debug) {
        print('🔔 Notifying AR session: permission dialog showing');
      }
      final result = await _channel.invokeMethod<bool>('notifyPermissionDialogShowing');
      return result ?? false;
    } catch (e) {
      if (debug) {
        print('⚠️ Error notifying permission dialog: $e');
      }
      return false;
    }
  }

  /// Notify the native layer that a permission dialog has been dismissed.
  /// 
  /// **IMPORTANT:** Call this AFTER the permission dialog is dismissed (granted or denied)
  /// to restore normal AR session lifecycle behavior.
  /// 
  /// This will also attempt to resume the AR session if it was paused.
  Future<bool> notifyPermissionDialogDismissed() async {
    try {
      if (debug) {
        print('🔔 Notifying AR session: permission dialog dismissed');
      }
      final result = await _channel.invokeMethod<bool>('notifyPermissionDialogDismissed');
      return result ?? false;
    } catch (e) {
      if (debug) {
        print('⚠️ Error notifying permission dialog dismissed: $e');
      }
      return false;
    }
  }

  /// Force resume the AR session after it may have been incorrectly paused.
  /// 
  /// Use this as a recovery mechanism if the AR session appears to be frozen
  /// or shows a black screen after permission dialogs or other interruptions.
  /// 
  /// Returns true if the resume was successful.
  Future<bool> forceResumeSession() async {
    try {
      if (debug) {
        print('🔄 Force resuming AR session');
      }
      final result = await _channel.invokeMethod<bool>('forceResumeSession');
      return result ?? false;
    } catch (e) {
      if (debug) {
        print('⚠️ Error force resuming AR session: $e');
      }
      return false;
    }
  }

  /// Execute an action that may trigger permission dialogs safely.
  /// 
  /// This is a convenience method that wraps the permission notification calls
  /// around any async action that might trigger permission dialogs.
  /// 
  /// Usage example:
  /// ```dart
  /// await arSessionManager.withPermissionProtection(() async {
  ///   final status = await Permission.storage.request();
  ///   if (status.isGranted) {
  ///     await saveScreenshot();
  ///   }
  /// });
  /// ```
  Future<T> withPermissionProtection<T>(Future<T> Function() action) async {
    try {
      await notifyPermissionDialogShowing();
      final result = await action();
      return result;
    } finally {
      await notifyPermissionDialogDismissed();
    }
  }

  /// Returns a future ImageProvider that contains a screenshot of the current AR Scene
  Future<ImageProvider> snapshot() async {
    final result = await _channel.invokeMethod<Uint8List>('snapshot');
    return MemoryImage(result!);
  }

  /// Pause and re-run AR session with reset flags (anchors cleared, tracking reset)
  Future<bool> softResetSession({bool removeExistingAnchors = true, bool resetTracking = true}) async {
    try {
      final result = await _channel.invokeMethod<bool>('softResetSession', {
        'removeExistingAnchors': removeExistingAnchors,
        'resetTracking': resetTracking,
      });
      return result ?? false;
    } catch (e) {
      if (debug) {
        print('Error in softResetSession: $e');
      }
      return false;
    }
  }

  /// Enhanced "NUKE ALL" - Phase 3 System-Level Memory Teardown
  /// 
  /// CRITICAL IMPROVEMENT: This addresses the issue where Phase 2 only achieved
  /// minimal memory reduction (1022MB → 966MB = 56MB) instead of returning to
  /// cold start levels (~350MB).
  /// 
  /// Phase 3 adds aggressive OS-level memory pressure simulation and hardware 
  /// GPU resource forcing to achieve complete teardown.
  /// 
  /// TIMING CRITICAL: Must be called BEFORE widget disposal/navigation.
  /// Enhanced nukeAll that prevents camera freezing
  /// This method performs memory cleanup without interrupting the camera feed
  /// Returns immediately while cleanup continues in background
  Future<bool> nukeAllNonBlocking({
    bool purgeCaches = true,
    bool removeExistingAnchors = true,
    bool resetTracking = false, // Default to false to minimize interruption
  }) async {
    try {
      if (debug) {
        print('📍 ARSessionManager: Starting non-blocking memory cleanup');
        print('📍 Goal: Clean memory while keeping camera active');
      }
      
      final result = await _channel.invokeMethod<bool>('ar#nukeAllNonBlocking', {
        'purgeCaches': purgeCaches,
        'removeExistingAnchors': removeExistingAnchors,
        'resetTracking': resetTracking,
      });
      
      final success = result ?? false;
      
      if (debug) {
        print('📍 ARSessionManager: Non-blocking cleanup initiated - continuing in background');
      }
      
      // Give a moment for cleanup to start
      await Future.delayed(const Duration(milliseconds: 100));
      
      return success;
      
    } catch (e) {
      if (debug) {
        print('📍 ARSessionManager: Non-blocking cleanup error: $e');
      }
      return false;
    }
  }

  /// If called after super.dispose(), native cleanup may not execute properly.
  Future<bool> nukeAll({
    bool purgeCaches = true,
    bool removeExistingAnchors = true,
    bool resetTracking = true,
  }) async {
    try {
      if (debug) {
        print('📍 ARSessionManager: === PHASE 3 SYSTEM-LEVEL NUKE ALL ===');
        print('📍 ARSessionManager: Goal: Return memory to cold start (~350MB)');
        print('📍 ARSessionManager: Previous: 1022MB → 966MB (insufficient)');
        print('📍 ARSessionManager: Phase 3: OS memory pressure + GPU forcing');
      }
      
      // CRITICAL: Pre-nuke object removal - this was missing in previous attempts
      if (debug) {
        print('📍 ARSessionManager: 🧹 PRE-NUKE: Complete object removal...');
      }
      
      try {
        await _channel.invokeMethod<void>('removeAllObjects');
        await Future.delayed(const Duration(milliseconds: 150));
        
        if (debug) {
          print('📍 ARSessionManager: ✅ Pre-nuke object removal completed');
        }
      } catch (e) {
        if (debug) {
          print('📍 ARSessionManager: ⚠️ Pre-nuke removal failed: $e (continuing)');
        }
      }
      
      // PHASE 3: System-level aggressive teardown
      if (debug) {
        print('📍 ARSessionManager: 🚀 PHASE 3: System memory pressure...');
      }
      
      final result = await _channel.invokeMethod<bool>('ar#nukeAll', {
        'purgeCaches': purgeCaches,
        'removeExistingAnchors': removeExistingAnchors,
        'resetTracking': resetTracking,
        // Phase 3 enhancements for system-level cleanup
        'forceSystemMemoryPressure': true,
        'enableHardwareGpuReset': true,
        'simulateMemoryWarning': true,
      });
      
      final success = result ?? false;
      
      if (debug) {
        print('📍 ARSessionManager: ${success ? '✅ PHASE 3 completed' : '❌ PHASE 3 failed'}');
        if (success) {
          print('📍 ARSessionManager: Memory should approach cold start levels');
        }
      }
      
      // Extended wait for system-level cleanup processing
      if (success) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
      
      return success;
    } catch (e) {
      if (debug) {
        print('📍 ARSessionManager: ❌ Phase 3 error: $e');
      }
      return false;
    }
  }

  // =================================================================
  // Light Estimation Methods
  // =================================================================
  
  /// Get current light estimate from the AR scene
  /// Returns a map containing:
  /// - Android: pixelIntensity, colorCorrection, isLowLight, isVeryLowLight, timestamp
  /// - iOS: ambientIntensity, normalizedIntensity, ambientColorTemperature, isLowLight, isVeryLowLight, timestamp
  Future<Map<String, dynamic>?> getLightEstimate() async {
    try {
      final result = await _channel.invokeMethod<Map>('getLightEstimate');
      return result?.cast<String, dynamic>();
    } catch (e) {
      if (debug) print('Error getting light estimate: $e');
      return null;
    }
  }

  /// Enable or disable automatic lighting condition monitoring
  /// When enabled, [onLightingConditionChanged] callback will be invoked periodically
  /// 
  /// [enable] - Set to true to start monitoring, false to stop
  /// [intervalMs] - Check interval in milliseconds (default: 1000ms = 1 second)
  Future<void> enableLightingMonitoring({
    bool enable = true,
    int intervalMs = 1000,
  }) async {
    try {
      await _channel.invokeMethod('enableLightingMonitoring', {
        'enable': enable,
        'intervalMs': intervalMs,
      });
      if (debug) {
        print('💡 Lighting monitoring ${enable ? "enabled" : "disabled"} (interval: ${intervalMs}ms)');
      }
    } catch (e) {
      if (debug) print('Error toggling lighting monitoring: $e');
    }
  }

  /// Debug method to check what native resources are still alive after nukeAll.
  /// Helps identify what's preventing full memory release.
  /// Returns a map with resource status information.
  Future<Map<String, dynamic>?> getPluginState() async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>('ar#getPluginState');
      return result?.map((key, value) => MapEntry(key.toString(), value));
    } catch (e) {
      if (debug) {
        print('❌ Error getting plugin state: $e');
      }
      return null;
    }
  }

  // =================================================================
  // Depth API / Occlusion Methods
  // =================================================================
  
  /// Check if the device supports the Depth API
  /// Returns true if depth mode is supported, false otherwise
  /// 
  /// Note: Not all ARCore devices support depth. Devices without ToF sensors
  /// can still support depth through motion-based calculation.
  Future<bool> isDepthSupported() async {
    try {
      final result = await _channel.invokeMethod<bool>('isDepthSupported');
      return result ?? false;
    } catch (e) {
      if (debug) print('Error checking depth support: $e');
      return false;
    }
  }

  /// Enable or disable depth-based occlusion
  /// 
  /// When enabled, virtual objects will be realistically occluded by real-world objects.
  /// This makes AR scenes look much more realistic - objects can appear behind real furniture,
  /// walls, or people.
  /// 
  /// [enable] - Set to true to enable occlusion, false to disable
  /// Returns true if the operation succeeded
  /// 
  /// Example:
  /// ```dart
  /// // Enable occlusion for realistic rendering
  /// bool success = await sessionManager.enableDepthOcclusion(true);
  /// if (success) {
  ///   print("Depth occlusion enabled - objects will be hidden behind real objects");
  /// }
  /// ```
  Future<bool> enableDepthOcclusion(bool enable) async {
    try {
      final result = await _channel.invokeMethod<bool>('enableDepthOcclusion', {
        'enable': enable,
      });
      if (debug) {
        print('🔍 Depth occlusion ${enable ? "ENABLED" : "DISABLED"}: ${result == true ? "✅" : "❌"}');
      }
      return result ?? false;
    } catch (e) {
      if (debug) print('Error toggling depth occlusion: $e');
      return false;
    }
  }

  /// Check if depth occlusion is currently enabled
  /// Returns true if occlusion is enabled, false otherwise
  Future<bool> isDepthOcclusionEnabled() async {
    try {
      final result = await _channel.invokeMethod<bool>('isDepthOcclusionEnabled');
      return result ?? false;
    } catch (e) {
      if (debug) print('Error checking depth occlusion status: $e');
      return false;
    }
  }

  // =================================================================
  // People Occlusion (iOS only - works WITHOUT LiDAR)
  // =================================================================

  /// Check if people occlusion is supported on this device
  /// 
  /// People occlusion uses machine learning to segment people from the scene
  /// and render them in front of AR objects. This creates a more realistic
  /// experience where people can walk in front of virtual objects.
  /// 
  /// **Requirements:**
  /// - iOS 13.0+
  /// - A12 chip or later (iPhone XS/XR or newer)
  /// - Does NOT require LiDAR (works on more devices than depth occlusion)
  /// 
  /// Returns true if people occlusion is supported, false otherwise.
  Future<bool> isPeopleOcclusionSupported() async {
    try {
      final result = await _channel.invokeMethod<bool>('isPeopleOcclusionSupported');
      return result ?? false;
    } catch (e) {
      if (debug) print('Error checking people occlusion support: $e');
      return false;
    }
  }

  /// Enable or disable people occlusion
  /// 
  /// When enabled, real people will appear in front of AR objects using
  /// machine learning-based person segmentation. This is different from
  /// depth occlusion (which requires LiDAR) - people occlusion works on
  /// any device with an A12 chip or later.
  /// 
  /// [enable] - Set to true to enable, false to disable
  /// Returns true if the operation succeeded
  /// 
  /// **Note:** You can enable both people occlusion AND depth occlusion
  /// for best results on LiDAR devices.
  /// 
  /// Example:
  /// ```dart
  /// // Check if supported first
  /// if (await sessionManager.isPeopleOcclusionSupported()) {
  ///   // Enable people occlusion
  ///   bool success = await sessionManager.enablePeopleOcclusion(true);
  ///   if (success) {
  ///     print("People will now appear in front of AR objects!");
  ///   }
  /// }
  /// ```
  Future<bool> enablePeopleOcclusion(bool enable) async {
    try {
      final result = await _channel.invokeMethod<bool>('enablePeopleOcclusion', {
        'enable': enable,
      });
      if (debug) {
        print('👤 People occlusion ${enable ? "ENABLED" : "DISABLED"}: ${result == true ? "✅" : "❌"}');
      }
      return result ?? false;
    } catch (e) {
      if (debug) print('Error toggling people occlusion: $e');
      return false;
    }
  }

  /// Check if people occlusion is currently enabled
  /// Returns true if people occlusion is active, false otherwise
  Future<bool> isPeopleOcclusionEnabled() async {
    try {
      final result = await _channel.invokeMethod<bool>('isPeopleOcclusionEnabled');
      return result ?? false;
    } catch (e) {
      if (debug) print('Error checking people occlusion status: $e');
      return false;
    }
  }

  /// Show or hide the LiDAR mesh debug visualization
  /// 
  /// When enabled, you can see the reconstructed 3D mesh that the LiDAR
  /// is building. This helps debug occlusion issues by showing exactly
  /// what geometry the device thinks exists in the scene.
  /// 
  /// [show] - Set to true to show the debug mesh, false to hide it
  /// Returns true if the operation succeeded
  /// 
  /// **Use cases:**
  /// - Debug why occlusion isn't working in certain areas
  /// - See how well the LiDAR is reconstructing your environment
  /// - Identify areas with mesh artifacts
  /// 
  /// Example:
  /// ```dart
  /// // Show the mesh to debug
  /// await sessionManager.showDebugMesh(true);
  /// // Hide when done debugging
  /// await sessionManager.showDebugMesh(false);
  /// ```
  Future<bool> showDebugMesh(bool show) async {
    try {
      final result = await _channel.invokeMethod<bool>('showDebugMesh', {
        'show': show,
      });
      return result ?? false;
    } catch (e) {
      if (debug) print('Error showing debug mesh: $e');
      return false;
    }
  }

  /// Acquire the current depth image from ARCore
  /// 
  /// Returns a map containing:
  /// - width: Width of the depth image
  /// - height: Height of the depth image
  /// - depthData: List of depth values in millimeters
  /// - format: "millimeters" (the unit of depth values)
  /// 
  /// Returns null if depth data is not available yet.
  /// 
  /// Note: Depth data may not be available immediately after starting the AR session.
  /// It requires motion and tracked feature points to calculate depth.
  /// 
  /// Example:
  /// ```dart
  /// final depthImage = await sessionManager.acquireDepthImage();
  /// if (depthImage != null) {
  ///   print("Depth image: ${depthImage['width']}x${depthImage['height']}");
  ///   List<int> depths = depthImage['depthData'];
  ///   print("First pixel depth: ${depths[0]}mm");
  /// }
  /// ```
  Future<Map<String, dynamic>?> acquireDepthImage() async {
    try {
      final result = await _channel.invokeMethod<Map>('acquireDepthImage');
      return result?.cast<String, dynamic>();
    } catch (e) {
      if (debug) print('Depth image not available: $e');
      return null;
    }
  }
}
