import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_2/models/ar_node.dart';
import 'package:ar_flutter_plugin_2/models/ar_anchor.dart';
import 'package:ar_flutter_plugin_2/models/ar_hittest_result.dart';
import 'package:ar_flutter_plugin_2/datatypes/node_types.dart';
import 'package:ar_flutter_plugin_2/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin_2/datatypes/hittest_result_types.dart';
import 'package:vector_math/vector_math_64.dart' as vm;
import 'package:flutter/material.dart';

class AutoPlacementTestScreen extends StatefulWidget {
  @override
  _AutoPlacementTestScreenState createState() => _AutoPlacementTestScreenState();
}

class _AutoPlacementTestScreenState extends State<AutoPlacementTestScreen> {
  ARSessionManager? arSessionManager;
  ARObjectManager? arObjectManager;
  ARAnchorManager? arAnchorManager;
  List<ARNode> nodes = [];
  List<ARAnchor> anchors = [];
  bool _autoPlacementMode = true; // Start in auto placement mode
  
  @override
  void dispose() {
    super.dispose();
    arSessionManager?.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Auto Placement Test'),
        backgroundColor: Colors.blue,
        actions: [
          IconButton(
            icon: Icon(_autoPlacementMode ? Icons.auto_awesome : Icons.touch_app),
            onPressed: _toggleAutoPlacement,
          ),
        ],
      ),
      body: Container(
        child: Stack(
          children: [
            ARView(
              onARViewCreated: onARViewCreated,
              planeDetectionConfig: PlaneDetectionConfig.horizontal,
            ),
            Align(
              alignment: FractionalOffset.bottomCenter,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton(
                    onPressed: onRemoveEverything,
                    child: Text("Remove Everything"),
                  ),
                  ElevatedButton(
                    onPressed: _toggleAutoPlacement,
                    child: Text(_autoPlacementMode ? "Disable Auto" : "Enable Auto"),
                  ),
                ],
              )
            ),
          ],
        ),
      ),
    );
  }

  void onARViewCreated(
    ARSessionManager arSessionManager,
    ARObjectManager arObjectManager,
    ARAnchorManager arAnchorManager,
    ARLocationManager arLocationManager,
  ) {
    print("🚀🚀🚀 FLUTTER: onARViewCreated called!");
    
    this.arSessionManager = arSessionManager;
    this.arObjectManager = arObjectManager;
    this.arAnchorManager = arAnchorManager;

    // EXACT same initialization as working object_gestures
    this.arSessionManager!.onInitialize(
      showFeaturePoints: false,
      showPlanes: true,
      customPlaneTexturePath: "Images/triangle.png",
      showWorldOrigin: false,
      handlePans: true,
      handleRotation: true,
    );
    this.arObjectManager!.onInitialize();

    // Set the callback - this is the key part
    this.arSessionManager!.onPlaneOrPointTap = onPlaneOrPointTapped;
    print("🎯🎯🎯 FLUTTER: Callback set! Function: ${this.arSessionManager!.onPlaneOrPointTap}.");
  }

  Future<void> onPlaneOrPointTapped(List<ARHitTestResult> hitTestResults) async {
    print("🎯 onPlaneOrPointTapped called with ${hitTestResults.length} results");
    print("🔄 Auto placement mode: $_autoPlacementMode");
    
    if (hitTestResults.isNotEmpty) {
      var singleHitTestResult = hitTestResults.firstWhere(
        (hitTestResult) => hitTestResult.type == ARHitTestResultType.plane,
        orElse: () => hitTestResults.first
      );

      if (_autoPlacementMode) {
        // AUTO MODE: Place duck automatically when any plane is tapped
        print("🦆 AUTO MODE: Placing duck automatically!");
        _placeDuckAtHitResult(singleHitTestResult);
      } else {
        // NORMAL MODE: Use the original object_gestures behavior
        print("🎯 NORMAL MODE: Manual placement");
        _placeDuckAtHitResult(singleHitTestResult);
      }
    }
  }

  void _placeDuckAtHitResult(ARHitTestResult hitResult) async {
    var newAnchor = ARPlaneAnchor(transformation: hitResult.worldTransform);
    bool? didAddAnchor = await this.arAnchorManager!.addAnchor(newAnchor);
    
    if (didAddAnchor!) {
      this.anchors.add(newAnchor);
      
      // Add duck at plane level (not eye level) - EXACT same as object_gestures
      var newNode = ARNode(
        type: NodeType.webGLB,
        uri: "https://github.com/KhronosGroup/glTF-Sample-Models/raw/main/2.0/Duck/glTF-Binary/Duck.glb",
        scale: vm.Vector3(0.2, 0.2, 0.2),
        position: vm.Vector3(0.0, 0.0, 0.0), // Place at anchor position, not above it
        rotation: vm.Vector4(1.0, 0.0, 0.0, 0.0),
        isTransformable: true,
        enablePanGestures: false, // Use built-in pan for small model reliability
        enableRotationGestures: true
      );
      
      String? addedNodeId = await this.arObjectManager!.addNode(newNode, planeAnchor: newAnchor);
      
      if (addedNodeId != null) {
        this.nodes.add(newNode);
        print("✅ Duck placed at plane level!");
      } else {
        this.arAnchorManager!.removeAnchor(newAnchor);
        print("❌ Failed to add duck node");
      }
    } else {
      print("❌ Failed to add plane anchor");
    }
  }

  void _toggleAutoPlacement() {
    setState(() {
      _autoPlacementMode = !_autoPlacementMode;
      print("🔄 Auto placement mode: $_autoPlacementMode");
    });
    
    // Show a clear message about the current mode
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_autoPlacementMode 
          ? "🔍 AUTO MODE: Tap any plane to place duck automatically!"
          : "🎯 NORMAL MODE: Tap plane to place duck normally"),
        backgroundColor: _autoPlacementMode ? Colors.green : Colors.blue,
        duration: Duration(seconds: 2),
      )
    );
  }

  onRemoveEverything() async {
    print("🧹 Removing everything...");
    for (var anchor in this.anchors) {
      this.arAnchorManager!.removeAnchor(anchor);
    }
    this.anchors = [];
    for (var node in this.nodes) {
      this.arObjectManager!.removeNode(node);
    }
    this.nodes = [];
    print("✅ Everything removed!");
  }
}