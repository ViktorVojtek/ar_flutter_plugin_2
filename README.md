# ar_flutter_plugin_2
[![pub package](https://img.shields.io/pub/v/ar_flutter_plugin_2.svg)](https://pub.dev/packages/ar_flutter_plugin_2)



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

  void onPlaneDetected(dynamic plane) {
    debugPrint("Plane detected: $plane");
    // You can add additional plane detection logic here if needed
    // For example, you might want to track detected planes for better object placement
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

| Example Name                 | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | Link to Code                                                                                                                                         |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |------------------------------------------------------------------------------------------------------------------------------------------------------|
| Debug Options                | Simple AR scene with toggles to visualize the world origin, feature points and tracked planes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | [Debug Options Code](https://github.com/hlefe/ar_flutter_plugin_2/blob/main/examples/debug_options.dart)                                   |
| Local & Online Objects        | AR scene with buttons to place GLTF objects from the flutter asset folders, GLB objects from the internet, or a GLB object from the app's Documents directory at a given position, rotation and scale. Additional buttons allow to modify scale, position and orientation with regard to the world origin after objects have been placed.                                                                                                                                                                                                                                                                | [Local & Online Objects Code](https://github.com/hlefe/ar_flutter_plugin_2/blob/main/examples/local_and_web_objects.dart)                  |
| Objects & Anchors on Planes  | AR Scene in which tapping on a plane creates an anchor with a 3D model attached to it                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | [Objects & Anchors on Planes Code](https://github.com/hlefe/ar_flutter_plugin_2/blob/main/examples/objects_on_planes.dart)                 |
| Object Transformation Gestures | Same as Objects & Anchors on Planes example, but objects can be panned and rotated using gestures after being placed                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | [Objects Gestures](https://github.com/hlefe/ar_flutter_plugin_2/blob/main/examples/object_gestures.dart)                                   |
| Screenshots                  | Same as Objects & Anchors on Planes Example, but the snapshot function is used to take screenshots of the AR Scene                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | [Screenshots Code](https://github.com/hlefe/ar_flutter_plugin_2/blob/main/examples/screenshot.dart)                            |
| Cloud Anchors                | AR Scene in which objects can be placed, uploaded and downloaded, thus creating an interactive AR experience that can be shared between multiple devices. Currently, the example allows to upload the last placed object along with its anchor and download all anchors within a radius of 100m along with all the attached objects (independent of which device originally placed the objects). As sharing the objects is done by using the Google Cloud Anchor Service and Firebase, this requires some additional setup, please read [Getting Started with cloud anchors](cloudAnchorSetup.md)        | [Cloud Anchors Code](https://github.com/hlefe/ar_flutter_plugin_2/blob/main/examples/cloud_anchor.dart)                         |
| External Object Management   | Similar to the Cloud Anchors example, but contains UI to choose between different models. Rather than being hard-coded, an external database (Firestore) is used to manage the available models. As sharing the objects is done by using the Google Cloud Anchor Service and Firebase, this requires some additional setup, please read [Getting Started with cloud anchors](cloudAnchorSetup.md). Also make sure that in your Firestore database, the collection "models" contains some entries with the fields "name", "image", and "uri", where "uri" points to the raw file of a model in GLB format | [External Model Management Code](https://github.com/hlefe/ar_flutter_plugin_2/blob/main/examples/external_model_management.dart) |


## Plugin Architecture

This is a rough sketch of the architecture the plugin implements:

![ar_plugin_architecture](https://github.com/hlefe/ar_flutter_plugin_2/raw/main/AR_Plugin_Architecture_highlevel.svg)