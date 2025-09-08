import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_2/models/ar_node.dart';
import 'package:ar_flutter_plugin_2/datatypes/node_types.dart';
import 'package:ar_flutter_plugin_2/datatypes/config_planedetection.dart';
import 'package:vector_math/vector_math_64.dart' as vm;
import 'package:flutter/material.dart';

class PergolaPlacementExample extends StatefulWidget {
  @override
  _PergolaPlacementExampleState createState() => _PergolaPlacementExampleState();
}

class _PergolaPlacementExampleState extends State<PergolaPlacementExample> {
  ARSessionManager? arSessionManager;
  ARObjectManager? arObjectManager;
  ARLocationManager? arLocationManager;
  ARAnchorManager? arAnchorManager;

  List<ARNode> nodes = [];
  String _statusText = "⏳ Initializing AR...";
  bool _isARInitialized = false;

  @override
  void dispose() {
    print("🧹 Pergola example: Disposing AR session");
    arSessionManager?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Enhanced Pergola Placement"),
        backgroundColor: Colors.green[700],
        foregroundColor: Colors.white,
      ),
      body: Stack(
        children: [
          // AR View - constrained to not cover buttons
          Positioned.fill(
            bottom: 180, // Leave space for buttons
            child: ARView(
              onARViewCreated: _onARViewCreated,
              planeDetectionConfig: PlaneDetectionConfig.horizontal,
            ),
          ),
          // Status overlay
          Positioned(
            top: 20,
            left: 20,
            right: 20,
            child: Container(
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _statusText,
                    style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                  ),
                  SizedBox(height: 8),
                  Text(
                    "Objects placed: ${nodes.length}",
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  if (_isARInitialized) ...[
                    SizedBox(height: 8),
                    Text(
                      "Tap buttons below to place pergolas",
                      style: TextStyle(color: Colors.green[300], fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          ),
          // Control panel - positioned above AR view
          Positioned(
            bottom: 20,
            left: 20,
            right: 20,
            child: Container(
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 8,
                    offset: Offset(0, -2),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    "Force Placement Test",
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.green[700],
                    ),
                  ),
                  SizedBox(height: 16),
                  
                  // Manual force placement buttons
                  ElevatedButton(
                    onPressed: () {
                      print("🎯🎯🎯 FORCE PLACE PERGOLA BUTTON PRESSED!");
                      _forcePlace();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.purple,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(vertical: 16, horizontal: 24),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: Text(
                      "FORCE PLACE\nPERGOLA",
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  
                  SizedBox(height: 12),
                  
                  // Clear button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: nodes.isNotEmpty ? _removeAllObjects : null,
                      icon: Icon(Icons.clear_all),
                      label: Text("Clear All"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _onARViewCreated(
      ARSessionManager arSessionManager,
      ARObjectManager arObjectManager,
      ARAnchorManager arAnchorManager,
      ARLocationManager arLocationManager) async {
    
    print("🚀 Pergola example: AR View created");
    
    this.arSessionManager = arSessionManager;
    this.arObjectManager = arObjectManager;
    this.arAnchorManager = arAnchorManager;
    this.arLocationManager = arLocationManager;

    try {
      // Initialize AR session
      this.arSessionManager!.onInitialize(
        showFeaturePoints: true,
        showPlanes: true,
        customPlaneTexturePath: "triangle.png",
        showWorldOrigin: true,
        handleTaps: true,
        handlePans: true,
        handleRotation: true,
      );
      
      this.arObjectManager!.onInitialize();

      // Set up object interaction callbacks
      arObjectManager!.onPanStart = (String nodeName) {
        print("🔥 Pan started on pergola: $nodeName");
        setState(() {
          _statusText = "Panning pergola: ${_getNodeDisplayName(nodeName)}";
        });
      };

      arObjectManager!.onPanEnd = (String nodeName, vm.Matrix4 transform) {
        print("🔥 Pan ended on pergola: $nodeName");
        setState(() {
          _statusText = "Moved pergola: ${_getNodeDisplayName(nodeName)}";
        });
      };

      arObjectManager!.onRotationStart = (String nodeName) {
        print("🔥 Rotation started on pergola: $nodeName");
        setState(() {
          _statusText = "Rotating pergola: ${_getNodeDisplayName(nodeName)}";
        });
      };

      arObjectManager!.onRotationEnd = (String nodeName, vm.Matrix4 transform) {
        print("🔥 Rotation ended on pergola: $nodeName");
        setState(() {
          _statusText = "Rotated pergola: ${_getNodeDisplayName(nodeName)}";
        });
      };

      arObjectManager!.onNodeTap = (List<String> nodeNames) {
        print("🔥 Pergola tapped: $nodeNames");
        if (nodeNames.isNotEmpty) {
          setState(() {
            _statusText = "Selected: ${_getNodeDisplayName(nodeNames.first)}";
          });
        }
      };

      setState(() {
        _isARInitialized = true;
        _statusText = "✅ AR ready! Tap 'FORCE PLACE PERGOLA' to test manual placement.";
      });

    } catch (e) {
      print("❌ Error initializing AR: $e");
      setState(() {
        _statusText = "❌ AR initialization failed: $e";
      });
    }
  }

  String _getNodeDisplayName(String nodeName) {
    if (nodeName.contains("pergola_small")) return "Small Pergola";
    if (nodeName.contains("pergola_medium")) return "Medium Pergola";
    if (nodeName.contains("pergola_big")) return "Big Pergola";
    return nodeName;
  }

  void _forcePlace() async {
    print("🎯🎯🎯 FLUTTER: Force place button pressed!");
    
    if (arObjectManager == null) {
      print("❌ ARObjectManager not initialized");
      setState(() {
        _statusText = "❌ AR not ready";
      });
      return;
    }

    try {
      setState(() {
        _statusText = "🚀 Force placing pergola 1 meter forward...";
      });

      // Create manual placement 1 meter forward from camera
      vm.Matrix4 cameraTransform = vm.Matrix4.identity();
      cameraTransform.setTranslation(vm.Vector3(0, 0, -1)); // 1 meter forward

      var newNode = ARNode(
        type: NodeType.webGLB,
        uri: "https://github.com/KhronosGroup/glTF-Sample-Models/raw/master/2.0/Duck/glTF-Binary/Duck.glb",
        scale: vm.Vector3(2.0, 2.0, 2.0),
        position: vm.Vector3(0, 0, -1), // 1 meter in front
        rotation: vm.Vector4(0, 0, 0, 1),
      );

      String? nodeId = await arObjectManager!.addNode(newNode);
      if (nodeId != null) {
        nodes.add(newNode);
        print("✅ FORCE PLACED: Pergola added at manual position with ID: $nodeId");
        setState(() {
          _statusText = "✅ Force placed pergola 1m forward! ID: $nodeId";
        });
      } else {
        print("❌ Failed to add pergola");
        setState(() {
          _statusText = "❌ Failed to place pergola";
        });
      }
    } catch (e) {
      print("❌ Error in force placement: $e");
      setState(() {
        _statusText = "❌ Error: $e";
      });
    }
  }

  void _removeAllObjects() async {
    print("🧹 Removing all pergolas");
    try {
      for (var node in nodes) {
        await arObjectManager!.removeNode(node);
      }
      setState(() {
        nodes.clear();
        _statusText = "🧹 All pergolas removed";
      });
    } catch (e) {
      print("❌ Error removing pergolas: $e");
    }
  }
}
