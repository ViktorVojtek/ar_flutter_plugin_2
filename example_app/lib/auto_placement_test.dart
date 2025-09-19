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
  List<String> _selectionEvents = []; // Track recent selection events for debugging
  String? _lastSelectionNodeId; // Track last selection to avoid duplicate events
  DateTime? _lastSelectionTime; // Track timing to filter rapid changes
  String? _lastDeselectedNode; // Track recently deselected node for UI feedback
  DateTime? _deselectionTime; // Track when deselection happened
  
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
            // PROMINENT Selection indicator at top center
            if (_selectedNodeName != null)
              Positioned(
                top: 60,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.green.withOpacity(0.95),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.5),
                          blurRadius: 8,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.radio_button_checked, color: Colors.white, size: 20),
                        SizedBox(width: 8),
                        Text(
                          'SELECTED: $_selectedNodeName',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(width: 8),
                        Icon(Icons.touch_app, color: Colors.white, size: 20),
                      ],
                    ),
                  ),
                ),
              ),
            // Deselection indicator
            if (_lastDeselectedNode != null && _deselectionTime != null)
              Positioned(
                top: 60,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.95),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.5),
                          blurRadius: 8,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.radio_button_unchecked, color: Colors.white, size: 20),
                        SizedBox(width: 8),
                        Text(
                          'DESELECTED: $_lastDeselectedNode',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(width: 8),
                        Icon(Icons.clear, color: Colors.white, size: 20),
                      ],
                    ),
                  ),
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
                      SizedBox(height: 8),
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.green.withOpacity(0.8),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.touch_app, color: Colors.white, size: 16),
                            SizedBox(width: 4),
                            Text(
                              'SELECTED: $_selectedNodeName',
                              style: TextStyle(
                                color: Colors.white, 
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        '✋ Pan & Rotate available | Tap again or empty space to deselect',
                        style: TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                    ],
                    // Selection events history
                    if (_selectionEvents.isNotEmpty) ...[
                      SizedBox(height: 8),
                      Container(
                        padding: EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.7),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '📝 Recent Selection Events:',
                              style: TextStyle(
                                color: Colors.white70, 
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            SizedBox(height: 4),
                            ...(_selectionEvents.take(5).map((event) => Padding(
                              padding: EdgeInsets.only(bottom: 2),
                              child: Text(
                                event,
                                style: TextStyle(
                                  color: Colors.white70, 
                                  fontSize: 10,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ))),
                          ],
                        ),
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
            // Model info and selection status
            Positioned(
              bottom: 20,
              left: 20,
              right: 20,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Selection Status Widget
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _selectedNodeName != null 
                          ? Colors.green.withOpacity(0.9)
                          : Colors.grey.withOpacity(0.8),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Column(
                      children: [
                        Text(
                          'SELECTION STATUS',
                          style: TextStyle(
                            color: Colors.white, 
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        SizedBox(height: 4),
                        Text(
                          _selectedNodeName != null 
                              ? '🎯 Selected: $_selectedNodeName'
                              : '⭕ No object selected',
                          style: TextStyle(
                            color: Colors.white, 
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        if (_selectedNodeName != null) ...[
                          SizedBox(height: 2),
                          Text(
                            'Tap the object again to deselect\nTap empty space to deselect\nPan/Rotate gestures available',
                            style: TextStyle(
                              color: Colors.white70, 
                              fontSize: 9,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ] else ...[
                          SizedBox(height: 2),
                          Text(
                            'Tap any object to select it',
                            style: TextStyle(
                              color: Colors.white70, 
                              fontSize: 9,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ],
                    ),
                  ),
                  SizedBox(height: 8),
                  // Objects and Next Model Info
                  Container(
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
                ],
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
      
      // Set up selection state change handler
      arObjectManager!.onSelectionChanged = _onSelectionChanged;
      print("🔄 Selection state change handler set up - handler is: ${arObjectManager!.onSelectionChanged != null ? 'SET' : 'NULL'}");
      print("🔄 ARObjectManager onSelectionChanged callback configured");
      
      // Set up session tap handler for empty space taps (deselection)
      arSessionManager!.onPlaneOrPointTap = _onEmptySpaceTapped;
      print("⭕ Empty space tap handler set up");
      
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

  void _onEmptySpaceTapped(List<ARHitTestResult> hitTestResults) {
    print("⭕ Empty space tap event received with ${hitTestResults.length} hit results");
    
    // Only deselect if we have a selected object and this was truly an empty space tap
    if (_selectedNodeName != null) {
      String previousSelection = _selectedNodeName!;
      
      // Add event to history
      final timestamp = DateTime.now().millisecondsSinceEpoch.toString().substring(7);
      setState(() {
        _selectionEvents.insert(0, "[$timestamp] ⭕ Flutter empty space tap");
        if (_selectionEvents.length > 10) {
          _selectionEvents.removeLast();
        }
        
        _selectedNodeName = null;
        _statusText = "⭕ Deselected: $previousSelection (empty space tap)";
      });
      print("⭕ Empty space tapped - deselected: $previousSelection");
    } else {
      print("⭕ Empty space tapped - no object was selected");
      setState(() {
        _statusText = "Empty space tapped - no object selected";
      });
    }
  }

  void _onNodeTapped(List<String> nodeNames) {
    print("👆 Node tap event received with ${nodeNames.length} nodes: $nodeNames");
    
    if (nodeNames.isNotEmpty) {
      String tappedNodeName = nodeNames.first;
      print("🎯 Processing tap on node: $tappedNodeName");
      
      setState(() {
        final timestamp = DateTime.now().millisecondsSinceEpoch.toString().substring(7);
        
        if (_selectedNodeName == tappedNodeName) {
          // Same node tapped - deselect it
          _selectionEvents.insert(0, "[$timestamp] 🔄 Flutter tap deselect: $tappedNodeName");
          if (_selectionEvents.length > 10) {
            _selectionEvents.removeLast();
          }
          
          _selectedNodeName = null;
          _statusText = "🔄 Deselected: $tappedNodeName";
          print("🔄 Deselected node: $tappedNodeName");
        } else {
          // Different node tapped - select it
          String previousSelection = _selectedNodeName ?? "none";
          _selectionEvents.insert(0, "[$timestamp] 🎯 Flutter tap select: $tappedNodeName");
          if (_selectionEvents.length > 10) {
            _selectionEvents.removeLast();
          }
          
          _selectedNodeName = tappedNodeName;
          _statusText = "🎯 Selected: $tappedNodeName";
          print("🎯 Selected node: $tappedNodeName (previous: $previousSelection)");
        }
      });
    } else {
      // Empty space tapped - deselect any selected object
      if (_selectedNodeName != null) {
        String previousSelection = _selectedNodeName!;
        setState(() {
          _selectedNodeName = null;
          _statusText = "⭕ Deselected: $previousSelection (empty space tap)";
        });
        print("⭕ Empty space tapped - deselected: $previousSelection");
      } else {
        print("⭕ Empty space tapped - no object was selected");
        setState(() {
          _statusText = "Empty space tapped - no selection change";
        });
      }
    }
  }

  void _onSelectionChanged(String? selectedNodeId) {
    print("🔄 _onSelectionChanged called with: $selectedNodeId");
    print("🔄 Selection state changed by Android: $selectedNodeId");
    
    final now = DateTime.now();
    final timeSinceLastChange = _lastSelectionTime != null ? now.difference(_lastSelectionTime!).inMilliseconds : 1000;
    
    // Filter out rapid changes on the same node (within 100ms) to avoid UI flicker during gestures
    if (_lastSelectionNodeId == selectedNodeId && timeSinceLastChange < 100) {
      print("🔄 Filtered out rapid duplicate selection change (${timeSinceLastChange}ms ago)");
      return;
    }
    
    // Update tracking variables
    _lastSelectionNodeId = selectedNodeId;
    _lastSelectionTime = now;
    
    // Track deselection for UI feedback
    if (selectedNodeId == null && _selectedNodeName != null) {
      _lastDeselectedNode = _selectedNodeName;
      _deselectionTime = now;
      // Clear deselection indicator after 2 seconds
      Future.delayed(Duration(seconds: 2), () {
        if (mounted) {
          setState(() {
            _lastDeselectedNode = null;
            _deselectionTime = null;
          });
        }
      });
    }
    
    // Add event to history (keep last 10 events)
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString().substring(7); // Last 6 digits
    String eventText;
    if (selectedNodeId != null) {
      eventText = "[$timestamp] 📱 Android selected: $selectedNodeId";
    } else {
      eventText = "[$timestamp] 📱 Android deselected: ${_selectedNodeName ?? 'none'}";
    }
    
    setState(() {
      _selectionEvents.insert(0, eventText);
      if (_selectionEvents.length > 10) {
        _selectionEvents.removeLast();
      }
      
      String previousSelection = _selectedNodeName ?? "none";
      _selectedNodeName = selectedNodeId;
      if (selectedNodeId != null) {
        _statusText = "📱 Android selected: $selectedNodeId";
        print("📱 Android selected node: $selectedNodeId (previous: $previousSelection)");
      } else {
        _statusText = "📱 Android deselected: $previousSelection";
        print("📱 Android deselected node: $previousSelection");
      }
    });
    print("🔄 _onSelectionChanged completed - _selectedNodeName is now: $_selectedNodeName");
  }

  Future<void> _removeAllObjects() async {
    if (arObjectManager == null) return;
    
    print("🧹 Removing all ${nodes.length} objects...");
    
    try {
      setState(() {
        _statusText = "Removing all ${nodes.length} objects...";
      });
      
      // Remove all nodes
      for (ARNode node in nodes) {
        await arObjectManager!.removeNode(node);
        print("🗑️ Removed node: ${node.name}");
      }
      
      setState(() {
        nodes.clear();
        _selectedNodeName = null; // Clear selection when removing all objects
        _statusText = "✅ All objects removed - Scene cleared";
        _modelIndex = 0; // Reset to first model
      });
      
      print("✅ All objects removed successfully - selection cleared");
      
    } catch (e) {
      print("❌ Error removing objects: $e");
      setState(() {
        _statusText = "❌ Error removing objects: $e";
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
