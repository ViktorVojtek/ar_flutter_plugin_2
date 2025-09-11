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
import 'dart:io' show Platform;

/// Test app to validate cross-platform scaling consistency
/// 
/// This example demonstrates:
/// 1. Same scale values should produce same visual results on iOS and Android
/// 2. Models should render properly without needing platform-specific scaling
/// 3. Testing different scale values to ensure consistency
class ScaleConsistencyTest extends StatefulWidget {
  @override
  _ScaleConsistencyTestState createState() => _ScaleConsistencyTestState();
}

class _ScaleConsistencyTestState extends State<ScaleConsistencyTest> {
  ARSessionManager? arSessionManager;
  ARObjectManager? arObjectManager;
  ARLocationManager? arLocationManager;
  ARAnchorManager? arAnchorManager;

  List<ARNode> nodes = <ARNode>[];
  bool _isARInitialized = false;
  String _statusText = "Initializing AR...";
  double _currentScale = 1.0;

  // Test models with different expected scales
  final List<Map<String, dynamic>> _testModels = [
    {
      'name': 'Duck (Standard)',
      'uri': 'https://github.com/KhronosGroup/glTF-Sample-Models/raw/master/2.0/Duck/glTF-Binary/Duck.glb',
      'expectedScale': 1.0,
      'description': 'Should look like a normal-sized duck'
    },
    {
      'name': 'Fox (Small)',
      'uri': 'https://github.com/KhronosGroup/glTF-Sample-Models/raw/master/2.0/Fox/glTF/Fox.gltf',
      'expectedScale': 0.5,
      'description': 'Should be smaller than duck'
    },
    {
      'name': 'FlightHelmet (Medium)',
      'uri': 'https://github.com/KhronosGroup/glTF-Sample-Models/raw/master/2.0/FlightHelmet/glTF/FlightHelmet.gltf',
      'expectedScale': 2.0,
      'description': 'Should be larger than duck'
    },
  ];

  int _currentModelIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Cross-Platform Scale Test"),
        backgroundColor: Colors.blue,
      ),
      body: Stack(
        children: [
          // AR View
          ARView(
            onARViewCreated: _onARViewCreated,
            planeDetectionConfig: PlaneDetectionConfig.horizontal,
          ),
          
          // Status and Info Overlay
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
                    "Platform: ${Platform.isIOS ? 'iOS' : 'Android'}",
                    style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 4),
                  Text(
                    _statusText,
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  SizedBox(height: 8),
                  Text(
                    "Current Scale: ${_currentScale.toStringAsFixed(1)}",
                    style: TextStyle(color: Colors.yellow, fontSize: 14),
                  ),
                  Text(
                    "Objects placed: ${nodes.length}",
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  if (_testModels.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        "Testing: ${_testModels[_currentModelIndex]['name']}",
                        style: TextStyle(color: Colors.green, fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
          ),
          
          // Scale Controls
          Positioned(
            bottom: 200,
            left: 20,
            right: 20,
            child: Container(
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  Text(
                    "Scale: ${_currentScale.toStringAsFixed(1)}",
                    style: TextStyle(color: Colors.white, fontSize: 16),
                  ),
                  Slider(
                    value: _currentScale,
                    min: 0.1,
                    max: 5.0,
                    divisions: 49,
                    onChanged: (value) {
                      setState(() {
                        _currentScale = value;
                      });
                    },
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      ElevatedButton(
                        onPressed: () => setState(() => _currentScale = 0.1),
                        child: Text("0.1x"),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                      ),
                      ElevatedButton(
                        onPressed: () => setState(() => _currentScale = 1.0),
                        child: Text("1.0x"),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                      ),
                      ElevatedButton(
                        onPressed: () => setState(() => _currentScale = 2.0),
                        child: Text("2.0x"),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
                      ),
                    ],
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
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton(
                      onPressed: _isARInitialized ? _placeTestModel : null,
                      child: Text("Place Model"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                      ),
                    ),
                    ElevatedButton(
                      onPressed: _isARInitialized ? _nextTestModel : null,
                      child: Text("Next Model"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton(
                      onPressed: nodes.isNotEmpty ? _removeAllObjects : null,
                      child: Text("Clear All"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                      ),
                    ),
                    ElevatedButton(
                      onPressed: _isARInitialized ? _runScaleTest : null,
                      child: Text("Auto Test"),
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
        _statusText = "AR initialized. Test cross-platform scaling consistency.";
      });

      print("✅ AR initialization completed");
      
    } catch (e) {
      print("❌ Error initializing AR: $e");
      setState(() {
        _statusText = "Error initializing AR: $e";
      });
    }
  }

  Future<void> _placeTestModel() async {
    if (!_isARInitialized || arObjectManager == null) {
      print("❌ AR not initialized");
      return;
    }

    final testModel = _testModels[_currentModelIndex];
    
    setState(() {
      _statusText = "Placing ${testModel['name']} with scale $_currentScale...";
    });

    try {
      // Create position for the model
      double xOffset = (nodes.length % 3) * 0.4 - 0.4; // -0.4, 0, 0.4
      double zOffset = (nodes.length ~/ 3) * -0.4 - 0.8; // -0.8, -1.2, -1.6, etc.
      
      vm.Vector3 position = vm.Vector3(xOffset, -1.0, zOffset);
      
      Matrix4 transformation = Matrix4.identity();
      transformation.setTranslationRaw(position.x, position.y, position.z);
      
      String nodeName = "${testModel['name']}_${_currentScale.toStringAsFixed(1)}_${DateTime.now().millisecondsSinceEpoch}";
      
      ARNode node = ARNode(
        type: NodeType.webGLB,
        uri: testModel['uri'],
        name: nodeName,
        transformation: transformation,
        scale: vm.Vector3(_currentScale, _currentScale, _currentScale),
        isTransformable: true,
        enablePanGestures: true,
        enableRotationGestures: true,
      );

      print("📦 Placing test model: $nodeName");
      print("📏 Scale: $_currentScale on ${Platform.isIOS ? 'iOS' : 'Android'}");
      print("📍 Position: $position");
      
      String? result = await arObjectManager!.addNode(node);
      
      if (result != null) {
        nodes.add(node);
        setState(() {
          _statusText = "✅ ${testModel['name']} placed! Expected: ${testModel['description']}";
        });
        print("✅ Model placed successfully");
      } else {
        setState(() {
          _statusText = "❌ Failed to place ${testModel['name']}";
        });
        print("❌ Model placement failed");
      }
      
    } catch (e) {
      print("❌ Exception during model placement: $e");
      setState(() {
        _statusText = "❌ Error: $e";
      });
    }
  }

  void _nextTestModel() {
    setState(() {
      _currentModelIndex = (_currentModelIndex + 1) % _testModels.length;
      _statusText = "Selected: ${_testModels[_currentModelIndex]['name']}";
    });
  }

  Future<void> _runScaleTest() async {
    setState(() {
      _statusText = "Running automatic scale consistency test...";
    });

    // Clear existing models
    await _removeAllObjects();
    
    // Test different scales
    List<double> testScales = [0.5, 1.0, 2.0];
    
    for (int i = 0; i < testScales.length; i++) {
      setState(() {
        _currentScale = testScales[i];
      });
      
      await _placeTestModel();
      await Future.delayed(Duration(milliseconds: 1000)); // Wait between placements
      
      // Switch to next model for variety
      _nextTestModel();
    }
    
    setState(() {
      _statusText = "✅ Scale test completed! Compare visual sizes across platforms.";
    });
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
        _statusText = "All objects removed. Ready for new tests.";
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
