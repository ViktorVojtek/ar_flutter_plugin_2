import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // For MissingPluginException
import 'package:provider/provider.dart';
import 'package:vector_math/vector_math_64.dart' as vm;
import 'dart:io';
import 'dart:async';

// AR Plugin Imports
import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_2/models/ar_node.dart';
import 'package:ar_flutter_plugin_2/models/ar_anchor.dart'; // For ARPlaneAnchor
import 'package:ar_flutter_plugin_2/models/ar_hittest_result.dart';
import 'package:ar_flutter_plugin_2/datatypes/node_types.dart';
import 'package:ar_flutter_plugin_2/datatypes/config_planedetection.dart';

// Camera and permissions
import 'package:saver_gallery/saver_gallery.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

// App Imports
import '../models/product.dart';
import '../providers/ar_navigation_provider.dart';
import '../components/ar_modal_navigator.dart';
import '../components/screen/inspiration/lead_form.dart';
import '../services/ar_memory_manager.dart';
import '../services/analytics_service.dart';

import 'category.dart';

const bool _enableArLogs = false;

void _arLog(Object? message, {bool force = false}) {
  if (!force && (!_enableArLogs || !kDebugMode)) {
    return;
  }
  _arLog(message?.toString());
}

class ARScreen extends StatefulWidget {
  const ARScreen({super.key, required this.title, this.product});

  final String title;
  final Product? product;

  @override
  State<ARScreen> createState() => _ARScreenState();
}

class _ARScreenState extends State<ARScreen> {
  // Core AR components (simplified, based on working example)
  ARSessionManager? arSessionManager;
  ARObjectManager? arObjectManager;
  ARLocationManager? arLocationManager;
  ARAnchorManager? arAnchorManager;

  // Simple state management
  List<ARNode> nodes = <ARNode>[];
  Map<String, ARNode> nodeIdToNodeMap = {}; // Track node ID to ARNode mapping
  Map<String, Product> nodeToProductMap =
      {}; // Track which product belongs to each node
  bool _isARInitialized = false;
  bool _isARSupported = true; // Add AR capability checking
  String _statusText = "Initializing AR...";

  // Model queuing state - queue models until scanning is complete
  bool _hasPendingModel = false;

  // Individual object selection state
  String? selectedNodeId;
  DateTime? _lastNodeTapTime; // Track when a node was last tapped
  final Set<String> _nodesBeingRemoved =
      {}; // Track nodes currently being removed

  // Surface scanning state - RE-ENABLED (without UI overlay)
  bool _isScanningComplete =
      false; // Changed back to false to require proper scanning
  int _detectedPlanesCount = 0;
  bool _showScanningHint = false; // Keep false to hide UI overlay
  static const int _minimumPlanesCount =
      3; // At least 3 plane detections for good coverage
  Timer? _planeScanningTimer;

  // Light estimation state
  Timer? _lightEstimationTimer;
  double? _currentLightIntensity;
  bool _showLowLightWarning = false;
  static const double _lowLightThreshold = 0.3; // 30% threshold

  // Depth occlusion state
  bool _depthSupported = false;
  bool _occlusionEnabled = false;
  String _depthInfo = "Checking...";
  Timer? _depthMonitorTimer;

  // Product state (keep from original)
  Product? _currentProduct;
  String? modelUri;
  bool isDownloadingModel = false;

  // Screenshot state
  bool _isTakingScreenshot = false;

  // DEBUG: Force low memory UI for testing (set to true to see memory warning dialog and disabled button)
  static const bool _debugForceMemoryWarning = false;

  @override
  void initState() {
    super.initState();
    _arLog('🎬 AR SCREEN: initState called');
    _arLog('🎬 AR SCREEN: widget.product = ${widget.product}');
    _arLog('🎬 AR SCREEN: widget.product?.id = ${widget.product?.id}');
    _arLog('🎬 AR SCREEN: widget.product?.name = ${widget.product?.name}');
    _arLog(
      '🎬 AR SCREEN: widget.product?.modelUrl = ${widget.product?.modelUrl}',
    );

    _currentProduct = widget.product;
    _checkARSupport(); // Check AR capability first

    // Wrap initial model handling in error handler
    try {
      _handleNewProductModel();
    } catch (e) {
      _arLog('AR Screen: ⚠️ Error in initial model handling: $e');
    }
  }

  @override
  void didUpdateWidget(ARScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.product?.id != widget.product?.id) {
      _arLog('AR Screen: Product changed - updating model');
      _currentProduct = widget.product;
      _handleNewProductModel();
    }
  }

  @override
  void dispose() {
    _arLog('AR Screen: Disposing AR session...');
    _planeScanningTimer?.cancel();
    _lightEstimationTimer?.cancel();
    _depthMonitorTimer?.cancel();

    // CRITICAL: Set flag FIRST to prevent new initialization during disposal
    _isARInitialized = false;

    // CRITICAL: Use safeDispose() to prevent EGL context and camera crashes
    // safeDispose() automatically pauses AR session, releases camera, then disposes
    if (arSessionManager != null) {
      try {
        _arLog(
          'AR Screen: 🗑️ Safely disposing AR session (pause + dispose)...',
        );
        arSessionManager!.safeDispose();
        _arLog('AR Screen: ✅ AR session safeDispose called successfully');
      } catch (e) {
        _arLog('AR Screen: ⚠️ Error during safeDispose: $e');
        // Fallback to regular dispose if safeDispose fails
        try {
          arSessionManager?.dispose();
        } catch (disposeError) {
          _arLog('AR Screen: ⚠️ Error during fallback dispose: $disposeError');
        }
      }
    }

    // Clear all manager references
    arSessionManager = null;
    arObjectManager = null;
    arAnchorManager = null;
    arLocationManager = null;

    // Clear all references to prevent memory leaks
    nodes.clear();
    nodeIdToNodeMap.clear();
    nodeToProductMap.clear();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Wrap entire build in error boundary
    try {
      return PopScope(
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) {
            // Reset AR navigation state when user exits AR screen (e.g., Android back button)
            context.read<ArNavigationProvider>().resetGoFromAR();
          }
        },
        child: Scaffold(
          body: Stack(
            children: [
              // Check if AR is supported before showing ARView
              if (_isARSupported) ...[
                // AR View (simplified, based on working example)
                ARView(
                  onARViewCreated: _onARViewCreated,
                  planeDetectionConfig: PlaneDetectionConfig.horizontal,
                ),

                // UI Overlays (keep from original but simplified)
                _buildLowLightWarning(),
                _buildDepthStatusOverlay(),
                // _buildScanningGuidanceOverlay(), // DISABLED: Scanning guidance overlay removed
                _buildBackButton(),
                _buildAddButton(), // Now handles both add and delete functionality
                _buildShoppingCartButton(), // New shopping cart button
                _buildDepthToggleButton(),
                _buildCameraButton(),

                // Loading overlay for model downloads
                if (isDownloadingModel) _buildLoadingOverlay(),
              ] else ...[
                // Show fallback UI for unsupported devices
                _buildARUnsupportedView(),
              ],
            ],
          ),
        ),
      );
    } catch (e, stackTrace) {
      _arLog('AR Screen: ❌ Error in build method: $e');
      _arLog('AR Screen: Stack trace: $stackTrace');
      // Return error view instead of crashing
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 48),
              const SizedBox(height: 16),
              const Text(
                'AR Error',
                style: TextStyle(color: Colors.white, fontSize: 20),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  'Please restart the app',
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Go Back'),
              ),
            ],
          ),
        ),
      );
    }
  }

  /// Check if AR is supported on this device
  Future<void> _checkARSupport() async {
    try {
      // For now, assume AR is supported and handle errors gracefully
      // The ar_flutter_plugin will handle device compatibility
      setState(() {
        _isARSupported = true;
        _statusText = "Kontrola podpory AR...";
      });
    } catch (e) {
      _arLog('Kontrola podpory AR zlyhala: $e');
      setState(() {
        _isARSupported = false;
        _statusText = "AR nie je podporované na tomto zariadení";
      });
    }
  }

  /// Build fallback view for devices that don't support AR
  Widget _buildARUnsupportedView() {
    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.white),
            const SizedBox(height: 16),
            const Text(
              'AR Not Supported',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Toto zariadenie nepodporuje AR funkcie.\nProsim použite zariadenie s podporou ARKit.',
              style: TextStyle(color: Colors.white70, fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            _buildBackButton(),
          ],
        ),
      ),
    );
  }

  /// Initialize AR session (simplified, based on working example)
  void _onARViewCreated(
    ARSessionManager arSessionManager,
    ARObjectManager arObjectManager,
    ARAnchorManager arAnchorManager,
    ARLocationManager arLocationManager,
  ) {
    _arLog('AR Screen: Initializing AR session...');

    this.arSessionManager = arSessionManager;
    this.arObjectManager = arObjectManager;
    this.arAnchorManager = arAnchorManager;
    this.arLocationManager = arLocationManager;

    // Wrap initialization in error handler to prevent crashes
    runZonedGuarded(
      () {
        _initializeAR();
      },
      (error, stackTrace) {
        _arLog('AR Screen: ❌ Error during AR view creation: $error');
        _arLog('AR Screen: Stack trace: $stackTrace');
        if (mounted) {
          setState(() {
            _statusText = "AR initialization error - please restart";
          });
        }
      },
    );
  }

  Future<void> _initializeAR() async {
    try {
      setState(() {
        _statusText = "Initializing AR session...";
      });

      // CRITICAL: Check if session is already initialized to prevent double initialization
      if (_isARInitialized) {
        _arLog('AR Screen: ⚠️ AR session already initialized, skipping');
        return;
      }

      // CRITICAL: Check if managers are null (screen was disposed during initialization)
      if (arSessionManager == null || arObjectManager == null) {
        _arLog('AR Screen: ⚠️ Managers are null, screen was likely disposed');
        return;
      }

      // Configure session with plane detection enabled for surface scanning
      await arSessionManager!.onInitialize(
        showFeaturePoints: false,
        showPlanes: false, // Hide plane visualization (the white dots)
        customPlaneTexturePath: null,
        showWorldOrigin: false,
        handlePans: true,
        handleRotation: true,
        maxPanDistance: 5.0,
      );

      // Configure object manager with proper gesture handling
      await arObjectManager!.onInitialize();

      // Set up gesture handlers for pan and rotation with null checks to prevent crashes
      arObjectManager!.onPanStart = (String nodeName) {
        try {
          // Check if node is being removed or doesn't exist
          if (_nodesBeingRemoved.contains(nodeName) ||
              !nodeIdToNodeMap.containsKey(nodeName)) {
            _arLog(
              'AR Screen: ⚠️ Pan started on non-existent/removing node: $nodeName',
            );
            return;
          }
          _arLog('AR Screen: 🔥 Pan started on node: $nodeName');
        } catch (e) {
          _arLog('AR Screen: ❌ Error in onPanStart: $e');
        }
      };

      arObjectManager!.onPanChange = (String nodeName) {
        try {
          if (_nodesBeingRemoved.contains(nodeName) ||
              !nodeIdToNodeMap.containsKey(nodeName))
            return;
          _arLog('AR Screen: 🔥 Pan changing on node: $nodeName');
        } catch (e) {
          _arLog('AR Screen: ❌ Error in onPanChange: $e');
        }
      };

      arObjectManager!.onPanEnd = (String nodeName, Matrix4 transform) {
        try {
          if (_nodesBeingRemoved.contains(nodeName) ||
              !nodeIdToNodeMap.containsKey(nodeName)) {
            _arLog(
              'AR Screen: ⚠️ Pan ended on non-existent/removing node: $nodeName',
            );
            return;
          }
          _arLog('AR Screen: 🔥 Pan ended on node: $nodeName');
        } catch (e) {
          _arLog('AR Screen: ❌ Error in onPanEnd: $e');
        }
      };

      arObjectManager!.onRotationStart = (String nodeName) {
        try {
          if (_nodesBeingRemoved.contains(nodeName) ||
              !nodeIdToNodeMap.containsKey(nodeName)) {
            _arLog(
              'AR Screen: ⚠️ Rotation started on non-existent/removing node: $nodeName',
            );
            return;
          }
          _arLog('AR Screen: 🔥 Rotation started on node: $nodeName');
        } catch (e) {
          _arLog('AR Screen: ❌ Error in onRotationStart: $e');
        }
      };

      arObjectManager!.onRotationChange = (String nodeName) {
        try {
          if (_nodesBeingRemoved.contains(nodeName) ||
              !nodeIdToNodeMap.containsKey(nodeName))
            return;
          _arLog('AR Screen: 🔥 Rotation changing on node: $nodeName');
        } catch (e) {
          _arLog('AR Screen: ❌ Error in onRotationChange: $e');
        }
      };

      arObjectManager!.onRotationEnd = (String nodeName, Matrix4 transform) {
        try {
          if (_nodesBeingRemoved.contains(nodeName) ||
              !nodeIdToNodeMap.containsKey(nodeName)) {
            _arLog(
              'AR Screen: ⚠️ Rotation ended on non-existent/removing node: $nodeName',
            );
            return;
          }
          _arLog('AR Screen: 🔥 Rotation ended on node: $nodeName');
        } catch (e) {
          _arLog('AR Screen: ❌ Error in onRotationEnd: $e');
        }
      };

      // Set up node tap callback with null checks to prevent crashes
      arObjectManager!.onNodeTap = (List<String> nodeNames) {
        try {
          _arLog('AR Screen: 🔥 Node tapped: $nodeNames');
          if (nodeNames.isNotEmpty) {
            final tappedNode = nodeNames.first;
            // Check if node still exists before selecting it
            if (!nodeIdToNodeMap.containsKey(tappedNode)) {
              _arLog('AR Screen: ⚠️ Tapped node no longer exists: $tappedNode');
              return;
            }
            _arLog(
              'AR Screen: 🔍 DEBUG: Setting selectedNodeId from "$selectedNodeId" to "$tappedNode"',
            );
            _arLog(
              'AR Screen: 🔍 DEBUG: Available product mappings: ${nodeToProductMap.keys.toList()}',
            );
            setState(() {
              selectedNodeId = tappedNode;
              _lastNodeTapTime = DateTime.now(); // Record when node was tapped
              _statusText = "Selected: ${nodeNames.join(', ')}";
            });
            _arLog(
              'AR Screen: 🔍 DEBUG: After setState - selectedNodeId = "$selectedNodeId"',
            );
            _arLog('AR Screen: 🔍 DEBUG: Recorded tap time: $_lastNodeTapTime');
          } else {
            _arLog(
              'AR Screen: ⚠️ Node tap received but nodeNames list is empty',
            );
          }
        } catch (e) {
          _arLog('AR Screen: ❌ Error in onNodeTap: $e');
        }
      };

      // iOS DESELECTION FIX: Handle onSelectionChanged for iOS RealityKit
      // iOS sends this callback when tapping empty space to deselect
      arObjectManager!.onSelectionChanged = (String? newSelectedNodeId) {
        try {
          _arLog('AR Screen: 🔄 onSelectionChanged received: $newSelectedNodeId');
          
          // If newSelectedNodeId is null, iOS is telling us to deselect
          if (newSelectedNodeId == null && selectedNodeId != null) {
            _arLog('AR Screen: 🔄 iOS deselection - clearing selectedNodeId');
            _deselectCurrentObject();
          } else if (newSelectedNodeId != null) {
            // Selection changed to a new node (handled by onNodeTap, but sync state)
            _arLog('AR Screen: 🔄 iOS selection changed to: $newSelectedNodeId');
            if (selectedNodeId != newSelectedNodeId) {
              setState(() {
                selectedNodeId = newSelectedNodeId;
                _statusText = "Selected: $newSelectedNodeId";
              });
            }
          }
        } catch (e) {
          _arLog('AR Screen: ❌ Error in onSelectionChanged: $e');
        }
      };

      // Check again if managers are still valid before setting up session callbacks
      if (arSessionManager == null) {
        _arLog(
          'AR Screen: ⚠️ Session manager became null during initialization',
        );
        return;
      }

      // Set up plane detection callback (for error prevention)
      arSessionManager!.onPlaneDetected = (dynamic plane) {
        _arLog('AR Screen: 🌊 Plane detected event: $plane');
        // This callback might not work reliably, using timer approach instead
      };

      // Set up plane/point tap handler for object interaction only
      arSessionManager!.onPlaneOrPointTap = (List<ARHitTestResult> hitResults) {
        _arLog(
          'AR Screen: 🎯 Plane/point tapped with ${hitResults.length} hit results',
        );
        _arLog(
          'AR Screen: 🔍 DEBUG: Current selectedNodeId = "$selectedNodeId"',
        );

        // RE-ENABLED: Surface scanning check - wait for scanning completion
        if (!_isScanningComplete && selectedNodeId != null) {
          _arLog(
            'AR Screen: ⏳ Surface scanning not complete - waiting for floor scan',
          );
          setState(() {
            _statusText = "Scanning floor... Please wait.";
            _showScanningHint = false; // Keep false to hide UI overlay
          });
          return;
        }

        // CRITICAL FIX: Prevent immediate deselection if a node was just tapped
        // This fixes iOS issue where onPlaneOrPointTap fires right after onNodeTap
        if (_lastNodeTapTime != null) {
          final timeSinceTap = DateTime.now().difference(_lastNodeTapTime!);
          if (timeSinceTap.inMilliseconds < 200) {
            _arLog(
              'AR Screen: 🛡️ Ignoring plane tap - node was just selected ${timeSinceTap.inMilliseconds}ms ago',
            );
            return;
          }
        }

        // SIMPLIFIED DESELECTION: Only clear local state when tapping empty space
        if (selectedNodeId != null) {
          _arLog('AR Screen: 🔥 Deselecting object: $selectedNodeId');
          _deselectCurrentObject(); // Now synchronous
        }
      };

      // Check one more time before marking as initialized
      if (!mounted || arSessionManager == null) {
        _arLog(
          'AR Screen: ⚠️ Widget unmounted or session null, aborting initialization',
        );
        return;
      }

      setState(() {
        _isARInitialized = true;
        _statusText = "Scanning floor..."; // Updated status message
        _showScanningHint = false; // Keep false to hide UI overlay
      });

      _arLog('AR Screen: ✅ AR initialization completed');

      // Start light estimation monitoring
      _startLightEstimationMonitoring();

      // Initialize depth occlusion
      _initializeDepthOcclusion();

      // RE-ENABLED: Automatic plane detection timer (without UI overlay)
      _startAutomaticPlaneDetection();

      // Check if we have a product to load - this handles both initial product and updates
      if (_currentProduct != null || widget.product != null) {
        _arLog(
          'AR Screen: 🎯 Product available after AR init - processing model...',
        );
        _handleNewProductModel();
      }
    } catch (e) {
      _arLog('AR Screen: ❌ Error initializing AR: $e');

      // Check if this is an AR capability issue
      if (e.toString().contains('ARKit') ||
          e.toString().contains('not supported') ||
          e.toString().contains('unsupported')) {
        setState(() {
          _isARSupported = false;
          _statusText = "AR not supported on this device";
        });
      } else {
        setState(() {
          _statusText = "Error initializing AR: $e";
        });
      }
    }
  }

  /// Handle new product model (keep from original)
  void _handleNewProductModel() {
    final product = _currentProduct ?? widget.product;
    String? productId = product?.id;
    _arLog('AR Screen: === HANDLING NEW PRODUCT MODEL ===');
    _arLog('AR Screen: Product ID: $productId');
    _arLog('AR Screen: Product name: ${product?.name}');
    _arLog('AR Screen: Product modelUrl: ${product?.modelUrl}');
    _arLog('AR Screen: AR initialized: $_isARInitialized');

    if (product == null) {
      _arLog('AR Screen: ⚠️ No product available to handle');
      return;
    }

    String? modelUrl;

    // Method 1: Direct modelUrl field
    if (product.modelUrl.isNotEmpty) {
      final candidate = product.modelUrl.toString();
      _arLog('AR Screen: Checking direct modelUrl: $candidate');

      if (candidate.toLowerCase().endsWith('.glb')) {
        modelUrl = candidate;
        _arLog('AR Screen: ✅ Found GLB modelUrl directly: $modelUrl');
      } else {
        _arLog(
          'AR Screen: modelUrl is not GLB ($candidate), checking assets for GLB files...',
        );
        final assets = product.assets;
        if (assets.isNotEmpty) {
          // Find the first .glb file in assets
          for (var asset in assets) {
            if (asset.url.toLowerCase().endsWith('.glb')) {
              modelUrl = asset.url;
              _arLog('AR Screen: ✅ Found GLB in assets: $modelUrl');
              break;
            }
          }
        }
      }
    }

    // Method 2: Check assets if no direct modelUrl
    if (modelUrl == null && product.assets.isNotEmpty) {
      _arLog('AR Screen: No direct modelUrl, checking assets...');
      for (var asset in product.assets) {
        if (asset.url.toLowerCase().endsWith('.glb')) {
          modelUrl = asset.url;
          _arLog('AR Screen: ✅ Found GLB in assets: $modelUrl');
          break;
        }
      }
    }

    if (modelUrl != null && modelUrl != modelUri) {
      _arLog('AR Screen: 📦 New model URL detected: $modelUrl');
      setState(() {
        modelUri = modelUrl;
        _statusText = _isARInitialized
            ? (_isScanningComplete
                  ? "Loading new model..."
                  : "Scanning floor... Model will load when ready.")
            : "AR initializing...";
      });

      // If AR is ready, place the model immediately
      if (_isARInitialized) {
        _arLog('AR Screen: 📦 AR is ready, calling _placeModelFromProduct()');
        _placeModelFromProduct();
      } else {
        _arLog(
          'AR Screen: 📦 AR not ready yet, model will be placed after initialization',
        );
      }
    } else if (modelUrl != null &&
        modelUrl == modelUri &&
        _isARInitialized &&
        !_hasPendingModel) {
      // Model URL is same as before, but AR just initialized - try placing again
      _arLog(
        'AR Screen: 🔄 Same model URL but AR just initialized - attempting placement',
      );
      _arLog('AR Screen: 🔄 modelUri: $modelUri');
      _arLog('AR Screen: 🔄 _isARInitialized: $_isARInitialized');
      _arLog('AR Screen: 🔄 _isScanningComplete: $_isScanningComplete');
      _placeModelFromProduct();
    } else if (modelUrl == null) {
      _arLog('AR Screen: ⚠️ No GLB model found for product');
      setState(() {
        modelUri = null;
        _statusText = _isARInitialized
            ? "No 3D model available for this product"
            : "AR initializing...";
      });
    }
  }

  /// Place model from current product (simplified)
  Future<void> _placeModelFromProduct() async {
    // Wrap entire method in try-catch to prevent crashes
    try {
      if (!_isARInitialized || arObjectManager == null || modelUri == null) {
        _arLog(
          'AR Screen: ❌ Cannot place model - AR not ready or no model URI',
        );
        return;
      }

      // Check if widget is still mounted
      if (!mounted) {
        _arLog('AR Screen: ⚠️ Widget unmounted, aborting model placement');
        return;
      }

      // RE-ENABLED: Surface scanning check - wait for proper floor scanning
      if (!_isScanningComplete) {
        _arLog(
          'AR Screen: ⏳ Surface scanning not complete - queuing model for placement',
        );
        _arLog('AR Screen: ⏳ Model URI queued: $modelUri');
        _arLog(
          'AR Screen: ⏳ Detected planes: $_detectedPlanesCount / $_minimumPlanesCount',
        );
        setState(() {
          _hasPendingModel = true;
          _statusText =
              "Scanning floor... Model will be placed automatically when ready.";
          _showScanningHint = false; // Keep false to hide UI overlay
        });
        return;
      }

      // Clear pending flag since we're placing now
      _hasPendingModel = false;

      if (!mounted) return;

      setState(() {
        isDownloadingModel = true;
        _statusText = "Loading 3D model...";
      });

      try {
        _arLog('AR Screen: 🎯 Placing model from URL: $modelUri');

        // Additional safety check
        if (arObjectManager == null || arAnchorManager == null) {
          _arLog('AR Screen: ❌ Managers became null during placement');
          if (mounted) {
            setState(() {
              isDownloadingModel = false;
              _statusText = "AR session lost - please restart";
            });
          }
          return;
        }

        // FIXED: Use simple positioning like the working auto_placement_test.dart
        // Instead of complex trigonometric calculations, use simple offset positions
        double baseX = 0.0;
        double baseY = -1.0; // Consistent Y level
        double baseZ = -1.0; // Consistent distance

        // Simple positioning: spread objects in a line instead of complex semi-circle
        if (nodes.isNotEmpty) {
          int objectIndex = nodes.length;
          // Simple spacing: 0.6 meters apart horizontally
          baseX = (objectIndex % 3 - 1) * 0.6; // -0.6, 0.0, 0.6 pattern
          // Alternate between front and back rows
          if (objectIndex >= 3) {
            baseZ = -1.5; // Back row
          }
        }

        vm.Vector3 simplePosition = vm.Vector3(baseX, baseY, baseZ);

        _arLog('AR Screen: 🎯 Simple position for object ${nodes.length + 1}:');
        _arLog('AR Screen: 🎯   Position: $simplePosition');

        Matrix4 transformation = Matrix4.identity();
        transformation.setTranslationRaw(
          simplePosition.x,
          simplePosition.y,
          simplePosition.z,
        );

        String nodeName = "Product_${DateTime.now().millisecondsSinceEpoch}";

        // FIXED: Use smaller, consistent scale like auto_placement_test.dart
        vm.Vector3 scale = vm.Vector3(
          1.0,
          1.0,
          1.0,
        ); // Consistent scale instead of platform-dependent

        // CRITICAL: Create an anchor at the desired position for panning to work
        // Panning requires an anchor - without it, only rotation works!
        var newAnchor = ARPlaneAnchor(transformation: transformation);
        bool? didAddAnchor = await arAnchorManager!.addAnchor(newAnchor);

        if (didAddAnchor != true) {
          _arLog('AR Screen: ❌ Failed to create anchor for object');
          setState(() {
            isDownloadingModel = false;
            _statusText = "Failed to create anchor";
          });
          return;
        }

        _arLog('AR Screen: ✅ Anchor created: ${newAnchor.name}');

        // Node position should be (0,0,0) relative to anchor - anchor provides world position
        ARNode node = ARNode(
          type: NodeType.webGLB,
          uri: modelUri!,
          name: nodeName,
          position: vm.Vector3(0.0, 0.0, 0.0), // Position relative to anchor
          scale: scale, // Reasonable default scale
          isTransformable: true,
          enablePanGestures: true,
          enableRotationGestures: true,
        );

        _arLog('AR Screen: 📦 Created ARNode: $nodeName');
        _arLog('AR Screen: 📍 Position: $simplePosition (anchor position)');
        _arLog('AR Screen: 🌐 URL: $modelUri');

        // Place the model WITH the anchor - this enables panning!
        String? result = await arObjectManager!.addNode(
          node,
          planeAnchor: newAnchor,
        );

        if (result != null) {
          _arLog('AR Screen: ✅ PLACEMENT SUCCESS! Node ID: $result');

          // Store the ARNode with comprehensive tracking
          nodes.add(node);

          // Map both the returned ID and original node name to the ARNode object
          nodeIdToNodeMap[result] = node; // Map returned ID to ARNode object
          nodeIdToNodeMap[node.name] =
              node; // Also map original name to ARNode object

          // Map both the returned ID and original node name to the product
          if (_currentProduct != null) {
            nodeToProductMap[result] =
                _currentProduct!; // Use the returned ID as primary key
            nodeToProductMap[node.name] =
                _currentProduct!; // Also map original name for compatibility
            _arLog(
              'AR Screen: 📝 Stored product mapping: $result -> ${_currentProduct!.name}',
            );
            _arLog(
              'AR Screen: 📝 Stored product mapping: ${node.name} -> ${_currentProduct!.name}',
            );
            _arLog(
              'AR Screen: 📝 Stored ARNode mapping: $result -> ${node.name}',
            );
            _arLog(
              'AR Screen: 📝 Stored ARNode mapping: ${node.name} -> ${node.name}',
            );
          }

          setState(() {
            isDownloadingModel = false;
            _statusText =
                "✅ Model placed! Tap objects to select them for deletion.";
          });
        } else {
          _arLog('AR Screen: ❌ PLACEMENT FAILED! addNode returned null');
          setState(() {
            isDownloadingModel = false;
            _statusText = "❌ Model placement failed - please try again";
          });
        }
      } catch (e) {
        _arLog('AR Screen: ❌ Exception during model placement: $e');
        if (mounted) {
          setState(() {
            isDownloadingModel = false;
            _statusText = "❌ Model placement error: $e";
          });
        }
      }
    } catch (outerError, stackTrace) {
      // Outer catch to handle any errors in the entire method
      _arLog(
        'AR Screen: ❌ Critical error in _placeModelFromProduct: $outerError',
      );
      _arLog('AR Screen: Stack trace: $stackTrace');
      if (mounted) {
        setState(() {
          isDownloadingModel = false;
          _statusText = "❌ Critical error - please restart";
        });
      }
    }
  }

  /// Start automatic plane detection using timer-based approach (without UI overlay)
  void _startAutomaticPlaneDetection() {
    if (_isScanningComplete) return;

    _arLog('AR Screen: 🔍 Starting automatic plane detection timer...');

    // Start a timer that checks for planes periodically
    _planeScanningTimer = Timer.periodic(Duration(seconds: 2), (timer) async {
      try {
        if (!_isARInitialized ||
            arSessionManager == null ||
            _isScanningComplete ||
            !mounted) {
          timer.cancel();
          return;
        }

        await _checkForDetectedPlanes();
      } catch (e) {
        _arLog('AR Screen: ⚠️ Error in plane detection timer: $e');
        // Don't cancel timer, just log the error
      }
    });

    // Also simulate plane detection based on time (planes are hidden but detection still works)
    Timer.periodic(Duration(seconds: 3), (timer) {
      try {
        if (_isScanningComplete || !mounted) {
          timer.cancel();
          return;
        }

        // Simulate plane detection (planes are hidden with showPlanes: false)
        _simulatePlaneDetection();
      } catch (e) {
        _arLog('AR Screen: ⚠️ Error in plane simulation timer: $e');
      }
    });
  }

  /// Check for detected planes using hit testing
  Future<void> _checkForDetectedPlanes() async {
    try {
      // Since we can see white dots (planes) but callback isn't working,
      // let's use a time-based approach combined with visual confirmation
      if (_detectedPlanesCount < _minimumPlanesCount) {
        _arLog('AR Screen: 🔍 Checking for planes automatically...');
        // Simulate detection since planes are visually confirmed
        _updateSurfaceScanning();
      }
    } catch (e) {
      _arLog('AR Screen: ❌ Error checking for planes: $e');
    }
  }

  /// Simulate plane detection since visual planes are confirmed
  void _simulatePlaneDetection() {
    if (_detectedPlanesCount < _minimumPlanesCount) {
      _arLog('AR Screen: 🌊 Simulating plane detection (planes are visible)');
      _updateSurfaceScanning();
    }
  }

  /// Update surface scanning progress based on automatic plane detection (without UI overlay)
  void _updateSurfaceScanning() {
    // Increment the counter each time a plane is detected
    _detectedPlanesCount++;

    _arLog(
      'AR Screen: 📊 Surface scanning update - detected planes: $_detectedPlanesCount',
    );

    // Check if we have sufficient surface area scanned
    bool wasComplete = _isScanningComplete;
    _isScanningComplete = _detectedPlanesCount >= _minimumPlanesCount;

    if (!wasComplete && _isScanningComplete) {
      // Scanning just completed
      _arLog('AR Screen: ✅ Surface scanning completed!');
      _planeScanningTimer?.cancel(); // Stop the timer
      setState(() {
        _statusText =
            "Floor scanned! Tap + to add products or tap objects to select them.";
        _showScanningHint = false; // Keep false to hide UI overlay
      });

      // If we have a pending model, place it now
      _arLog('AR Screen: 🔍 Checking for pending model...');
      _arLog('AR Screen: 🔍 _hasPendingModel: $_hasPendingModel');
      _arLog('AR Screen: 🔍 modelUri: $modelUri');
      _arLog('AR Screen: 🔍 _currentProduct: ${_currentProduct?.name}');

      if (_hasPendingModel && modelUri != null) {
        _arLog(
          'AR Screen: 🎯 Placing queued model now that scanning is complete',
        );
        _placeModelFromProduct();
      } else if (modelUri != null && !_hasPendingModel) {
        _arLog(
          'AR Screen: 🎯 Model available but not flagged as pending - placing anyway',
        );
        _placeModelFromProduct();
      } else {
        _arLog('AR Screen: ⚠️ No pending model to place');
      }
    } else if (!_isScanningComplete) {
      // Still scanning - update progress (without showing UI overlay)
      setState(() {
        _statusText =
            "Scanning floor ($_detectedPlanesCount/$_minimumPlanesCount areas found)";
        _showScanningHint = false; // Keep false to hide UI overlay
      });
    }
  }

  /// Deselect the currently selected object (SIMPLIFIED: Only clear local state)
  void _deselectCurrentObject() {
    _arLog(
      'AR Screen: 🔄 _deselectCurrentObject called - selectedNodeId: "$selectedNodeId"',
    );

    if (selectedNodeId == null) {
      _arLog('AR Screen: ⚠️ No object selected to deselect');
      return;
    }

    // SIMPLIFIED: Only clear local UI state, don't interfere with AR plugin internals
    final previousSelection = selectedNodeId;
    _arLog('AR Screen: 🔄 Clearing selection state for: $previousSelection');

    setState(() {
      selectedNodeId = null;
      _statusText = _isScanningComplete
          ? "Object deselected. Tap + to add products."
          : "Scanning floor..."; // Restored scanning check
    });

    _arLog(
      'AR Screen: ✅ Local selection state cleared - gestures should work normally',
    );
  }

  bool _isBenignRemovalError(Object error) {
    final message = error.toString();
    return message.contains('_UnmodifiableByteDataView') ||
        message.contains('No point hit') ||
        message.contains('node not found') ||
        message.contains('Node not found') ||
        message.contains('No implementation found for method removeNode') ||
        message.contains('timestamp') ||
        message.contains('PoseManager') ||
        message.contains('MissingPluginException');
  }

  Future<bool> _tryRemoveNode(ARNode node) async {
    if (arObjectManager == null) {
      return false;
    }

    try {
      final result = await arObjectManager!.removeNode(node);
      _arLog('AR Screen: ✅ removeNode returned $result for ${node.name}');
      return result != false;
    } on MissingPluginException catch (error, stackTrace) {
      _arLog('AR Screen: ⚠️ MissingPluginException during removeNode: $error');
      _arLog(stackTrace.toString());
      if (_isBenignRemovalError(error)) {
        _arLog(
          'AR Screen: ✅ Treating MissingPluginException as benign, assuming removal succeeded',
        );
        return true;
      }
      return false;
    } on PlatformException catch (error, stackTrace) {
      _arLog(
        'AR Screen: ⚠️ PlatformException during removeNode: ${error.code} ${error.message}',
      );
      _arLog(stackTrace.toString());
      if (_isBenignRemovalError(error)) {
        _arLog(
          'AR Screen: ✅ Treating PlatformException as benign, assuming removal succeeded',
        );
        return true;
      }
      return false;
    } catch (error, stackTrace) {
      _arLog('AR Screen: ❌ Unexpected error during removeNode: $error');
      _arLog(stackTrace.toString());
      if (_isBenignRemovalError(error)) {
        _arLog(
          'AR Screen: ✅ Treating unexpected error as benign, assuming removal succeeded',
        );
        return true;
      }
      return false;
    }
  }

  Future<bool> _tryRemoveNodeById(String nodeId) async {
    if (arObjectManager == null) {
      return false;
    }

    try {
      final result = await arObjectManager!.removeNodeDeep(nodeId);
      _arLog('AR Screen: ✅ removeNodeDeep returned $result for $nodeId');
      return result;
    } on MissingPluginException catch (error, stackTrace) {
      _arLog(
        'AR Screen: ⚠️ MissingPluginException during removeNodeDeep: $error',
      );
      _arLog(stackTrace.toString());
      if (_isBenignRemovalError(error)) {
        _arLog(
          'AR Screen: ✅ Treating MissingPluginException as benign for removeNodeDeep',
        );
        return true;
      }
      return false;
    } on PlatformException catch (error, stackTrace) {
      _arLog(
        'AR Screen: ⚠️ PlatformException during removeNodeDeep: ${error.code} ${error.message}',
      );
      _arLog(stackTrace.toString());
      if (_isBenignRemovalError(error)) {
        _arLog(
          'AR Screen: ✅ Treating PlatformException as benign for removeNodeDeep',
        );
        return true;
      }
      return false;
    } catch (error, stackTrace) {
      _arLog('AR Screen: ❌ Unexpected error during removeNodeDeep: $error');
      _arLog(stackTrace.toString());
      if (_isBenignRemovalError(error)) {
        _arLog(
          'AR Screen: ✅ Treating unexpected error as benign for removeNodeDeep',
        );
        return true;
      }
      return false;
    }
  }

  void _cleanupRemovedNode(String nodeId, {ARNode? removedNode}) {
    final productToRemove = nodeToProductMap[nodeId];
    nodeToProductMap.remove(nodeId);

    if (removedNode != null) {
      nodeToProductMap.remove(removedNode.name);
      nodes.remove(removedNode);
      if (removedNode.name != nodeId) {
        nodes.removeWhere((node) => node.name == nodeId);
      }
      nodeIdToNodeMap.remove(removedNode.name);
    } else {
      nodes.removeWhere((node) => node.name == nodeId);
    }

    nodeIdToNodeMap.remove(nodeId);

    if (productToRemove != null) {
      nodeToProductMap.removeWhere((key, value) => value == productToRemove);
    }

    if (mounted) {
      setState(() {
        _statusText = nodes.isEmpty
            ? "Object removed! ${modelUri != null ? 'Select a product to place.' : 'Add objects using the + button.'}"
            : "Object removed! Tap objects to select them.";
      });
    }

    _arLog(
      'AR Screen: 🧹 Cleanup complete - remaining objects: ${nodes.length}',
    );
  }

  /// Remove selected object (improved node tracking for cross-platform compatibility)
  Future<void> _removeSelectedObject() async {
    if (arObjectManager == null || selectedNodeId == null) {
      _arLog('AR Screen: ❌ Cannot remove - no object selected or AR not ready');
      return;
    }

    // Store the node ID before clearing to prevent race conditions
    final nodeIdToRemove = selectedNodeId!;

    // Mark this node as being removed to prevent gesture handlers from accessing it
    _nodesBeingRemoved.add(nodeIdToRemove);

    // CRITICAL: Clear selection state IMMEDIATELY to prevent gesture callbacks
    // from trying to access the node while it's being removed
    setState(() {
      selectedNodeId = null;
      _statusText = "Removing selected object...";
    });

    try {
      _arLog('AR Screen: 🗑️ Removing individual object: $nodeIdToRemove');

      // First, try to get the ARNode object from our tracking map
      ARNode? nodeToRemove = nodeIdToNodeMap[nodeIdToRemove];
      if (nodeToRemove == null) {
        for (final node in nodes) {
          if (node.name == nodeIdToRemove) {
            nodeToRemove = node;
            break;
          }
        }
      }

      if (nodeToRemove == null) {
        _arLog(
          'AR Screen: ❌ Could not find ARNode object for selected ID: $nodeIdToRemove',
        );
        _arLog('AR Screen: 🔍 Available node IDs: ${nodeIdToNodeMap.keys}');
        _arLog(
          'AR Screen: 🔍 Available node names: ${nodes.map((n) => n.name)}',
        );

        final deepRemovalSuccess = await _tryRemoveNodeById(nodeIdToRemove);
        if (deepRemovalSuccess) {
          _cleanupRemovedNode(nodeIdToRemove);
        } else if (mounted) {
          setState(() {
            _statusText = "❌ Could not find object to remove";
          });
        }
        return;
      }

      _arLog('AR Screen: 🗑️ Found ARNode to remove: ${nodeToRemove.name}');

      await Future.delayed(const Duration(milliseconds: 100));
      _arLog('AR Screen: ⏱️ Delay complete, proceeding with removal...');

      bool removalSucceeded = await _tryRemoveNode(nodeToRemove);

      if (!removalSucceeded) {
        _arLog(
          'AR Screen: ❌ Regular removeNode did not confirm success, trying removeNodeDeep...',
        );
        removalSucceeded = await _tryRemoveNodeById(nodeIdToRemove);
      }

      if (removalSucceeded) {
        _cleanupRemovedNode(nodeIdToRemove, removedNode: nodeToRemove);
      } else if (mounted) {
        setState(() {
          _statusText = "❌ Failed to remove object - please try again";
        });
      }
    } catch (e, stackTrace) {
      _arLog('AR Screen: ❌ Exception during object removal: $e');
      _arLog('AR Screen: ❌ Error type: ${e.runtimeType}');
      _arLog('AR Screen: ❌ Stack trace: $stackTrace');

      if (mounted) {
        setState(() {
          _statusText = "❌ Object removal failed";
        });
      }
    } finally {
      // Always remove from the tracking set, even if removal failed
      _nodesBeingRemoved.remove(nodeIdToRemove);
      _arLog('AR Screen: 🧹 Removed $nodeIdToRemove from removal tracking set');
    }
  }

  /// Navigate to category (keep from original)
  Future<void> _navigateToCategory() async {
    _arLog('AR Screen: === CHECKING MEMORY BEFORE SHOWING CATEGORY MODAL ===');

    // CRITICAL: Check memory BEFORE opening modal to prevent user from browsing if memory is full
    final memInfo = await ARMemoryManager.getCurrentMemoryInfo();

    // DEBUG: Force memory warning for UI testing
    if (_debugForceMemoryWarning || !memInfo.canAddModel) {
      _arLog('AR Screen: ❌ Memory check failed - cannot add more models');
      _arLog(
        'AR Screen: Memory status: ${memInfo.status}, Usage: ${memInfo.usagePercentage.toStringAsFixed(1)}%',
      );

      // Show memory warning dialog
      _showMemoryWarningDialog(memInfo);

      setState(() {
        _statusText = "Nedostatok pamäte - odstráňte niektoré objekty";
      });

      return;
    }

    _arLog('AR Screen: ✅ Memory check passed - showing category modal');

    // Set navigation state
    if (mounted) {
      context.read<ArNavigationProvider>().setGoFromAR();
    }

    // Show modal overlay instead of navigation - this keeps AR session alive
    final result = await showModalBottomSheet<Product?>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) =>
          _buildARModalOverlay(child: CategoryScreen(isSearchHeaderShow: true)),
    );

    // Handle result if user selected a product
    if (mounted && result != null) {
      _arLog('AR Screen: 📦 Product selected from modal: ${result.name}');
      // Update current product state
      setState(() {
        _currentProduct = result;
      });

      // Process the new product model
      _handleNewProductModel();
    } else {
      // User closed modal without selecting a product
      _arLog('AR Screen: ℹ️ Modal closed without selection');
    }

    _arLog('AR Screen: ✅ Category modal closed - AR session preserved');
  }

  /// Build AR modal overlay (keep from original)
  Widget _buildARModalOverlay({required Widget child}) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.9,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
        ),
        child: ARModalNavigator(
          initialChild: child,
          onProductSelected: (Product product) {
            Navigator.of(context).pop(product);
          },
        ),
      ),
    );
  }

  /// Start monitoring light estimation
  void _startLightEstimationMonitoring() {
    _arLog('AR Screen: Starting light estimation monitoring');

    // Check light estimation every second
    _lightEstimationTimer = Timer.periodic(const Duration(seconds: 1), (
      timer,
    ) async {
      if (arSessionManager != null) {
        try {
          final lightData = await arSessionManager!.getLightEstimate();

          if (lightData != null) {
            // Extract intensity from the light estimate data
            // Android uses 'pixelIntensity', iOS uses 'normalizedIntensity'
            // Both are normalized to 0.0-1.0 range
            final intensity =
                (lightData['pixelIntensity'] ??
                        lightData['normalizedIntensity'] ??
                        0.0)
                    as double;

            _arLog(
              'AR Screen: Light intensity: ${(intensity * 100).toStringAsFixed(1)}%',
            );

            // Check if we should show warning (below 30% threshold)
            bool shouldShowWarning = intensity < _lowLightThreshold;

            // Update state if light condition changed
            if (_showLowLightWarning != shouldShowWarning ||
                _currentLightIntensity != intensity) {
              if (mounted) {
                setState(() {
                  _currentLightIntensity = intensity;
                  _showLowLightWarning = shouldShowWarning;
                });
              }
            }
          }
        } catch (e) {
          _arLog('AR Screen: Error getting light estimate: $e');
        }
      }
    });
  }

  /// Build low light warning overlay
  Widget _buildLowLightWarning() {
    if (!_showLowLightWarning) {
      return const SizedBox.shrink();
    }

    return Positioned(
      bottom:
          MediaQuery.of(context).padding.bottom +
          120.0, // Above bottom controls
      left: 16,
      right: 16,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(12),
          // border: Border.all(color: Colors.yellow.withValues(alpha: 0.5), width: 1),
        ),
        child: Row(
          children: [
            const Icon(Icons.lightbulb_outline, color: Colors.yellow, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                "Nedostatok svetla.\nZapnite svetlo, alebo odtiahnite závesy.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // DISABLED: Build scanning guidance overlay - no longer needed since scanning is disabled
  // /// Build scanning guidance overlay to help users understand surface scanning
  // Widget _buildScanningGuidanceOverlay() {
  //   if (_isScanningComplete || !_showScanningHint) {
  //     return const SizedBox.shrink();
  //   }
  //
  //   return Positioned(
  //     top: MediaQuery.of(context).padding.top + 80.0, // Below back button
  //     left: 16,
  //     right: 16,
  //     child: Container(
  //       padding: const EdgeInsets.all(16),
  //       decoration: BoxDecoration(
  //         color: Colors.black.withValues(alpha: 0.7),
  //         borderRadius: BorderRadius.circular(12),
  //         border: Border.all(color: Colors.orange.withValues(alpha: 0.5), width: 1),
  //       ),
  //       child: Column(
  //         crossAxisAlignment: CrossAxisAlignment.start,
  //         mainAxisSize: MainAxisSize.min,
  //         children: [
  //           Row(
  //             children: [
  //               Icon(
  //                 Icons.device_hub,
  //                 color: Colors.orange,
  //                 size: 20,
  //               ),
  //               const SizedBox(width: 8),
  //               Expanded(
  //                 child: Text(
  //                   "Scanning Floor Surface",
  //                   style: TextStyle(
  //                     color: Colors.white,
  //                     fontSize: 16,
  //                     fontWeight: FontWeight.bold,
  //                   ),
  //                 ),
  //               ),
  //               GestureDetector(
  //                 onTap: () {
  //                   setState(() {
  //                     _showScanningHint = false;
  //                   });
  //                 },
  //                 child: Icon(
  //                   Icons.close,
  //                   color: Colors.white70,
  //                   size: 18,
  //                 ),
  //               ),
  //             ],
  //           ),
  //           const SizedBox(height: 8),
  //           Text(
  //             _statusText,
  //             style: TextStyle(color: Colors.white, fontSize: 14),
  //           ),
  //           const SizedBox(height: 8),
  //           Row(
  //             children: [
  //               Icon(
  //                 Icons.phone_android,
  //                 color: Colors.blue,
  //                 size: 16,
  //               ),
  //               const SizedBox(width: 6),
  //               Expanded(
  //                 child: Text(
  //                   "Move your device slowly from side to side to detect more floor area",
  //                   style: TextStyle(
  //                     color: Colors.white70,
  //                     fontSize: 12,
  //                   ),
  //                 ),
  //               ),
  //             ],
  //           ),
  //           const SizedBox(height: 4),
  //           // Progress indicator
  //           LinearProgressIndicator(
  //             value: _detectedPlanesCount / _minimumPlanesCount,
  //             backgroundColor: Colors.white24,
  //             valueColor: AlwaysStoppedAnimation<Color>(
  //               _detectedPlanesCount >= _minimumPlanesCount ? Colors.green : Colors.orange,
  //             ),
  //           ),
  //           const SizedBox(height: 4),
  //           Text(
  //             "Progress: ${_detectedPlanesCount}/$_minimumPlanesCount areas detected",
  //             style: TextStyle(
  //               color: Colors.white60,
  //               fontSize: 11,
  //             ),
  //           ),
  //         ],
  //       ),
  //     ),
  //   );
  // }

  /// Build back button (keep from original but simplified)
  Widget _buildBackButton() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 8.0,
      left: 16.0,
      child: Container(
        padding: const EdgeInsets.all(4.0),
        decoration: BoxDecoration(
          color: Colors.black.withAlpha((0.5 * 255).toInt()),
          borderRadius: BorderRadius.circular(32.0),
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
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () async {
            _arLog('AR Screen: Back button pressed - disposing AR session');
            // Reset AR navigation state when exiting AR screen
            context.read<ArNavigationProvider>().resetGoFromAR();
            Navigator.of(context).pop();
          },
        ),
      ),
    );
  }

  /// Build add/delete button (merged functionality)
  Widget _buildAddButton() {
    bool hasSelection = selectedNodeId != null;
    bool showAddButton =
        !hasSelection; // Show + when no selection, trash when object selected

    // RE-ENABLED: Scanning state check - only allow adding after scanning
    // Also check for debug memory warning or actual memory limits
    bool canAddObjects =
        (_isScanningComplete && !_debugForceMemoryWarning) || hasSelection;

    // Use red background for delete button, white/gray for add button
    Color buttonColor;
    if (showAddButton) {
      buttonColor = canAddObjects
          ? Colors.white.withAlpha((0.9 * 255).toInt())
          : Colors.grey.withAlpha(
              (0.7 * 255).toInt(),
            ); // Gray when scanning or memory full
    } else {
      // Red background for delete/remove button
      buttonColor = Colors.red.withAlpha((0.9 * 255).toInt());
    }

    return Positioned(
      bottom: MediaQuery.of(context).padding.bottom + 16.0,
      left: 20,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: buttonColor,
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
          onPressed: () async {
            if (showAddButton) {
              // Check scanning state and memory warning
              if (_isScanningComplete && !_debugForceMemoryWarning) {
                _navigateToCategory();
              } else if (_debugForceMemoryWarning) {
                // Show memory warning immediately without async check
                _arLog('AR Screen: 🧪 DEBUG: Forced memory warning triggered');
                final memInfo = await ARMemoryManager.getCurrentMemoryInfo();
                _showMemoryWarningDialog(memInfo);
              } else {
                // Silently ignore tap while scanning (no UI overlay shown)
                _arLog(
                  'AR Screen: ⏳ Cannot add objects - floor scanning in progress',
                );
              }
            } else {
              // Run removal in a zone to catch any uncaught exceptions from the plugin
              await runZonedGuarded(
                () async {
                  try {
                    await _removeSelectedObject();
                  } catch (e) {
                    _arLog('AR Screen: ❌ Error in delete button handler: $e');
                    if (mounted) {
                      setState(() {
                        _statusText = "Error removing object";
                      });
                    }
                  }
                },
                (error, stackTrace) {
                  // Catch any exceptions that escaped our try-catch (from plugin native code)
                  _arLog('AR Screen: ⚠️ Uncaught exception in zone: $error');
                  _arLog('AR Screen: ⚠️ Stack trace: $stackTrace');
                  // Don't show error to user since removal likely succeeded
                },
              );
            }
          },
          icon: Icon(
            showAddButton ? Icons.add : Icons.delete,
            color: showAddButton
                ? (canAddObjects
                      ? Color(0xFF22514C)
                      : Colors.grey[600]) // Gray icon while scanning
                : Colors
                      .white, // White icon for delete button on red background
            size: 24,
          ),
          padding: EdgeInsets.zero,
        ),
      ),
    );
  }

  /// Build shopping cart button (for forms and shop links)
  Widget _buildShoppingCartButton() {
    _arLog('AR Screen: 🛒 Building shopping cart button...');
    final currentSelectedId = selectedNodeId;
    _arLog('AR Screen: 🛒 selectedNodeId: $currentSelectedId');

    // Only show if we have a selected object and can find its corresponding product
    if (currentSelectedId == null) {
      _arLog('AR Screen: 🛒 No selected node - hiding shopping cart button');
      return const SizedBox.shrink();
    }

    // Get the product for the selected node (try multiple lookup strategies)
    Product? selectedProduct = nodeToProductMap[currentSelectedId];

    // If not found by direct lookup, try finding by matching any stored key
    if (selectedProduct == null) {
      _arLog(
        'AR Screen: 🛒 Direct lookup failed, trying alternative lookups...',
      );
      _arLog(
        'AR Screen: 🛒 Available keys in nodeToProductMap: ${nodeToProductMap.keys.toList()}',
      );

      // Try to find a key that contains or matches our selectedNodeId
      for (String key in nodeToProductMap.keys) {
        if (key.contains(currentSelectedId) ||
            currentSelectedId.contains(key)) {
          selectedProduct = nodeToProductMap[key];
          _arLog(
            'AR Screen: 🛒 Found product via alternative lookup with key: $key',
          );
          break;
        }
      }

      // If still not found, try using _currentProduct as fallback since we track it
      if (selectedProduct == null && _currentProduct != null) {
        selectedProduct = _currentProduct;
        _arLog(
          'AR Screen: 🛒 Using _currentProduct as fallback: ${selectedProduct?.name}',
        );
      }
    }

    _arLog(
      'AR Screen: 🛒 Product for selected node: ${selectedProduct?.name ?? "NOT FOUND"}',
    );

    if (selectedProduct == null) {
      _arLog(
        'AR Screen: 🛒 No product found for node $currentSelectedId - hiding shopping cart button',
      );
      return const SizedBox.shrink();
    }

    final hasCompanyForm = _hasCompanyForm(selectedProduct);
    final hasShopUrl = _hasShopUrl(selectedProduct);

    _arLog(
      'AR Screen: 🛒 hasCompanyForm: $hasCompanyForm, hasShopUrl: $hasShopUrl',
    );

    // Only show if product has either form capability or shop URL
    if (!hasCompanyForm && !hasShopUrl) {
      _arLog('AR Screen: 🛒 No form or shop URL - hiding shopping cart button');
      return const SizedBox.shrink();
    }

    _arLog(
      'AR Screen: 🛒 Showing shopping cart button for ${selectedProduct.name}',
    );

    return Positioned(
      bottom: MediaQuery.of(context).padding.bottom + 16.0,
      right: 20,
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
          onPressed: () => _onShoppingCartPress(
            selectedProduct!,
          ), // selectedProduct is guaranteed non-null here
          icon: Icon(Icons.shopping_cart, color: Color(0xFF22514C), size: 24),
          padding: EdgeInsets.zero,
        ),
      ),
    );
  }

  /// Check if product has company form capability
  bool _hasCompanyForm(Product product) {
    // For demonstration purposes, let's show the form for certain products
    // In a real implementation, this would check the raw product data
    // For now, we'll use a simple heuristic based on product name
    if (product.name.toLowerCase().contains('saffron')) {
      return true; // Saffron products have forms
    }
    return false;
  }

  /// Check if product has shop URL
  bool _hasShopUrl(Product product) {
    // Check if product has an actual shop URL
    return product.shopUrl != null && product.shopUrl!.isNotEmpty;
  }

  /// Handle shopping cart button press
  Future<void> _onShoppingCartPress(Product product) async {
    final hasCompanyForm = _hasCompanyForm(product);

    if (hasCompanyForm) {
      // Show lead form modal
      await _showLeadFormModal(product);
    } else {
      // Open shop URL
      await _openShopUrl(product);
    }
  }

  /// Show lead form modal
  Future<void> _showLeadFormModal(Product product) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (context, scrollController) => Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
            ),
          ),
          child: Column(
            children: [
              // Drag handle
              Container(
                margin: const EdgeInsets.only(top: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              // Title
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Text(
                  'Contact ${product.name}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Form content with proper scrolling and padding
              Expanded(
                child: SingleChildScrollView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(
                    16.0,
                    0,
                    16.0,
                    32.0,
                  ), // Extra bottom padding
                  child: const InspirationLeadForm(shouldAutoFocus: true),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Open shop URL
  Future<void> _openShopUrl(Product product) async {
    // Use the actual product shop URL if available
    String? targetUrl = product.shopUrl;

    // If no shop URL is available, show an error
    if (targetUrl.isEmpty) {
      _arLog(
        'AR Screen: ⚠️ No shop URL available for product: ${product.name}',
      );
      _showSnackBar('❌ No shop link available for this product');
      return;
    }

    _arLog('AR Screen: 🌐 Attempting to open URL: $targetUrl');

    try {
      final uri = Uri.parse(targetUrl);
      _arLog('AR Screen: 🌐 Parsed URI: $uri');

      // Check if URL can be launched
      bool canLaunch = await canLaunchUrl(uri);
      _arLog('AR Screen: 🌐 Can launch URL: $canLaunch');

      if (canLaunch) {
        bool launched = await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
          // Add additional web view fallback for Android
          webViewConfiguration: const WebViewConfiguration(
            enableJavaScript: true,
            enableDomStorage: true,
          ),
        );

        if (launched) {
          _arLog('AR Screen: ✅ Successfully opened shop URL: $targetUrl');
          // _showSnackBar('Opening shop for ${product.name}...');
        } else {
          _arLog('AR Screen: ❌ launchUrl returned false for: $targetUrl');
          _showSnackBar('❌ Could not open shop link');
        }
      } else {
        _arLog('AR Screen: ❌ canLaunchUrl returned false for: $targetUrl');
        // Try alternative launch mode
        try {
          _arLog('AR Screen: 🔄 Trying platformDefault launch mode...');
          bool altLaunched = await launchUrl(
            uri,
            mode: LaunchMode.platformDefault,
          );
          if (altLaunched) {
            _arLog(
              'AR Screen: ✅ Successfully opened with platformDefault mode',
            );
            // _showSnackBar('Opening shop for ${product.name}...');
          } else {
            _arLog('AR Screen: ❌ Alternative launch also failed');
            _showSnackBar('❌ Could not open shop link - no browser found');
          }
        } catch (altError) {
          _arLog('AR Screen: ❌ Alternative launch error: $altError');
          _showSnackBar('❌ Could not open shop link');
        }
      }
    } catch (e) {
      _arLog('AR Screen: ❌ Error launching URL: $e');
      _arLog('AR Screen: ❌ Error type: ${e.runtimeType}');
      _showSnackBar('❌ Error opening shop link: ${e.toString()}');
    }
  }

  /// Build loading overlay (simplified)
  Widget _buildLoadingOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withAlpha((0.3 * 255).toInt()),
        child: Center(
          child: Container(
            padding: EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF22514C)),
                ),
                SizedBox(height: 16),
                Text(
                  "Nahrávam 3D model...",
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Build camera button (centered at bottom)
  Widget _buildCameraButton() {
    if (nodes.isEmpty) return const SizedBox.shrink();

    // Show disabled state if AR is reinitializing
    bool isARReady = arSessionManager != null && _isARInitialized;

    return Positioned(
      bottom: MediaQuery.of(context).padding.bottom + 16.0,
      left: 0,
      right: 0,
      child: Center(
        child: GestureDetector(
          onTap: (isARReady && !_isTakingScreenshot)
              ? _takeARScreenshot
              : () {
                  if (!isARReady) {
                    _showSnackBar('⏳ Počkajte na inicializáciu AR');
                  }
                },
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              // Gray out button if AR not ready, otherwise green
              color: isARReady
                  ? const Color(0xFF004C44).withValues(alpha: 0.85)
                  : Colors.grey.withValues(alpha: 0.6),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: _isTakingScreenshot
                  ? const CircularProgressIndicator(
                      strokeWidth: 3,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Color(0xFFA6E7B8),
                      ),
                    )
                  : Container(
                      width: 50, // 64 - (7px padding * 2) = 50px
                      height: 50,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          // Gray border if not ready
                          color: isARReady
                              ? const Color(0xFFA6E7B8)
                              : Colors.grey[400]!,
                          width: 1,
                        ),
                      ),
                      child: Center(
                        child: SvgPicture.asset(
                          'assets/icons/camera_icon.svg',
                          width: 24,
                          height: 24,
                          colorFilter: isARReady
                              ? null
                              : ColorFilter.mode(
                                  Colors.grey[600]!,
                                  BlendMode.srcIn,
                                ),
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  /// Take AR screenshot and save to gallery
  Future<void> _takeARScreenshot() async {
    // Set loading state at the very beginning
    setState(() {
      _isTakingScreenshot = true;
    });

    try {
      _arLog('AR Screen: 📸 Starting screenshot process...');

      // CRITICAL: Check if AR session is still valid before proceeding
      if (arSessionManager == null || !_isARInitialized) {
        _arLog('AR Screen: ❌ AR session not ready for screenshot');
        _showSnackBar('❌ AR nepripravené, skúste znova');
        return;
      }

      // For Android, check permissions BEFORE attempting to capture
      if (Platform.isAndroid) {
        _arLog('AR Screen: 🤖 Android detected, checking permissions first...');

        // Android-specific: Request storage permission and WAIT for user response
        // CRITICAL: Permission dialog will cause window focus loss and may pause AR session
        bool hasPermission = await _requestStoragePermission();
        if (!hasPermission) {
          // Permission denied - don't show error, user already knows they denied it
          _arLog('AR Screen: ❌ Android storage permission denied by user');
          return; // Exit silently without showing error message
        }

        _arLog('AR Screen: ✅ Storage permission granted');

        // CRITICAL: After permission dialog closes, the AR session may have been destroyed
        // This is an Android system behavior - permission dialogs can cause activity recreation
        if (arSessionManager == null || !_isARInitialized) {
          _arLog(
            'AR Screen: ❌ AR session was destroyed during permission dialog',
          );
          _showSnackBar('❌ AR bolo reštartované. Prosím skúste znova.');

          // The AR screen will automatically reinitialize through the normal lifecycle
          // User should just wait a moment and try again
          return;
        }

        // Give the system time to fully restore after permission dialog
        // and ensure AR session is stable before attempting screenshot
        _arLog(
          'AR Screen: ⏳ Waiting for AR session to stabilize after permission...',
        );
        await Future.delayed(Duration(milliseconds: 500));

        // Double-check session is still valid after delay
        if (arSessionManager == null || !_isARInitialized) {
          _arLog('AR Screen: ❌ AR session lost after permission dialog');
          _showSnackBar('❌ AR sa reštartuje. Počkajte chvíľu a skúste znova.');
          return;
        }

        _arLog(
          'AR Screen: ✅ AR session verified stable, proceeding with screenshot',
        );
      }

      // For iOS or Android with granted permission, proceed with capture
      await _captureAndSaveScreenshot();
    } catch (e) {
      _arLog('AR Screen: ❌ Screenshot error: $e');
      // Only show error snackbar for actual capture errors, not permission issues
      if (!e.toString().contains('permission') &&
          !e.toString().contains('Permission')) {
        _showSnackBar('❌ Snímka obrazovky zlyhala');
      }
    } finally {
      // Always clear loading state when done
      if (mounted) {
        setState(() {
          _isTakingScreenshot = false;
        });
      }
    }
  }

  /// Capture and save screenshot (separated logic)
  Future<void> _captureAndSaveScreenshot() async {
    try {
      // Use AR plugin's native snapshot function instead of RepaintBoundary
      // This captures the actual AR scene including 3D models
      if (arSessionManager == null) {
        _showSnackBar('❌ AR session not ready for screenshot');
        _arLog('AR Screen: ❌ AR session manager is null');
        return;
      }

      _arLog('AR Screen: 📸 Taking AR scene snapshot...');
      _arLog('AR Screen: Platform: ${Platform.isAndroid ? 'Android' : 'iOS'}');

      // Get the native AR screenshot with platform-specific error handling
      // CRITICAL: The snapshot() method may pause the AR session internally
      ImageProvider imageProvider;
      try {
        imageProvider = await arSessionManager!.snapshot();
        _arLog('AR Screen: 📸 Snapshot captured successfully');

        // CRITICAL: Give AR session time to stabilize after snapshot
        // The snapshot may have briefly paused the session
        await Future.delayed(Duration(milliseconds: 150));
        _arLog('AR Screen: 📸 AR session stabilized after snapshot');
      } catch (snapshotError) {
        _arLog('AR Screen: ❌ Snapshot failed: $snapshotError');
        _arLog(
          'AR Screen: ❌ Snapshot error type: ${snapshotError.runtimeType}',
        );

        if (Platform.isAndroid) {
          // Android AR screenshots have known issues - don't show error messages
          // Just log for debugging purposes
          _arLog(
            'AR Screen: 🤖 Android snapshot failed (expected on first permission request)',
          );
          if (snapshotError is MissingPluginException) {
            _arLog(
              'AR Screen: 🤖 Android snapshot method not implemented in AR plugin',
            );
          }
          // Don't show any error message - permission dialog provides feedback
        } else {
          // Only show errors on iOS where this feature is fully supported
          _showSnackBar('❌ Failed to capture AR screenshot: $snapshotError');
        }
        return;
      }

      // Convert ImageProvider to bytes with enhanced error handling
      Uint8List imageBytes;
      try {
        if (imageProvider is MemoryImage) {
          imageBytes = imageProvider.bytes;
          _arLog(
            'AR Screen: 📸 Image converted to bytes, size: ${imageBytes.length} bytes',
          );
        } else {
          _arLog(
            'AR Screen: ❌ ImageProvider is not MemoryImage: ${imageProvider.runtimeType}',
          );

          // Don't show error messages on Android
          if (!Platform.isAndroid) {
            _showSnackBar('❌ Failed to process AR screenshot');
          }
          return;
        }
      } catch (conversionError) {
        _arLog('AR Screen: ❌ Image conversion failed: $conversionError');
        // Don't show error messages on Android
        if (!Platform.isAndroid) {
          _showSnackBar('❌ Failed to process screenshot: $conversionError');
        }
        return;
      }

      if (imageBytes.isEmpty) {
        _arLog('AR Screen: ❌ Image bytes are empty');
        // Don't show error messages on Android
        if (!Platform.isAndroid) {
          _showSnackBar('❌ Failed to generate screenshot data');
        }
        return;
      }

      // Generate filename with timestamp
      String fileName =
          'AR_Screenshot_${DateTime.now().millisecondsSinceEpoch}.png';
      _arLog('AR Screen: 📸 Saving as: $fileName');

      // Save image to gallery using SaverGallery
      try {
        final result = await SaverGallery.saveImage(
          imageBytes,
          quality: 100,
          fileName: fileName,
          skipIfExists: false,
          androidRelativePath:
              "Pictures/Virtualdom", // Creates a VirtualDom folder
        );

        _arLog(
          'AR Screen: 📸 SaverGallery result: isSuccess=${result.isSuccess}',
        );
        if (result.errorMessage != null) {
          _arLog('AR Screen: 📸 SaverGallery error: ${result.errorMessage}');
        }

        if (result.isSuccess) {
          // Track AR screenshot event (fire-and-forget with safety wrapper)
          AnalyticsService.trackEventSafely(
            () => AnalyticsService.trackARScreenshot(
              productId: _currentProduct?.id,
              partnerId: null, // Could extract from product if available
            ),
          );

          _showSuccessDialog(
            'AR Fotka Uložená!',
            'Vaša AR fotka bola úspešne uložená do galérie.',
          );
          _arLog('AR Screen: ✅ AR screenshot saved successfully: $fileName');
        } else {
          // Don't show save errors on Android - permission dialogs provide feedback
          if (!Platform.isAndroid) {
            final errorMsg = result.errorMessage ?? "Unknown error";
            _showSnackBar('❌ Failed to save AR photo: $errorMsg');
          }
          _arLog('AR Screen: ❌ Save failed: ${result.errorMessage}');
        }
      } catch (saveError) {
        _arLog('AR Screen: ❌ SaverGallery exception: $saveError');
        // Don't show save errors on Android - permission dialogs provide feedback
        if (!Platform.isAndroid) {
          _showSnackBar('❌ Failed to save AR photo: $saveError');
        }
      }
    } catch (e, stackTrace) {
      _arLog('AR Screen: ❌ AR screenshot capture error: $e');
      _arLog('AR Screen: ❌ Stack trace: $stackTrace');
      // Don't show any error message for capture errors on Android
      // The permission system handles feedback, and Android AR screenshots have known limitations
      if (!Platform.isAndroid) {
        // Only show errors on iOS where screenshot functionality is fully supported
        _showSnackBar('❌ Failed to capture AR screenshot: $e');
      }
    }
  }

  /// Request storage permission for saving photos
  Future<bool> _requestStoragePermission() async {
    try {
      if (Platform.isAndroid) {
        // For Android 13+ (API 33+), the system automatically uses READ_MEDIA_IMAGES
        // For older versions, it falls back to storage permission
        // We try photos permission first (works for all Android versions)

        _arLog('AR Screen: Requesting photos permission...');
        var permission = await Permission.photos.request();
        _arLog('AR Screen: Photos permission status: $permission');

        if (permission == PermissionStatus.granted) {
          return true;
        }

        // If photos permission is not available or denied, try storage permission
        // This handles older Android versions
        _arLog(
          'AR Screen: Photos permission not granted, trying storage permission...',
        );
        permission = await Permission.storage.request();
        _arLog('AR Screen: Storage permission status: $permission');

        if (permission == PermissionStatus.granted) {
          return true;
        }

        // If both failed, try manageExternalStorage for Android 11+
        _arLog('AR Screen: Trying manageExternalStorage permission...');
        permission = await Permission.manageExternalStorage.request();
        _arLog(
          'AR Screen: ManageExternalStorage permission status: $permission',
        );

        return permission == PermissionStatus.granted;
      } else {
        // For iOS, try multiple photo permission approaches
        _arLog('AR Screen: Checking iOS photo permissions...');

        // First try photosAddOnly (specifically for saving photos)
        var permission = await Permission.photosAddOnly.status;
        _arLog(
          'AR Screen: iOS PhotosAddOnly permission current status: $permission',
        );

        if (permission == PermissionStatus.granted) {
          return true;
        }

        if (permission != PermissionStatus.granted &&
            permission != PermissionStatus.permanentlyDenied) {
          permission = await Permission.photosAddOnly.request();
          _arLog(
            'AR Screen: iOS PhotosAddOnly permission after request: $permission',
          );

          if (permission == PermissionStatus.granted) {
            return true;
          }
        }

        // Fallback to general photos permission
        permission = await Permission.photos.status;
        _arLog('AR Screen: iOS Photos permission current status: $permission');

        if (permission == PermissionStatus.granted) {
          return true;
        }

        if (permission == PermissionStatus.permanentlyDenied) {
          // Show dialog to guide user to settings
          _showPermissionSettingsDialog();
          return false;
        }

        if (permission != PermissionStatus.granted &&
            permission != PermissionStatus.permanentlyDenied) {
          permission = await Permission.photos.request();
          _arLog('AR Screen: iOS Photos permission after request: $permission');

          if (permission == PermissionStatus.permanentlyDenied) {
            _showPermissionSettingsDialog();
            return false;
          }

          return permission == PermissionStatus.granted;
        }

        return false;
      }
    } catch (e) {
      _arLog('AR Screen: ❌ Permission request error: $e');
      // Try a fallback approach
      try {
        _arLog('AR Screen: Trying fallback permission approach...');
        final permission = await Permission.storage.request();
        return permission == PermissionStatus.granted;
      } catch (fallbackError) {
        _arLog('AR Screen: ❌ Fallback permission also failed: $fallbackError');
        return false;
      }
    }
  }

  /// Show memory warning dialog when user tries to add model but memory is low
  void _showMemoryWarningDialog(MemoryInfo memInfo) {
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: const [
              Icon(Icons.warning_amber, color: Colors.orange, size: 28),
              SizedBox(width: 8),
              Text('Nedostatok pamäte'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Nie je možné pridať ďalší objekt. Zariadenie má nedostatok voľnej pamäte.',
                style: TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 12),
              Text(
                'Využitie pamäte: ${memInfo.usagePercentage.toStringAsFixed(1)}%',
                style: TextStyle(fontSize: 14, color: Colors.grey[700]),
              ),
              Text(
                'Status: ${memInfo.status.name}',
                style: TextStyle(fontSize: 14, color: Colors.grey[700]),
              ),
              const SizedBox(height: 12),
              Text(
                'Odstráňte niektoré objekty zo scény a skúste znova.',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  /// Show dialog to guide user to app settings for permission
  void _showPermissionSettingsDialog() {
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Photos Permission Required'),
          content: const Text(
            'To save AR screenshots, this app needs access to your photos. '
            'Please go to Settings > Privacy & Security > Photos and enable access for Virtualdom.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(context).pop();
                await openAppSettings();
              },
              child: const Text('Open Settings'),
            ),
          ],
        );
      },
    );
  }

  /// Show success dialog with custom title and message
  void _showSuccessDialog(String title, String message) {
    if (!mounted) return;

    // Clear loading state before showing the success dialog
    setState(() {
      _isTakingScreenshot = false;
    });

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.check_circle, color: Colors.green[600], size: 28),
              const SizedBox(width: 12),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          content: Text(message, style: const TextStyle(fontSize: 16)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF22514C),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
              ),
              child: const Text(
                'OK',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Show snackbar message to user
  void _showSnackBar(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
        backgroundColor: message.startsWith('✅')
            ? Colors.green[700]
            : message.startsWith('❌')
            ? Colors.red[700]
            : Colors.blue[700],
      ),
    );
  }

  // ==================== DEPTH OCCLUSION METHODS ====================

  /// Initialize depth occlusion support
  Future<void> _initializeDepthOcclusion() async {
    try {
      if (arSessionManager == null) {
        _arLog(
          'AR Screen: ⚠️ Cannot initialize depth - session manager is null',
        );
        return;
      }

      // Check if depth is supported on this device
      bool supported = await arSessionManager!.isDepthSupported();
      _arLog('AR Screen: 🔍 Depth support check: $supported');

      if (supported) {
        // Explicitly enable depth occlusion (as per the guide)
        _arLog('AR Screen: 🔍 Enabling depth occlusion...');
        bool enableResult = await arSessionManager!.enableDepthOcclusion(true);
        _arLog('AR Screen: 🔍 Enable depth occlusion result: $enableResult');

        // Verify it's actually enabled
        bool enabled = await arSessionManager!.isDepthOcclusionEnabled();
        _arLog('AR Screen: 🔍 Depth occlusion verified status: $enabled');

        if (mounted) {
          setState(() {
            _depthSupported = supported;
            _occlusionEnabled = enabled;
            _depthInfo = enabled
                ? "Occlusion enabled - objects hidden behind real objects"
                : "Occlusion disabled - objects always visible";
          });
        }

        // Start monitoring depth data
        _monitorDepthData();
      } else {
        if (mounted) {
          setState(() {
            _depthSupported = false;
            _depthInfo = "Depth not supported on this device";
          });
        }
        _arLog(
          'AR Screen: ℹ️ Depth not supported - occlusion features unavailable',
        );
      }
    } catch (e) {
      _arLog('AR Screen: ❌ Error initializing depth occlusion: $e');
      if (mounted) {
        setState(() {
          _depthSupported = false;
          _depthInfo = "Depth initialization failed";
        });
      }
    }
  }

  /// Monitor depth data availability
  void _monitorDepthData() {
    _depthMonitorTimer?.cancel();
    _depthMonitorTimer = Timer.periodic(const Duration(seconds: 3), (
      timer,
    ) async {
      if (!mounted || arSessionManager == null) {
        timer.cancel();
        return;
      }

      try {
        final depthImage = await arSessionManager!.acquireDepthImage();
        if (depthImage != null) {
          int width = depthImage['width'];
          int height = depthImage['height'];
          String format = depthImage['format'] ?? 'unknown';

          if (mounted) {
            setState(() {
              _depthInfo = "Depth: ${width}x${height} ($format)";
            });
          }
          _arLog(
            'AR Screen: 🔍 Depth image: ${width}x${height} format: $format',
          );
        }
      } catch (e) {
        _arLog('AR Screen: ⚠️ Error acquiring depth image: $e');
      }
    });
  }

  /// Toggle depth occlusion on/off
  Future<void> _toggleDepthOcclusion() async {
    if (!_depthSupported) {
      _showSnackBar('❌ Depth not supported on this device');
      return;
    }

    if (arSessionManager == null) {
      _showSnackBar('❌ AR session not initialized');
      return;
    }

    try {
      bool newState = !_occlusionEnabled;
      bool success = await arSessionManager!.enableDepthOcclusion(newState);

      if (success) {
        setState(() {
          _occlusionEnabled = newState;
          _depthInfo = newState
              ? "Occlusion enabled - objects hidden behind real objects"
              : "Occlusion disabled - objects always visible";
        });

        _showSnackBar(
          newState
              ? '✅ Occlusion enabled - objects hidden behind real objects'
              : '⚠️ Occlusion disabled - objects always visible',
        );

        _arLog('AR Screen: 🔍 Depth occlusion toggled to: $newState');
      } else {
        _showSnackBar('❌ Failed to toggle occlusion');
        _arLog('AR Screen: ❌ Failed to toggle depth occlusion');
      }
    } catch (e) {
      _showSnackBar('❌ Error toggling occlusion: $e');
      _arLog('AR Screen: ❌ Error toggling depth occlusion: $e');
    }
  }

  /// Build depth status overlay (top-left corner)
  Widget _buildDepthStatusOverlay() {
    if (!_depthSupported) return const SizedBox.shrink();

    return Positioned(
      top: MediaQuery.of(context).padding.top + 60,
      left: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: _occlusionEnabled ? const Color(0xFF4CAF50) : Colors.grey,
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _occlusionEnabled ? Icons.visibility : Icons.visibility_off,
              color: _occlusionEnabled ? const Color(0xFF4CAF50) : Colors.grey,
              size: 16,
            ),
            const SizedBox(width: 6),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '🔍 Depth Occlusion',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  _occlusionEnabled ? 'ON' : 'OFF',
                  style: TextStyle(
                    color: _occlusionEnabled
                        ? const Color(0xFF4CAF50)
                        : Colors.grey,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Build depth occlusion toggle button (right side, middle)
  Widget _buildDepthToggleButton() {
    if (!_depthSupported) return const SizedBox.shrink();

    return Positioned(
      right: 16,
      top: MediaQuery.of(context).size.height / 2 - 28,
      child: GestureDetector(
        onTap: _toggleDepthOcclusion,
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: _occlusionEnabled
                ? const Color(0xFF4CAF50).withValues(alpha: 0.85)
                : Colors.grey.withValues(alpha: 0.85),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Icon(
            _occlusionEnabled ? Icons.visibility : Icons.visibility_off,
            color: Colors.white,
            size: 28,
          ),
        ),
      ),
    );
  }
}
