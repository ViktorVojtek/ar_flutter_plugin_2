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

/// Test app to demonstrate camera freeze fix during memory cleanup
/// 
/// This example shows:
/// 1. How the non-blocking cleanup prevents camera freezing
/// 2. Comparison between aggressive cleanup vs gentle cleanup
/// 3. Memory management without session interruption
class CameraFreezeFix extends StatefulWidget {
  @override
  _CameraFreezeFixState createState() => _CameraFreezeFixState();
}

class _CameraFreezeFixState extends State<CameraFreezeFix> {
  ARSessionManager? arSessionManager;
  ARObjectManager? arObjectManager;
  ARLocationManager? arLocationManager;
  ARAnchorManager? arAnchorManager;

  List<ARNode> nodes = <ARNode>[];
  bool _isARInitialized = false;
  String _statusText = "Initializing AR...";
  int _cleanupTest = 0;
  bool _isCleaningUp = false;

  // Heavy model assets for testing memory usage
  final List<String> _heavyModelUris = [
    "https://github.com/KhronosGroup/glTF-Sample-Models/raw/master/2.0/Sponza/glTF/Sponza.gltf",
    "https://github.com/KhronosGroup/glTF-Sample-Models/raw/master/2.0/FlightHelmet/glTF/FlightHelmet.gltf",
    "https://github.com/KhronosGroup/glTF-Sample-Models/raw/master/2.0/BrainStem/glTF/BrainStem.gltf",
    "https://github.com/KhronosGroup/glTF-Sample-Models/raw/master/2.0/Duck/glTF-Binary/Duck.glb",
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Camera Freeze Fix Test"),
        backgroundColor: Colors.green,
      ),
      body: Stack(
        children: [
          // AR View
          ARView(
            onARViewCreated: _onARViewCreated,
            planeDetectionConfig: PlaneDetectionConfig.horizontal,
          ),
          
          // Status and Memory Info Overlay
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
                  Text(
                    "Cleanup tests: $_cleanupTest",
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  if (_isCleaningUp)
                    Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.green),
                            ),
                          ),
                          SizedBox(width: 8),
                          Text(
                            "Cleaning up memory...",
                            style: TextStyle(color: Colors.green, fontSize: 12),
                          ),
                        ],
                      ),
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
            child: Column(
              children: [
                // Heavy loading row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton(
                      onPressed: _isARInitialized && !_isCleaningUp ? _loadHeavyModels : null,
                      child: Text("Load Heavy Models"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange,
                        foregroundColor: Colors.white,
                      ),
                    ),
                    ElevatedButton(
                      onPressed: nodes.isNotEmpty && !_isCleaningUp ? _removeAllObjects : null,
                      child: Text("Remove All"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
                
                SizedBox(height: 10),
                
                // Cleanup test row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton(
                      onPressed: _isARInitialized && !_isCleaningUp ? _testNonBlockingCleanup : null,
                      child: Text("Non-Blocking\nCleanup"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                      ),
                    ),
                    ElevatedButton(
                      onPressed: _isARInitialized && !_isCleaningUp ? _testAggressiveCleanup : null,
                      child: Text("Aggressive\nCleanup"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.purple,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
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

      setState(() {
        _isARInitialized = true;
        _statusText = "AR initialized. Test camera freeze fix by loading heavy models and cleaning up.";
      });

      print("✅ AR initialization completed");
      
    } catch (e) {
      print("❌ Error initializing AR: $e");
      setState(() {
        _statusText = "Error initializing AR: $e";
      });
    }
  }

  Future<void> _loadHeavyModels() async {
    if (!_isARInitialized || arObjectManager == null) {
      print("❌ AR not initialized");
      return;
    }

    setState(() {
      _statusText = "Loading heavy models to increase memory usage...";
    });

    try {
      print("🎯 Loading heavy models to test memory cleanup");
      
      for (int i = 0; i < _heavyModelUris.length; i++) {
        // Create positions in a grid pattern
        double x = (i % 2 == 0) ? -0.5 : 0.5;
        double z = (i < 2) ? -1.0 : -1.5;
        
        vm.Vector3 position = vm.Vector3(x, -1.0, z);
        
        Matrix4 transformation = Matrix4.identity();
        transformation.setTranslationRaw(position.x, position.y, position.z);
        
        String nodeName = "HeavyModel_${i}_${DateTime.now().millisecondsSinceEpoch}";
        
        ARNode node = ARNode(
          type: NodeType.webGLB,
          uri: _heavyModelUris[i],
          name: nodeName,
          transformation: transformation,
          scale: vm.Vector3(0.3, 0.3, 0.3),
          isTransformable: true,
          enablePanGestures: true,
          enableRotationGestures: true,
        );

        print("📦 Loading heavy model $i: $nodeName");
        
        String? result = await arObjectManager!.addNode(node);
        
        if (result != null) {
          nodes.add(node);
          setState(() {
            _statusText = "Loaded heavy model ${i + 1}/${_heavyModelUris.length}. Memory should be high now.";
          });
        } else {
          print("❌ Failed to load heavy model $i");
        }
        
        // Small delay between loads
        await Future.delayed(Duration(milliseconds: 500));
      }
      
      setState(() {
        _statusText = "Heavy models loaded! Memory usage is high. Test cleanup methods.";
      });
      
    } catch (e) {
      print("❌ Exception during heavy model loading: $e");
      setState(() {
        _statusText = "❌ Heavy model loading error: $e";
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
        _statusText = "All objects removed. Memory partially cleaned.";
      });
      
    } catch (e) {
      print("❌ Error removing objects: $e");
      setState(() {
        _statusText = "Error removing objects: $e";
      });
    }
  }

  Future<void> _testNonBlockingCleanup() async {
    if (arSessionManager == null) return;

    setState(() {
      _isCleaningUp = true;
      _statusText = "Testing NON-BLOCKING cleanup (camera should stay smooth)...";
    });

    try {
      print("🔄 Testing non-blocking cleanup - camera should NOT freeze");
      
      final stopwatch = Stopwatch()..start();
      
      final success = await arSessionManager!.nukeAllNonBlocking(
        purgeCaches: true,
        removeExistingAnchors: true,
        resetTracking: false, // Keep camera active
      );
      
      stopwatch.stop();
      
      setState(() {
        _cleanupTest++;
        _isCleaningUp = false;
      });
      
      if (success) {
        setState(() {
          _statusText = "✅ Non-blocking cleanup completed in ${stopwatch.elapsedMilliseconds}ms. Camera should be smooth!";
        });
        print("✅ Non-blocking cleanup completed - camera should remain active");
      } else {
        setState(() {
          _statusText = "❌ Non-blocking cleanup failed";
        });
      }
      
      // Clear local node tracking
      nodes.clear();
      
    } catch (e) {
      setState(() {
        _isCleaningUp = false;
        _statusText = "❌ Non-blocking cleanup error: $e";
      });
      print("❌ Non-blocking cleanup error: $e");
    }
  }

  Future<void> _testAggressiveCleanup() async {
    if (arSessionManager == null) return;

    setState(() {
      _isCleaningUp = true;
      _statusText = "Testing AGGRESSIVE cleanup (camera might freeze briefly)...";
    });

    try {
      print("⚡ Testing aggressive cleanup - camera might freeze");
      
      final stopwatch = Stopwatch()..start();
      
      final success = await arSessionManager!.nukeAll(
        purgeCaches: true,
        removeExistingAnchors: true,
        resetTracking: true, // This causes camera interruption
      );
      
      stopwatch.stop();
      
      setState(() {
        _cleanupTest++;
        _isCleaningUp = false;
      });
      
      if (success) {
        setState(() {
          _statusText = "⚡ Aggressive cleanup completed in ${stopwatch.elapsedMilliseconds}ms. Camera may have frozen.";
        });
        print("⚡ Aggressive cleanup completed - camera may have frozen");
      } else {
        setState(() {
          _statusText = "❌ Aggressive cleanup failed";
        });
      }
      
      // Clear local node tracking
      nodes.clear();
      
    } catch (e) {
      setState(() {
        _isCleaningUp = false;
        _statusText = "❌ Aggressive cleanup error: $e";
      });
      print("❌ Aggressive cleanup error: $e");
    }
  }

  @override
  void dispose() {
    // Use non-blocking cleanup to prevent camera freeze during disposal
    _performNonBlockingDisposal();
    super.dispose();
  }

  Future<void> _performNonBlockingDisposal() async {
    try {
      print('🔄 Starting non-blocking disposal to prevent camera freeze...');
      
      final success = await arSessionManager?.nukeAllNonBlocking(
        purgeCaches: true,
        removeExistingAnchors: true,
        resetTracking: false, // Keep camera active until the end
      );
      
      if (success == true) {
        print('✅ Non-blocking disposal completed - camera should stay active');
      } else {
        print('⚠️ Non-blocking disposal failed - using fallback');
        await _removeAllObjects();
      }
    } catch (e) {
      print('❌ Disposal error: $e');
    }
    
    // Standard disposal
    await arSessionManager?.dispose();
  }
}
