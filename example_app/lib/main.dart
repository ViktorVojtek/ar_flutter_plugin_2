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

// Model types enum for different 3D models
enum ModelType {
  localPointCloud,
  duckWeb,
  characterWeb,
}

// Model configuration class
class ModelConfig {
  final String name;
  final String uri;
  final NodeType nodeType;
  final vector_math.Vector3 scale;
  final vector_math.Vector3 position;
  
  const ModelConfig({
    required this.name,
    required this.uri,
    required this.nodeType,
    required this.scale,
    required this.position,
  });
}

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
      home: ObjectGestures(),
    );
  }
}

// Copy the ObjectGestures class from examples/object_gestures.dart
// Remove the FlutterFlow-specific imports and modify as needed
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
  
  // Model selection state
  ModelType _selectedModel = ModelType.localPointCloud;
  
  // Model configurations
  static final Map<ModelType, ModelConfig> _modelConfigs = {
    ModelType.localPointCloud: ModelConfig(
      name: "Point Cloud (Local)",
      uri: "models/point_cloud.glb",
      nodeType: NodeType.localGLTF2,
      scale: vector_math.Vector3(0.5, 0.5, 0.5),
      position: vector_math.Vector3(0.0, 0.1, 0.0),
    ),
    ModelType.duckWeb: ModelConfig(
      name: "Duck (Internet)",
      uri: "https://github.com/KhronosGroup/glTF-Sample-Models/raw/refs/heads/main/2.0/Duck/glTF-Binary/Duck.glb",
      nodeType: NodeType.webGLB,
      scale: vector_math.Vector3(0.2, 0.2, 0.2),
      position: vector_math.Vector3(0.0, 0.0, 0.0),
    ),
    ModelType.characterWeb: ModelConfig(
      name: "Avocado (Internet)",
      uri: "https://github.com/KhronosGroup/glTF-Sample-Models/raw/refs/heads/main/2.0/Avocado/glTF-Binary/Avocado.glb",
      nodeType: NodeType.webGLB,
      scale: vector_math.Vector3(5.0, 5.0, 5.0),
      position: vector_math.Vector3(0.0, 0.0, 0.0),
    ),
  };
  
  // Method to select model type
  void _selectModel(ModelType modelType) {
    setState(() {
      _selectedModel = modelType;
    });
    debugPrint("AR_DEBUG: 🎨 Selected model: ${_modelConfigs[modelType]?.name}");
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("Selected: ${_modelConfigs[modelType]?.name}"),
        duration: Duration(seconds: 1),
      )
    );
  }

  @override
  void dispose() {
    super.dispose();
    arSessionManager?.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AR Model Placement - Select & Tap'),
      ),
      body: Stack(
        children: [
          ARView(
            onARViewCreated: onARViewCreated,
            planeDetectionConfig: PlaneDetectionConfig.horizontal,
          ),
          Align(
            alignment: FractionalOffset.bottomCenter,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // Model selection buttons
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton(
                      onPressed: () => _selectModel(ModelType.localPointCloud),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _selectedModel == ModelType.localPointCloud 
                          ? Colors.green 
                          : Colors.blue,
                      ),
                      child: Text("Point Cloud\n(Local)"),
                    ),
                    ElevatedButton(
                      onPressed: () => _selectModel(ModelType.duckWeb),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _selectedModel == ModelType.duckWeb 
                          ? Colors.green 
                          : Colors.blue,
                      ),
                      child: Text("Duck\n(Internet)"),
                    ),
                    ElevatedButton(
                      onPressed: () => _selectModel(ModelType.characterWeb),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _selectedModel == ModelType.characterWeb 
                          ? Colors.green 
                          : Colors.blue,
                      ),
                      child: Text("Character\n(Internet)"),
                    ),
                  ],
                ),
                SizedBox(height: 10),
                // Remove everything button
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton(
                      onPressed: onRemoveEverything,
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                      child: Text("Remove Everything")
                    ),
                  ]
                ),
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
    this.arSessionManager = arSessionManager;
    this.arObjectManager = arObjectManager;
    this.arAnchorManager = arAnchorManager;

    this.arSessionManager!.onInitialize(
      showFeaturePoints: false,
      showPlanes: false,
      // customPlaneTexturePath: "Images/triangle.png",
      showWorldOrigin: false,
      handlePans: true,
      handleRotation: true,
    );
    this.arObjectManager!.onInitialize();

    this.arSessionManager!.onPlaneOrPointTap = onPlaneOrPointTapped;
    // Add other callbacks as needed...
  }

  Future<void> onRemoveEverything() async {
    debugPrint("AR_DEBUG: 🧹 Removing all objects and anchors...");
    
    // Remove all nodes first
    for (var node in nodes) {
      await this.arObjectManager!.removeNode(node);
    }
    nodes.clear();
    
    // Then remove all anchors
    for (var anchor in anchors) {
      await this.arAnchorManager!.removeAnchor(anchor);
    }
    anchors.clear();
    
    debugPrint("AR_DEBUG: ✅ Removed all objects and anchors. Nodes: ${nodes.length}, Anchors: ${anchors.length}");
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("All objects removed"))
    );
  }

  Future<void> onPlaneOrPointTapped(List<ARHitTestResult> hitTestResults) async {
    debugPrint("AR_DEBUG: 🎯 Plane tapped! Hit test results: ${hitTestResults.length}");
    
    // Get the selected model configuration
    final modelConfig = _modelConfigs[_selectedModel];
    if (modelConfig == null) {
      debugPrint("AR_DEBUG: ❌ No model configuration found for selected model");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("No model configuration found"), backgroundColor: Colors.red)
      );
      return;
    }
    
    debugPrint("AR_DEBUG: 🎨 Using model: ${modelConfig.name}");
    
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
        
        // Create node using selected model configuration
        var newNode = ARNode(
          type: modelConfig.nodeType,
          uri: modelConfig.uri,
          scale: modelConfig.scale,
          position: modelConfig.position,
          rotation: vector_math.Vector4(1.0, 0.0, 0.0, 0.0), // No rotation
        );
        
        debugPrint("AR_DEBUG: 🌟 Creating ${modelConfig.name} node...");
        debugPrint("AR_DEBUG: 📊 Model details - URI: ${modelConfig.uri}, Type: ${modelConfig.nodeType}, Scale: ${modelConfig.scale}");
        
        // Add the node to the anchor
        String? nodeId = await this.arObjectManager!.addNode(newNode, planeAnchor: newAnchor);
        
        debugPrint("AR_DEBUG: 🔗 Add node result: $nodeId");
        
        if (nodeId != null) {
          this.nodes.add(newNode);
          debugPrint("AR_DEBUG: ✅ Model added successfully with ID: $nodeId, total nodes: ${nodes.length}");
          
          // Show success message to user
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("${modelConfig.name} placed! ID: $nodeId"), 
              duration: Duration(seconds: 3),
              backgroundColor: Colors.green,
            )
          );
        } else {
          debugPrint("AR_DEBUG: ❌ Failed to add model to anchor");
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Failed to add ${modelConfig.name}"), backgroundColor: Colors.red, duration: Duration(seconds: 3))
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
}