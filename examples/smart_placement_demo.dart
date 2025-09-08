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

class SmartPlacementExample extends StatefulWidget {
  @override
  _SmartPlacementExampleState createState() => _SmartPlacementExampleState();
}

class _SmartPlacementExampleState extends State<SmartPlacementExample> {
  ARSessionManager? arSessionManager;
  ARObjectManager? arObjectManager;
  ARLocationManager? arLocationManager;
  ARAnchorManager? arAnchorManager;

  List<ARNode> nodes = <ARNode>[];
  String _statusText = "Initializing AR for smart placement demo...";

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Smart Object Placement Demo"),
        backgroundColor: Colors.green,
      ),
      body: Stack(
        children: [
          // AR View
          ARView(
            onARViewCreated: _onARViewCreated,
            planeDetectionConfig: PlaneDetectionConfig.horizontal,
          ),
          // Status and Controls Overlay
          Positioned(
            top: 20,
            left: 20,
            right: 20,
            child: Container(
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _statusText,
                    style: TextStyle(color: Colors.white, fontSize: 16),
                  ),
                  SizedBox(height: 8),
                  Text(
                    "Objects placed: ${nodes.length}",
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ],
              ),
            ),
          ),
          // Object placement controls
          Positioned(
            bottom: 50,
            left: 20,
            right: 20,
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildObjectButton("Small Grill", "SMALL", vm.Vector3(0.5, 0.5, 0.5)),
                    _buildObjectButton("Medium Table", "MEDIUM", vm.Vector3(1.2, 0.8, 1.2)),
                  ],
                ),
                SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildObjectButton("Large Pergola", "BIG", vm.Vector3(3.0, 2.5, 3.0)),
                    _buildObjectButton("Huge Gazebo", "BIG", vm.Vector3(4.5, 3.0, 4.5)),
                  ],
                ),
                SizedBox(height: 10),
                ElevatedButton(
                  onPressed: _removeAllObjects,
                  child: Text("Clear All"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    minimumSize: Size(200, 45),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildObjectButton(String label, String sizeType, vm.Vector3 scale) {
    return ElevatedButton(
      onPressed: () => _placeObjectWithSmartPlacement(label, sizeType, scale),
      child: Text(label, textAlign: TextAlign.center),
      style: ElevatedButton.styleFrom(
        backgroundColor: _getButtonColor(sizeType),
        foregroundColor: Colors.white,
        minimumSize: Size(80, 45),
      ),
    );
  }

  Color _getButtonColor(String sizeType) {
    switch (sizeType) {
      case 'SMALL': return Colors.orange;
      case 'MEDIUM': return Colors.blue;
      case 'BIG': return Colors.green;
      default: return Colors.grey;
    }
  }

  void _onARViewCreated(
      ARSessionManager sessionManager,
      ARObjectManager objectManager,
      ARAnchorManager anchorManager,
      ARLocationManager locationManager) {
    
    setState(() {
      arSessionManager = sessionManager;
      arObjectManager = objectManager;
      arLocationManager = locationManager;
      arAnchorManager = anchorManager;
      _statusText = "AR initialized. Try placing objects with different sizes!";
    });

    _initializeAR();
  }

  void _initializeAR() async {
    try {
      await arSessionManager!.onInitialize(
        showPlanes: false,
        customPlaneTexturePath: null,
        showWorldOrigin: false,
        showFeaturePoints: false,
        handlePans: true,
        handleRotation: true,
      );

      await arObjectManager!.onInitialize();

      // Set up gesture handlers
      arObjectManager!.onPanStart = (String nodeName) {
        print("🔥 Pan started on node: $nodeName");
        setState(() {
          _statusText = "Panning object: $nodeName";
        });
      };

      arObjectManager!.onPanEnd = (String nodeName, vm.Matrix4 transform) {
        print("🔥 Pan ended on node: $nodeName");
        setState(() {
          _statusText = "Object moved: $nodeName";
        });
      };

      arObjectManager!.onRotationStart = (String nodeName) {
        print("🔥 Rotation started on node: $nodeName");
        setState(() {
          _statusText = "Rotating object: $nodeName";
        });
      };

      arObjectManager!.onNodeTap = (List<String> nodeNames) {
        print("🔥 Node tapped: $nodeNames");
        setState(() {
          _statusText = "Tapped on: ${nodeNames.join(', ')}";
        });
      };

    } catch (e) {
      print("❌ Error initializing AR: $e");
      setState(() {
        _statusText = "Error initializing AR: $e";
      });
    }
  }

  Future<void> _placeObjectWithSmartPlacement(String label, String sizeType, vm.Vector3 scale) async {
    if (arObjectManager == null) {
      print("❌ AR Object Manager not available");
      return;
    }

    setState(() {
      _statusText = "Placing $label with smart positioning...";
    });

    try {
      print("🎯 Placing $label (size: $sizeType) with smart placement");
      print("🎯 Object scale: $scale");
      
      String nodeName = "${sizeType}_${DateTime.now().millisecondsSinceEpoch}";
      
      ARNode node = ARNode(
        type: NodeType.webGLB,
        uri: "https://github.com/KhronosGroup/glTF-Sample-Models/raw/refs/heads/main/2.0/Duck/glTF-Binary/Duck.glb",
        name: nodeName,
        scale: scale, // This scale will be used by smart placement to determine optimal position
        isTransformable: true,
        enablePanGestures: true,
        enableRotationGestures: true,
      );

      print("📦 Created ARNode: $nodeName with scale: $scale");
      
      // Use the new smart placement method!
      String? result = await arObjectManager!.addNodeWithSmartPlacement(
        node,
        sizeType: sizeType, // Helps with placement calculation
      );
      
      if (result != null) {
        print("✅ SMART PLACEMENT SUCCESS! Node ID: $result");
        print("📍 Object placed at optimal distance for its size");
        nodes.add(node);
        setState(() {
          _statusText = "✅ $label placed! Scale: ${scale.length.toStringAsFixed(1)}m, optimized position";
        });
      } else {
        print("❌ SMART PLACEMENT FAILED!");
        setState(() {
          _statusText = "❌ Failed to place $label";
        });
      }
      
    } catch (e) {
      print("❌ Exception during smart placement: $e");
      setState(() {
        _statusText = "❌ Error placing $label: $e";
      });
    }
  }

  Future<void> _removeAllObjects() async {
    if (arObjectManager == null || nodes.isEmpty) return;

    setState(() {
      _statusText = "Removing all objects...";
    });

    try {
      for (ARNode node in nodes) {
        await arObjectManager!.removeNode(node);
      }
      
      nodes.clear();
      
      setState(() {
        _statusText = "All objects removed. Ready for new smart placement demo.";
      });
      
    } catch (e) {
      print("❌ Error removing objects: $e");
      setState(() {
        _statusText = "Error removing objects: $e";
      });
    }
  }

  @override
  void dispose() {
    arSessionManager?.dispose();
    super.dispose();
  }
}
