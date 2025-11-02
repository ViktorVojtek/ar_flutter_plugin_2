import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin_2/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_2/models/ar_anchor.dart';
import 'package:ar_flutter_plugin_2/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin_2/datatypes/node_types.dart';
import 'package:ar_flutter_plugin_2/datatypes/hittest_result_types.dart';
import 'package:ar_flutter_plugin_2/models/ar_node.dart';
import 'package:ar_flutter_plugin_2/models/ar_hittest_result.dart';
import 'package:vector_math/vector_math_64.dart' as vector_math;

/// Example demonstrating coaching overlays on both iOS and Android
/// 
/// iOS: Uses native ARCoachingOverlayView (automatic)
/// Android: Uses custom Flutter overlay (manual implementation)
class ARCoachingExample extends StatefulWidget {
  @override
  _ARCoachingExampleState createState() => _ARCoachingExampleState();
}

class _ARCoachingExampleState extends State<ARCoachingExample> {
  ARSessionManager? arSessionManager;
  ARObjectManager? arObjectManager;
  ARAnchorManager? arAnchorManager;
  
  List<ARNode> nodes = [];
  List<ARAnchor> anchors = [];
  
  // Coaching overlay state (for Android)
  bool _showCoaching = true;
  String _coachingMessage = "Move your device to scan the area";
  IconData _coachingIcon = Icons.phone_android;
  Timer? _coachingTimer;
  bool _isLowLight = false;
  
  @override
  void dispose() {
    _coachingTimer?.cancel();
    arSessionManager?.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('AR Coaching Overlay Demo'),
        backgroundColor: Colors.blue,
      ),
      body: Stack(
        children: [
          // AR View
          ARView(
            onARViewCreated: onARViewCreated,
            planeDetectionConfig: PlaneDetectionConfig.horizontal,
          ),
          
          // Custom coaching overlay for Android
          // iOS uses native ARCoachingOverlayView automatically
          if (Platform.isAndroid && _showCoaching)
            _buildAndroidCoachingOverlay(),
          
          // Instructions at bottom
          if (!_showCoaching)
            Positioned(
              bottom: 20,
              left: 20,
              right: 20,
              child: Container(
                padding: EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  Platform.isIOS 
                    ? "✅ iOS: Native coaching overlay active\nTap a surface to place an object"
                    : "✅ Android: Custom coaching complete\nTap a surface to place an object",
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.black87,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
        ],
      ),
    );
  }
  
  /// Build custom coaching overlay for Android
  /// (iOS uses native ARCoachingOverlayView)
  Widget _buildAndroidCoachingOverlay() {
    return Container(
      color: Colors.black.withOpacity(0.85),
      child: Center(
        child: Container(
          padding: EdgeInsets.all(32),
          margin: EdgeInsets.all(40),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 10,
                offset: Offset(0, 5),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Animated phone icon
              TweenAnimationBuilder<double>(
                duration: Duration(seconds: 2),
                tween: Tween(begin: -15, end: 15),
                curve: Curves.easeInOut,
                builder: (context, value, child) {
                  return Transform.translate(
                    offset: Offset(value, 0),
                    child: Icon(
                      _coachingIcon,
                      size: 60,
                      color: _isLowLight ? Colors.orange : Colors.blue,
                    ),
                  );
                },
                onEnd: () {
                  if (mounted) setState(() {}); // Loop animation
                },
              ),
              SizedBox(height: 24),
              
              // Main message
              Text(
                _coachingMessage,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 12),
              
              // Detailed instructions
              Text(
                _isLowLight
                  ? "AR tracking works best in\nwell-lit environments"
                  : "Point at a flat surface\nMove slowly from side to side",
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.black54,
                ),
                textAlign: TextAlign.center,
              ),
              
              SizedBox(height: 20),
              
              // Platform indicator
              Container(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green.withOpacity(0.3)),
                ),
                child: Text(
                  "Android (ARCore) - Custom Overlay",
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.green[700],
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  void onARViewCreated(
    ARSessionManager sessionManager,
    ARObjectManager objectManager,
    ARAnchorManager anchorManager,
    ARLocationManager locationManager,
  ) {
    print("🚀 AR View Created");
    
    arSessionManager = sessionManager;
    arObjectManager = objectManager;
    arAnchorManager = anchorManager;
    
    // Initialize AR session
    arSessionManager!.onInitialize(
      showAnimatedGuide: true, // ✅ Works automatically on iOS!
      showPlanes: true,
      handleTaps: true,
      showFeaturePoints: false,
    );
    arObjectManager!.onInitialize();
    
    // Set up plane/point tap handler
    arSessionManager!.onPlaneOrPointTap = onPlaneOrPointTapped;
    
    // Monitor lighting conditions (works on both platforms)
    arSessionManager!.onLightingConditionChanged = (lightData) {
      bool isLowLight = lightData['isLowLight'] ?? false;
      
      if (isLowLight && mounted) {
        setState(() {
          _isLowLight = true;
          _coachingMessage = "⚠️ Low light detected";
          _coachingIcon = Icons.wb_sunny;
          _showCoaching = true;
        });
      } else if (_isLowLight && !isLowLight && mounted) {
        setState(() {
          _isLowLight = false;
          _coachingMessage = "Move your device to scan the area";
          _coachingIcon = Icons.phone_android;
        });
      }
    };
    arSessionManager!.enableLightingMonitoring(enable: true, intervalMs: 1000);
    
    // On Android, start coaching timer
    if (Platform.isAndroid) {
      _startAndroidCoachingTimer();
    }
    
    print(Platform.isIOS 
      ? "✅ iOS: Native ARCoachingOverlayView enabled"
      : "✅ Android: Custom coaching overlay active");
  }
  
  /// Start coaching timer for Android
  /// Auto-hide after 10 seconds or when object is placed
  void _startAndroidCoachingTimer() {
    // Auto-hide coaching after 10 seconds of scanning
    _coachingTimer = Timer(Duration(seconds: 10), () {
      if (mounted && !_isLowLight) {
        setState(() {
          _showCoaching = false;
        });
        print("⏱️ Android coaching timer expired - hiding overlay");
      }
    });
  }
  
  Future<void> onPlaneOrPointTapped(List<ARHitTestResult> hitTestResults) async {
    print("🎯 Plane tapped! Hit test results: ${hitTestResults.length}");
    
    if (hitTestResults.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("No surface detected - keep scanning"),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    
    // Hide coaching overlay on first successful tap
    if (mounted) {
      setState(() {
        _showCoaching = false;
      });
    }
    _coachingTimer?.cancel();
    
    // Find plane hit result
    var planeHitResult = hitTestResults.firstWhere(
      (result) => result.type == ARHitTestResultType.plane,
      orElse: () => hitTestResults.first,
    );
    
    // Create anchor
    var newAnchor = ARPlaneAnchor(
      transformation: planeHitResult.worldTransform,
    );
    
    bool? didAddAnchor = await arAnchorManager!.addAnchor(newAnchor);
    
    if (didAddAnchor == true) {
      anchors.add(newAnchor);
      
      // Create a simple cube model
      var newNode = ARNode(
        type: NodeType.webGLB,
        uri: "https://github.com/KhronosGroup/glTF-Sample-Models/raw/master/2.0/Duck/glTF-Binary/Duck.glb",
        scale: vector_math.Vector3(0.3, 0.3, 0.3),
        position: vector_math.Vector3(0.0, 0.0, 0.0),
        rotation: vector_math.Vector4(1.0, 0.0, 0.0, 0.0),
      );
      
      String? nodeId = await arObjectManager!.addNode(newNode, planeAnchor: newAnchor);
      
      if (nodeId != null) {
        nodes.add(newNode);
        print("✅ Object placed successfully! ID: $nodeId");
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("🦆 Duck placed! Coaching complete."),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      } else {
        print("❌ Failed to add node");
      }
    } else {
      print("❌ Failed to create anchor");
    }
  }
}
