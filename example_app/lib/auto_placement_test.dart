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
  int _modelIndex = 0; // Track which model to place next
  String? _selectedNodeName; // Track currently selected object
  
  // Different models to test with
  final List<Map<String, dynamic>> _testModels = [
    {
      'name': 'Duck',
      'url': 'https://github.com/KhronosGroup/glTF-Sample-Models/raw/refs/heads/main/2.0/Duck/glTF-Binary/Duck.glb',
      'scale': 0.5,
      'position': [0.0, -1.2, -0.8], // Front center
    },
    {
      'name': 'Avocado',
      'url': 'https://github.com/KhronosGroup/glTF-Sample-Models/raw/refs/heads/main/2.0/Avocado/glTF-Binary/Avocado.glb',
      'scale': 0.3,
      'position': [0.5, -1.0, -1.0], // Right side
    },
    {
      'name': 'DamagedHelmet',
      'url': 'https://github.com/KhronosGroup/glTF-Sample-Models/raw/refs/heads/main/2.0/DamagedHelmet/glTF-Binary/DamagedHelmet.glb',
      'scale': 0.4,
      'position': [-0.5, -1.0, -1.0], // Left side
    },
    {
      'name': 'Lantern',
      'url': 'https://github.com/KhronosGroup/glTF-Sample-Models/raw/refs/heads/main/2.0/Lantern/glTF-Binary/Lantern.glb',
      'scale': 0.6,
      'position': [0.0, -0.8, -1.5], // Back center
    },
  ];

  @override
  void initState() {
    super.initState();
    print("🔧 AutoPlacement test screen initializing...");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Auto Placement Test'),
        backgroundColor: Colors.orange,
      ),
      body: Container(
        child: Stack(
          children: [
            ARView(
              onARViewCreated: onARViewCreated,
              planeDetectionConfig: PlaneDetectionConfig.horizontal,
            ),
            // Status overlay
            Positioned(
              top: 20,
              left: 20,
              right: 20,
              child: Container(
                padding: EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'AR Auto Placement Test',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      _statusText,
                      style: TextStyle(color: Colors.white, fontSize: 14),
                    ),
                    if (_selectedNodeName != null) ...[
                      SizedBox(height: 4),
                      Text(
                        'Selected: $_selectedNodeName',
                        style: TextStyle(color: Colors.green, fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // Control buttons
            Positioned(
              bottom: 100,
              left: 20,
              right: 20,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton(
                    onPressed: _isARInitialized ? _placeNextModel : null,
                    child: Text('Place Model'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      foregroundColor: Colors.white,
                    ),
                  ),
                  ElevatedButton(
                    onPressed: _isARInitialized && nodes.isNotEmpty ? _removeAllObjects : null,
                    child: Text('Clear All'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
            // Model info
            Positioned(
              bottom: 20,
              left: 20,
              right: 20,
              child: Container(
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.8),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Objects: ${nodes.length} | Next: ${_testModels[_modelIndex % _testModels.length]['name']}',
                  style: TextStyle(color: Colors.white, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ),
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
    ARLocationManager arLocationManager
  ) {
    print("🚀 ARView created, initializing managers...");
    
    this.arSessionManager = arSessionManager;
    this.arObjectManager = arObjectManager;
    this.arAnchorManager = arAnchorManager;
    this.arLocationManager = arLocationManager;

    _initializeARSession();
  }

  Future<void> _initializeARSession() async {
    if (arSessionManager == null) {
      print("❌ Session manager is null, cannot initialize");
      return;
    }
    
    try {
      print("⚙️ Initializing AR session with auto placement configuration...");
      
      await arSessionManager!.onInitialize(
        showPlanes: true, // HYBRID SOLUTION: Enable for hit detection, Android will handle gesture conflicts
        customPlaneTexturePath: null, // Invisible planes
        handlePans: true,
        handleRotation: true,
        showWorldOrigin: false, // Reduce visual noise
        showAnimatedGuide: false,
      );
      
      print("✅ AR session initialized successfully");
      
      await arObjectManager!.onInitialize();
      print("✅ Object manager initialized");
      
      // Set up node selection handler
      arObjectManager!.onNodeTap = _onNodeTapped;
      print("🎯 Node tap handler set up");
      
      setState(() {
        _isARInitialized = true;
        _statusText = "AR Ready! Tap 'Place Model' to auto-place objects";
      });
      
      print("🎉 Auto placement test ready!");
      
    } catch (e) {
      print("❌ Error during AR initialization: $e");
      setState(() {
        _statusText = "AR initialization failed: $e";
      });
    }
  }

  Future<void> _placeNextModel() async {
    if (!_isARInitialized || arObjectManager == null) {
      print("❌ AR not initialized or object manager not available");
      return;
    }

    // Get the current model to place
    Map<String, dynamic> currentModel = _testModels[_modelIndex % _testModels.length];
    String modelName = currentModel['name'];
    String modelUrl = currentModel['url'];
    double modelScale = currentModel['scale'];
    List<double> position = List<double>.from(currentModel['position']);

    setState(() {
      _statusText = "Placing $modelName (${nodes.length + 1})...";
    });

    try {
      print("🎯 Testing placement of $modelName on Android ARCore");
      
      // Create a node with the specific model's position and scale
      vm.Vector3 autoPosition = vm.Vector3(position[0], position[1], position[2]);
      
      // Create transformation matrix for the position
      Matrix4 transformation = Matrix4.identity();
      transformation.setTranslationRaw(autoPosition.x, autoPosition.y, autoPosition.z);
      
      String nodeName = "${modelName}_${DateTime.now().millisecondsSinceEpoch}";
      
      ARNode node = ARNode(
        type: NodeType.webGLB,
        uri: modelUrl,
        name: nodeName,
        transformation: transformation,
        scale: vm.Vector3(modelScale, modelScale, modelScale),
        isTransformable: true,
        enablePanGestures: true,
        enableRotationGestures: true,
      );

      print("📦 Created ARNode: $nodeName");
      print("📍 Position: $autoPosition");
      print("📏 Scale: ${node.scale}");
      print("🌐 URL: $modelUrl");
      
      // Place the model
      String? result = await arObjectManager!.addNode(node);
      
      if (result != null) {
        print("✅ PLACEMENT SUCCESS! Node ID: $result for $modelName");
        nodes.add(node);
        
        // Move to next model for next placement
        _modelIndex++;
        
        setState(() {
          _statusText = "Placed $modelName! Total: ${nodes.length} objects";
        });
      } else {
        print("❌ PLACEMENT FAILED for $modelName");
        setState(() {
          _statusText = "Failed to place $modelName";
        });
      }
      
    } catch (e) {
      print("❌ Error placing $modelName: $e");
      setState(() {
        _statusText = "Error placing $modelName: $e";
      });
    }
  }

  void _onNodeTapped(List<String> nodeNames) {
    if (nodeNames.isNotEmpty) {
      String tappedNodeName = nodeNames.first;
      print("👆 Node tapped: $tappedNodeName");
      
      setState(() {
        if (_selectedNodeName == tappedNodeName) {
          _selectedNodeName = null; // Deselect if same node tapped
          print("🔄 Deselected node: $tappedNodeName");
        } else {
          _selectedNodeName = tappedNodeName; // Select new node
          print("🎯 Selected node: $tappedNodeName");
        }
      });
    }
  }

  Future<void> _removeAllObjects() async {
    if (arObjectManager == null) return;
    
    print("🧹 Removing all \${nodes.length} objects...");
    
    try {
      // Remove all nodes
      for (ARNode node in nodes) {
        await arObjectManager!.removeNode(node);
        print("🗑️ Removed node: \${node.name}");
      }
      
      setState(() {
        nodes.clear();
        _selectedNodeName = null;
        _statusText = "All objects removed";
        _modelIndex = 0; // Reset to first model
      });
      
      print("✅ All objects removed successfully");
      
    } catch (e) {
      print("❌ Error removing objects: \$e");
      setState(() {
        _statusText = "Error removing objects: \$e";
      });
    }
  }

  @override
  void dispose() {
    print("🧹 AutoPlacement test screen disposing...");
    arSessionManager?.dispose();
    super.dispose();
  }
}
