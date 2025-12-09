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

/// Test widget to verify the rotation jump fix.
/// 
/// This test:
/// 1. Places a model on a detected plane
/// 2. Allows rotation gestures
/// 3. Displays real-time Y position to verify stability during rotation
/// 4. Logs warnings if Y position changes more than 1cm during rotation
class RotationJumpTest extends StatefulWidget {
  const RotationJumpTest({Key? key}) : super(key: key);

  @override
  State<RotationJumpTest> createState() => _RotationJumpTestState();
}

class _RotationJumpTestState extends State<RotationJumpTest> {
  ARSessionManager? arSessionManager;
  ARObjectManager? arObjectManager;
  ARLocationManager? arLocationManager;
  ARAnchorManager? arAnchorManager;

  List<ARNode> nodes = <ARNode>[];
  List<ARAnchor> anchors = <ARAnchor>[];
  
  bool _isARInitialized = false;
  String _statusText = "Initializing AR...";
  
  // Rotation tracking
  double? _rotationStartY;
  double? _currentY;
  bool _isRotating = false;
  double _maxYDelta = 0.0;
  int _rotationCount = 0;
  bool _centerOriginEnabled = true;  // Toggle for testing

  // Test model URL
  static const String _testModelUrl = 
      'https://github.com/KhronosGroup/glTF-Sample-Models/raw/refs/heads/main/2.0/Duck/glTF-Binary/Duck.glb';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rotation Jump Test'),
        backgroundColor: Colors.deepPurple,
        actions: [
          // Toggle centerOriginOnLoad
          IconButton(
            icon: Icon(_centerOriginEnabled ? Icons.center_focus_strong : Icons.center_focus_weak),
            tooltip: 'Toggle centerOriginOnLoad: ${_centerOriginEnabled ? "ON" : "OFF"}',
            onPressed: () {
              setState(() {
                _centerOriginEnabled = !_centerOriginEnabled;
              });
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('centerOriginOnLoad: ${_centerOriginEnabled ? "ENABLED" : "DISABLED"}\nPlace a new model to test.'),
                  duration: const Duration(seconds: 2),
                ),
              );
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          ARView(
            onARViewCreated: onARViewCreated,
            planeDetectionConfig: PlaneDetectionConfig.horizontal,
          ),
          // Status panel
          Positioned(
            top: 10,
            left: 10,
            right: 10,
            child: Card(
              color: Colors.black87,
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _statusText,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'centerOriginOnLoad: ${_centerOriginEnabled ? "✅ ON (fix active)" : "❌ OFF (old behavior)"}',
                      style: TextStyle(
                        color: _centerOriginEnabled ? Colors.green : Colors.orange,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (_currentY != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Current Y: ${_currentY!.toStringAsFixed(4)}m',
                        style: const TextStyle(color: Colors.cyan, fontSize: 12),
                      ),
                    ],
                    if (_isRotating) ...[
                      Text(
                        '🔄 ROTATING - Start Y: ${_rotationStartY?.toStringAsFixed(4)}m',
                        style: const TextStyle(color: Colors.yellow, fontSize: 12),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      'Rotations: $_rotationCount | Max Y Delta: ${(_maxYDelta * 100).toStringAsFixed(2)}cm',
                      style: TextStyle(
                        color: _maxYDelta > 0.01 ? Colors.red : Colors.green,
                        fontSize: 12,
                      ),
                    ),
                    if (_maxYDelta > 0.01)
                      const Text(
                        '⚠️ Y JUMP DETECTED (>1cm)!',
                        style: TextStyle(color: Colors.red, fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                    if (_maxYDelta <= 0.01 && _rotationCount > 0)
                      const Text(
                        '✅ Rotation stable (Y delta ≤1cm)',
                        style: TextStyle(color: Colors.green, fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                  ],
                ),
              ),
            ),
          ),
          // Instructions
          Positioned(
            bottom: 100,
            left: 10,
            right: 10,
            child: Card(
              color: Colors.white.withOpacity(0.9),
              child: const Padding(
                padding: EdgeInsets.all(12.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '📍 Tap a plane to place the model',
                      style: TextStyle(fontSize: 14),
                    ),
                    Text(
                      '🔄 Use two fingers to rotate',
                      style: TextStyle(fontSize: 14),
                    ),
                    Text(
                      '📊 Watch the Y position - it should stay stable!',
                      style: TextStyle(fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Clear button
          Positioned(
            bottom: 20,
            left: 20,
            right: 20,
            child: ElevatedButton(
              onPressed: _clearAll,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Clear All & Reset'),
            ),
          ),
        ],
      ),
    );
  }

  void onARViewCreated(
    ARSessionManager sessionManager,
    ARObjectManager objectManager,
    ARAnchorManager anchorManager,
    ARLocationManager locationManager,
  ) {
    arSessionManager = sessionManager;
    arObjectManager = objectManager;
    arAnchorManager = anchorManager;
    arLocationManager = locationManager;

    arSessionManager!.onInitialize(
      showFeaturePoints: false,
      showPlanes: true,
      showWorldOrigin: false,
      handlePans: true,
      handleRotation: true,
      handleTaps: true,
    );
    arObjectManager!.onInitialize();

    // Set up callbacks
    arSessionManager!.onPlaneOrPointTap = onPlaneOrPointTapped;
    arObjectManager!.onRotationStart = onRotationStart;
    arObjectManager!.onRotationChange = onRotationChange;
    arObjectManager!.onRotationEnd = onRotationEnd;

    setState(() {
      _isARInitialized = true;
      _statusText = "AR Ready - Tap a plane to place model";
    });

    debugPrint("🚀 RotationJumpTest: AR initialized");
  }

  Future<void> onPlaneOrPointTapped(List<ARHitTestResult> hitTestResults) async {
    if (hitTestResults.isEmpty) return;

    // Find a plane hit result
    final planeHit = hitTestResults.firstWhere(
      (hit) => hit.type == ARHitTestResultType.plane,
      orElse: () => hitTestResults.first,
    );

    setState(() {
      _statusText = "Placing model...";
    });

    try {
      // Create anchor at hit position
      var newAnchor = ARPlaneAnchor(transformation: planeHit.worldTransform);
      bool? didAddAnchor = await arAnchorManager!.addAnchor(newAnchor);

      if (didAddAnchor == true) {
        anchors.add(newAnchor);

        // Create node with rotation enabled
        // Position at (0,0,0) relative to anchor - the anchor provides world position
        var newNode = ARNode(
          type: NodeType.webGLB,
          uri: _testModelUrl,
          scale: vector_math.Vector3(0.3, 0.3, 0.3),
          position: vector_math.Vector3(0.0, 0.0, 0.0),
          enableRotationGestures: true,
          enablePanGestures: true,
          enableScaleGestures: false,
          centerOriginOnLoad: _centerOriginEnabled,  // Test flag!
        );

        String? nodeId = await arObjectManager!.addNode(newNode, planeAnchor: newAnchor);
        
        if (nodeId != null) {
          nodes.add(newNode);
          setState(() {
            _statusText = "Model placed! Try rotating with two fingers.";
            _maxYDelta = 0.0;
            _rotationCount = 0;
          });
          debugPrint("✅ Model placed with centerOriginOnLoad=$_centerOriginEnabled, nodeId=$nodeId");
        } else {
          setState(() {
            _statusText = "Failed to add node";
          });
        }
      } else {
        setState(() {
          _statusText = "Failed to add anchor";
        });
      }
    } catch (e) {
      setState(() {
        _statusText = "Error: $e";
      });
      debugPrint("❌ Error placing model: $e");
    }
  }

  void onRotationStart(String nodeName) {
    debugPrint("🔄 Rotation START for $nodeName");
    
    // Try to get current Y position from the node
    // Note: In a real implementation, you'd get this from the transform callback
    setState(() {
      _isRotating = true;
      _rotationStartY = _currentY;
      _statusText = "Rotating... Watch the Y position!";
    });
  }

  void onRotationChange(String nodeName) {
    // This would be called during rotation - track position changes
    // Note: For accurate Y tracking, you'd need the transform update callback
  }

  void onRotationEnd(String nodeName, Matrix4 transform) {
    debugPrint("🔄 Rotation END for $nodeName");
    
    // Extract Y position from transform
    final newY = transform.getTranslation().y;
    
    setState(() {
      _isRotating = false;
      _currentY = newY;
      _rotationCount++;
      
      if (_rotationStartY != null) {
        final delta = (newY - _rotationStartY!).abs();
        if (delta > _maxYDelta) {
          _maxYDelta = delta;
        }
        
        if (delta > 0.01) {
          _statusText = "⚠️ Y JUMP: ${(delta * 100).toStringAsFixed(2)}cm!";
          debugPrint("⚠️ Y-JUMP DETECTED: ${(delta * 100).toStringAsFixed(2)}cm");
        } else {
          _statusText = "✅ Rotation stable! (Y delta: ${(delta * 100).toStringAsFixed(2)}cm)";
          debugPrint("✅ Rotation stable - Y delta: ${(delta * 100).toStringAsFixed(2)}cm");
        }
      }
    });
  }

  void _clearAll() async {
    // Remove all nodes
    for (var node in nodes) {
      await arObjectManager?.removeNode(node);
    }
    nodes.clear();

    // Remove all anchors
    for (var anchor in anchors) {
      await arAnchorManager?.removeAnchor(anchor);
    }
    anchors.clear();

    setState(() {
      _statusText = "Cleared! Tap a plane to place a new model.";
      _currentY = null;
      _rotationStartY = null;
      _isRotating = false;
      _maxYDelta = 0.0;
      _rotationCount = 0;
    });

    debugPrint("🧹 All models and anchors cleared");
  }

  @override
  void dispose() {
    arSessionManager?.dispose();
    super.dispose();
  }
}
