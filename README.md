# ar_flutter_plugin_2
[![pub package](https://img.shields.io/pub/v/ar_flutter_plugin_2.svg)](https://pub.dev/packages/ar_flutter_plugin_2)

## NEW: Deep Memory Cleanup 🚀

This plugin now includes **advanced memory management** to prevent OOM crashes and ensure stable AR performance:

- **Deep Resource Cleanup**: Thoroughly destroy GPU resources, textures, and materials
- **Shared Asset Loading**: Load assets once, share between multiple nodes (50-80% memory reduction)
- **Cache Purging**: Clear accumulated caches and unused resources
- **Session Reset**: Soft reset AR sessions without app restart
- **Memory Monitoring**: Real-time memory usage statistics
- **Load Backpressure**: Queue model loading to prevent memory spikes
- **🚨 NUKE ALL**: Complete memory teardown to cold start levels

### Full Memory Reset

When you need to return memory to near cold start levels:

```dart
final ok = await sessionManager.nukeAll(purgeCaches: true);
if (ok) {
  setState(() => _shouldRenderARView = false);
  await Future.delayed(const Duration(milliseconds: 50));
  await Future.delayed(const Duration(milliseconds: 300)); // optional
  setState(() => _shouldRenderARView = true);
}
```

`nukeAll()` performs complete teardown of AR session, renderer, SwapChain/layers, caches and singletons. Removing the AR widget for at least one frame lets Android/iOS deallocate surfaces/layers for maximum memory reset.

📖 **[Full Deep Memory Cleanup Documentation](DEEP_MEMORY_CLEANUP.md)**
📖 **[NUKE ALL Complete Documentation](NUKE_ALL_DOCUMENTATION.md)**

## NEW: iOS Default Lighting and Visibility

- Default lighting is enabled on iOS to improve visibility of PBR models.
- For very large/thin models (e.g., pergolas), consider a higher initial scale and a small Y-offset when spawning to avoid “burial” in the floor during the first frame.

See the pergola example links below for practical values.

## NEW: Smart Object Placement System 🎯

This plugin now includes a **size-based classification system** for optimal object placement and interaction:

- **Size-Based Types**: SMALL, MEDIUM, BIG instead of object-specific types
- **Smart Placement**: Automatic optimal distance calculation based on object size
- **Enhanced Gestures**: Size-aware touch detection and interaction areas
- **Cross-Platform**: Consistent behavior on Android and iOS
- **Flexible**: Same size type works for different object categories

### Smart Placement Usage

```dart
// Place objects with optimal positioning based on size
String? result = await arObjectManager.addNodeWithSmartPlacement(
  arNode,
  sizeType: "BIG", // SMALL, MEDIUM, or BIG
);
```

**Size Guidelines:**
- **SMALL**: Objects < 1m (grills, decorations) → placed 1.5-2m away
- **MEDIUM**: Objects 1-2m (tables, chairs) → placed 2.5-3m away  
- **BIG**: Objects > 2m (pergolas, gazebos) → placed 4-6m away

📖 **[Size-Based Classification Documentation](SIZE_BASED_CLASSIFICATION.md)**

---

This version is a direct adaptation of the original ar_flutter_plugin (https://pub.dev/packages/ar_flutter_plugin), 
migrating the Android component from Sceneform to sceneview_android, enabling the use of animated models.<br>
This fork was created because the original plugin had not been updated since 2022. <br><br>
➡ Changes include an update to the AR Core endpoint, a gradle upgrade, and compatibility with FlutterFlow.<br>
➡ Migration has been done from sceneform to sceneview_android with the help of Cursor (Ai editor) so maybe some parts are not fully correct (Any contribution is welcome)


<b>❤️ I invite you to collaborate and contribute to the improvement of this plugin.</b><br>
To contribute code and discuss ideas, [create a pull request](https://github.com/hlefe/ar_flutter_plugin_2/compare), [open an issue](https://github.com/hlefe/ar_flutter_plugin_2/issues/new), or [start a discussion](https://github.com/hlefe/ar_flutter_plugin_2/discussions).

## Fluterflow demo app
<table>
<td>
<img src="https://avatars.githubusercontent.com/u/74943865?s=48&amp;v=4" width="30" height="30" style="max-width: 100%; margin-bottom: -9px;"> </img>
</td>
<td>
<b> You can find a complete example running on FlutterFlow here :</b><br>
<a href="https://app.flutterflow.io/project/a-r-flutter-lib-ipqw3k">https://app.flutterflow.io/project/a-r-flutter-lib-ipqw3k</a>
</td>
</table>

### Installing

Add the Flutter package to your project by running:

```bash
flutter pub add ar_flutter_plugin_2
```

Or manually add this to your `pubspec.yaml` file (and run `flutter pub get`):

```yaml
ar_flutter_plugin_2:
    git:
      url: https://github.com/ViktorVojtek/ar_flutter_plugin_2.git
      ref: main
```

Or in FlutterFlow : 

<table>
<td>
<img src="https://avatars.githubusercontent.com/u/74943865?s=48&amp;v=4" width="30" height="30" style="max-width: 100%; margin-bottom: -9px;"> </img>
</td>
<td> Simply add : <br> <b>ar_flutter_plugin_2: ^0.0.3 </b> <br> in pubspecs dependencies of your widget.
</td>
</table>

### Importing

Add this to your code:

```dart
import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';
```

## What’s new (Sep 2025)

These updates improve reliability, especially for thin or very large models, and harmonize Android/iOS behavior.

- Direct camera-relative placement: addNode without an anchor now spawns in front of the camera on both Android and iOS.
- Robust pan with Y-lock: Pan freely on X/Z with Y locked; native fallback uses a camera-facing plane when tracked plane hits are unreliable.
- Per-node gesture flags: Enable/disable pan/rotation on each ARNode for predictable routing.
- Better selection for thin structures: Larger helper colliders and enhanced hit tests (native) make pergolas/selectable skeletons easy to tap and pan.
- Return types unified: addNode returns nodeId (String?), removeNode returns bool.
- Deep removal: removeNodeDeep(nodeId) tears down native/GPU resources more aggressively.
- Smart placement: addNodeWithSmartPlacement(node, sizeType) positions objects at an optimal, size-aware distance.
- iOS: Default lighting enabled for better rendering out of the box.

### Direct camera-relative placement (no anchor)

Minimal example that places an object ~1m in front of the camera and enables gestures:

```dart
final position = vec.Vector3(0.0, 0.0, -1.0); // z is forward in camera space
final transform = Matrix4.identity()..setTranslation(position);

final node = ARNode(
  type: NodeType.webGLB,
  uri: "https://…/Duck.glb",
  transformation: transform,
  scale: vec.Vector3(0.5, 0.5, 0.5),
  isTransformable: true,
  enablePanGestures: false,  // small models: prefer native pan + fallback
  enableRotationGestures: true,
);

final nodeId = await arObjectManager.addNode(node);
```

Notes:
- For small models, set enablePanGestures: false to use the native pan with camera-plane fallback.
- For very large models (pergolas), set enablePanGestures: true for unlimited XZ panning with Y locked.

### Unlimited XZ panning with Y-lock and fallback

Per-node gestures provide flexibility:
- enablePanGestures: true → custom unlimited XZ pan with Y-lock.
- enablePanGestures: false → built-in/native pan with camera-plane fallback for reliability on small/thin meshes.

You can also subscribe to transformation updates:

```dart
arObjectManager.onNodeTransformed = (nodeName, position, rotation) {
  debugPrint('Node $nodeName moved to $position');
};
```

### Smart placement API

Place objects at a size-aware distance to avoid “too close” large objects or “too far” small ones:

```dart
final node = ARNode(
  type: NodeType.webGLB,
  uri: "https://…/Duck.glb",
  scale: vec.Vector3(3.0, 2.5, 3.0),
  isTransformable: true,
  enablePanGestures: true,
  enableRotationGestures: true,
);

final nodeId = await arObjectManager.addNodeWithSmartPlacement(
  node,
  sizeType: 'BIG', // SMALL | MEDIUM | BIG
);
```

Under the hood, the plugin computes optimal distance and height offsets and shares hints with the native layer. If a platform doesn’t implement smart placement, the call gracefully falls back to addNode.

### Removal and deep cleanup

Track returned node IDs for robust removal and resource teardown:

```dart
// Shallow removal (detaches from scene)
final ok = await arObjectManager.removeNode(node);

// Deep removal (native + GPU resources)
if (nodeId != null) {
  final deepOk = await arObjectManager.removeNodeDeep(nodeId);
}
```

Pair this with the existing nukeAll() when you need to reset the entire AR session.

## IOS Permissions
* To prevent your application from crashing when launching augmented reality on iOS, you need to add the following permission to the Info.plist file (located under ios/Runner) :

  ```
  <key>NSCameraUsageDescription</key>
  <string>This application requires camera access for augmented reality functionality.</string>
  
  ```
  <br>
<table>
<td>
<img src="https://avatars.githubusercontent.com/u/74943865?s=48&amp;v=4" width="30" height="30" style="max-width: 100%; margin-bottom: -9px;"> </img>
</td>
<td><b> If you're using FlutterFlow, go to "App Settings" > "Permissions"<br>
 For the "Camera" line, toggle the switch to "On" and add the description :<br> "This application requires access to the camera to enable augmented reality features."  </b><br>
<br>

</td></table>

If you have problems with permissions on iOS (e.g. with the camera view not showing up even though camera access is allowed), add this to the ```podfile``` of your app's ```ios``` directory:

```pod
  post_install do |installer|
    installer.pods_project.targets.each do |target|
      flutter_additional_ios_build_settings(target)
      target.build_configurations.each do |config|
        # Additional configuration options could already be set here

        # BEGINNING OF WHAT YOU SHOULD ADD
        config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= [
          '$(inherited)',

          ## dart: PermissionGroup.camera
          'PERMISSION_CAMERA=1',

          ## dart: PermissionGroup.photos
          'PERMISSION_PHOTOS=1',

          ## dart: [PermissionGroup.location, PermissionGroup.locationAlways, PermissionGroup.locationWhenInUse]
          'PERMISSION_LOCATION=1',

          ## dart: PermissionGroup.sensors
          'PERMISSION_SENSORS=1',

          ## dart: PermissionGroup.bluetooth
          'PERMISSION_BLUETOOTH=1',

          # add additional permission groups if required
        ]
        # END OF WHAT YOU SHOULD ADD
      end
    end
  end
```

## ✨ Enhanced Features

### 🎯 Comprehensive Plane Detection
This plugin now provides detailed information about detected planes including:

- **Position data**: Get the exact 3D coordinates of detected planes
- **Height information**: Essential for distinguishing ground planes from tables, desks, etc.
- **Size measurements**: Width, length, and total area of detected planes  
- **Plane alignment**: Distinguish between horizontal and vertical surfaces
- **Transform data**: Full transformation matrix for advanced positioning

This enables smart object placement based on plane characteristics:
```dart
void onPlaneDetected(ARPlane plane) {
  if (plane.alignment == 'horizontal' && plane.height < 0.3) {
    // Ground plane - place floor objects
  } else if (plane.height >= 0.5 && plane.height <= 1.2) {
    // Table/desk surface - place smaller objects
  } else if (plane.alignment == 'vertical') {
    // Wall - place wall-mounted objects
  }
}
```

See `examples/enhanced_plane_detection.dart` for a complete implementation.

## Example AR screen implementation
- with methods for add/remove object

```

import 'dart:io';

import 'package:ar_flutter_plugin_2/models/ar_anchor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

//AR Flutter Plugin
import 'package:ar_flutter_plugin_2/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin_2/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin_2/models/ar_hittest_result.dart';
import 'package:ar_flutter_plugin_2/datatypes/node_types.dart';
import 'package:ar_flutter_plugin_2/models/ar_node.dart';

//Other custom imports
import 'package:vector_math/vector_math_64.dart' as vec;

class ARScreen extends StatefulWidget {
  const ARScreen({super.key, required this.title});

  final String title;

  @override
  _ARScreenState createState() => _ARScreenState();
}

class _ARScreenState extends State<ARScreen> {
  ARSessionManager? arSessionManager;
  ARObjectManager? arObjectManager;
  ARAnchorManager? arAnchorManager;
  ARLocationManager? arLocationManager;

  HttpClient? httpClient;
  String? modelUri;
  String? modelName;
  String? selectedNode;
  List<ARNode> nodes = [];
  List<String> nodeCreationOrder = []; // Track the order nodes were created
  vec.Vector3 nodePosition = vec.Vector3(0, 0, -1);

  void onARViewCreated(
    ARSessionManager sessionManager,
    ARObjectManager objectManager,
    ARAnchorManager anchorManager,
    ARLocationManager locationManager
  ) {
    arSessionManager = sessionManager;
    arObjectManager = objectManager;
    arAnchorManager = anchorManager;
    arLocationManager = locationManager;

    // Initialize the AR Session
    arSessionManager?.onInitialize(
      showFeaturePoints: false,
      showPlanes: false,
      // customPlaneTexturePath: "Images/triangle.png",
      showWorldOrigin: false,
      handleTaps: true,
      handlePans: true,
      handleRotation: true,
    );

    // Initialize ObjectManager
    arObjectManager?.onInitialize();
    arObjectManager?.onNodeTap = onNodeTapped as NodeTapResultHandler?;

    // Set up callback handlers
    arSessionManager?.onPlaneOrPointTap = onPlaneOrPointTapped;
    arSessionManager?.onPlaneDetected = onPlaneDetected;

    // Additional configuration for anchorManager and locationManager can also be set
  }

  Future<void> onNodeTapped(List<String> tappedNodes) async {
    if (tappedNodes.isEmpty) {
      debugPrint("No nodes tapped.");
      return;
    }

    String tappedNodeId = tappedNodes.first;
    
    // Check if the tapped node ID exists in our creation order
    if (nodeCreationOrder.contains(tappedNodeId)) {
      setState(() {
        selectedNode = tappedNodeId;
      });
    } else {
      debugPrint("Tapped node ID not found in nodeCreationOrder");
      debugPrint("Available node IDs: $nodeCreationOrder");
    }
  }

  void onPlaneOrPointTapped(List<ARHitTestResult> hitTestResults) {
    if (hitTestResults.isEmpty) {
      return;
    }

    // Check if model is downloaded
    if (modelName == null) {
      debugPrint("Model not downloaded yet. Please tap 'Add Model' first.");
      return;
    }

    // Get the first hit result - this is where the user tapped
    var hitTestResult = hitTestResults.first;
    
    // Get the world position from hit test
    vec.Vector3 worldPosition = vec.Vector3(
      hitTestResult.worldTransform.getColumn(3).x,
      hitTestResult.worldTransform.getColumn(3).y,
      hitTestResult.worldTransform.getColumn(3).z,
    );
    
    // Adjust Y position to be slightly above the floor
    worldPosition.y += 0.05;

    
    // Place the pending object at the hit position
    placeObjectAtPosition(worldPosition, NodeType.fileSystemAppFolderGLB, modelName);
  }

  Future<void> placeObjectAtPosition(vec.Vector3 position, NodeType nodeType, String? modelUri) async {
    if (modelUri == null || modelUri.isEmpty) {
      debugPrint("Model URI is empty, cannot place object.");
      return;
    }

    Matrix4 transformation = Matrix4.identity();
    transformation.setTranslationRaw(position.x, position.y, position.z);

    var newAnchor = ARPlaneAnchor(transformation: transformation);

    bool? didAddAnchor = await arAnchorManager!.addAnchor(newAnchor);

    if (didAddAnchor != null && didAddAnchor) {
      String objectUniqueName = "ARObject_${DateTime.now().millisecondsSinceEpoch}"; // Unique name for the object
      
      // This function should create an ARNode and add it to the ARObjectManager
      ARNode node = ARNode(
        type: nodeType,
        uri: modelUri,
        position: vec.Vector3(0.0, 0.0, 0.0),
        scale: vec.Vector3(0.2, 0.2, 0.2), // Add scale to make object visible
        rotation: vec.Vector4(1.0, 0.0, 0.0, 0.0), // Add rotation
        data: {
          'name': objectUniqueName, // Store the unique name in data
        },
      );
      
      try {
        String? addedNodeName = await arObjectManager?.addNode(node, planeAnchor: newAnchor);
        // Now we get the actual node name that was added
        debugPrint("Node creation result: $addedNodeName");
        if (addedNodeName != null) {
          nodes.add(node);
          nodeCreationOrder.add(addedNodeName); // Track creation order using the returned name
          
          // Print all node names for debugging
          for (int i = 0; i < nodes.length; i++) {
            debugPrint("Node $i name: ${nodes[i].data!['name']}, URI: ${nodes[i].uri}");
          }
        } else {
          debugPrint("Failed to add node to anchor");
        }
      } catch (e) {
        debugPrint("Error creating ARNode: $e");
        return;
      }
    } else {
      debugPrint("Failed to add anchor for the ARNode.");
    }
  }

  void onPlaneDetected(ARPlane plane) {
    debugPrint("Plane detected: $plane");
    
    // Enhanced plane information is now available
    debugPrint("Plane type: ${plane.type}");
    debugPrint("Plane alignment: ${plane.alignment}"); // 'horizontal' or 'vertical'
    debugPrint("Plane height: ${plane.height}m");
    debugPrint("Plane position: (${plane.center.x}, ${plane.center.y}, ${plane.center.z})");
    debugPrint("Plane size: ${plane.width}m × ${plane.length}m");
    debugPrint("Plane area: ${plane.extent.area}m²");
    
    // Example: Filter planes by type
    if (plane.alignment == 'horizontal' && plane.height < 0.3) {
      debugPrint("Ground plane detected at height ${plane.height}m");
    } else if (plane.alignment == 'horizontal' && plane.height >= 0.5 && plane.height <= 1.2) {
      debugPrint("Table/desk surface detected at height ${plane.height}m");
    } else if (plane.alignment == 'vertical') {
      debugPrint("Wall detected");
    }
    
    // You can now use plane height and position for intelligent object placement
  }

  Future<void> addModel() async {
    // Download the model first
    httpClient = HttpClient();
    try {
      String objectName = "LocalDuck.glb"; // Name of the model file
      await _downloadFile(
        "https://github.com/KhronosGroup/glTF-Sample-Models/raw/refs/heads/main/2.0/Duck/glTF-Binary/Duck.glb",
        objectName,
      );
      modelName = objectName; // Store the model name for later use
      debugPrint("Model downloaded successfully, ready to place on tap");
    } catch (e) {
      debugPrint("Failed to download model: $e");
    }
  }

  void removeModel() {
    if (nodes.isEmpty) {
      debugPrint("No nodes to remove");
      setState(() {
        selectedNode = null;
      });
      return;
    }

    ARNode? nodeToRemove;
    int nodeIndexToRemove = -1;
    
    // If we have a selected node ID, try to find and remove it
    if (selectedNode != null) {
      // Find the index of the selected node ID in our creation order
      int selectedIndex = nodeCreationOrder.indexOf(selectedNode!);
      if (selectedIndex >= 0 && selectedIndex < nodes.length) {
        nodeToRemove = nodes[selectedIndex];
        nodeIndexToRemove = selectedIndex;
        debugPrint("Found selected node at index $selectedIndex: ${selectedNode!}");
      } else {
        debugPrint("Selected node ID not found in valid range");
      }
    }
    
    // If no specific node was selected or found, remove the last one
    if (nodeToRemove == null && nodes.isNotEmpty) {
      nodeToRemove = nodes.last;
      nodeIndexToRemove = nodes.length - 1;
      debugPrint("No selected node found, removing last node instead: ${nodeCreationOrder.last}");
    }
    
    if (nodeToRemove != null && nodeIndexToRemove >= 0) {
      String nodeIdToRemove = nodeCreationOrder[nodeIndexToRemove];
      debugPrint("Removing node with ID: $nodeIdToRemove");
      
      // Remove from both lists
      nodes.removeAt(nodeIndexToRemove);
      nodeCreationOrder.removeAt(nodeIndexToRemove);
      
      // Remove from AR scene
      arObjectManager?.removeNode(nodeToRemove);
      
      debugPrint("Node removed successfully.");
      debugPrint("Remaining nodes: ${nodes.length}");
      debugPrint("Remaining nodeCreationOrder: $nodeCreationOrder");
      
      // Clear selection after removal
      setState(() {
        selectedNode = null;
      });
      debugPrint("Cleared selection after removal");
    } else {
      debugPrint("No node to remove");
      setState(() {
        selectedNode = null;
      });
    }
  }

  Future<String> _downloadFile(String url, String filename) async {
    try {
      var request = await httpClient!.getUrl(Uri.parse(url));
      var response = await request.close();
      var bytes = await consolidateHttpClientResponseBytes(response);
      String dir = (await getApplicationDocumentsDirectory()).path;
      String filePath = '$dir/$filename';
      File file = File(filePath);
      await file.writeAsBytes(bytes);
      debugPrint("Downloading finished, path: $filePath");

      return filePath;
    } catch (e) {
      debugPrint('Download failed: $e');
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                ARView(
                  onARViewCreated: onARViewCreated,
                  planeDetectionConfig: PlaneDetectionConfig.horizontal,
                ),
                selectedNode != null ? Positioned(
                  bottom: 80,
                  left: 20,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Show which node is selected
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          "Selected: ${nodeCreationOrder.indexOf(selectedNode!) + 1}/${nodeCreationOrder.length}\n${selectedNode!}",
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Previous button to cycle backwards
                          ElevatedButton(
                            onPressed: () {
                              if (nodeCreationOrder.isNotEmpty) {
                                int currentIndex = nodeCreationOrder.indexOf(selectedNode!);
                                int prevIndex = (currentIndex - 1 + nodeCreationOrder.length) % nodeCreationOrder.length;
                                setState(() {
                                  selectedNode = nodeCreationOrder[prevIndex];
                                });
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.orange,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            ),
                            child: const Text("Prev", style: TextStyle(fontSize: 10)),
                          ),
                          const SizedBox(width: 4),
                          // Next button to cycle through nodes
                          ElevatedButton(
                            onPressed: () {
                              if (nodeCreationOrder.isNotEmpty) {
                                int currentIndex = nodeCreationOrder.indexOf(selectedNode!);
                                int nextIndex = (currentIndex + 1) % nodeCreationOrder.length;
                                setState(() {
                                  selectedNode = nodeCreationOrder[nextIndex];
                                });
                                debugPrint("Manually cycled forward to: $selectedNode (index: $nextIndex)");
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            ),
                            child: const Text("Next", style: TextStyle(fontSize: 10)),
                          ),
                          const SizedBox(width: 8),
                          // Remove button
                          ElevatedButton(
                            onPressed: removeModel,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              elevation: 8,
                            ),
                            child: const Text("Remove", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ) : const SizedBox.shrink(),
                Positioned(
                  bottom: 20,
                  right: 20,
                  child: ElevatedButton(
                    onPressed: addModel,
                    child: const Text("Download Model"),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

```

In FlutterFlow :

<table>
<td style="min-width:30px">
<img src="https://avatars.githubusercontent.com/u/74943865?s=48&amp;v=4" width="30" height="30" style="max-width: 100%; margin-bottom: -9px;"> </img>
</td>
<td>
Unfortunately, at this stage, it is not possible to carry out the procedure above within FlutterFlow.  <br>
Therefore, it is necessary to publish your project with github and make the modifications manually. <br> And then publish wih Github selected in Deployment Sources : <br> <a href="https://docs.flutterflow.io/customizing-your-app/manage-custom-code-in-github#id-9.-deploy-from-the-main-branch">FlutterFlow Publish from Github</a>
</td>
</table>


### Example Applications

| Example Name                 | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | Link to Code |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --- |
| Debug Options                | Visualize the world origin, feature points, and tracked planes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | examples/debug_options.dart |
| Local & Online Objects       | Place GLTF/GLB from assets, web, or Documents with position/rotation/scale controls                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | examples/local_and_web_objects.dart |
| Objects & Anchors on Planes  | Tap a plane to create an anchor with a 3D model attached                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | examples/objects_on_planes.dart |
| Object Transformation Gestures | Pan/rotate objects after placement using gestures                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | examples/object_gestures.dart |
| Screenshots                  | Take a snapshot of the AR Scene                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | examples/screenshot.dart |
| Cloud Anchors                | Upload/download anchors and attached objects via Google Cloud Anchor + Firebase                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | examples/cloud_anchor.dart |
| External Object Management   | Choose models from Firestore and place them in AR                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | examples/external_model_management.dart |
| Smart Placement Demo         | Showcases addNodeWithSmartPlacement and size-aware placement for SMALL/MEDIUM/BIG                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | examples/smart_placement_demo.dart |

See also in example_app/:
- example_app/lib/pergola_placement_example_fixed.dart (pergola visibility/offsets and smart spacing)
- example_app/lib/auto_placement_test.dart (direct addNode camera-relative spawn)

## Migration notes (last-week baseline → current)

Use this quick checklist to update dependent apps:

- Capture node IDs returned by addNode/addNodeWithSmartPlacement and keep a map for removals.
- Swap any void removeNode calls for bool result handling; use removeNodeDeep(nodeId) when fully tearing down.
- For small objects, prefer enablePanGestures: false to leverage native pan with fallback; for large objects, true for unlimited XZ pan with Y-lock.
- For tap-to-place large objects, add a small forward offset from the tap point (see pergola example) or use smart placement.
- On iOS, large/thin models may need a slightly higher initial scale and tiny Y-offset to ensure visibility on first frame.

Minimal before/after highlights:

```dart
// Before: addNode returned no ID in some flows, removals relied on ARNode only
final added = await arObjectManager.addNode(node, planeAnchor: anchor);
await arObjectManager.removeNode(node);

// After: capture nodeId and prefer deep removal when needed
final nodeId = await arObjectManager.addNode(node, planeAnchor: anchor);
if (nodeId != null) {
  // ... later
  await arObjectManager.removeNodeDeep(nodeId);
}

// Per-node gestures
final node = ARNode(
  // ...
  isTransformable: true,
  enablePanGestures: false,     // native pan + fallback (small)
  enableRotationGestures: true,
);
```


## Plugin Architecture

This is a rough sketch of the architecture the plugin implements:

![ar_plugin_architecture](https://github.com/hlefe/ar_flutter_plugin_2/raw/main/AR_Plugin_Architecture_highlevel.svg)