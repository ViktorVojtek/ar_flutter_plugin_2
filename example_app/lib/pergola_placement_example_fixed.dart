import 'package:flutter/material.dart';
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

class PergolePlacementExample extends StatefulWidget {
  @override
  _PergolePlacementExampleState createState() => _PergolePlacementExampleState();
}

class _PergolePlacementExampleState extends State<PergolePlacementExample> {
  ARSessionManager? arSessionManager;
  ARObjectManager? arObjectManager;
  ARLocationManager? arLocationManager;
  ARAnchorManager? arAnchorManager;

  List<ARNode> nodes = <ARNode>[];
  List<ARAnchor> anchors = <ARAnchor>[];
  String _statusText = "Select an object type, then tap on a surface to place it";
  
  // What object to place when user taps
  String _selectedObjectType = "MEDIUM";
  vm.Vector3 _selectedObjectScale = vm.Vector3(0.6, 0.6, 0.6);
  String _selectedObjectLabel = "Medium Test";
  String _selectedObjectUri = "https://github.com/KhronosGroup/glTF-Sample-Models/raw/refs/heads/main/2.0/Duck/glTF-Binary/Duck.glb";

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Pergola Smart Placement Test"),
        backgroundColor: Colors.orange,
      ),
      body: Stack(
        children: [
          // AR View
          ARView(
            onARViewCreated: _onARViewCreated,
            planeDetectionConfig: PlaneDetectionConfig.horizontal,
          ),
          // Status Overlay
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
          // Placement Controls
          Positioned(
            bottom: 50,
            left: 20,
            right: 20,
            child: Column(
              children: [
                Text(
                  "Smart Placement Demo - Select then Tap to Place",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    shadows: [Shadow(color: Colors.black, offset: Offset(1, 1))],
                  ),
                ),
                SizedBox(height: 15),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildSizeTestButton("SMALL Test", "SMALL", vm.Vector3(0.3, 0.3, 0.3)),
                    _buildSizeTestButton("MEDIUM Test", "MEDIUM", vm.Vector3(0.6, 0.6, 0.6)),
                  ],
                ),
                SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildPergolaButton("Real Pergola", "BIG", vm.Vector3(1.0, 1.0, 1.0)),
                    _buildSizeTestButton("HUGE Test", "BIG", vm.Vector3(1.5, 1.5, 1.5)),
                  ],
                ),
                SizedBox(height: 10),
                // Current selection indicator
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.8),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    "Selected: ${_selectedObjectLabel}",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
                SizedBox(height: 15),
                ElevatedButton(
                  onPressed: _removeAllObjects,
                  child: Text("Clear All Objects"),
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

  Widget _buildSizeTestButton(String label, String sizeType, vm.Vector3 scale) {
    bool isSelected = _selectedObjectType == sizeType && _selectedObjectLabel == label;
    return ElevatedButton(
      onPressed: () => _selectObject(label, sizeType, scale, "https://github.com/KhronosGroup/glTF-Sample-Models/raw/refs/heads/main/2.0/Duck/glTF-Binary/Duck.glb"),
      child: Text(label, style: TextStyle(fontSize: 12)),
      style: ElevatedButton.styleFrom(
        backgroundColor: isSelected ? Colors.yellow : _getSizeColor(sizeType),
        foregroundColor: isSelected ? Colors.black : Colors.white,
        minimumSize: Size(80, 45),
      ),
    );
  }

  Widget _buildPergolaButton(String label, String sizeType, vm.Vector3 scale) {
    bool isSelected = _selectedObjectType == sizeType && _selectedObjectLabel == label;
    return ElevatedButton(
      onPressed: () => _selectObject(label, sizeType, scale, "https://storage.googleapis.com/vd_ar_bucket/Pergola_Eva_450cm_pivottest_1-d02c09c2-bcec-490f-9452-feca8da064e5.glb"),
      child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
      style: ElevatedButton.styleFrom(
        backgroundColor: isSelected ? Colors.yellow : Colors.green,
        foregroundColor: isSelected ? Colors.black : Colors.white,
        minimumSize: Size(80, 45),
      ),
    );
  }

  Color _getSizeColor(String sizeType) {
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
      _statusText = "AR initialized. Select an object type and tap on a surface to place it with smart spacing!";
    });

    _initializeAR();
  }

  void _initializeAR() async {
    try {
      await arSessionManager!.onInitialize(
        showPlanes: true, // Enable plane visualization for tap detection
        showWorldOrigin: false,
        handlePans: true,
        handleRotation: true,
      );
      await arObjectManager!.onInitialize();

      // Set up plane/point tap handler for object placement
      arSessionManager!.onPlaneOrPointTap = _onPlaneOrPointTapped;

      arObjectManager!.onNodeTap = (List<String> nodeNames) {
        print("🔥 Node tapped: $nodeNames");
        setState(() {
          _statusText = "Tapped on: ${nodeNames.join(', ')} - Select object type and tap plane to place more";
        });
      };

    } catch (e) {
      print("❌ Error initializing AR: $e");
      setState(() {
        _statusText = "Error initializing AR: $e";
      });
    }
  }

  // Handle plane/point taps for placing objects
  Future<void> _onPlaneOrPointTapped(List<ARHitTestResult> hitTestResults) async {
    print("🎯 Plane tapped! Hit test results: ${hitTestResults.length}");
    
    if (hitTestResults.isEmpty) {
      setState(() {
        _statusText = "No surface detected - move device to detect planes";
      });
      return;
    }
    
    // Find the first plane hit result
    ARHitTestResult? planeHitTestResult;
    try {
      planeHitTestResult = hitTestResults.firstWhere(
        (hitTestResult) => hitTestResult.type == ARHitTestResultType.plane,
      );
    } catch (e) {
      planeHitTestResult = hitTestResults.first;
    }
    
    // Create anchor at the tapped position
    var newAnchor = ARPlaneAnchor(transformation: planeHitTestResult.worldTransform);
    bool? didAddAnchor = await arAnchorManager!.addAnchor(newAnchor);
    
    if (didAddAnchor == true) {
      anchors.add(newAnchor);
      
      // Calculate smart offset based on object size
      vm.Vector3 smartOffset = _calculateSmartOffset(_selectedObjectType);
      
      var newNode = ARNode(
        type: NodeType.webGLB,
        uri: _selectedObjectUri,
        name: "${_selectedObjectType}_${DateTime.now().millisecondsSinceEpoch}",
        scale: _selectedObjectScale,
        position: smartOffset, // Smart positioning relative to anchor
        isTransformable: true,
        enablePanGestures: true,
        enableRotationGestures: true,
      );
      
      print("📍 Placing ${_selectedObjectLabel} with smart offset: $smartOffset");
      
      String? nodeId = await arObjectManager!.addNode(newNode, planeAnchor: newAnchor);
      
      if (nodeId != null) {
        nodes.add(newNode);
        setState(() {
          _statusText = "✅ ${_selectedObjectLabel} placed! Tap surface to place another";
        });
        print("✅ SUCCESS: ${_selectedObjectLabel} placed with ID: $nodeId");
      } else {
        setState(() {
          _statusText = "❌ Failed to place ${_selectedObjectLabel}";
        });
      }
    }
  }
  
  // Calculate smart positioning offset based on object type
  vm.Vector3 _calculateSmartOffset(String objectType) {
    switch (objectType.toUpperCase()) {
      case 'BIG':
        return vm.Vector3(0.0, 0.0, 2.0); // 2m forward from tap point for large objects
      case 'SMALL':
        return vm.Vector3(0.0, 0.0, 0.5); // 0.5m forward from tap point for small objects
      case 'MEDIUM':
      default:
        return vm.Vector3(0.0, 0.0, 1.0); // 1m forward from tap point for medium objects
    }
  }
  
  // Select what object will be placed when user taps
  void _selectObject(String label, String sizeType, vm.Vector3 scale, String uri) {
    setState(() {
      _selectedObjectType = sizeType;
      _selectedObjectScale = scale;
      _selectedObjectLabel = label;
      _selectedObjectUri = uri;
      _statusText = "Selected: $label - Now tap on a surface to place it with smart spacing";
    });
    print("🎯 Selected: $label ($sizeType) for tap-to-place");
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
        _statusText = "All objects removed. Select an object type and tap to place new ones.";
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
