import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // For MissingPluginException
import 'package:provider/provider.dart';
import 'package:vector_math/vector_math_64.dart' as vm;
import 'dart:typed_data';
import 'dart:io';
import 'dart:math' as math;

// AR Plugin Imports
import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_2/models/ar_node.dart';
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
import 'category.dart';

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
  Map<String, Product> nodeToProductMap = {}; // Track which product belongs to each node
  bool _isARInitialized = false;
  String _statusText = "Initializing AR...";
  
  // Individual object selection state
  String? selectedNodeId;
  
  // Product state (keep from original)
  Product? _currentProduct;
  String? modelUri;
  bool isDownloadingModel = false;

  @override
  void initState() {
    super.initState();
    _currentProduct = widget.product;
    _handleNewProductModel();
  }

  @override
  void didUpdateWidget(ARScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.product?.id != widget.product?.id) {
      debugPrint('AR Screen: Product changed - updating model');
      _currentProduct = widget.product;
      _handleNewProductModel();
    }
  }

  @override
  void dispose() {
    debugPrint('AR Screen: Disposing AR session...');
    arSessionManager?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // AR View (simplified, based on working example)
          ARView(
            onARViewCreated: _onARViewCreated,
            planeDetectionConfig: PlaneDetectionConfig.horizontal,
          ),
          
          // UI Overlays (keep from original but simplified)
          _buildStatusOverlay(),
          _buildBackButton(),
          _buildAddButton(), // Now handles both add and delete functionality
          _buildShoppingCartButton(), // New shopping cart button
          _buildCameraButton(),
          
          // Loading overlay for model downloads
          if (isDownloadingModel) _buildLoadingOverlay(),
        ],
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
    debugPrint('AR Screen: Initializing AR session...');
    
    this.arSessionManager = arSessionManager;
    this.arObjectManager = arObjectManager;
    this.arAnchorManager = arAnchorManager;
    this.arLocationManager = arLocationManager;

    // Set up managers (simplified)
    _initializeAR();
  }

  Future<void> _initializeAR() async {
    try {
      // Configure session (FIXED: Enable planes for hit detection but keep them invisible)
      await arSessionManager!.onInitialize(
        showFeaturePoints: false,
        showPlanes: false, // Enable detection but keep planes invisible to avoid touch conflicts
        customPlaneTexturePath: null,
        showWorldOrigin: false,
        handlePans: true,
        handleRotation: true,
      );

      // Configure object manager with proper gesture handling
      await arObjectManager!.onInitialize();

      // Set up gesture handlers for pan and rotation (FIXED: Use print like working example)
      arObjectManager!.onPanStart = (String nodeName) {
        print('AR Screen: 🔥 Pan started on node: $nodeName'); // FIXED: Use print instead of debugPrint
        setState(() {
          _statusText = "Panning object: $nodeName";
        });
      };

      arObjectManager!.onPanChange = (String nodeName) {
        print('AR Screen: 🔥 Pan changing on node: $nodeName'); // FIXED: Use print instead of debugPrint
      };

      arObjectManager!.onPanEnd = (String nodeName, Matrix4 transform) {
        print('AR Screen: 🔥 Pan ended on node: $nodeName'); // FIXED: Use print instead of debugPrint
        setState(() {
          _statusText = "Pan gesture completed on: $nodeName";
        });
      };

      arObjectManager!.onRotationStart = (String nodeName) {
        print('AR Screen: 🔥 Rotation started on node: $nodeName'); // FIXED: Use print instead of debugPrint
        setState(() {
          _statusText = "Rotating object: $nodeName";
        });
      };

      arObjectManager!.onRotationChange = (String nodeName) {
        print('AR Screen: 🔥 Rotation changing on node: $nodeName'); // FIXED: Use print instead of debugPrint
      };

      arObjectManager!.onRotationEnd = (String nodeName, Matrix4 transform) {
        print('AR Screen: 🔥 Rotation ended on node: $nodeName'); // FIXED: Use print instead of debugPrint
        setState(() {
          _statusText = "Rotation gesture completed on: $nodeName";
        });
      };
      
      // Set up node tap callback (FIXED: Simplified like working example)
      arObjectManager!.onNodeTap = (List<String> nodeNames) {
        print('AR Screen: 🔥 Node tapped: $nodeNames'); // FIXED: Use print instead of debugPrint
        if (nodeNames.isNotEmpty) {
          print('AR Screen: 🔍 DEBUG: Setting selectedNodeId from \"$selectedNodeId\" to \"${nodeNames.first}\"');
          setState(() {
            selectedNodeId = nodeNames.first;
            _statusText = "Selected: ${nodeNames.join(', ')}";
          });
          print('AR Screen: 🔍 DEBUG: After setState - selectedNodeId = \"$selectedNodeId\"');
        } else {
          print('AR Screen: ⚠️ Node tap received but nodeNames list is empty');
        }
      };

      // Set up plane/point tap handler (FIXED: Simplified like working example)
      arSessionManager!.onPlaneOrPointTap = (List<ARHitTestResult> hitResults) {
        print('AR Screen: 🎯 Plane/point tapped with ${hitResults.length} hit results'); // FIXED: Use print
        print('AR Screen: 🔍 DEBUG: Current selectedNodeId = "$selectedNodeId"');
        
        for (var hit in hitResults) {
          print('AR Screen: 🎯 Hit result type: ${hit.type}, distance: ${hit.distance}');
        }
        
        // DESELECTION LOGIC: When tapping empty space, deselect any selected object
        if (selectedNodeId != null) {
          print('AR Screen: 🔥 Deselecting object: $selectedNodeId');
          _deselectCurrentObject();
        } else {
          print('AR Screen: ⚠️ No object selected - selectedNodeId is null, cannot deselect');
        }
        
        setState(() {
          _statusText = "Tapped on plane/point with ${hitResults.length} hits${selectedNodeId != null ? ' - deselecting' : ' - no selection'}";
        });
      };

      setState(() {
        _isARInitialized = true;
        _statusText = "AR ready! ${modelUri != null ? 'Loading model...' : 'Select a product to place. Tap objects to select them.'}";
      });

      debugPrint('AR Screen: ✅ AR initialization completed');
      
      // If we have a model URI from product, place it automatically
      if (modelUri != null) {
        _placeModelFromProduct();
      }

    } catch (e) {
      debugPrint('AR Screen: ❌ Error initializing AR: $e');
      setState(() {
        _statusText = "Error initializing AR: $e";
      });
    }
  }

  /// Handle new product model (keep from original)
  void _handleNewProductModel() {
    final product = _currentProduct ?? widget.product;
    String? productId = product?.id;
    debugPrint('AR Screen: === HANDLING NEW PRODUCT MODEL ===');
    debugPrint('AR Screen: Product ID: $productId');
    debugPrint('AR Screen: Product modelUrl: ${product?.modelUrl}');

    String? modelUrl;
    
    // Method 1: Direct modelUrl field
    if (product != null && product.modelUrl.isNotEmpty) {
      final candidate = product.modelUrl.toString();
      debugPrint('AR Screen: Checking direct modelUrl: $candidate');
      
      if (candidate.toLowerCase().endsWith('.glb')) {
        modelUrl = candidate;
        debugPrint('AR Screen: ✅ Found GLB modelUrl directly: $modelUrl');
      } else {
        debugPrint('AR Screen: modelUrl is not GLB ($candidate), checking assets for GLB files...');
        final assets = product.assets;
        if (assets.isNotEmpty) {
          // Find the first .glb file in assets
          for (var asset in assets) {
            if (asset.url.toLowerCase().endsWith('.glb')) {
              modelUrl = asset.url;
              debugPrint('AR Screen: ✅ Found GLB in assets: $modelUrl');
              break;
            }
          }
        }
      }
    }

    // Method 2: Check assets if no direct modelUrl
    if (modelUrl == null && product != null && product.assets.isNotEmpty) {
      debugPrint('AR Screen: No direct modelUrl, checking assets...');
      for (var asset in product.assets) {
        if (asset.url.toLowerCase().endsWith('.glb')) {
          modelUrl = asset.url;
          debugPrint('AR Screen: ✅ Found GLB in assets: $modelUrl');
          break;
        }
      }
    }

    if (modelUrl != null && modelUrl != modelUri) {
      debugPrint('AR Screen: 📦 New model URL detected: $modelUrl');
      setState(() {
        modelUri = modelUrl;
        _statusText = _isARInitialized ? "Loading new model..." : "AR initializing...";
      });
      
      // If AR is ready, place the model immediately
      if (_isARInitialized) {
        _placeModelFromProduct();
      }
    } else if (modelUrl == null) {
      debugPrint('AR Screen: ⚠️ No GLB model found for product');
      setState(() {
        modelUri = null;
        _statusText = _isARInitialized ? "No 3D model available for this product" : "AR initializing...";
      });
    }
  }

  /// Place model from current product (simplified)
  Future<void> _placeModelFromProduct() async {
    if (!_isARInitialized || arObjectManager == null || modelUri == null) {
      debugPrint('AR Screen: ❌ Cannot place model - AR not ready or no model URI');
      return;
    }

    setState(() {
      isDownloadingModel = true;
      _statusText = "Loading 3D model...";
    });

    try {
      debugPrint('AR Screen: 🎯 Placing model from URL: $modelUri');
      
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
      
      debugPrint('AR Screen: 🎯 Simple position for object ${nodes.length + 1}:');
      debugPrint('AR Screen: 🎯   Position: $simplePosition');
      
      Matrix4 transformation = Matrix4.identity();
      transformation.setTranslationRaw(simplePosition.x, simplePosition.y, simplePosition.z);
      
      String nodeName = "Product_${DateTime.now().millisecondsSinceEpoch}";

      // FIXED: Use smaller, consistent scale like auto_placement_test.dart
      vm.Vector3 scale = vm.Vector3(0.5, 0.5, 0.5); // Consistent scale instead of platform-dependent
      
      ARNode node = ARNode(
        type: NodeType.webGLB,
        uri: modelUri!,
        name: nodeName,
        transformation: transformation,
        scale: scale, // Reasonable default scale
        isTransformable: true,
        enablePanGestures: true,
        enableRotationGestures: true,
      );

      debugPrint('AR Screen: 📦 Created ARNode: $nodeName');
      debugPrint('AR Screen: 📍 Position: $simplePosition');
      debugPrint('AR Screen: 🌐 URL: $modelUri');

      // Place the model (this is the key working part from example)
      String? result = await arObjectManager!.addNode(node);

      if (result != null) {
        debugPrint('AR Screen: ✅ PLACEMENT SUCCESS! Node ID: $result');
        
        // Store the ARNode with its original name, but track the AR plugin's returned ID
        nodes.add(node);
        
        // CRITICAL FIX: Map both the original node name AND the returned ID to the same ARNode
        // This way gesture callbacks work regardless of which ID they use
        if (_currentProduct != null) {
          nodeToProductMap[result] = _currentProduct!; // Use the returned ID as primary key
          nodeToProductMap[nodeName] = _currentProduct!; // Also map original name for compatibility
          debugPrint('AR Screen: 📝 Stored product mapping: $result -> ${_currentProduct!.name}');
          debugPrint('AR Screen: 📝 Stored product mapping: $nodeName -> ${_currentProduct!.name}');
        }
        
        setState(() {
          isDownloadingModel = false;
          _statusText = "✅ Model placed! Tap objects to select them for deletion.";
        });
      } else {
        debugPrint('AR Screen: ❌ PLACEMENT FAILED! addNode returned null');
        setState(() {
          isDownloadingModel = false;
          _statusText = "❌ Model placement failed - please try again";
        });
      }

    } catch (e) {
      debugPrint('AR Screen: ❌ Exception during model placement: $e');
      setState(() {
        isDownloadingModel = false;
        _statusText = "❌ Model placement error: $e";
      });
    }
  }

  /// Deselect the currently selected object using the new deselectAllNodes API
  Future<void> _deselectCurrentObject() async {
    debugPrint('AR Screen: 🔄 _deselectCurrentObject called - selectedNodeId: "$selectedNodeId", arObjectManager: ${arObjectManager != null}');
    
    if (selectedNodeId == null || arObjectManager == null) {
      debugPrint('AR Screen: ⚠️ Cannot deselect - selectedNodeId: "$selectedNodeId", arObjectManager: ${arObjectManager != null}');
      return;
    }

    try {
      debugPrint('AR Screen: 🔄 Deselecting object: $selectedNodeId');
      
      // Use the deselectAllNodes method from ARObjectManager (new API)
      bool success = await arObjectManager!.deselectAllNodes();
      
      if (success) {
        debugPrint('AR Screen: ✅ Successfully deselected object: $selectedNodeId');
      } else {
        debugPrint('AR Screen: ⚠️ Deselection call completed but success status unclear');
      }
      
      setState(() {
        final previousSelection = selectedNodeId;
        selectedNodeId = null;
        _statusText = "Object deselected. Tap + to add products.";
        debugPrint('AR Screen: 🔄 setState completed - previous: "$previousSelection", current: "$selectedNodeId"');
      });
      
    } catch (e) {
      debugPrint('AR Screen: ❌ Error during deselection: $e');
      // Clear selection state anyway
      setState(() {
        final previousSelection = selectedNodeId;
        selectedNodeId = null;
        _statusText = "Deselection error, but cleared selection state";
        debugPrint('AR Screen: 🔄 Error setState completed - previous: "$previousSelection", current: "$selectedNodeId"');
      });
    }
  }

  /// Remove selected object (individual removal using removeNode with ARNode object)
  Future<void> _removeSelectedObject() async {
    if (arObjectManager == null || selectedNodeId == null) {
      debugPrint('AR Screen: ❌ Cannot remove - no object selected or AR not ready');
      return;
    }
    
    setState(() {
      _statusText = "Removing selected object...";
    });

    try {
      debugPrint('AR Screen: 🗑️ Removing individual object: $selectedNodeId');
      
      // Find the ARNode object that corresponds to the selected ID
      ARNode? nodeToRemove;
      for (ARNode node in nodes) {
        // Check if this node matches the selected ID
        // The selectedNodeId could be either the original name or the returned ID
        if (node.name == selectedNodeId || nodeToProductMap.containsKey(node.name)) {
          // Additional check: make sure this node's product matches the selected node's product
          final nodeProduct = nodeToProductMap[node.name];
          final selectedProduct = nodeToProductMap[selectedNodeId];
          if (nodeProduct == selectedProduct) {
            nodeToRemove = node;
            break;
          }
        }
      }
      
      if (nodeToRemove == null) {
        debugPrint('AR Screen: ❌ Could not find ARNode object for selected ID: $selectedNodeId');
        setState(() {
          _statusText = "❌ Could not find object to remove";
        });
        return;
      }
      
      debugPrint('AR Screen: 🗑️ Found ARNode to remove: ${nodeToRemove.name}');
      
      // Use removeNode with ARNode object like the working example
      bool success = await arObjectManager!.removeNode(nodeToRemove);
      
      if (success) {
        debugPrint('AR Screen: ✅ Successfully removed object: ${nodeToRemove.name}');
        
        // Remove from local tracking
        nodes.remove(nodeToRemove);
        
        // Remove from product mapping - remove all entries for this product/node
        final productToRemove = nodeToProductMap[selectedNodeId];
        nodeToProductMap.removeWhere((key, value) => value == productToRemove);
        
        setState(() {
          selectedNodeId = null;
          _statusText = nodes.isEmpty 
              ? "Object removed! ${modelUri != null ? 'Select a product to place.' : 'Add objects using the + button.'}" 
              : "Object removed! Tap objects to select them.";
        });
        
        debugPrint('AR Screen: Updated nodes list - remaining objects: ${nodes.length}');
      } else {
        debugPrint('AR Screen: ❌ Failed to remove object: ${nodeToRemove.name}');
        setState(() {
          _statusText = "❌ Failed to remove object - please try again";
        });
      }

    } catch (e) {
      debugPrint('AR Screen: ❌ Exception during object removal: $e');
      setState(() {
        _statusText = "❌ Object removal error: $e";
      });
    }
  }

  /// Navigate to category (keep from original)
  Future<void> _navigateToCategory() async {
    debugPrint('AR Screen: === SHOWING CATEGORY MODAL OVERLAY ===');
    
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
      builder: (context) => _buildARModalOverlay(
        child: CategoryScreen(isSearchHeaderShow: true),
      ),
    );
    
    // Handle result if user selected a product
    if (mounted && result != null) {
      // Update current product state
      setState(() {
        _currentProduct = result;
        // Enhanced navigation will provide raw product data in future implementation
      });
      
      // Start new model download and placement process
      _handleNewProductModel();
    }
    
    debugPrint('AR Screen: ✅ Category modal closed - AR session preserved');
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

  /// Build status overlay (debug information like working example)
  Widget _buildStatusOverlay() {
    // Only show debug overlay when there are objects or during development
    if (nodes.isEmpty && selectedNodeId == null) return const SizedBox.shrink();
    
    return Positioned(
      top: MediaQuery.of(context).padding.top + 80.0, // Below back button
      left: 16,
      right: 16,
      child: GestureDetector(
        onTap: () {
          // Backup deselection method - tap the status overlay to deselect
          if (selectedNodeId != null) {
            debugPrint('AR Screen: 🎯 Deselecting via status overlay tap');
            _deselectCurrentObject();
          }
        },
        child: Container(
          padding: EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(8),
            // Add a subtle border when object is selected to hint it's tappable
            border: selectedNodeId != null 
                ? Border.all(color: Colors.yellow.withOpacity(0.3), width: 1)
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _statusText,
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
              if (nodes.isNotEmpty) ...[
                SizedBox(height: 4),
                Text(
                  "Objects: ${nodes.length}",
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
              if (selectedNodeId != null) ...[
                SizedBox(height: 4),
                Text(
                  "Selected: $selectedNodeId",
                  style: TextStyle(color: Colors.yellow, fontSize: 12),
                ),
                // Show product info if available
                Builder(
                  builder: (context) {
                    final product = nodeToProductMap[selectedNodeId];
                    if (product != null) {
                      return Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Text(
                          "Product: ${product.name}",
                          style: TextStyle(color: Colors.green, fontSize: 11),
                        ),
                      );
                    }
                    return SizedBox.shrink();
                  },
                ),
                SizedBox(height: 4),
                Text(
                  "💡 Tap here to deselect",
                  style: TextStyle(color: Colors.orange, fontSize: 10, fontStyle: FontStyle.italic),
                ),
              ],
              if (nodes.isNotEmpty) ...[
                SizedBox(height: 4),
                Text(
                  "💡 Tap objects to select • Drag to move • Rotate with two fingers",
                  style: TextStyle(color: Colors.white60, fontSize: 10),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

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
            debugPrint('AR Screen: Back button pressed - disposing AR session');
            Navigator.of(context).pop();
          },
        ),
      ),
    );
  }

  /// Build add/delete button (merged functionality)
  Widget _buildAddButton() {
    bool hasSelection = selectedNodeId != null;
    bool showAddButton = !hasSelection; // Show + when no selection, - when object selected
    
    return Positioned(
      bottom: MediaQuery.of(context).padding.bottom + 16.0,
      left: 20,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: Colors.white.withAlpha((0.9 * 255).toInt()),   // Red for delete button
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
          onPressed: showAddButton ? _navigateToCategory : _removeSelectedObject,
          icon: Icon(
            showAddButton ? Icons.add : Icons.remove,
            color: Color(0xFF22514C),
            size: 24,
          ),
          padding: EdgeInsets.zero,
        ),
      ),
    );
  }

  /// Build shopping cart button (for forms and shop links)
  Widget _buildShoppingCartButton() {
    debugPrint('AR Screen: 🛒 Building shopping cart button...');
    debugPrint('AR Screen: 🛒 selectedNodeId: $selectedNodeId');
    
    // Only show if we have a selected object and can find its corresponding product
    if (selectedNodeId == null) {
      debugPrint('AR Screen: 🛒 No selected node - hiding shopping cart button');
      return const SizedBox.shrink();
    }
    
    // Get the product for the selected node (simplified approach)
    final selectedProduct = nodeToProductMap[selectedNodeId];
    debugPrint('AR Screen: 🛒 Product for selected node: ${selectedProduct?.name ?? "NOT FOUND"}');
    
    if (selectedProduct == null) {
      debugPrint('AR Screen: 🛒 No product found for node $selectedNodeId - hiding shopping cart button');
      return const SizedBox.shrink();
    }
    
    final hasCompanyForm = _hasCompanyForm(selectedProduct);
    final hasShopUrl = _hasShopUrl(selectedProduct);
    
    debugPrint('AR Screen: 🛒 hasCompanyForm: $hasCompanyForm, hasShopUrl: $hasShopUrl');
    
    // Only show if product has either form capability or shop URL
    if (!hasCompanyForm && !hasShopUrl) {
      debugPrint('AR Screen: 🛒 No form or shop URL - hiding shopping cart button');
      return const SizedBox.shrink();
    }
    
    debugPrint('AR Screen: 🛒 Showing shopping cart button for ${selectedProduct.name}');
    
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
          onPressed: () => _onShoppingCartPress(selectedProduct),
          icon: Icon(
            Icons.shopping_cart,
            color: Color(0xFF22514C),
            size: 24,
          ),
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
    // Always show the shopping cart since we can provide a fallback URL
    // In a real implementation, this would check actual product URLs
    return true;
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
                  padding: const EdgeInsets.fromLTRB(16.0, 0, 16.0, 32.0), // Extra bottom padding
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
    String targetUrl;
    
    // For demonstration purposes, create URLs based on product name
    if (product.name.toLowerCase().contains('saffron')) {
      targetUrl = 'https://www.saffron.sk/';
    } else if (product.name.toLowerCase().contains('chair') || product.name.toLowerCase().contains('sofa')) {
      targetUrl = 'https://www.ikea.com/';
    } else if (product.name.toLowerCase().contains('lamp') || product.name.toLowerCase().contains('light')) {
      targetUrl = 'https://www.philips.com/';
    } else {
      // Generic search fallback
      targetUrl = 'https://www.google.com/search?q=${Uri.encodeComponent(product.name + ' buy online')}';
    }
    
    debugPrint('AR Screen: 🌐 Attempting to open URL: $targetUrl');
    
    try {
      final uri = Uri.parse(targetUrl);
      debugPrint('AR Screen: 🌐 Parsed URI: $uri');
      
      // Check if URL can be launched
      bool canLaunch = await canLaunchUrl(uri);
      debugPrint('AR Screen: 🌐 Can launch URL: $canLaunch');
      
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
          debugPrint('AR Screen: ✅ Successfully opened shop URL: $targetUrl');
          // _showSnackBar('Opening shop for ${product.name}...');
        } else {
          debugPrint('AR Screen: ❌ launchUrl returned false for: $targetUrl');
          _showSnackBar('❌ Could not open shop link');
        }
      } else {
        debugPrint('AR Screen: ❌ canLaunchUrl returned false for: $targetUrl');
        // Try alternative launch mode
        try {
          debugPrint('AR Screen: 🔄 Trying platformDefault launch mode...');
          bool altLaunched = await launchUrl(uri, mode: LaunchMode.platformDefault);
          if (altLaunched) {
            debugPrint('AR Screen: ✅ Successfully opened with platformDefault mode');
            // _showSnackBar('Opening shop for ${product.name}...');
          } else {
            debugPrint('AR Screen: ❌ Alternative launch also failed');
            _showSnackBar('❌ Could not open shop link - no browser found');
          }
        } catch (altError) {
          debugPrint('AR Screen: ❌ Alternative launch error: $altError');
          _showSnackBar('❌ Could not open shop link');
        }
      }
    } catch (e) {
      debugPrint('AR Screen: ❌ Error launching URL: $e');
      debugPrint('AR Screen: ❌ Error type: ${e.runtimeType}');
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
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
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
  
    return Positioned(
      bottom: MediaQuery.of(context).padding.bottom + 16.0,
      left: 0,
      right: 0,
      child: Center(
        child: GestureDetector(
          onTap: _takeARScreenshot,
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: const Color(0xFF004C44).withOpacity(0.85), // Green background with 85% opacity
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Container(
                width: 50, // 64 - (7px padding * 2) = 50px
                height: 50,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0xFFA6E7B8), // Light green border
                    width: 1,
                  ),
                ),
                child: Center(
                  child: SvgPicture.asset(
                    'assets/icons/camera_icon.svg',
                    width: 24,
                    height: 24,
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
    try {
      debugPrint('AR Screen: 📸 Starting screenshot process...');
      
      // For iOS, try direct save first (iOS handles permissions automatically for photo saving)
      if (Platform.isIOS) {
        debugPrint('AR Screen: iOS detected, trying direct save approach...');
        await _captureAndSaveScreenshot();
        return;
      }
      
      // For Android, check if AR session is ready first
      if (Platform.isAndroid) {
        if (arSessionManager == null) {
          _showSnackBar('❌ AR session not initialized yet');
          debugPrint('AR Screen: ❌ Android AR session not ready');
          return;
        }
        
        // Check if AR tracking is working
        debugPrint('AR Screen: 🤖 Android detected, checking AR session state...');
        
        // Android-specific: Request storage permission
        bool hasPermission = await _requestStoragePermission();
        if (!hasPermission) {
          _showSnackBar('❌ Storage permission required to save photos');
          debugPrint('AR Screen: ❌ Android storage permission denied');
          return;
        }
        
        debugPrint('AR Screen: ✅ Storage permission granted');
      }
      
      await _captureAndSaveScreenshot();

    } catch (e) {
      debugPrint('AR Screen: ❌ Screenshot error: $e');
      _showSnackBar('❌ Screenshot failed: $e');
    }
  }

  /// Capture and save screenshot (separated logic)
  Future<void> _captureAndSaveScreenshot() async {
    try {
      // Use AR plugin's native snapshot function instead of RepaintBoundary
      // This captures the actual AR scene including 3D models
      if (arSessionManager == null) {
        _showSnackBar('❌ AR session not ready for screenshot');
        debugPrint('AR Screen: ❌ AR session manager is null');
        return;
      }

      debugPrint('AR Screen: 📸 Taking AR scene snapshot...');
      debugPrint('AR Screen: Platform: ${Platform.isAndroid ? 'Android' : 'iOS'}');
      
      // Get the native AR screenshot with platform-specific error handling
      ImageProvider imageProvider;
      try {
        imageProvider = await arSessionManager!.snapshot();
        debugPrint('AR Screen: 📸 Snapshot captured successfully');
      } catch (snapshotError) {
        debugPrint('AR Screen: ❌ Snapshot failed: $snapshotError');
        debugPrint('AR Screen: ❌ Snapshot error type: ${snapshotError.runtimeType}');
        
        if (Platform.isAndroid && snapshotError is MissingPluginException) {
          debugPrint('AR Screen: 🤖 Android snapshot method not implemented in AR plugin');
          _showSnackBar('❌ AR screenshots not available on Android yet');
          
          // Show informative dialog about the limitation
          showDialog(
            context: context,
            builder: (BuildContext context) {
              return AlertDialog(
                title: const Text('Android Limitation'),
                content: const Text(
                  'AR screenshots are currently only supported on iOS devices. '
                  'The Android version of this feature is still in development.\n\n'
                  'On iOS, this feature works perfectly and captures the full AR scene including 3D models.'
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
        } else {
          _showSnackBar('❌ Failed to capture AR screenshot: $snapshotError');
        }
        return;
      }
      
      // Convert ImageProvider to bytes with enhanced error handling
      Uint8List imageBytes;
      try {
        if (imageProvider is MemoryImage) {
          imageBytes = imageProvider.bytes;
          debugPrint('AR Screen: 📸 Image converted to bytes, size: ${imageBytes.length} bytes');
        } else {
          debugPrint('AR Screen: ❌ ImageProvider is not MemoryImage: ${imageProvider.runtimeType}');
          
          // Try alternative conversion for Android
          if (Platform.isAndroid) {
            debugPrint('AR Screen: 🔄 Attempting Android-specific image conversion...');
            // For Android, we might need to handle different ImageProvider types
            _showSnackBar('❌ Android AR screenshot format not supported');
            return;
          } else {
            _showSnackBar('❌ Failed to process AR screenshot');
            return;
          }
        }
      } catch (conversionError) {
        debugPrint('AR Screen: ❌ Image conversion failed: $conversionError');
        _showSnackBar('❌ Failed to process screenshot: $conversionError');
        return;
      }

      if (imageBytes.isEmpty) {
        debugPrint('AR Screen: ❌ Image bytes are empty');
        _showSnackBar('❌ Failed to generate screenshot data');
        return;
      }

      // Generate filename with timestamp
      String fileName = 'AR_Screenshot_${DateTime.now().millisecondsSinceEpoch}.png';
      debugPrint('AR Screen: 📸 Saving as: $fileName');
      
      // Save image to gallery using SaverGallery
      try {
        final result = await SaverGallery.saveImage(
          imageBytes,
          quality: 100,
          fileName: fileName,
          skipIfExists: false,
          androidRelativePath: "Pictures/VirtualDom", // Creates a VirtualDom folder
        );

        debugPrint('AR Screen: 📸 SaverGallery result: isSuccess=${result.isSuccess}');
        if (result.errorMessage != null) {
          debugPrint('AR Screen: 📸 SaverGallery error: ${result.errorMessage}');
        }

        if (result.isSuccess) {
          _showSuccessDialog('AR Fotka Uložená!', 'Vaša AR fotka bola úspešne uložená do galérie.');
          debugPrint('AR Screen: ✅ AR screenshot saved successfully: $fileName');
        } else {
          _showSnackBar('❌ Failed to save AR photo: ${result.errorMessage ?? "Unknown error"}');
          debugPrint('AR Screen: ❌ Save failed: ${result.errorMessage}');
        }
      } catch (saveError) {
        debugPrint('AR Screen: ❌ SaverGallery exception: $saveError');
        _showSnackBar('❌ Failed to save AR photo: $saveError');
      }
    } catch (e, stackTrace) {
      debugPrint('AR Screen: ❌ AR screenshot capture error: $e');
      debugPrint('AR Screen: ❌ Stack trace: $stackTrace');
      _showSnackBar('❌ Failed to capture AR screenshot: $e');
    }
  }

  /// Request storage permission for saving photos
  Future<bool> _requestStoragePermission() async {
    try {
      if (Platform.isAndroid) {
        // For Android 13+ (API 33+), the system automatically uses READ_MEDIA_IMAGES
        // For older versions, it falls back to storage permission
        // We try photos permission first (works for all Android versions)
        
        debugPrint('AR Screen: Requesting photos permission...');
        var permission = await Permission.photos.request();
        debugPrint('AR Screen: Photos permission status: $permission');
        
        if (permission == PermissionStatus.granted) {
          return true;
        }
        
        // If photos permission is not available or denied, try storage permission
        // This handles older Android versions
        debugPrint('AR Screen: Photos permission not granted, trying storage permission...');
        permission = await Permission.storage.request();
        debugPrint('AR Screen: Storage permission status: $permission');
        
        if (permission == PermissionStatus.granted) {
          return true;
        }
        
        // If both failed, try manageExternalStorage for Android 11+
        debugPrint('AR Screen: Trying manageExternalStorage permission...');
        permission = await Permission.manageExternalStorage.request();
        debugPrint('AR Screen: ManageExternalStorage permission status: $permission');
        
        return permission == PermissionStatus.granted;
        
      } else {
        // For iOS, try multiple photo permission approaches
        debugPrint('AR Screen: Checking iOS photo permissions...');
        
        // First try photosAddOnly (specifically for saving photos)
        var permission = await Permission.photosAddOnly.status;
        debugPrint('AR Screen: iOS PhotosAddOnly permission current status: $permission');
        
        if (permission == PermissionStatus.granted) {
          return true;
        }
        
        if (permission != PermissionStatus.granted && permission != PermissionStatus.permanentlyDenied) {
          permission = await Permission.photosAddOnly.request();
          debugPrint('AR Screen: iOS PhotosAddOnly permission after request: $permission');
          
          if (permission == PermissionStatus.granted) {
            return true;
          }
        }
        
        // Fallback to general photos permission
        permission = await Permission.photos.status;
        debugPrint('AR Screen: iOS Photos permission current status: $permission');
        
        if (permission == PermissionStatus.granted) {
          return true;
        }
        
        if (permission == PermissionStatus.permanentlyDenied) {
          // Show dialog to guide user to settings
          _showPermissionSettingsDialog();
          return false;
        }
        
        if (permission != PermissionStatus.granted && permission != PermissionStatus.permanentlyDenied) {
          permission = await Permission.photos.request();
          debugPrint('AR Screen: iOS Photos permission after request: $permission');
          
          if (permission == PermissionStatus.permanentlyDenied) {
            _showPermissionSettingsDialog();
            return false;
          }
          
          return permission == PermissionStatus.granted;
        }
        
        return false;
      }
    } catch (e) {
      debugPrint('AR Screen: ❌ Permission request error: $e');
      // Try a fallback approach
      try {
        debugPrint('AR Screen: Trying fallback permission approach...');
        final permission = await Permission.storage.request();
        return permission == PermissionStatus.granted;
      } catch (fallbackError) {
        debugPrint('AR Screen: ❌ Fallback permission also failed: $fallbackError');
        return false;
      }
    }
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
            'Please go to Settings > Privacy & Security > Photos and enable access for VirtualDom.',
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
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(
                Icons.check_circle,
                color: Colors.green[600],
                size: 28,
              ),
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
          content: Text(
            message,
            style: const TextStyle(
              fontSize: 16,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF22514C),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
              child: const Text(
                'OK',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
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
        backgroundColor: message.startsWith('✅') ? Colors.green[700] : 
                         message.startsWith('❌') ? Colors.red[700] : 
                         Colors.blue[700],
      ),
    );
  }
}
