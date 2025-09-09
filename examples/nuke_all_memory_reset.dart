import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin_2/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin_2/datatypes/node_types.dart';
import 'package:ar_flutter_plugin_2/datatypes/hittest_result_types.dart';
import 'package:ar_flutter_plugin_2/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_2/models/ar_node.dart';
import 'package:ar_flutter_plugin_2/models/ar_hittest_result.dart';
import 'package:ar_flutter_plugin_2/models/ar_anchor.dart';
import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

/// Demonstrates the complete "NUKE" teardown functionality that brings memory
/// usage close to cold start levels by destroying session, renderer, caches, and GPU resources.
/// 
/// This example shows the proper choreography:
/// 1. Load heavy AR models to increase memory usage
/// 2. Remove all objects using deep cleanup
/// 3. Call nukeAll() for complete teardown
/// 4. Remove AR PlatformView for at least one frame
/// 5. Recreate AR view with fresh session
class NukeAllMemoryResetExample extends StatefulWidget {
  @override
  _NukeAllMemoryResetExampleState createState() => _NukeAllMemoryResetExampleState();
}

class _NukeAllMemoryResetExampleState extends State<NukeAllMemoryResetExample> {
  ARSessionManager? arSessionManager;
  ARObjectManager? arObjectManager;
  ARAnchorManager? arAnchorManager;
  
  List<ARNode> nodes = <ARNode>[];
  List<ARAnchor> anchors = <ARAnchor>[];
  
  bool _shouldRenderARView = true;
  bool _isLoading = false;
  String _statusMessage = "Tap to place heavy models";
  int _modelsPlaced = 0;
  
  // Heavy model assets for testing memory usage
  final List<String> _heavyModelUris = [
    "https://github.com/KhronosGroup/glTF-Sample-Models/raw/master/2.0/Sponza/glTF/Sponza.gltf",
    "https://github.com/KhronosGroup/glTF-Sample-Models/raw/master/2.0/FlightHelmet/glTF/FlightHelmet.gltf",
    "https://github.com/KhronosGroup/glTF-Sample-Models/raw/master/2.0/BrainStem/glTF/BrainStem.gltf",
    "https://github.com/KhronosGroup/glTF-Sample-Models/raw/master/2.0/Lantern/glTF/Lantern.gltf",
  ];

  @override
  void dispose() {
    arSessionManager?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('NUKE Memory Reset Demo'),
        backgroundColor: Colors.red.shade700,
      ),
      body: Column(
        children: [
          // Status Panel
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _statusMessage,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text("Models placed: $_modelsPlaced"),
                if (_isLoading)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: LinearProgressIndicator(),
                  ),
              ],
            ),
          ),
          
          // Control Buttons
          Container(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _isLoading ? null : _addHeavyModel,
                        icon: const Icon(Icons.add_circle),
                        label: const Text('Add Heavy Model'),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _isLoading || nodes.isEmpty ? null : _removeAllNodes,
                        icon: const Icon(Icons.delete_sweep),
                        label: const Text('Remove All'),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _isLoading ? null : _performNukeAll,
                    icon: const Icon(Icons.settings_power),
                    label: const Text('NUKE ALL - Full Memory Reset'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _isLoading ? null : _getMemoryInfo,
                    icon: const Icon(Icons.memory),
                    label: const Text('Check Memory Usage'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
                  ),
                ),
              ],
            ),
          ),
          
          // AR View
          Expanded(
            child: _shouldRenderARView
                ? ARView(
                    onARViewCreated: _onARViewCreated,
                    planeDetectionConfig: PlaneDetectionConfig.horizontalAndVertical,
                  )
                : Container(
                    color: Colors.black,
                    child: const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.visibility_off,
                            color: Colors.white,
                            size: 64,
                          ),
                          SizedBox(height: 16),
                          Text(
                            'AR View Removed\n(Allowing OS to deallocate surfaces)',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white, fontSize: 16),
                          ),
                        ],
                      ),
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
    ARLocationManager arLocationManager,
  ) {
    this.arSessionManager = arSessionManager;
    this.arObjectManager = arObjectManager;
    this.arAnchorManager = arAnchorManager;

    this.arSessionManager!.onInitialize(
      showFeaturePoints: false,
      showPlanes: true,
      handleTaps: true,
    );
    this.arObjectManager!.onInitialize();

    this.arSessionManager!.onPlaneOrPointTap = _onPlaneOrPointTapped;
    this.arObjectManager!.onPanStart = _onPanStart;
    this.arObjectManager!.onPanChange = _onPanChange;
    // Remove onPanEnd assignment since it has type issues

    setState(() {
      _statusMessage = "AR initialized - Tap to place heavy models";
    });
  }

  Future<void> _onPlaneOrPointTapped(List<ARHitTestResult> hitTestResults) async {
    if (_isLoading || hitTestResults.isEmpty) return;
    
    var singleHitTestResult = hitTestResults.firstWhere(
      (hitTestResult) => hitTestResult.type == ARHitTestResultType.plane,
      orElse: () => hitTestResults.first,
    );

    await _addHeavyModelAtLocation(singleHitTestResult);
  }

  Future<void> _addHeavyModel() async {
    setState(() {
      _statusMessage = "Tap on a plane to place heavy model";
    });
  }

  Future<void> _addHeavyModelAtLocation(ARHitTestResult hitTestResult) async {
    if (_isLoading) return;
    
    setState(() {
      _isLoading = true;
      _statusMessage = "Loading heavy model...";
    });

    try {
      final modelUri = _heavyModelUris[_modelsPlaced % _heavyModelUris.length];
      
      var newAnchor = ARPlaneAnchor(
        name: "heavyModel_${DateTime.now().millisecondsSinceEpoch}",
        transformation: hitTestResult.worldTransform,
      );

      bool didAddAnchor = await arAnchorManager!.addAnchor(newAnchor) ?? false;
      
      if (didAddAnchor) {
        var newNode = ARNode(
          type: NodeType.webGLB,
          uri: modelUri,
          scale: Vector3(0.5, 0.5, 0.5),
          position: Vector3(0.0, 0.0, 0.0),
          rotation: Vector4(1.0, 0.0, 0.0, 0.0),
        );

  String? addedNodeId = await arObjectManager!.addNode(newNode, planeAnchor: newAnchor);
  bool didAddNode = addedNodeId != null;
        
        if (didAddNode) {
          anchors.add(newAnchor);
          nodes.add(newNode);
          _modelsPlaced++;
          
          setState(() {
            _statusMessage = "Heavy model added! Models: $_modelsPlaced";
          });
        } else {
          setState(() {
            _statusMessage = "Failed to add model to scene";
          });
        }
      } else {
        setState(() {
          _statusMessage = "Failed to add anchor";
        });
      }
    } catch (e) {
      setState(() {
        _statusMessage = "Error loading model: $e";
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _removeAllNodes() async {
    if (_isLoading) return;
    
    setState(() {
      _isLoading = true;
      _statusMessage = "Removing all models with deep cleanup...";
    });

    try {
      // Use deep removal for maximum memory cleanup
      for (var node in nodes) {
        await arObjectManager!.removeNodeDeep(node.name);
      }
      
      for (var anchor in anchors) {
        await arAnchorManager!.removeAnchor(anchor);
      }
      
      nodes.clear();
      anchors.clear();
      _modelsPlaced = 0;
      
      setState(() {
        _statusMessage = "All models removed with deep cleanup";
      });
    } catch (e) {
      setState(() {
        _statusMessage = "Error during removal: $e";
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _performNukeAll() async {
    if (_isLoading) return;
    
    setState(() {
      _isLoading = true;
      _statusMessage = "🚨 NUCLEAR OPTION: Full memory reset in progress...";
    });

    try {
      // Step 1: Remove any remaining nodes first
      if (nodes.isNotEmpty) {
        await _removeAllNodes();
        // Wait for cleanup to complete
        await Future.delayed(const Duration(milliseconds: 500));
      }

      // Step 2: Call the nuclear option
      setState(() {
        _statusMessage = "🔥 Calling nukeAll() - destroying session, renderer, caches...";
      });
      
      final success = await arSessionManager!.nukeAll(
        purgeCaches: true,
        removeExistingAnchors: true,
        resetTracking: true,
      );

      if (success) {
        setState(() {
          _statusMessage = "✅ nukeAll() completed - removing AR view...";
        });

        // Step 3: Remove AR PlatformView for at least one frame
        setState(() {
          _shouldRenderARView = false;
        });

        // Step 4: Wait for OS to deallocate surfaces/layers
        await Future.delayed(const Duration(milliseconds: 100));
        
        setState(() {
          _statusMessage = "⏳ Allowing OS to deallocate surfaces and layers...";
        });
        
        await Future.delayed(const Duration(milliseconds: 400));

        // Step 5: Recreate AR view with fresh session
        setState(() {
          _statusMessage = "🔄 Recreating AR view with fresh session...";
          _shouldRenderARView = true;
        });

        // Wait for AR view to initialize
        await Future.delayed(const Duration(milliseconds: 1000));

        setState(() {
          _statusMessage = "🎉 NUKE COMPLETE! Memory reset to near cold start levels";
          _modelsPlaced = 0;
        });
      } else {
        setState(() {
          _statusMessage = "❌ nukeAll() failed";
        });
      }
    } catch (e) {
      setState(() {
        _statusMessage = "💥 Error during NUKE: $e";
        _shouldRenderARView = true; // Restore AR view on error
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _getMemoryInfo() async {
    if (arObjectManager == null) return;
    
    try {
      final memInfo = await arObjectManager!.getMemoryInfo();
      
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Memory Information'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Loaded Nodes: ${memInfo['nodeCount'] ?? 'N/A'}'),
              Text('Resource Handles: ${memInfo['resourceHandles'] ?? 'N/A'}'),
              Text('Cached Assets: ${memInfo['cachedAssets'] ?? 'N/A'}'),
              Text('Cache Memory: ${memInfo['cacheMemoryMB'] ?? 'N/A'} MB'),
              const Divider(),
              const Text('Use NUKE ALL to reset to cold start levels'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to get memory info: $e')),
      );
    }
  }

  void _onPanStart(String nodeName) {
    print("Started panning node $nodeName");
  }

  void _onPanChange(String nodeName) {
    print("Continued panning node $nodeName");
  }
}
