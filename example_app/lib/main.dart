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
import 'auto_placement_test_fixed.dart';
import 'light_estimation_screen.dart';
import 'ar_coaching_example.dart';
import 'rotation_jump_test.dart';

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
      home: MainMenu(),
    );
  }
}

class MainMenu extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('AR Flutter Plugin Examples'),
        backgroundColor: Colors.blue,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Choose an example:',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            SizedBox(height: 30),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => AutoPlacementTestScreen()),
                );
              },
              child: Text('Auto Placement Test'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                minimumSize: Size(200, 50),
              ),
            ),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => ObjectGestures()),
                );
              },
              child: Text('Object Gestures Example'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                minimumSize: Size(200, 50),
              ),
            ),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => LightEstimationScreen()),
                );
              },
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.wb_sunny, size: 20),
                  SizedBox(width: 8),
                  Text('Light Estimation'),
                ],
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
                minimumSize: Size(200, 50),
              ),
            ),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => ARCoachingExample()),
                );
              },
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.assistant, size: 20),
                  SizedBox(width: 8),
                  Text('Coaching Overlay Demo'),
                ],
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.purple,
                foregroundColor: Colors.white,
                minimumSize: Size(200, 50),
              ),
            ),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => RotationJumpTest()),
                );
              },
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.rotate_right, size: 20),
                  SizedBox(width: 8),
                  Text('Rotation Jump Test'),
                ],
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.deepPurple,
                foregroundColor: Colors.white,
                minimumSize: Size(200, 50),
              ),
            ),
          ],
        ),
      ),
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
  
  // Store mapping of node to its ID for removal
  Map<ARNode, String> nodeToIdMap = {};
  
  // Selection state tracking
  String? _selectedNodeName;
  List<String> _selectionEvents = [];
  String? _lastSelectionNodeId;
  DateTime? _lastSelectionTime;
  String? _lastDeselectedNode;
  DateTime? _deselectionTime;

  // Height-locked panning state
  bool _heightLockedPanningEnabled = false;

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
          Align(
            alignment: FractionalOffset.bottomCenter,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // Height-locked panning toggle
                Container(
                  margin: EdgeInsets.symmetric(horizontal: 20),
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.2),
                        blurRadius: 6,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _heightLockedPanningEnabled ? Icons.lock : Icons.lock_open,
                        color: _heightLockedPanningEnabled ? Colors.green : Colors.orange,
                        size: 24,
                      ),
                      SizedBox(width: 8),
                      Text(
                        _heightLockedPanningEnabled ? 'Height-Locked Panning: ON' : 'Height-Locked Panning: OFF',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                      SizedBox(width: 12),
                      Switch(
                        value: _heightLockedPanningEnabled,
                        onChanged: _toggleHeightLockedPanning,
                        activeColor: Colors.green,
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 12),
                // Info text about the feature
                Container(
                  margin: EdgeInsets.symmetric(horizontal: 20),
                  padding: EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.withOpacity(0.3)),
                  ),
                  child: Text(
                    _heightLockedPanningEnabled 
                      ? '🔒 Objects stay at floor height when dragged, even in poorly scanned areas!'
                      : '🔓 Normal panning - limited to well-scanned surfaces',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.blue[800],
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
                SizedBox(height: 12),
                // Remove everything button
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton(
                      onPressed: onRemoveEverything,
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                      child: Text("Remove All Models")
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
      showPlanes: false, // TEMPORARILY DISABLE plane visualization to test tap detection
      showWorldOrigin: false,
      handlePans: true,
      handleRotation: true,
    );
    this.arObjectManager!.onInitialize();

    // Set up gesture handlers for object interaction
    this.arObjectManager!.onPanStart = (String nodeName) {
      print("🔥 Pan started on node: $nodeName");
    };

    this.arObjectManager!.onPanChange = (String nodeName) {
      print("🔥 Pan changing on node: $nodeName");
    };

    this.arObjectManager!.onPanEnd = (String nodeName, Matrix4 transform) {
      print("🔥 Pan ended on node: $nodeName");
    };

    this.arObjectManager!.onRotationStart = (String nodeName) {
      print("🔥 Rotation started on node: $nodeName");
    };

    this.arObjectManager!.onRotationChange = (String nodeName) {
      print("🔥 Rotation changing on node: $nodeName");
    };

    this.arObjectManager!.onRotationEnd = (String nodeName, Matrix4 transform) {
      print("🔥 Rotation ended on node: $nodeName");
    };

    this.arObjectManager!.onNodeTap = (List<String> nodeNames) {
      print("🔥 Node tapped: $nodeNames");
    };

    // CRITICAL FIX: Add selection state change handler
    this.arObjectManager!.onSelectionChanged = _onSelectionChanged;
    print("🔄 Selection state change handler set up - handler is: ${this.arObjectManager!.onSelectionChanged != null ? 'SET' : 'NULL'}");
    print("🔄 ARObjectManager onSelectionChanged callback configured");

    this.arSessionManager!.onPlaneOrPointTap = onPlaneOrPointTapped;
    print("🎯🎯🎯 FLUTTER: Callback set! Function: $onPlaneOrPointTapped");
    
    // Enable height-locked panning by default for better user experience
    _enableHeightLockedPanningByDefault();
    
    // Add other callbacks as needed...
  }

  Future<void> onRemoveEverything() async {
    debugPrint("AR_DEBUG: 🧹 Removing all objects and anchors...");
    debugPrint("AR_DEBUG: 🧹 Current nodes: ${nodes.length}, nodeToIdMap: ${nodeToIdMap.length}");
    
    // Remove all nodes first - try using stored IDs, fallback to regular removal
    for (var node in nodes) {
      String? nodeId = nodeToIdMap[node];
      if (nodeId != null) {
        debugPrint("AR_DEBUG: 🧹 Removing node with deep cleanup using ID: $nodeId");
        try {
          bool? success = await this.arObjectManager!.removeNodeDeep(nodeId);
          debugPrint("AR_DEBUG: ${success == true ? '✅' : '❌'} Remove result for $nodeId: $success");
        } catch (e) {
          debugPrint("AR_DEBUG: ❌ Error removing node $nodeId: $e, trying regular removal");
          await this.arObjectManager!.removeNode(node);
        }
      } else {
        debugPrint("AR_DEBUG: ⚠️ Node ID not found, using regular removal for: ${node.name}");
        await this.arObjectManager!.removeNode(node);
      }
    }
    nodes.clear();
    nodeToIdMap.clear(); // Clear the ID mapping as well
    
    // Then remove all anchors
    for (var anchor in anchors) {
      debugPrint("AR_DEBUG: 🧹 Removing anchor: ${anchor.name}");
      await this.arAnchorManager!.removeAnchor(anchor);
    }
    anchors.clear();
    
    // Clear selection state
    setState(() {
      _selectedNodeName = null;
      _lastDeselectedNode = null;
      _deselectionTime = null;
    });
    
    debugPrint("AR_DEBUG: ✅ Removed all objects and anchors. Nodes: ${nodes.length}, Anchors: ${anchors.length}");
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("All objects removed - Scene cleared"),
        backgroundColor: Colors.green,
      )
    );
  }

  Future<void> onPlaneOrPointTapped(List<ARHitTestResult> hitTestResults) async {
    print("🎯🎯🎯 FLUTTER: onPlaneOrPointTapped called with ${hitTestResults.length} results");
    debugPrint("AR_DEBUG: 🎯 Plane tapped! Hit test results: ${hitTestResults.length}");
    
    // ALWAYS show a notification that tap was detected
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("👆 TAP DETECTED! Results: ${hitTestResults.length}"), 
        backgroundColor: Colors.blue,
        duration: Duration(seconds: 1)
      )
    );
    
    if (hitTestResults.isEmpty) {
      debugPrint("AR_DEBUG: ❌ No hit test results - make sure planes are detected");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("No surface detected - move device to detect planes"), backgroundColor: Colors.orange)
      );
      return;
    }
    
    debugPrint("AR_DEBUG: 🦆 Placing Duck model...");
    
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
        
        // Create Room model node - complex geometry perfect for testing ambient occlusion
        var newNode = ARNode(
          type: NodeType.webGLB,
          uri: "https://storage.googleapis.com/room-bucket/laira-a6e5eaae-09d1-406d-896c-64117a20c10e.glb",
          scale: vector_math.Vector3(1.0, 1.0, 1.0), // Full scale for room model
          position: vector_math.Vector3(0.0, 0.0, 0.0), // Place directly on the plane
          rotation: vector_math.Vector4(1.0, 0.0, 0.0, 0.0), // No rotation
          isTransformable: true,        // Enable transformations
          enablePanGestures: true,      // Enable pan (drag) gestures  
          enableRotationGestures: true, // Enable rotation gestures
        );
        
        debugPrint("AR_DEBUG: 🏠 Creating Room model node...");
        debugPrint("AR_DEBUG: 📊 Room details - URI: laira-room.glb, Type: webGLB, Scale: (1.0, 1.0, 1.0)");
        
        // Add the node to the anchor
        String? nodeId = await this.arObjectManager!.addNode(newNode, planeAnchor: newAnchor);
        
        debugPrint("AR_DEBUG: 🔗 Add node result: $nodeId");
        
        if (nodeId != null) {
          this.nodes.add(newNode);
          this.nodeToIdMap[newNode] = nodeId; // Store the mapping for removal
          debugPrint("AR_DEBUG: ✅ Room model added successfully with ID: $nodeId, total nodes: ${nodes.length}");
          debugPrint("AR_DEBUG: 📝 Stored node ID mapping for removal: $nodeId");
          
          // CRITICAL FIX: Set up selection handler after successful object placement
          // This ensures ARObjectManager is fully initialized and working
          if (this.arObjectManager!.onSelectionChanged == null) {
            this.arObjectManager!.onSelectionChanged = _onSelectionChanged;
            print("🔄 LATE SETUP: Selection handler configured after successful object placement");
            print("🔄 LATE SETUP: Handler status: ${this.arObjectManager!.onSelectionChanged != null ? 'SET' : 'NULL'}");
          } else {
            print("🔄 Selection handler already configured");
          }
          
          // Log the floor height for debugging (if height-locked panning is enabled)
          if (_heightLockedPanningEnabled) {
            _logNodeFloorHeight(nodeId);
          }
          
          // Show success message to user
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_heightLockedPanningEnabled 
                ? "🏠 Room model placed! Try dragging it - check the ambient occlusion shadows in corners!"
                : "🏠 Room model placed! ID: $nodeId - Look for AO shadows!"), 
              duration: Duration(seconds: 3),
              backgroundColor: Colors.green,
            )
          );
        } else {
          debugPrint("AR_DEBUG: ❌ Failed to add Room model to anchor");
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Failed to place Room model"), backgroundColor: Colors.red, duration: Duration(seconds: 3))
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
        print("📱 Android selected node: $selectedNodeId (previous: $previousSelection)");
      } else {
        print("📱 Android deselected node: $previousSelection");
      }
    });
    print("🔄 _onSelectionChanged completed - _selectedNodeName is now: $_selectedNodeName");
  }

  /// Enable height-locked panning by default for better user experience
  Future<void> _enableHeightLockedPanningByDefault() async {
    try {
      if (arObjectManager != null) {
        bool success = await arObjectManager!.enableHeightLockedPanning(tolerance: 0.05);
        if (success) {
          setState(() {
            _heightLockedPanningEnabled = true;
          });
          print("🔒 Height-locked panning enabled by default with 5cm tolerance");
          
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("🔒 Height-locked panning enabled - objects will stay at floor height!"),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 3),
            )
          );
        } else {
          print("❌ Failed to enable height-locked panning by default");
        }
      }
    } catch (e) {
      print("❌ Error enabling height-locked panning by default: $e");
    }
  }

  /// Toggle height-locked panning on/off
  Future<void> _toggleHeightLockedPanning(bool enabled) async {
    try {
      if (arObjectManager == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("AR not initialized yet"), backgroundColor: Colors.orange)
        );
        return;
      }

      bool success = false;
      if (enabled) {
        success = await arObjectManager!.enableHeightLockedPanning(tolerance: 0.05);
        print("🔒 Attempting to enable height-locked panning...");
      } else {
        success = await arObjectManager!.disableHeightLockedPanning();
        print("🔓 Attempting to disable height-locked panning...");
      }

      if (success) {
        setState(() {
          _heightLockedPanningEnabled = enabled;
        });
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(enabled 
              ? "🔒 Height-locked panning enabled - objects stay at floor height!"
              : "🔓 Height-locked panning disabled - normal ARCore panning"),
            backgroundColor: enabled ? Colors.green : Colors.orange,
            duration: Duration(seconds: 2),
          )
        );
        
        print(enabled 
          ? "✅ Height-locked panning enabled successfully"
          : "✅ Height-locked panning disabled successfully");
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("❌ Failed to ${enabled ? 'enable' : 'disable'} height-locked panning"),
            backgroundColor: Colors.red,
          )
        );
        print("❌ Failed to ${enabled ? 'enable' : 'disable'} height-locked panning");
      }
    } catch (e) {
      print("❌ Error toggling height-locked panning: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Error: $e"),
          backgroundColor: Colors.red,
        )
      );
    }
  }

  /// Log the floor height of a node for debugging purposes
  Future<void> _logNodeFloorHeight(String nodeId) async {
    try {
      if (arObjectManager != null) {
        double? height = await arObjectManager!.getNodeFloorHeight(nodeId);
        if (height != null) {
          print("🔒 Floor height for node $nodeId: ${height.toStringAsFixed(3)}m");
        } else {
          print("⚠️ No floor height stored for node $nodeId");
        }
      }
    } catch (e) {
      print("❌ Error getting floor height for node $nodeId: $e");
    }
  }
}