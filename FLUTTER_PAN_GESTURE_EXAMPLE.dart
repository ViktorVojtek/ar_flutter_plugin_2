// EXAMPLE: How to properly enable pan gestures in your Flutter app

import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin_2/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin_2/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:flutter/material.dart';

class ARViewExample extends StatefulWidget {
  @override
  _ARViewExampleState createState() => _ARViewExampleState();
}

class _ARViewExampleState extends State<ARViewExample> {
  ARSessionManager? arSessionManager;
  ARObjectManager? arObjectManager;
  ARLocationManager? arLocationManager;
  ARAnchorManager? arAnchorManager;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("AR Pan Gesture Test")),
      body: ARView(
        onARViewCreated: onARViewCreated,
        // CRITICAL: Enable plane detection for better hit testing
        planeDetectionConfig: PlaneDetectionConfig.horizontalAndVertical,
      ),
    );
  }

  void onARViewCreated(
    ARSessionManager arSessionManager,
    ARObjectManager arObjectManager,
    ARAnchorManager arAnchorManager,
    ARLocationManager arLocationManager,
  ) {
    this.arSessionManager = arSessionManager;
    this.arObjectManager = arObjectManager;
    this.arAnchorManager = arAnchorManager;
    this.arLocationManager = arLocationManager;

    // Initialize session
    this.arSessionManager!.onInitialize(
      showAnimatedGuide: true,
      showFeaturePoints: false,
      handleTaps: true,           // Enable tap gestures
      handlePans: true,           // CRITICAL: Enable pan gestures
      handleRotation: false,      // Disable rotation for testing
      showPlanes: true,          // Show planes for debugging
    );

    // Set up gesture callbacks
    this.arObjectManager!.onPanStart = (nodeName) {
      print("Pan started on node: $nodeName");
    };

    this.arObjectManager!.onPanChange = (nodeName) {
      print("Pan changed on node: $nodeName");
    };

    this.arObjectManager!.onPanEnd = (nodeName, transform) {
      print("Pan ended on node: $nodeName");
    };

    this.arObjectManager!.onNodeTap = (nodeNames) {
      print("Node tapped: $nodeNames");
    };
  }

  // Add a 3D object for testing
  Future<void> addTestObject() async {
    // Example code to add a test object
    // You'll need to implement this based on your specific use case
  }
}

/* 
KEY POINTS FOR ENABLING PAN GESTURES:

1. Set handlePans: true in ARView creation
2. Set handlePans: true in arSessionManager.onInitialize()
3. Enable plane detection for better hit testing
4. Set up pan gesture callbacks to see events
5. Make sure you're passing these parameters correctly

COMMON MISTAKES:
- Not setting handlePans: true in both places
- Not enabling plane detection
- Not setting up callbacks to verify gestures work
*/
