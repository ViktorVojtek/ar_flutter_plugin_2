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
  List<ARAnchor> anchors = <ARAnchor>[]; // Track anchors for cleanup
  bool _isARInitialized = false;
  String _statusText = "Initializing AR...";
  int _modelIndex = 0; // Track which model to place next
  
  // Different models to test with
  final List<Map<String, dynamic>> _testModels = [
    {
      'name': 'Room Model',
      'url': 'https://storage.googleapis.com/room-bucket/laira-a6e5eaae-09d1-406d-896c-64117a20c10e.glb',
      'scale': 1.0,
      'position': [0.0, 0.0, -0.8], // Front center at floor level (Y=0)
    },
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Auto Placement Test - Multiple Models"),
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
                    Text(
                      "💡 Tap and drag different models to test gestures",
                      style: TextStyle(color: Colors.yellow, fontSize: 12),
                    ),
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

  String _getNextButtonText() {
    if (nodes.isEmpty) {
      return "Place ${_testModels[0]['name']}";
    }
    int nextIndex = _modelIndex % _testModels.length;
    return "Place ${_testModels[nextIndex]['name']} (${nodes.length + 1})";
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
        showPlanes: true,  // Show detected planes so user can see floor detection
        customPlaneTexturePath: null,
        showWorldOrigin: false,
        showFeaturePoints: false,
        handlePans: true,
        handleRotation: true,
      );

      await arObjectManager!.onInitialize();

      // Enable occlusion for realistic AR (iOS only)
      // Enable occlusion for realistic AR (iOS only)
      // Set enableDepth: true to test LiDAR mesh occlusion (may have artifacts)
      await _enableOcclusionIfSupported(enableDepth: true);

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
        _statusText = "AR initialized. Objects will be placed in front of camera.";
      });

      print("✅ AR initialization completed");
      
      // Wait a moment for AR to stabilize
      await Future.delayed(Duration(seconds: 2));
      
      setState(() {
        _statusText = "Ready! Tap 'Place Model' to add objects.";
      });
      
    } catch (e) {
      print("❌ Error initializing AR: $e");
      setState(() {
        _statusText = "Error initializing AR: $e";
      });
    }
  }

  Future<void> _placeNextModel() async {
    if (!_isARInitialized || arObjectManager == null || arAnchorManager == null || arSessionManager == null) {
      print("❌ AR not initialized or managers not available");
      return;
    }

    // Get the current model to place
    Map<String, dynamic> currentModel = _testModels[_modelIndex % _testModels.length];
    String modelName = currentModel['name'];
    String modelUrl = currentModel['url'];
    double modelScale = currentModel['scale'];

    setState(() {
      _statusText = "Placing $modelName (${nodes.length + 1})...";
    });

    try {
      print("🎯 Testing placement of $modelName on Android ARCore");
      
      // Get camera pose to place object in front of camera
      Matrix4? cameraPose = await arSessionManager!.getCameraPose();
      
      if (cameraPose == null) {
        print("❌ Failed to get camera pose");
        setState(() {
          _statusText = "❌ Failed to get camera position. Try moving the device.";
        });
        return;
      }
      
      // Extract camera position
      vm.Vector3 cameraPosition = vm.Vector3(
        cameraPose.getColumn(3).x,
        cameraPose.getColumn(3).y,
        cameraPose.getColumn(3).z,
      );
      
      // Extract camera forward direction (negative Z axis in camera space)
      vm.Vector3 cameraForward = vm.Vector3(
        -cameraPose.getColumn(2).x,
        -cameraPose.getColumn(2).y,
        -cameraPose.getColumn(2).z,
      ).normalized();
      
      // Place object 1.5 meters in front of camera, slightly below camera height
      vm.Vector3 placementPosition = cameraPosition + (cameraForward * 1.5);
      placementPosition.y -= 0.5; // 50cm below camera (approximate floor level)
      
      print("📍 Camera position: $cameraPosition");
      print("📍 Camera forward: $cameraForward");
      print("📍 Placement position: $placementPosition");
      
      // Create transformation matrix for anchor
      Matrix4 transformation = Matrix4.identity();
      transformation.setTranslationRaw(placementPosition.x, placementPosition.y, placementPosition.z);
      
      // Create anchor at the calculated position
      var newAnchor = ARPlaneAnchor(transformation: transformation);
      bool? didAddAnchor = await arAnchorManager!.addAnchor(newAnchor);
      
      print("🔗 Add anchor result: $didAddAnchor");
      
      if (didAddAnchor != true) {
        print("❌ Failed to create anchor for $modelName");
        setState(() {
          _statusText = "❌ Failed to create anchor for $modelName";
        });
        return;
      }
      
      print("✅ Anchor created successfully at calculated position");
      
      // Now create the node and attach it to the anchor
      String nodeName = "${modelName}_${DateTime.now().millisecondsSinceEpoch}";
      
      ARNode node = ARNode(
        type: NodeType.webGLB,
        uri: modelUrl,
        name: nodeName,
        scale: vm.Vector3(modelScale, modelScale, modelScale),
        position: vm.Vector3(0.0, 0.0, 0.0), // Position relative to anchor
        rotation: vm.Vector4(1.0, 0.0, 0.0, 0.0),
        isTransformable: true,
        enablePanGestures: true,
        enableRotationGestures: true,
        enableScaleGestures: false,
      );

      print("📦 Created ARNode: $nodeName");
      print("📏 Scale: ${node.scale}");
      print("🌐 URL: $modelUrl");
      
      // CRITICAL: Add node to anchor (not standalone)
      String? nodeId = await arObjectManager!.addNode(node, planeAnchor: newAnchor);
      
      if (nodeId != null) {
        print("✅ PLACEMENT SUCCESS! Node ID: $nodeId for $modelName");
        nodes.add(node);
        anchors.add(newAnchor); // Track anchor for cleanup
        
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
        // Clean up the anchor since node placement failed
        await arAnchorManager!.removeAnchor(newAnchor);
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
      print("🧹 Removing ${nodes.length} nodes and ${anchors.length} anchors...");
      
      // Remove all nodes
      for (ARNode node in nodes) {
        await arObjectManager!.removeNode(node);
      }
      nodes.clear();
      
      // Remove all anchors
      for (ARAnchor anchor in anchors) {
        await arAnchorManager!.removeAnchor(anchor);
      }
      anchors.clear();
      
      _modelIndex = 0; // Reset for fresh testing
      
      setState(() {
        _statusText = "All objects removed. Ready for new multi-model test.";
      });
      
      print("✅ Successfully removed all nodes and anchors");
      
    } catch (e) {
      print("❌ Error removing objects: $e");
      setState(() {
        _statusText = "Error removing objects: $e";
      });
    }
  }

  /// Enable occlusion for realistic AR (iOS only - people and depth occlusion)
  /// Note: Depth occlusion is disabled by default as it can cause artifacts
  /// with LiDAR mesh reconstruction. People occlusion is more reliable.
  Future<void> _enableOcclusionIfSupported({bool enableDepth = false}) async {
    print("🔮 _enableOcclusionIfSupported() called (enableDepth: $enableDepth)");
    print("🔮 arSessionManager is null: ${arSessionManager == null}");
    
    try {
      if (arSessionManager == null) {
        print("🔮 arSessionManager is null, returning early");
        return;
      }
      
      // People occlusion is reliable and works well - enable by default
      print("🔮 Checking people occlusion support...");
      bool peopleSupported = await arSessionManager!.isPeopleOcclusionSupported();
      print("👤 People occlusion supported: $peopleSupported");
      if (peopleSupported) {
        bool success = await arSessionManager!.enablePeopleOcclusion(true);
        print("👤 People occlusion enable result: $success");
        if (success) {
          print("👤 People occlusion ENABLED!");
        }
      }
      
      // Depth/LiDAR occlusion can cause artifacts - only enable if requested
      if (enableDepth) {
        print("🔮 Checking depth occlusion support...");
        bool depthSupported = await arSessionManager!.isDepthSupported();
        print("🔍 Depth/LiDAR occlusion supported: $depthSupported");
        if (depthSupported) {
          bool success = await arSessionManager!.enableDepthOcclusion(true);
          print("🔍 Depth occlusion enable result: $success");
          if (success) {
            print("🔍 Depth occlusion ENABLED!");
            
            // Debug mesh visualization - uncomment to see LiDAR mesh
            // bool meshShown = await arSessionManager!.showDebugMesh(true);
            // if (meshShown) {
            //   print("🔍 Debug mesh visualization ENABLED - you can see the LiDAR mesh!");
            // }
          }
        }
      } else {
        print("🔮 Skipping depth occlusion (can cause artifacts with LiDAR mesh)");
      }
      
      if (!peopleSupported) {
        print("⚠️ People occlusion not supported on this device");
      }
    } catch (e, stackTrace) {
      print("❌ Error enabling occlusion: $e");
      print("❌ Stack trace: $stackTrace");
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
