import 'dart:io';
import 'dart:async';

import 'package:ar_flutter_plugin_2/models/ar_anchor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

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
import 'package:vector_math/vector_math_64.dart'; // ✅ Add this for Vector3, Vector4
import '../models/product.dart';

class ARScreen extends StatefulWidget {
  const ARScreen({super.key, required this.title, this.product});

  final String title;
  final Product? product;

  @override
  _ARScreenState createState() => _ARScreenState();
}

class _ARScreenState extends State<ARScreen> with WidgetsBindingObserver {
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
  Vector3 nodePosition = Vector3(0, 0, -1);
  bool isDownloadingModel = false;
  bool isARReady = false;
  bool hasPlacedInitialModel = false;
  bool showSuccessMessage = false;
  bool showInstructionMessage = false;
  bool isShowingProductModal = false;
  bool _isDisposing = false; // Add flag to prevent multiple disposals
  dynamic detectedPlane;

  @override
  void initState() {
    super.initState();
    debugPrint('AR Screen: === INIT STATE ===');
    
    // Add observer for app lifecycle changes
    WidgetsBinding.instance.addObserver(this);
    
    // For testing purposes, we'll use the Duck model instead of product models
    // This bypasses the large product model downloads
    modelName = "Duck.glb"; // Set model as ready immediately
    debugPrint('AR Screen: Model name set to: $modelName');
    
    // Mark AR as ready to trigger auto-placement when ARView is created
    WidgetsBinding.instance.addPostFrameCallback((_) {
      debugPrint('AR Screen: Post frame callback - checking auto-placement');
      debugPrint('AR Screen: - AR Ready: $isARReady');
      debugPrint('AR Screen: - Has placed initial: $hasPlacedInitialModel');
      
      // No need to download - we'll use direct URL to Duck model
      if (isARReady && !hasPlacedInitialModel) {
        debugPrint('AR Screen: Calling _checkForAutoPlacement from initState');
        _checkForAutoPlacement();
      } else {
        debugPrint('AR Screen: Not calling auto-placement from initState');
      }
    });
    
    debugPrint('AR Screen: Init state completed');
  }

  @override
  void dispose() {
    debugPrint('AR Screen: === DISPOSE CALLED ===');
    
    // Prevent multiple disposals
    if (_isDisposing) {
      debugPrint('AR Screen: Already disposing, skipping...');
      return;
    }
    _isDisposing = true;
    
    // Remove observer
    WidgetsBinding.instance.removeObserver(this);
    
    // Properly dispose of AR session to prevent memory leaks
    _disposeARSession().catchError((error) {
      debugPrint('AR Screen: Error during disposal: $error');
    });
    
    // Close HTTP client if it exists
    httpClient?.close();
    
    debugPrint('AR Screen: Dispose completed');
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    
    // Handle app lifecycle changes for AR session
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.inactive:
        // App is going to background, dispose AR session
        debugPrint('AR Screen: App lifecycle changed to $state, disposing AR session');
        if (!_isDisposing) {
          _disposeARSession().catchError((error) {
            debugPrint('AR Screen: Error during lifecycle disposal: $error');
          });
        }
        break;
      case AppLifecycleState.resumed:
        // App is back to foreground - AR will be re-initialized when the ARView is recreated
        debugPrint('AR Screen: App lifecycle changed to resumed');
        break;
      case AppLifecycleState.hidden:
        debugPrint('AR Screen: App lifecycle changed to hidden');
        break;
    }
  }

  Future<void> _disposeARSession() async {
    debugPrint('AR Screen: === DISPOSING AR SESSION ===');
    
    // Check if already disposing/disposed
    if (_isDisposing && arSessionManager == null) {
      debugPrint('AR Screen: AR session already disposed, skipping...');
      return;
    }
    
    debugPrint('AR Screen: Nodes to dispose: ${nodes.length}');
    debugPrint('AR Screen: AR managers available: ${arObjectManager != null}');
    
    try {
      // Remove all nodes first with proper error handling
      if (arObjectManager != null && nodes.isNotEmpty) {
        debugPrint('AR Screen: Removing ${nodes.length} nodes from AR scene...');
        
        // Create a copy of the nodes list to avoid modification during iteration
        final List<ARNode> nodesToRemove = List.from(nodes);
        
        for (int i = 0; i < nodesToRemove.length; i++) {
          try {
            await arObjectManager!.removeNode(nodesToRemove[i]);
            debugPrint('AR Screen: Removed node ${i + 1}/${nodesToRemove.length}');
          } catch (e) {
            debugPrint('AR Screen: Error removing node ${i + 1}: $e');
            // Continue with other nodes even if one fails
          }
        }
        debugPrint('AR Screen: Finished removing nodes from AR scene');
      }
      
      // Clear our tracking lists
      nodes.clear();
      nodeCreationOrder.clear();
      debugPrint('AR Screen: Cleared tracking lists');
      
      // Clear state variables
      selectedNode = null;
      hasPlacedInitialModel = false;
      detectedPlane = null;
      isARReady = false;
      debugPrint('AR Screen: Cleared state variables');
      
      // Dispose AR session managers if available
      if (arSessionManager != null) {
        try {
          await arSessionManager!.dispose();
          debugPrint('AR Screen: Disposed AR session manager');
        } catch (e) {
          debugPrint('AR Screen: Error disposing session manager: $e');
        }
      }
      
      // Clear references to prevent memory leaks
      arSessionManager = null;
      arObjectManager = null;
      arAnchorManager = null;
      arLocationManager = null;
      debugPrint('AR Screen: Cleared AR manager references');
      
    } catch (e) {
      // Ignore disposal errors as the session might already be disposed
      debugPrint('AR Screen: AR session disposal error: $e');
    }
    
    debugPrint('AR Screen: AR session disposal completed');
  }

  void onARViewCreated(
    ARSessionManager sessionManager,
    ARObjectManager objectManager,
    ARAnchorManager anchorManager,
    ARLocationManager locationManager
  ) {
    debugPrint('AR Screen: === AR VIEW CREATED ===');
    debugPrint('AR Screen: Session manager: $sessionManager');
    debugPrint('AR Screen: Object manager: $objectManager');
    debugPrint('AR Screen: Anchor manager: $anchorManager');
    debugPrint('AR Screen: Location manager: $locationManager');
    
    arSessionManager = sessionManager;
    arObjectManager = objectManager;
    arAnchorManager = anchorManager;
    arLocationManager = locationManager;

    // Initialize the AR Session
    debugPrint('AR Screen: Initializing AR session...');
    arSessionManager?.onInitialize(
      showFeaturePoints: false,
      showPlanes: true,
      showWorldOrigin: false,
      handleTaps: true,
      handlePans: true,         // ✅ Enable pan gestures
      handleRotation: true,     // ✅ Enable rotation gestures
      showAnimatedGuide: true,
    );
    debugPrint('AR Screen: AR session initialized');

    // Initialize ObjectManager
    debugPrint('AR Screen: Initializing object manager...');
    arObjectManager?.onInitialize();
    debugPrint('AR Screen: Object manager initialized');

    // Set up callback handlers
    debugPrint('AR Screen: Setting up callback handlers...');
    arSessionManager?.onPlaneOrPointTap = onPlaneOrPointTapped;
    arObjectManager?.onNodeTap = onNodeTapped as NodeTapResultHandler?;
    arSessionManager?.onPlaneDetected = onPlaneDetected;
    debugPrint('AR Screen: Callback handlers set up');

    // Set up comprehensive gesture callbacks
    debugPrint('AR Screen: Setting up gesture callbacks...');
    arObjectManager!.onPanStart = (nodeName) {
      debugPrint("🟢 Pan started on node: $nodeName");
      debugPrint("🟢 Current nodes: $nodeCreationOrder");
      debugPrint("🟢 Selected node: $selectedNode");
    };

    arObjectManager!.onPanChange = (nodeName) {
      debugPrint("🔄 Pan changed on node: $nodeName");
    };

    arObjectManager!.onPanEnd = (nodeName, transform) {
      debugPrint("🔴 Pan ended on node: $nodeName");
      debugPrint("🔴 New transform: $transform");
      // Update the node's transform if needed
    };

    arObjectManager!.onRotationStart = (nodeName) {
      debugPrint("🟡 Rotation started on node: $nodeName");
    };

    arObjectManager!.onRotationChange = (nodeName) {
      debugPrint("🔄 Rotation changed on node: $nodeName");
    };

    arObjectManager!.onRotationEnd = (nodeName, transform) {
      debugPrint("🔴 Rotation ended on node: $nodeName");
    };

    arObjectManager!.onNodeTap = (nodeNames) {
      debugPrint("👆 Node tapped: $nodeNames");
    };

    // Mark AR as ready
    if (mounted) {
      setState(() {
        isARReady = true;
      });
      debugPrint('AR Screen: AR marked as ready');
    } else {
      debugPrint('AR Screen: Widget not mounted, skipping setState');
      return;
    }
    
    debugPrint('AR Screen: Checking auto-placement conditions...');
    debugPrint('AR Screen: - Model name: $modelName');
    debugPrint('AR Screen: - Has placed initial: $hasPlacedInitialModel');

    // If model is already downloaded and we haven't placed initial model yet, check for auto-placement
    if (modelName != null && !hasPlacedInitialModel) {
      debugPrint('AR Screen: Triggering auto-placement check');
      _checkForAutoPlacement();
    } else {
      debugPrint('AR Screen: Auto-placement conditions not met');
    }
  }

  Future<void> onNodeTapped(List<String> tappedNodes) async {
    debugPrint('AR Screen: === NODE TAPPED ===');
    debugPrint('AR Screen: Tapped nodes count: ${tappedNodes.length}');
    debugPrint('AR Screen: Tapped nodes: $tappedNodes');
    
    if (tappedNodes.isEmpty) {
      debugPrint('AR Screen: No tapped nodes, returning');
      return;
    }

    String tappedNodeId = tappedNodes.first;
    debugPrint('AR Screen: First tapped node ID: $tappedNodeId');
    debugPrint('AR Screen: Current node creation order: $nodeCreationOrder');
    debugPrint('AR Screen: Current selected node: $selectedNode');
    
    // Check if the tapped node ID exists in our creation order
    if (nodeCreationOrder.contains(tappedNodeId)) {
      debugPrint('AR Screen: ✅ Node found in creation order, selecting it');
      if (mounted) {
        setState(() {
          selectedNode = tappedNodeId;
        });
        debugPrint('AR Screen: Selected node set to: $selectedNode');
        
        // Show selection feedback
        _showSnackBar('Model selected: ${nodeCreationOrder.indexOf(tappedNodeId) + 1}/${nodeCreationOrder.length}');
      } else {
        debugPrint('AR Screen: Widget not mounted, skipping node selection setState');
      }
    } else {
      debugPrint('AR Screen: ❌ Node not found in creation order - possible plugin issue');
      debugPrint('AR Screen: Available nodes: $nodeCreationOrder');
      debugPrint('AR Screen: Tapped node: $tappedNodeId');
    }
  }

  void onPlaneOrPointTapped(List<ARHitTestResult> hitTestResults) {
    debugPrint('AR Screen: === PLANE OR POINT TAPPED ===');
    debugPrint('AR Screen: Hit test results count: ${hitTestResults.length}');
    
    if (hitTestResults.isEmpty) {
      debugPrint('AR Screen: No hit test results, returning');
      return;
    }

    // Check if model is downloaded
    if (modelName == null) {
      debugPrint('AR Screen: Model name is null, returning');
      return;
    }
    debugPrint('AR Screen: Model name: $modelName');

    // If there's a selected node, deselect it first instead of placing a new model
    if (selectedNode != null) {
      debugPrint('AR Screen: Deselecting currently selected node: $selectedNode');
      if (mounted) {
        setState(() {
          selectedNode = null;
        });
      }
      return; // Don't place a new model, just deselect
    }

    // Get the first hit result - this is where the user tapped
    var hitTestResult = hitTestResults.first;
    debugPrint('AR Screen: Using hit test result: ${hitTestResult.worldTransform}');
    
    // Get the world position from hit test
    Vector3 worldPosition = Vector3(
      hitTestResult.worldTransform.getColumn(3).x,
      hitTestResult.worldTransform.getColumn(3).y,
      hitTestResult.worldTransform.getColumn(3).z,
    );
    debugPrint('AR Screen: Original world position: $worldPosition');
    
    // Adjust Y position to be slightly above the floor
    worldPosition.y += 0.05;
    debugPrint('AR Screen: Adjusted world position: $worldPosition');

    // Place the object at the tapped position (this allows multiple placements)
    debugPrint('AR Screen: Calling placeObjectAtPosition...');
    placeObjectAtPosition(
      worldPosition, 
      NodeType.webGLB, // Use webGLB instead of fileSystemAppFolderGLB
      "https://github.com/KhronosGroup/glTF-Sample-Models/raw/refs/heads/main/2.0/Duck/glTF-Binary/Duck.glb", // Use Duck model for testing
    );
  }

  Future<void> placeObjectAtPosition(Vector3 position, NodeType nodeType, String? modelUri) async {
    debugPrint('AR Screen: === PLACING OBJECT ===');
    debugPrint('AR Screen: Position: $position');
    debugPrint('AR Screen: NodeType: $nodeType');
    debugPrint('AR Screen: ModelUri: $modelUri');
    
    if (modelUri == null || modelUri.isEmpty) {
      debugPrint('AR Screen: ERROR - modelUri is null or empty');
      return;
    }

    Matrix4 transformation = Matrix4.identity();
    transformation.setTranslationRaw(position.x, position.y, position.z);
    debugPrint('AR Screen: Created transformation matrix: $transformation');

    var newAnchor = ARPlaneAnchor(transformation: transformation);
    debugPrint('AR Screen: Created ARPlaneAnchor');

    debugPrint('AR Screen: Calling addAnchor...');
    bool? didAddAnchor = await arAnchorManager!.addAnchor(newAnchor);
    debugPrint('AR Screen: addAnchor result: $didAddAnchor');

    if (didAddAnchor == true) {
      debugPrint('AR Screen: ✅ Anchor added successfully');
      String objectUniqueName = "ARObject_${DateTime.now().millisecondsSinceEpoch}";
      debugPrint('AR Screen: Generated unique name: $objectUniqueName');
      
      // This function should create an ARNode and add it to the ARObjectManager
      ARNode node = ARNode(
        type: nodeType,
        uri: modelUri,
        position: Vector3(0.0, 0.0, 0.0),        // ✅ Use Vector3, not vec.Vector3
        scale: Vector3(0.2, 0.2, 0.2),           // ✅ Use Vector3, not vec.Vector3
        rotation: Vector4(1.0, 0.0, 0.0, 0.0),   // ✅ Keep Vector4 as is
        // ❌ Remove data parameter - let native code handle naming
      );
      
      debugPrint('AR Screen: Created ARNode with:');
      debugPrint('AR Screen: - Type: $nodeType');
      debugPrint('AR Screen: - URI: $modelUri');
      debugPrint('AR Screen: - Position: ${node.position}');
      debugPrint('AR Screen: - Scale: ${node.scale}');
      debugPrint('AR Screen: - Rotation: ${node.rotation}');
      // ❌ Remove data logging since we're not using it anymore
      
      try {
        debugPrint('AR Screen: Calling arObjectManager.addNode...');
        debugPrint('AR Screen: Node type: $nodeType, URI: $modelUri');
        debugPrint('AR Screen: Node position: ${node.position}, scale: ${node.scale}');
        
        String? addedNodeName = await arObjectManager?.addNode(node, planeAnchor: newAnchor);
        debugPrint('AR Screen: addNode returned: $addedNodeName');
        
        if (addedNodeName != null) {
          debugPrint('AR Screen: ✅ Node created successfully with ID: $addedNodeName');
          nodes.add(node);
          nodeCreationOrder.add(addedNodeName);
          debugPrint('AR Screen: Added to tracking lists. Total nodes: ${nodes.length}');
          debugPrint('AR Screen: Node creation order: $nodeCreationOrder');
          
          // Node creation was successful
          if (mounted) {
            setState(() {
              selectedNode = addedNodeName;
            });
            debugPrint('AR Screen: Set selectedNode to: $addedNodeName');
          } else {
            debugPrint('AR Screen: Widget not mounted, skipping selectedNode setState');
          }
        } else {
          debugPrint('AR Screen: ❌ Node creation returned null - this indicates a plugin issue');
          _showSnackBar('Failed to place object: Node creation returned null');
          return;
        }
      } catch (e) {
        debugPrint('AR Screen: ❌ Exception during addNode: $e');
        String errorMessage = 'Failed to place object: $e';
        
        // Handle specific GLB loading errors based on repository findings
        if (e.toString().contains('TEXCOORD_2')) {
          errorMessage = 'Model not compatible: Contains unsupported texture coordinates (TEXCOORD_2)';
        } else if (e.toString().contains('loadMesh')) {
          errorMessage = 'Model loading failed: Incompatible mesh format';
        } else if (e.toString().contains('NotSupported')) {
          errorMessage = 'Model format not supported by AR engine';
        } else if (e.toString().contains('MissingPluginException')) {
          errorMessage = 'AR plugin error: Missing native implementation';
        } else if (e.toString().contains('SessionPausedException')) {
          errorMessage = 'AR session paused, please try again';
        }
        
        debugPrint('AR Screen: Error message: $errorMessage');
        _showSnackBar(errorMessage);
        return;
      }
    } else {
      debugPrint('AR Screen: ❌ Failed to add anchor');
      _showSnackBar('Failed to place object: Could not create anchor');
    }
  }

  void onPlaneDetected(dynamic plane) {
    debugPrint('AR Screen: === PLANE DETECTED ===');
    debugPrint('AR Screen: Plane data: $plane');
    
    // Store the first detected plane for auto-placement
    if (detectedPlane == null) {
      detectedPlane = plane;
      debugPrint('AR Screen: First plane stored for auto-placement');
      
      // If model is ready and AR is ready, try auto-placement
      if (modelName != null && isARReady && !hasPlacedInitialModel) {
        debugPrint('AR Screen: Triggering auto-placement from plane detection');
        _checkForAutoPlacement();
      } else {
        debugPrint('AR Screen: Not triggering auto-placement - model: $modelName, AR ready: $isARReady, initial placed: $hasPlacedInitialModel');
      }
    } else {
      debugPrint('AR Screen: Additional plane detected (already have one stored)');
    }
  }

  Future<void> addModel() async {
    if (mounted) {
      setState(() {
        isDownloadingModel = true;
      });
    }

    // For testing, we're using direct Duck model URL, so no download needed
    // Just set the model as ready
    modelName = "Duck.glb";
    
    if (mounted) {
      setState(() {
        isDownloadingModel = false;
      });
    }
    
    // Check for auto-placement after model is "downloaded"
    if (isARReady && !hasPlacedInitialModel && mounted) {
      _checkForAutoPlacement();
    }
  }

  void _checkForAutoPlacement() {
    debugPrint('AR Screen: === CHECKING AUTO-PLACEMENT CONDITIONS ===');
    debugPrint('AR Screen: - Model: $modelName');
    debugPrint('AR Screen: - AR Ready: $isARReady');
    debugPrint('AR Screen: - Initial placed: $hasPlacedInitialModel');
    debugPrint('AR Screen: - Session manager: ${arSessionManager != null}');
    debugPrint('AR Screen: - Object manager: ${arObjectManager != null}');
    debugPrint('AR Screen: - Anchor manager: ${arAnchorManager != null}');
    debugPrint('AR Screen: - Detected plane: ${detectedPlane != null}');
    debugPrint('AR Screen: - Widget mounted: $mounted');
    
    // Auto-place if we have all required conditions and haven't placed initial model yet
    // Wait for plane detection to get proper ground level
    if (modelName != null && 
        isARReady && 
        !hasPlacedInitialModel &&
        arSessionManager != null &&
        arObjectManager != null &&
        arAnchorManager != null &&
        detectedPlane != null) {
      
      debugPrint('AR Screen: ✅ All conditions met, starting auto-placement');
      // Add a small delay to ensure AR session is fully initialized
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted && !hasPlacedInitialModel) {
          debugPrint('AR Screen: Calling _autoPlaceModelOnPlane');
          _autoPlaceModelOnPlane();
        } else {
          debugPrint('AR Screen: Skipping auto-placement - widget not mounted or already placed');
        }
      });
    } else {
      debugPrint('AR Screen: ❌ Auto-placement conditions not met');
      // If we have model and AR is ready but no plane detected yet, 
      // try again after a short delay
      if (modelName != null && 
          isARReady && 
          !hasPlacedInitialModel &&
          arSessionManager != null &&
          arObjectManager != null &&
          arAnchorManager != null &&
          detectedPlane == null) {
        
        debugPrint('AR Screen: Waiting for plane detection...');
        Future.delayed(const Duration(milliseconds: 2000), () {
          if (mounted && !hasPlacedInitialModel) {
            debugPrint('AR Screen: Retrying auto-placement check');
            _checkForAutoPlacement();
          }
        });
      }
    }
  }

  Future<void> _autoPlaceModelOnPlane() async {
    debugPrint('AR Screen: === AUTO PLACING MODEL ON PLANE ===');
    
    if (modelName == null) {
      debugPrint('AR Screen: Auto-placement failed - no model');
      return;
    }

    try {
      debugPrint('AR Screen: Starting auto-placement with model: $modelName');
      
      Vector3 autoPosition;
      
      // If we have a detected plane, try to use its position information
      if (detectedPlane != null) {
        debugPrint('AR Screen: Using detected plane for positioning');
        
        // Try to extract plane position - this depends on the plane object structure
        // For now, we'll place at a reasonable ground level position
        autoPosition = Vector3(0.0, -0.8, -1.0); // 80cm below device level, 1m forward
        
        debugPrint('AR Screen: Plane-based position: $autoPosition');
      } else {
        debugPrint('AR Screen: No plane detected, using fallback position');
        // Fallback: place at a lower Y position relative to device
        autoPosition = Vector3(0.0, -0.5, -1.0); // 50cm below device, 1m forward
      }
      
      debugPrint('AR Screen: Auto-placement position: $autoPosition');
      
      // Use the same placement logic as manual tap placement for consistency
      debugPrint('AR Screen: Calling placeObjectAtPosition for auto-placement');
      await placeObjectAtPosition(autoPosition, NodeType.webGLB, "https://github.com/KhronosGroup/glTF-Sample-Models/raw/refs/heads/main/2.0/Duck/glTF-Binary/Duck.glb");
      
      // Mark that we've placed the initial model and show success message
      if (mounted) {
        setState(() {
          hasPlacedInitialModel = true;
          showSuccessMessage = true;
        });
      } else {
        debugPrint('AR Screen: Widget not mounted, skipping auto-placement setState');
        return;
      }
      
      debugPrint('AR Screen: ✅ Auto-placement completed successfully');
      
      // Hide success message after 3 seconds
      Timer(const Duration(seconds: 3), () {
        if (mounted) {
          setState(() {
            showSuccessMessage = false;
            showInstructionMessage = true;
          });
          
          // Hide instruction message after additional 4 seconds
          Timer(const Duration(seconds: 4), () {
            if (mounted) {
              setState(() {
                showInstructionMessage = false;
              });
            } else {
              debugPrint('AR Screen: Widget not mounted, skipping instruction message hide');
            }
          });
        } else {
          debugPrint('AR Screen: Widget not mounted, skipping success message hide');
        }
      });
      
    } catch (e) {
      debugPrint('AR Screen: ❌ Auto-placement error: $e');
      _showSnackBar('Auto-placement failed: $e');
    }
  }

  void _showSnackBar(String message) {
    try {
      if (mounted && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: Colors.black87,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            margin: EdgeInsets.only(
              bottom: MediaQuery.of(context).size.height * 0.1,
              left: 16,
              right: 16,
            ),
          ),
        );
      } else {
        debugPrint('AR Screen: Cannot show snackbar - widget not mounted or context invalid: $message');
      }
    } catch (e) {
      debugPrint('AR Screen: Error showing snackbar: $e');
    }
  }

  String _getLoadingText() {
    if (!isARReady) {
      return "Spúšťam AR...";
    } else if (isDownloadingModel) {
      return "Sťahujem 3D model...";
    }
    return "Načítavam...";
  }

  String _getLoadingSubtext() {
    if (!isARReady) {
      return "Nasadzujem rozšírenú realitu";
    } else if (isDownloadingModel) {
      return "Pripravujem Duck model na AR";
    }
    return "Prosím čakajte...";
  }

  void _navigateToCategory() {
    Navigator.of(context).pushNamed('/category');
  }

  void onGoBack() {
    debugPrint('AR Screen: === GO BACK PRESSED ===');
    debugPrint('AR Screen: Starting navigation cleanup...');
    
    // Start cleanup immediately
    _disposeARSession().then((_) {
      debugPrint('AR Screen: AR session disposed, proceeding with navigation');
      
      // Schedule navigation for the next frame to ensure proper cleanup
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          debugPrint('AR Screen: Navigating to home screen');
          Navigator.of(context).pushNamedAndRemoveUntil(
            '/',
            (route) => false, // Remove all previous routes
            arguments: {'selectedTabIndex': 0}, // Explicitly go to Home tab (index 0)
          );
        } else {
          debugPrint('AR Screen: Widget not mounted, skipping navigation');
        }
      });
    }).catchError((error) {
      debugPrint('AR Screen: Error during cleanup: $error');
      
      // Navigate anyway even if cleanup fails
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          debugPrint('AR Screen: Navigating despite cleanup error');
          Navigator.of(context).pushNamedAndRemoveUntil(
            '/',
            (route) => false,
            arguments: {'selectedTabIndex': 0},
          );
        }
      });
    });
  }

  void removeModel() {
    debugPrint('AR Screen: === REMOVE MODEL ===');
    debugPrint('AR Screen: Nodes count: ${nodes.length}');
    debugPrint('AR Screen: Selected node: $selectedNode');
    debugPrint('AR Screen: AR managers available: ${arObjectManager != null}');
    
    if (nodes.isEmpty) {
      debugPrint('AR Screen: No nodes to remove');
      if (mounted) {
        setState(() {
          selectedNode = null;
        });
      }
      return;
    }

    // Check if AR managers are still available
    if (arObjectManager == null) {
      debugPrint('AR Screen: AR Object Manager not available, clearing local state only');
      nodes.clear();
      nodeCreationOrder.clear();
      if (mounted) {
        setState(() {
          selectedNode = null;
        });
      }
      return;
    }

    ARNode? nodeToRemove;
    int nodeIndexToRemove = -1;
    
    // If we have a selected node ID, try to find and remove it
    if (selectedNode != null) {
      debugPrint('AR Screen: Looking for selected node: $selectedNode');
      // Find the index of the selected node ID in our creation order
      int selectedIndex = nodeCreationOrder.indexOf(selectedNode!);
      if (selectedIndex >= 0 && selectedIndex < nodes.length) {
        nodeToRemove = nodes[selectedIndex];
        nodeIndexToRemove = selectedIndex;
        debugPrint('AR Screen: Found selected node at index: $selectedIndex');
      } else {
        debugPrint('AR Screen: Selected node not found in tracking lists');
      }
    }
    
    // If no specific node was selected or found, remove the last one
    if (nodeToRemove == null && nodes.isNotEmpty) {
      debugPrint('AR Screen: No specific node selected, removing last node');
      nodeToRemove = nodes.last;
      nodeIndexToRemove = nodes.length - 1;
    }
    
    if (nodeToRemove != null && nodeIndexToRemove >= 0) {
      debugPrint('AR Screen: Removing node at index: $nodeIndexToRemove');
      
      // Remove from both lists first
      nodes.removeAt(nodeIndexToRemove);
      nodeCreationOrder.removeAt(nodeIndexToRemove);
      
      // Remove from AR scene with error handling
      Future.microtask(() async {
        try {
          if (arObjectManager != null) {
            await arObjectManager!.removeNode(nodeToRemove!);
            debugPrint('AR Screen: ✅ Node removed from AR scene successfully');
          }
        } catch (e) {
          debugPrint('AR Screen: ❌ Error removing node from AR scene: $e');
          // Continue anyway - the node was removed from our tracking lists
        }
      });
      
      // Clear selection after removal
      if (mounted) {
        setState(() {
          selectedNode = null;
        });
      }
      debugPrint('AR Screen: Node removal completed');
    } else {
      debugPrint('AR Screen: No node to remove, clearing selection');
      if (mounted) {
        setState(() {
          selectedNode = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      top: false,
      child: Scaffold(
        body: Column(
          children: [
            // const Header(),
            Expanded(
              child: Stack(
                children: [
                  ARView(
                    onARViewCreated: onARViewCreated,
                    // Use horizontalAndVertical for better hit testing and object placement
                    planeDetectionConfig: PlaneDetectionConfig.horizontalAndVertical,
                  ),
                  
                  // Loading indicator overlay
                  if (!isARReady || isDownloadingModel)
                    Container(
                      color: Colors.black.withOpacity(0.7),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(
                              color: Color(0xFF004C44),
                              strokeWidth: 3,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              _getLoadingText(),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _getLoadingSubtext(),
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.8),
                                fontSize: 12,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            // Show debug info when product is being downloaded
                            /* if (isDownloadingModel && widget.product != null) ...[
                              const SizedBox(height: 16),
                              Text(
                                'URL: ${widget.product!.modelUrl}',
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.6),
                                  fontSize: 10,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ], */
                          ],
                        ),
                      ),
                    ),
                  
                  // Status messages container - stacks multiple messages vertically to avoid overlap
                  Positioned(
                    top: MediaQuery.of(context).padding.top + 80.0,
                    left: 16,
                    right: 16,
                    child: Column(
                      children: [
                        // Status indicator when waiting for plane detection
                        if (isARReady && !isDownloadingModel && modelName != null && detectedPlane == null && !hasPlacedInitialModel)
                          Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            decoration: BoxDecoration(
                              color: Colors.white.withAlpha((0.9 * 255).toInt()),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.search, color: Color(0xFF004C77), size: 20),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    "Pohybujte zariadením, aby sa detekovali plochy a roviny",
                                    style: const TextStyle(
                                      color: Color(0xFF004C77),
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        
                        // Status indicator when model is ready but not yet placed
                        if (isARReady && !isDownloadingModel && modelName == null && !hasPlacedInitialModel)
                          Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            decoration: BoxDecoration(
                              color: Colors.white.withAlpha((0.9 * 255).toInt()),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.download, color: Color(0xFF004C77), size: 20),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    "Stlačte + na stiahnutie modelu",
                                    style: const TextStyle(
                                      color: Color(0xFF004C77),
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),

                        // Success indicator when model is auto-placed
                        if (hasPlacedInitialModel && showSuccessMessage)
                          Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            decoration: BoxDecoration(
                              color: Colors.white.withAlpha((0.9 * 255).toInt()),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.check_circle, color: Color(0xFF004C77), size: 20),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    "Duck model úspešne umiestnený!",
                                    style: const TextStyle(
                                      color: Color(0xFF004C77),
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        
                        // Instruction message for additional placements
                        if (hasPlacedInitialModel && showInstructionMessage)
                          Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            decoration: BoxDecoration(
                              color: Colors.white.withAlpha((0.9 * 255).toInt()),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.touch_app, color: Color(0xFF004C77), size: 20),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    "Dotykom odznačte aktívny model, potom znova ťuknite na umiestnenie nových objektov",
                                    style: const TextStyle(
                                      color: Color(0xFF004C77),
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        
                        // Show contextual message when a model is selected
                        if (selectedNode != null)
                          Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            decoration: BoxDecoration(
                              color: Colors.white.withAlpha((0.9 * 255).toInt()),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.info_outline, color: Color(0xFF004C77), size: 20),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    "Model označený.\nPre odznačenie sa dotknite miest mimo modelu, alebo použite tlačidlo na vymazanie ak ho chcete odstrániť.",
                                    style: const TextStyle(
                                      color: Color(0xFF004C77),
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  
                  // Back button positioned at the top left
                  Positioned(
                    left: 16.0,
                    top: MediaQuery.of(context).padding.top + 16.0,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha((0.6 * 255).toInt()),
                        borderRadius: BorderRadius.circular(24.0),
                      ),
                      child: IconButton(
                        onPressed: onGoBack,
                        icon: const Icon(
                          Icons.arrow_back,
                          color: Colors.white,
                          size: 24.0,
                        ),
                        padding: const EdgeInsets.all(8.0),
                      ),
                    ),
                  ),
                  
                  // Category button at bottom left
                  Positioned(
                    bottom: MediaQuery.of(context).padding.bottom + 16.0,
                    left: 20,
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: Colors.white.withAlpha((0.9 * 255).toInt()),
                        borderRadius: BorderRadius.circular(28),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withAlpha((0.2 * 255).toInt()),
                            spreadRadius: 2,
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: IconButton(
                        onPressed: _navigateToCategory,
                        icon: const Icon(
                          Icons.add,
                          color: Color(0xFF22514C),
                          size: 24,
                        ),
                        padding: EdgeInsets.zero,
                      ),
                    ),
                  ),

                  // Node selection controls - only show if a node is selected
                  selectedNode != null ? Positioned(
                    bottom: MediaQuery.of(context).padding.bottom + 16.0,
                    right: 20, // Moved right to avoid overlap with category button
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: Colors.white.withAlpha((0.9 * 255).toInt()),
                        borderRadius: BorderRadius.circular(28),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withAlpha((0.2 * 255).toInt()),
                            spreadRadius: 2,
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: IconButton(
                        onPressed: removeModel,
                        icon: const Icon(
                          Icons.delete_outline,
                          color: Color(0xFF22514C),
                          size: 24,
                        ),
                        padding: EdgeInsets.zero,
                      ),
                    ),
                  ) : const SizedBox.shrink(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}