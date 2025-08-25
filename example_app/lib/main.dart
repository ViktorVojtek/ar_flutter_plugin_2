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

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AR Flutter Plugin Example',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: ObjectGestures(),
    );
  }
}

class ObjectGestures extends StatefulWidget {
  @override
  State<ObjectGestures> createState() => _ObjectGesturesState();
}

class _ObjectGesturesState extends State<ObjectGestures> {
  ARSessionManager? arSessionManager;
  ARObjectManager? arObjectManager;
  ARAnchorManager? arAnchorManager;

  List<ARNode> nodes = [];
  List<ARAnchor> anchors = [];

  @override
  void dispose() {
    super.dispose();
    arSessionManager?.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AR Avocado Placement - Tap to Place'),
      ),
      body: Stack(
        children: [
          ARView(
            onARViewCreated: onARViewCreated,
            planeDetectionConfig: PlaneDetectionConfig.horizontal,
          ),
          Align(
            alignment: FractionalOffset.bottomCenter,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // Only remove everything button
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton(
                      onPressed: onRemoveEverything,
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                      child: Text("Remove All Avocados")
                    ),
                  ]
                ),
                SizedBox(height: 20),
              ]
            ),
          )
        ]
      )
    );
  }

  void onARViewCreated(
      ARSessionManager arSessionManager,
      ARObjectManager arObjectManager,
      ARAnchorManager arAnchorManager,
      ARLocationManager arLocationManager) {
    print("🚀🚀🚀 FLUTTER: onARViewCreated called!");
    this.arSessionManager = arSessionManager;
    this.arObjectManager = arObjectManager;
    this.arAnchorManager = arAnchorManager;

    this.arSessionManager!.onInitialize(
      showFeaturePoints: false,
      showPlanes: true, // Enable plane visualization
      showWorldOrigin: false,
      handlePans: true,
      handleRotation: true,
    );
    this.arObjectManager!.onInitialize();

    this.arSessionManager!.onPlaneOrPointTap = onPlaneOrPointTapped;
    print("🎯🎯🎯 FLUTTER: Callback set! Function: $onPlaneOrPointTapped");
    
    // Add other callbacks as needed...
  }

  Future<void> onRemoveEverything() async {
    debugPrint("AR_DEBUG: 🧹 Removing all objects and anchors...");
    
    // Remove all nodes first
    for (var node in nodes) {
      // await this.arObjectManager!.removeNode(node);
      await this.arObjectManager!.removeNodeDeep(node.name);
    }
    nodes.clear();
    
    // Then remove all anchors
    for (var anchor in anchors) {
      await this.arAnchorManager!.removeAnchor(anchor);
    }
    anchors.clear();
    
    debugPrint("AR_DEBUG: ✅ Removed all objects and anchors. Nodes: ${nodes.length}, Anchors: ${anchors.length}");
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("All objects removed"))
    );
  }

  Future<void> onPlaneOrPointTapped(List<ARHitTestResult> hitTestResults) async {
    print("🎯🎯🎯 FLUTTER: onPlaneOrPointTapped called with ${hitTestResults.length} results");
    debugPrint("AR_DEBUG: 🎯 Plane tapped! Hit test results: ${hitTestResults.length}");
    debugPrint("AR_DEBUG: 🥑 Placing Avocado model...");
    
    // Find the first plane hit result
    ARHitTestResult? planeHitTestResult;
    try {
      planeHitTestResult = hitTestResults.firstWhere(
        (hitTestResult) => hitTestResult.type == ARHitTestResultType.plane,
      );
      debugPrint("AR_DEBUG: ✅ Found plane hit result: ${planeHitTestResult.type}");
    } catch (e) {
      debugPrint("AR_DEBUG: ⚠️ No plane hit result found, using first result");
      planeHitTestResult = hitTestResults.isNotEmpty ? hitTestResults.first : null;
    }
    
    if (planeHitTestResult != null) {
      debugPrint("AR_DEBUG: 📍 Creating anchor at position...");
      // Create a new anchor at the tapped position
      var newAnchor = ARPlaneAnchor(transformation: planeHitTestResult.worldTransform);
      bool? didAddAnchor = await this.arAnchorManager!.addAnchor(newAnchor);
      
      debugPrint("AR_DEBUG: 🔗 Add anchor result: $didAddAnchor");
      
      if (didAddAnchor == true) {
        this.anchors.add(newAnchor);
        debugPrint("AR_DEBUG: ✅ Anchor added successfully, total anchors: ${anchors.length}");
        
        // Create Avocado node with gesture support enabled
        var newNode = ARNode(
          type: NodeType.webGLB,
          uri: "https://github.com/KhronosGroup/glTF-Sample-Models/raw/refs/heads/main/2.0/Avocado/glTF-Binary/Avocado.glb",
          scale: vector_math.Vector3(3.0, 3.0, 3.0),
          position: vector_math.Vector3(0.0, 0.0, -0.5),
          rotation: vector_math.Vector4(1.0, 0.0, 0.0, 0.0), // No rotation
          isTransformable: true,        // Enable transformations
          enablePanGestures: true,      // Enable pan (drag) gestures  
          enableRotationGestures: true, // Enable rotation gestures
        );
        
        debugPrint("AR_DEBUG: 🥑 Creating Avocado node...");
        debugPrint("AR_DEBUG: 📊 Avocado details - URI: Avocado.glb, Type: webGLB, Scale: (10.0, 10.0, 10.0)");
        
        // Add the node to the anchor
        String? nodeId = await this.arObjectManager!.addNode(newNode, planeAnchor: newAnchor);
        
        debugPrint("AR_DEBUG: 🔗 Add node result: $nodeId");
        
        if (nodeId != null) {
          this.nodes.add(newNode);
          debugPrint("AR_DEBUG: ✅ Avocado added successfully with ID: $nodeId, total nodes: ${nodes.length}");
          
          // Show success message to user
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("🥑 Avocado placed! ID: $nodeId"), 
              duration: Duration(seconds: 2),
              backgroundColor: Colors.green,
            )
          );
        } else {
          debugPrint("AR_DEBUG: ❌ Failed to add Avocado to anchor");
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Failed to place Avocado"), backgroundColor: Colors.red, duration: Duration(seconds: 3))
          );
        }
      } else {
        debugPrint("AR_DEBUG: ❌ Failed to create anchor");
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Failed to create anchor"), backgroundColor: Colors.red, duration: Duration(seconds: 3))
        );
      }
    } else {
      debugPrint("AR_DEBUG: ❌ No hit test result found");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("No surface detected"), backgroundColor: Colors.red, duration: Duration(seconds: 3))
      );
    }
  }
}