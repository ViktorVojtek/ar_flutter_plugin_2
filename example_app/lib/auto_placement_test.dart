import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';  
import 'package:ar_flutter_plugin_2/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_2/models/ar_node.dart';
import 'package:ar_flutter_plugin_2/models/ar_hittest_result.dart';
import 'package:ar_flutter_plugin_2/datatypes/node_types.dart';
import 'package:ar_flutter_plugin_2/datatypes/config_planedetection.dart';
import 'package:vector_math/vector_math_64.dart' as vm;
import 'package:flutter/material.dart';

class AutoPlacementTestScreen extends StatefulWidget {
  @override
  _AutoPlacementTestScreenState createState() => _AutoPlacementTestScreenState();
}

class _AutoPlacementTestScreenState extends State<AutoPlacementTestScreen> {
  ARSessionManager? arSessionManager;
  ARObjectManager? arObjectManager;
  ARLocationManager? arLocationManager;
  ARAnchorManager? arAnchorManager;

  List<ARNode> nodes = <ARNode>[];
  bool _isARInitialized = false;
  String _statusText = "Initializing AR...";

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Auto Placement Test"),
        backgroundColor: Colors.blue,
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
                color: Colors.black54,
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
          // Controls at bottom
          Positioned(
            bottom: 50,
            left: 20,
            right: 20,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(
                  onPressed: _isARInitialized ? _placeObjectAutomatically : null,
                  child: Text("Auto Place"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                  ),
                ),
                ElevatedButton(
                  onPressed: nodes.isNotEmpty ? _removeAllObjects : null,
                  child: Text("Remove All"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
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
      _statusText = "AR managers created, initializing session...";
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

      // Set up gesture handlers for pan and rotation
      arObjectManager!.onPanStart = (String nodeName) {
        print("🔥 Pan started on node: $nodeName");
        setState(() {
          _statusText = "Panning object: $nodeName";
        });
      };

      arObjectManager!.onPanChange = (String nodeName) {
        print("🔥 Pan changing on node: $nodeName");
      };

      arObjectManager!.onPanEnd = (String nodeName, Matrix4 transform) {
        print("🔥 Pan ended on node: $nodeName");
        setState(() {
          _statusText = "Pan gesture completed on: $nodeName";
        });
      };

      arObjectManager!.onRotationStart = (String nodeName) {
        print("🔥 Rotation started on node: $nodeName");
        setState(() {
          _statusText = "Rotating object: $nodeName";
        });
      };

      arObjectManager!.onRotationChange = (String nodeName) {
        print("🔥 Rotation changing on node: $nodeName");
      };

      arObjectManager!.onRotationEnd = (String nodeName, Matrix4 transform) {
        print("🔥 Rotation ended on node: $nodeName");
        setState(() {
          _statusText = "Rotation gesture completed on: $nodeName";
        });
      };

      arObjectManager!.onNodeTap = (List<String> nodeNames) {
        print("🔥 Node tapped: $nodeNames");
        setState(() {
          _statusText = "Tapped on: ${nodeNames.join(', ')}";
        });
      };

      // Set up plane/point tap handler for AR session manager
      arSessionManager!.onPlaneOrPointTap = (List<ARHitTestResult> hits) {
        print("🔥 Plane or point tapped with ${hits.length} hit results");
        for (var hit in hits) {
          print("🔥 Hit result type: ${hit.type}, distance: ${hit.distance}");
        }
        setState(() {
          _statusText = "Tapped on plane/point with ${hits.length} hits";
        });
      };

      setState(() {
        _isARInitialized = true;
        _statusText = "AR initialized. Tap 'Auto Place' to test automatic placement.";
      });

      print("✅ AR initialization completed");
      
      // Wait a moment for AR to stabilize, then test auto placement
      await Future.delayed(Duration(seconds: 2));
      
      setState(() {
        _statusText = "AR ready for automatic placement testing!";
      });
      
    } catch (e) {
      print("❌ Error initializing AR: $e");
      setState(() {
        _statusText = "Error initializing AR: $e";
      });
    }
  }

  Future<void> _placeObjectAutomatically() async {
    if (!_isARInitialized || arObjectManager == null) {
      print("❌ AR not initialized or object manager not available");
      return;
    }

    setState(() {
      _statusText = "Placing object automatically...";
    });

    try {
      print("🎯 Testing automatic object placement on Android ARCore");
      
      // Create a node with a specific position (in front of the camera)
  // Place 1m in front of the camera, keep Y at camera height for visibility
  vm.Vector3 autoPosition = vm.Vector3(0.0, 0.0, -1.0);
      
      // Create transformation matrix for the position
      Matrix4 transformation = Matrix4.identity();
      transformation.setTranslationRaw(autoPosition.x, autoPosition.y, autoPosition.z);
      
      String nodeName = "AutoPlacedDuck_${DateTime.now().millisecondsSinceEpoch}";
      
      ARNode node = ARNode(
        type: NodeType.webGLB,
        uri: "https://github.com/KhronosGroup/glTF-Sample-Models/raw/refs/heads/main/2.0/Duck/glTF-Binary/Duck.glb",
        name: nodeName,
        transformation: transformation,
        scale: vm.Vector3(0.5, 0.5, 0.5), // Visible at 1m distance
        isTransformable: true,
        // Use built-in pan with native fallback for small model reliability
        enablePanGestures: false,
        enableRotationGestures: true,
      );

      print("📦 Created ARNode: $nodeName");
      print("📍 Position: $autoPosition");
      print("📏 Scale: ${node.scale}");
      
      // THE KEY TEST: Call addNode WITHOUT planeAnchor - this should now work on Android!
      String? result = await arObjectManager!.addNode(node);
      
      if (result != null) {
        print("✅ AUTO PLACEMENT SUCCESS! Node ID: $result");
        nodes.add(node);
        setState(() {
    _statusText = "✅ Auto placement successful! Object is ~1m in front. Drag to pan, twist to rotate.";
        });
      } else {
        print("❌ AUTO PLACEMENT FAILED! addNode returned null");
        setState(() {
          _statusText = "❌ Auto placement failed - addNode returned null";
        });
      }
      
    } catch (e) {
      print("❌ Exception during auto placement: $e");
      setState(() {
        _statusText = "❌ Auto placement error: $e";
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
        _statusText = "All objects removed. Ready for new auto placement test.";
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
