import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin_2/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin_2/datatypes/node_types.dart';
import 'package:ar_flutter_plugin_2/datatypes/hittest_result_types.dart';
import 'package:ar_flutter_plugin_2/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_2/models/ar_anchor.dart';
import 'package:ar_flutter_plugin_2/models/ar_hittest_result.dart';
import 'package:ar_flutter_plugin_2/models/ar_node.dart';
import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

/// Example demonstrating the new deep memory cleanup functionality
/// 
/// This example shows:
/// - Creating multiple AR nodes with shared assets
/// - Using removeNodeDeep for thorough resource cleanup
/// - Cache purging and session soft reset
/// - Memory monitoring
/// - Backpressure handling for model loading
class DeepMemoryCleanupExample extends StatefulWidget {
  @override
  _DeepMemoryCleanupExampleState createState() =>
      _DeepMemoryCleanupExampleState();
}

class _DeepMemoryCleanupExampleState extends State<DeepMemoryCleanupExample> {
  ARSessionManager? arSessionManager;
  ARObjectManager? arObjectManager;
  ARAnchorManager? arAnchorManager;

  List<ARNode> nodes = [];
  Map<String, dynamic>? memoryInfo;
  bool _loadingInProgress = false;

  @override
  void dispose() {
    super.dispose();
    arSessionManager?.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
          title: const Text('Deep Memory Cleanup Example'),
          backgroundColor: Colors.blue,
        ),
        body: Container(
          child: Stack(
            children: [
              ARView(
                onARViewCreated: onARViewCreated,
                planeDetectionConfig: PlaneDetectionConfig.horizontalAndVertical,
              ),
              _buildControlPanel(),
              if (memoryInfo != null) _buildMemoryDisplay(),
            ],
          ),
        ));
  }

  Widget _buildControlPanel() {
    return Positioned(
      top: 10,
      left: 10,
      right: 10,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: _loadingInProgress ? null : _addSharedNodes,
                  child: Text('Add 3 Shared Nodes'),
                ),
              ),
              SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: nodes.isEmpty ? null : _removeAllNodesDeep,
                  child: Text('Deep Remove All'),
                ),
              ),
            ],
          ),
          SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: _purgeCaches,
                  child: Text('Purge Caches'),
                ),
              ),
              SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: _softResetSession,
                  child: Text('Soft Reset'),
                ),
              ),
            ],
          ),
          SizedBox(height: 10),
          ElevatedButton(
            onPressed: _updateMemoryInfo,
            child: Text('Update Memory Info'),
          ),
        ],
      ),
    );
  }

  Widget _buildMemoryDisplay() {
    return Positioned(
      bottom: 10,
      left: 10,
      right: 10,
      child: Container(
        padding: EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Memory Info:', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            if (memoryInfo!.containsKey('javaHeapUsedMB'))
              Text('Java Heap: ${(memoryInfo!['javaHeapUsedMB'] as double).toStringAsFixed(1)} MB', 
                   style: TextStyle(color: Colors.white)),
            if (memoryInfo!.containsKey('nativeHeapAllocatedMB'))
              Text('Native Heap: ${(memoryInfo!['nativeHeapAllocatedMB'] as double).toStringAsFixed(1)} MB', 
                   style: TextStyle(color: Colors.white)),
            if (memoryInfo!.containsKey('residentSizeMB'))
              Text('Resident: ${(memoryInfo!['residentSizeMB'] as double).toStringAsFixed(1)} MB', 
                   style: TextStyle(color: Colors.white)),
            Text('Active Nodes: ${memoryInfo!['activeNodes'] ?? 0}', 
                 style: TextStyle(color: Colors.white)),
            Text('Cached Assets: ${memoryInfo!['cachedAssets'] ?? 0}', 
                 style: TextStyle(color: Colors.white)),
          ],
        ),
      ),
    );
  }

  void onARViewCreated(
      ARSessionManager arSessionManager,
      ARObjectManager arObjectManager,
      ARAnchorManager arAnchorManager,
      ARLocationManager arLocationManager) {
    this.arSessionManager = arSessionManager;
    this.arObjectManager = arObjectManager;
    this.arAnchorManager = arAnchorManager;

    this.arSessionManager!.onPlaneOrPointTap = onPlaneOrPointTapped;
    this.arObjectManager!.onNodeTap = onNodeTapped;
    
    _updateMemoryInfo();
  }

  Future<void> _addSharedNodes() async {
    if (_loadingInProgress) return;
    
    setState(() {
      _loadingInProgress = true;
    });

    try {
      // Use the same asset URI for all nodes to demonstrate shared asset loading
      const String sharedAssetUri = 'models/Chicken_01.gltf';
      
      for (int i = 0; i < 3; i++) {
        // Create transformation matrix for different positions
        final Matrix4 transform = Matrix4.identity();
        transform.setTranslation(Vector3(i * 0.3 - 0.3, 0, -1.0));
        
        // Use createNodeFromAsset for shared loading
        final String? nodeId = await arObjectManager!.createNodeFromAsset(
          uri: sharedAssetUri,
          transformMatrix: transform.storage,
        );
        
        if (nodeId != null) {
          // Create ARNode for tracking with the assigned nodeId
          final ARNode node = ARNode(
            type: NodeType.localGLTF2,
            uri: sharedAssetUri,
            name: nodeId,
            scale: Vector3.all(0.5),
            position: Vector3(i * 0.3 - 0.3, 0, -1.0),
            rotation: Vector4(0, 0, 0, 1),
          );
          nodes.add(node);
          
          print('✅ Added shared node: $nodeId');
        } else {
          print('❌ Failed to create shared node $i');
        }
        
        // Small delay to demonstrate backpressure
        await Future.delayed(Duration(milliseconds: 200));
      }
      
      _updateMemoryInfo();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added ${nodes.length} shared nodes'))
      );
    } catch (e) {
      print('Error adding shared nodes: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red)
      );
    } finally {
      setState(() {
        _loadingInProgress = false;
      });
    }
  }

  Future<void> _removeAllNodesDeep() async {
    print('🗑️ Starting deep removal of ${nodes.length} nodes');
    
    for (final ARNode node in nodes) {
      final bool success = await arObjectManager!.removeNodeDeep(node.name);
      if (success) {
        print('✅ Deep removed node: ${node.name}');
      } else {
        print('❌ Failed to deep remove node: ${node.name}');
      }
    }
    
    setState(() {
      nodes.clear();
    });
    
    // Wait a moment for cleanup to complete
    await Future.delayed(Duration(milliseconds: 500));
    _updateMemoryInfo();
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('All nodes deep removed'))
    );
  }

  Future<void> _purgeCaches() async {
    print('🧹 Purging caches');
    
    final bool success = await arObjectManager!.purgeCaches();
    
    if (success) {
      print('✅ Caches purged successfully');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Caches purged'))
      );
    } else {
      print('❌ Failed to purge caches');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to purge caches'), backgroundColor: Colors.red)
      );
    }
    
    _updateMemoryInfo();
  }

  Future<void> _softResetSession() async {
    print('🔄 Soft resetting session');
    
    final bool success = await arSessionManager!.softResetSession(
      removeExistingAnchors: true,
      resetTracking: true,
    );
    
    if (success) {
      print('✅ Session soft reset successfully');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Session reset'))
      );
      
      // Clear our local nodes list since anchors were removed
      setState(() {
        nodes.clear();
      });
    } else {
      print('❌ Failed to soft reset session');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to reset session'), backgroundColor: Colors.red)
      );
    }
    
    _updateMemoryInfo();
  }

  Future<void> _updateMemoryInfo() async {
    try {
      final Map<String, dynamic> info = await arObjectManager!.getMemoryInfo();
      setState(() {
        memoryInfo = info;
      });
      print('📊 Memory info updated: $info');
    } catch (e) {
      print('❌ Failed to get memory info: $e');
    }
  }

  Future<void> onPlaneOrPointTapped(List<ARHitTestResult> hitTestResults) async {
    var singleHitTestResult = hitTestResults.firstWhere(
        (hitTestResult) => hitTestResult.type == ARHitTestResultType.plane);
    
    if (!_loadingInProgress) {
      var newAnchor = ARPlaneAnchor(transformation: singleHitTestResult.worldTransform);
      bool? didAddAnchor = await this.arAnchorManager!.addAnchor(newAnchor);
      
      if (didAddAnchor!) {
        // Add a single shared node at tap location
        final String? nodeId = await arObjectManager!.createNodeFromAsset(
          uri: 'models/Chicken_01.gltf',
          transformMatrix: singleHitTestResult.worldTransform.storage,
        );
        
        if (nodeId != null) {
          final ARNode node = ARNode(
            type: NodeType.localGLTF2,
            uri: 'models/Chicken_01.gltf',
            name: nodeId,
            scale: Vector3.all(0.5),
          );
          setState(() {
            nodes.add(node);
          });
          
          _updateMemoryInfo();
          print('✅ Added node via tap: $nodeId');
        }
      }
    }
  }

  void onNodeTapped(List<String> nodeNames) {
    if (nodeNames.isNotEmpty) {
      final String nodeName = nodeNames.first;
      print('🎯 Node tapped: $nodeName');
      
      showDialog(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: Text('Node Tapped'),
          content: Text('Do you want to deep remove this node?\n\nNode: $nodeName'),
          actions: [
            TextButton(
              child: Text('Cancel'),
              onPressed: () => Navigator.of(context).pop(),
            ),
            TextButton(
              child: Text('Deep Remove'),
              onPressed: () async {
                Navigator.of(context).pop();
                
                final bool success = await arObjectManager!.removeNodeDeep(nodeName);
                if (success) {
                  setState(() {
                    nodes.removeWhere((node) => node.name == nodeName);
                  });
                  _updateMemoryInfo();
                  
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Deep removed: $nodeName'))
                  );
                }
              },
            ),
          ],
        ),
      );
    }
  }
}
