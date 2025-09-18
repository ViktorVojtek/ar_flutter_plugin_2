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
      'name': 'FlightHelmet',
      'url': 'https://github.com/KhronosGroup/glTF-Sample-Models/raw/refs/heads/main/2.0/FlightHelmet/glTF-Binary/FlightHelmet.glb',
      'scale': 0.2,
      'position': [0.0, -0.8, -1.2], // Front higher
    },
  ];

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
                  if (nodes.isNotEmpty) ...[
                    SizedBox(height: 4),
                    Text(
                      "Models: ${nodes.map((n) => n.name.split('_')[0]).join(', ')}",
                      style: TextStyle(color: Colors.white60, fontSize: 12),
                    ),
                    SizedBox(height: 4),
                    if (_selectedNodeName != null) ...[
                      Text(
                        "🎯 Selected: ${_selectedNodeName!.split('_')[0]}",
                        style: TextStyle(color: Colors.green, fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 4),
                      Text(
                        "💡 Tap empty space to deselect",
                        style: TextStyle(color: Colors.yellow, fontSize: 12),
                      ),
                    ] else ...[
                      Text(
                        "💡 Tap objects to select, drag to move/rotate",
                        style: TextStyle(color: Colors.yellow, fontSize: 12),
                      ),
                    ],
                  ],
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
                  onPressed: _isARInitialized ? _placeNextModel : null,
                  child: Text(_getNextButtonText()),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                  ),
                ),
                // ALWAYS show deselect button when object is selected, make it prominent
                if (_selectedNodeName != null) ...[
                  ElevatedButton(
                    onPressed: _deselectCurrentObject,
                    child: Text("🔄 DESELECT"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    ),
                  ),
                  ElevatedButton(
                    onPressed: _testManualDeselection,
                    child: Text("⚡ Force Deselect"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.purple,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                  ),
                ],
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
        if (nodeNames.isNotEmpty) {
          print("🔍 DEBUG: Setting _selectedNodeName from '${_selectedNodeName}' to '${nodeNames.first}'");
          setState(() {
            _selectedNodeName = nodeNames.first;
            _statusText = "Selected: ${nodeNames.join(', ')}";
          });
          print("🔍 DEBUG: After setState - _selectedNodeName = '$_selectedNodeName'");
        } else {
          print("⚠️ Node tap received but nodeNames list is empty");
        }
      };

      // Set up plane/point tap handler for AR session manager
      arSessionManager!.onPlaneOrPointTap = (List<ARHitTestResult> hits) {
        print("🔥 Plane or point tapped with ${hits.length} hit results");
        print("🔍 DEBUG: Current _selectedNodeName = '$_selectedNodeName'");
        for (var hit in hits) {
          print("🔥 Hit result type: ${hit.type}, distance: ${hit.distance}");
        }
        
        // DESELECTION LOGIC: When tapping empty space, deselect any selected object
        if (_selectedNodeName != null) {
          print("🔥 Deselecting object: $_selectedNodeName");
          _deselectCurrentObject();
        } else {
          print("⚠️ No object selected - _selectedNodeName is null, cannot deselect");
        }
        
        setState(() {
          _statusText = "Tapped on plane/point with ${hits.length} hits${_selectedNodeName != null ? ' - deselecting' : ' - no selection'}";
        });
      };

      // ADDITIONAL: Set up a periodic check to see if we should trigger deselection
      // This is a workaround for the touch event issues
      print("✅ AR initialization completed - deselection setup ready");

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

  String _getNextButtonText() {
    if (nodes.isEmpty) {
      return "Place ${_testModels[0]['name']}";
    }
    int nextIndex = _modelIndex % _testModels.length;
    return "Place ${_testModels[nextIndex]['name']} (${nodes.length + 1})";
  }

  /// Deselect the currently selected object
  Future<void> _deselectCurrentObject() async {
    print("🔄 _deselectCurrentObject called - _selectedNodeName: '$_selectedNodeName', arObjectManager: ${arObjectManager != null}");
    
    if (_selectedNodeName == null || arObjectManager == null) {
      print("⚠️ Cannot deselect - _selectedNodeName: '$_selectedNodeName', arObjectManager: ${arObjectManager != null}");
      return;
    }

    try {
      print("🔄 Deselecting object: $_selectedNodeName");
      
      // Use the deselectAllNodes method from ARObjectManager
      bool success = await arObjectManager!.deselectAllNodes();
      
      if (success) {
        print("✅ Successfully deselected object: $_selectedNodeName");
      } else {
        print("⚠️ Deselection call completed but success status unclear");
      }
      
      setState(() {
        final previousSelection = _selectedNodeName;
        _selectedNodeName = null;
        _statusText = "Object deselected - no object currently selected";
        print("🔄 setState completed - previous: '$previousSelection', current: '$_selectedNodeName'");
      });
      
    } catch (e) {
      print("❌ Error during deselection: $e");
      // Clear selection state anyway
      setState(() {
        final previousSelection = _selectedNodeName;
        _selectedNodeName = null;
        _statusText = "Deselection error, but cleared selection state";
        print("🔄 Error setState completed - previous: '$previousSelection', current: '$_selectedNodeName'");
      });
    }
  }

  /// Test function to manually trigger deselection via plane/point tap simulation
  Future<void> _testManualDeselection() async {
    print("🧪 Testing manual deselection via simulated empty space tap");
    
    // Simulate an empty space tap by calling the same logic as onPlaneOrPointTap
    if (_selectedNodeName != null) {
      print("🔥 Simulating deselection for object: $_selectedNodeName");
      await _deselectCurrentObject();
    } else {
      print("⚠️ No object currently selected for deselection test");
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
          _statusText = "✅ $modelName placed! Total models: ${nodes.length}. Try gestures on different models.";
        });
      } else {
        print("❌ PLACEMENT FAILED! addNode returned null for $modelName");
        setState(() {
          _statusText = "❌ $modelName placement failed - addNode returned null";
        });
      }
      
    } catch (e) {
      print("❌ Exception during $modelName placement: $e");
      setState(() {
        _statusText = "❌ $modelName placement error: $e";
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
        _selectedNodeName = null; // Clear selection when removing all objects
        _statusText = "All objects removed. Ready for new auto placement test.";
      });
      
    } catch (e) {
      print("❌ Error removing objects: $e");
      setState(() {
        _selectedNodeName = null; // Clear selection even on error
        _statusText = "Error removing objects: $e";
      });
    }
  }

  Future<void> _performNonBlockingCleanup() async {
    try {
      print('🔄 Starting non-blocking cleanup to prevent camera freeze...');
      
      final success = await arSessionManager?.nukeAllNonBlocking(
        purgeCaches: true,
        removeExistingAnchors: true,
        resetTracking: false, // Keep camera active
      );
      
      if (success == true) {
        print('✅ Non-blocking cleanup completed - camera should stay active');
      } else {
        print('⚠️ Non-blocking cleanup failed - using fallback');
        // Fallback to basic cleanup without session pause
        await _removeAllObjects();
      }
    } catch (e) {
      print('❌ Cleanup error: $e');
    }
    
    // Standard disposal
    await arSessionManager?.dispose();
  }

  @override
  void dispose() {
    _performNonBlockingCleanup();
    super.dispose();
  }
}
