import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:vector_math/vector_math_64.dart' as vm;
import 'package:saver_gallery/saver_gallery.dart';
import 'package:permission_handler/permission_handler.dart';

// AR Plugin Imports
import 'package:ar_flutter_plugin_2/models/ar_hittest_result.dart';
import 'package:ar_flutter_plugin_2/models/ar_node.dart';
import 'package:ar_flutter_plugin_2/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin_2/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin_2/datatypes/node_types.dart';

// App Imports
import '../models/product.dart';
import '../models/ar_model_data.dart';
import '../services/ar_session_controller.dart';
import '../services/ar_model_manager.dart';
import '../services/ar_model_cache.dart';
import '../services/ar_plane_manager.dart';
import '../services/ar_error_handler.dart';
import '../services/ar_memory_manager.dart';
import '../utils/ar_constants.dart';
import '../providers/ar_navigation_provider.dart';

class ARScreen extends StatefulWidget {
  const ARScreen({super.key, required this.title, this.product});

  final String title;
  final Product? product;

  @override
  State<ARScreen> createState() => _ARScreenState();
}

class _ARScreenState extends State<ARScreen> with WidgetsBindingObserver {
  // Core AR components
  late final ARSessionController _sessionController;
  late final ARModelManager _modelManager;
  late final ARPlaneManager _planeManager;
  
  // UI State
  String? selectedNode;
  List<ARNode> nodes = [];
  List<String> nodeCreationOrder = [];
  bool isDownloadingModel = false;
  bool hasPlacedInitialModel = false;
  bool showInstructionMessage = false;
  bool isModelReadyForPlacement = false;
  bool isPlaneDetectionActive = false;
  bool _shouldRenderARView = true;
  bool _isProcessingNodeSelection = false;
  bool _hasBeenDisposed = false;
  bool _nukeAllAlreadyCalled = false;
  
  // Transform update throttling
  final Map<String, DateTime> _lastTransformUpdate = {};
  static const Duration _transformUpdateThrottle = Duration(milliseconds: 100);
  
  // Memory Management
  MemoryInfo? _currentMemoryInfo;
  bool _isMemoryMonitoringActive = false;
  bool _baselineSet = false;
  bool _isShowingMemoryWarning = false;
  
  // Single-object selection mode for Android
  String? _activeTransformableNode;
  bool _isAndroidSingleObjectMode = false;
  
  // Model restoration and session state
  bool _isRestoringModels = false;
  bool _isARSessionPaused = false;
  
  // Smart memory tracking for efficient object placement
  int _maxObjectsReachedBeforeMemoryLimit = 0;
  int _objectsRemovedSinceMemoryLimit = 0;
  
  // Current model info
  String? modelUri;
  String? cachedModelPath;
  bool isModelCached = false;
  String? currentUniqueProductId;
  
  // Legacy compatibility
  dynamic detectedPlane;

  @override
  void initState() {
    super.initState();
    _initializeComponents();
    _setupErrorHandler();
    _startARInitialization();
  }

  /// Initialize AR components and managers
  void _initializeComponents() {
    _sessionController = ARSessionController();
    _modelManager = ARModelManager();
    _planeManager = ARPlaneManager();
    
    // Initialize Android single-object mode
    _isAndroidSingleObjectMode = Platform.isAndroid;
    _activeTransformableNode = null;
    
    // Start memory monitoring
    _startMemoryMonitoring();
    
    WidgetsBinding.instance.addObserver(this);
  }

  /// Setup global error handler for AR-related errors
  void _setupErrorHandler() {
    FlutterError.onError = (FlutterErrorDetails details) {
      String errorString = details.exception.toString();
      
      if (ARErrorHandler.isCriticalARError(errorString)) {
        if (kDebugMode) {
          debugPrint('AR Screen: Critical AR error detected - attempting cleanup');
        }
        
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _handleCriticalARError();
        });
        return;
      }
      
      if (ARErrorHandler.isTypeCastingError(errorString)) {
        if (kDebugMode) {
          debugPrint('AR Screen: AR plugin type casting error caught');
        }
        return;
      }
      
      FlutterError.presentError(details);
    };
  }

  /// Start AR initialization process
  void _startARInitialization() {
    if (_sessionController.isSessionActive) {
      Future.delayed(ARConstants.sessionCleanupDelay, () {
        if (mounted && !_sessionController.isInitializing) {
          _continueARInitialization();
        }
      });
      return;
    }
    
    _shouldRenderARView = true;
    _continueARInitialization();
  }

  /// Continue with AR initialization
  void _continueARInitialization() {
    // Reset disposal flag for new AR session
    _hasBeenDisposed = false;
    
    _planeManager.reset();
    _modelManager.initialize();
    _handleNewProductModel();
  }

  @override
  void didUpdateWidget(ARScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    if (oldWidget.product?.id != widget.product?.id) {
      debugPrint('AR Screen: Product changed - updating model');
      _handleNewProductModel();
      
      if (_sessionController.isReady && modelUri != null && !hasPlacedInitialModel) {
        _startModelDownloadProcess();
      }
    }
  }

  @override
  void deactivate() {
    super.deactivate();
  }

  @override
  void dispose() {
    // Stop memory monitoring
    _stopMemoryMonitoring();
    
    // Final cleanup when widget is permanently removed
    if (!_hasBeenDisposed) {
      _forceDisposeARSession();
    }
    
    WidgetsBinding.instance.removeObserver(this);
    
    // Cleanup
    nodes.clear();
    nodeCreationOrder.clear();
    selectedNode = null;
    _isProcessingNodeSelection = false;

    super.dispose();

    // Async cleanup after widget disposal
    if (!_hasBeenDisposed) {
      _performAsyncCleanup();
    }
  }

  /// Perform async cleanup after widget disposal
  void _performAsyncCleanup() async {
    if (!_nukeAllAlreadyCalled) {
      try {
        final success = await _sessionController.sessionManager?.nukeAll(
          purgeCaches: true,
          removeExistingAnchors: true,
          resetTracking: true,
        );
        if (success != null && success) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('AR Screen: Error during async cleanup: $e');
        }
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    
    switch (state) {
      case AppLifecycleState.paused:
        _pauseARSession();
        break;
      case AppLifecycleState.detached:
        _forceDisposeARSession(completeDisposal: true);
        break;
      case AppLifecycleState.inactive:
        // Keep AR session for potential navigation transitions
        break;
      case AppLifecycleState.resumed:
        _resumeARSession();
        break;
      case AppLifecycleState.hidden:
        _pauseARSession();
        break;
    }
  }

  /// Handle critical AR errors with immediate cleanup
  Future<void> _handleCriticalARError() async {
    debugPrint('AR Screen: === HANDLING CRITICAL AR ERROR ===');
    
    try {
      // Clear UI state immediately
      _shouldRenderARView = false;
      
      nodes.clear();
      nodeCreationOrder.clear();
      selectedNode = null;
      
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {});
          }
        });
        // _showSnackBar('AR systém sa reštartuje kvôli chybe grafiky. Naviguje sa na hlavnú stránku...');
        
        // Phase 3 fix: Immediate cleanup BEFORE navigation
        if (!_nukeAllAlreadyCalled) {
          _nukeAllAlreadyCalled = true; // Prevent duplicate calls
          try {
            final success = await _sessionController.sessionManager?.nukeAll(
              purgeCaches: true,
              removeExistingAnchors: true,
              resetTracking: true,
            );
            if (success != null && success) {
              debugPrint('AR Screen: ✅ Critical error nukeAll completed');
              await Future.delayed(const Duration(milliseconds: 300));
            }
          } catch (e) {
            debugPrint('AR Screen: ❌ Critical error nukeAll failed: $e');
          }
        } else {
          debugPrint('AR Screen: ⚠️ Critical error - nukeAll already called, skipping duplicate');
        }
        
        // Navigate after cleanup
        if (mounted) {
          Navigator.of(context).pushNamedAndRemoveUntil(
            '/',
            (route) => false,
            arguments: {'selectedTabIndex': 0},
          );
        }
      }
    } catch (e) {
      debugPrint('AR Screen: Error during critical AR error handling: $e');
      if (mounted) {
        Navigator.of(context).pushNamedAndRemoveUntil(
          '/',
          (route) => false,
          arguments: {'selectedTabIndex': 0},
        );
      }
    }
  }

  /// Force immediate disposal of AR session
  Future<void> _forceDisposeARSession({bool completeDisposal = false}) async {
    debugPrint('AR Screen: === FORCE DISPOSING AR SESSION (completeDisposal: $completeDisposal) ===');
    
    // Prevent multiple disposal calls from interfering with persistent data
    if (_hasBeenDisposed) {
      debugPrint('AR Screen: Already disposed, skipping duplicate disposal call');
      return;
    }
    
    _shouldRenderARView = false;
    
    // Clear AR scene tracking but preserve persistent model data (unless complete disposal)
    _clearARSceneState();
    _hasBeenDisposed = true;

    if (completeDisposal) {
      // COMPLETE disposal - maximum memory cleanup
      debugPrint('AR Screen: 🧨 COMPLETE AR SESSION DISPOSAL - Maximum memory cleanup sequence');
      
      try {
        // Step 1: Call nukeAll FIRST while session manager is still available
        debugPrint('AR Screen: Step 1/6 - Aggressive nukeAll cleanup (while managers available)');
        if (_sessionController.sessionManager != null) {
          final nukeSuccess = await _sessionController.sessionManager?.nukeAll(
            purgeCaches: true,
            removeExistingAnchors: true,
            resetTracking: true,
          );
          debugPrint('AR Screen: nukeAll result: $nukeSuccess');
        } else {
          debugPrint('AR Screen: Session manager already null, skipping nukeAll');
        }
        
        // Step 2: Clear all local caches and references
        debugPrint('AR Screen: Step 2/6 - Clearing all local caches and references');
        nodes.clear();
        nodeCreationOrder.clear();
        selectedNode = null;
        _modelManager.clearAllModels(); // Clear all persistent model data
        
        // Clear additional caches
        try {
          await ARModelCache.clearCache(); // Clear downloaded model files
          debugPrint('AR Screen: ✅ Model cache cleared');
        } catch (e) {
          debugPrint('AR Screen: ⚠️ Error clearing model cache: $e');
        }
        
        // Step 3: Allow nukeAll to process completely
        debugPrint('AR Screen: Step 3/6 - Allowing nukeAll processing...');
        await Future.delayed(const Duration(milliseconds: 400));
        
        // Step 4: Now dispose session controller and managers
        debugPrint('AR Screen: Step 4/6 - Disposing session controller and managers');
        _sessionController.forceDispose();
        debugPrint('AR Screen: ✅ Session controller disposed');
        
        // Step 5: Additional aggressive cleanup delay
        debugPrint('AR Screen: Step 5/6 - Aggressive memory release delay...');
        await Future.delayed(const Duration(milliseconds: 800));
        
        // Step 6: Try to trigger garbage collection (platform-specific)
        debugPrint('AR Screen: Step 6/6 - Attempting garbage collection trigger');
        try {
          // Force garbage collection hints
          List<int>.filled(800000, 0).clear(); // Create and immediately clear large list
          await Future.delayed(const Duration(milliseconds: 100));
          debugPrint('AR Screen: ✅ GC trigger attempt completed');
        } catch (e) {
          debugPrint('AR Screen: GC trigger failed: $e');
        }
        
      } catch (e) {
        debugPrint('AR Screen: ❌ Error during complete disposal: $e');
      }
      
    } else {
      // Standard disposal (current behavior)
      _sessionController.forceDispose();
      
      final ok = await _sessionController.sessionManager?.nukeAll(
        purgeCaches: true,
        removeExistingAnchors: true,
        resetTracking: true,
      );
      if (ok != null && ok) {
        if (mounted) {
          setState(() => _shouldRenderARView = false);
          await Future.delayed(const Duration(milliseconds: 50));
          await Future.delayed(const Duration(milliseconds: 300));
          if (mounted) {
            setState(() => _shouldRenderARView = true);
          }
        }
      }
    }

    if (mounted && !completeDisposal) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {});
        }
      });
    }
  }

  // =================================================================
  // Memory Management Methods
  // =================================================================

  /// Start memory monitoring for AR session
  void _startMemoryMonitoring() {
    if (_isMemoryMonitoringActive) return;

    _isMemoryMonitoringActive = true;
    
    // Reset memory tracking for fresh AR session
    ARMemoryManager.resetTracking();
    ARMemoryManager.startMemoryMonitoring();
    _updateMemoryInfo();
  }

  /// Stop memory monitoring
  void _stopMemoryMonitoring() {
    if (!_isMemoryMonitoringActive) return;

    _isMemoryMonitoringActive = false;
    ARMemoryManager.stopMemoryMonitoring();
  }

  /// Update current memory information
  Future<void> _updateMemoryInfo() async {
    try {
      final memoryInfo = await ARMemoryManager.getCurrentMemoryInfo();
      
      // Set baseline on first memory update if not set
      if (!_baselineSet) {
        ARMemoryManager.setBaseline(memoryInfo);
        _baselineSet = true;
      }
      
      if (mounted) {
        setState(() {
          _currentMemoryInfo = memoryInfo;
        });
      }

      // Handle critical memory situations
      if (memoryInfo.status == MemoryStatus.danger || memoryInfo.status == MemoryStatus.overLimit) {
        _handleMemoryPressure(memoryInfo);
      }

    } catch (e) {
      if (kDebugMode) {
        debugPrint('AR Screen: Error updating memory info: $e');
      }
    }
  }

  /// Handle memory pressure situations
  void _handleMemoryPressure(MemoryInfo memoryInfo) {
    if (memoryInfo.status == MemoryStatus.overLimit) {
      _showMemoryWarning(
        'Critical memory usage detected. Please remove some AR models to prevent crashes.',
        isEmergency: true,
      );
      
      // Consider automatic cleanup if too many models
      if (nodes.length > 3) {
        _showMemoryWarning(
          'Too many AR models may cause crashes. Consider removing some models.',
          isEmergency: true,
        );
      }
      
    } else if (memoryInfo.status == MemoryStatus.danger) {
      _showMemoryWarning(
        'High memory usage detected. Adding more models may cause crashes.',
        isEmergency: false,
      );
    }
  }

  /// Show memory warning to user
  void _showMemoryWarning(String message, {required bool isEmergency}) {
    // We do not need to show this warning for now
    return;
    // if (!mounted) return;

    // Use ScaffoldMessenger to show warning
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isEmergency ? Colors.red[700] : Colors.orange[700],
        duration: Duration(seconds: isEmergency ? 6 : 4),
        action: isEmergency ? SnackBarAction(
          label: 'Odstrániť objekty',
          textColor: Colors.white,
          onPressed: () {
            // If there's a selected node, remove it
            if (selectedNode != null) {
              _removeSelectedModel();
            } 
          },
        ) : null,
      ),
    );
  }

  /// Show memory placement failure overlay
  void _showMemoryPlacementFailure() {
    if (!mounted || _isShowingMemoryWarning) return;
    
    setState(() {
      _isShowingMemoryWarning = true;
    });
    
    // Auto-hide after 3 seconds
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _isShowingMemoryWarning = false;
        });
      }
    });
  }

  /// Check if it's safe to add another model
  Future<bool> _canSafelyAddModel({bool isForRestoration = false}) async {
    try {
      final memoryInfo = await ARMemoryManager.getCurrentMemoryInfo();
      
      debugPrint('AR Screen: === MEMORY SAFETY CHECK (isForRestoration: $isForRestoration) ===');
      debugPrint('AR Screen: Current nodes: ${nodes.length}');
      debugPrint('AR Screen: Max objects reached before limit: $_maxObjectsReachedBeforeMemoryLimit');
      debugPrint('AR Screen: Objects removed since limit: $_objectsRemovedSinceMemoryLimit');
      debugPrint('AR Screen: Memory status: ${memoryInfo.status}');
      debugPrint('AR Screen: Can add model (memory): ${memoryInfo.canAddModel}');
      
      // Add debug decision logging
      await ARMemoryManager.debugMemoryDecision();
      
      // Smart memory-aware placement logic:
      // If we've hit memory limits before and removed objects, use that history
      if (_maxObjectsReachedBeforeMemoryLimit > 0 && _objectsRemovedSinceMemoryLimit > 0) {
        int effectiveCapacity = _maxObjectsReachedBeforeMemoryLimit;
        int currentObjects = nodes.length;
        
        debugPrint('AR Screen: Using smart capacity logic:');
        debugPrint('AR Screen: - Effective capacity: $effectiveCapacity');
        debugPrint('AR Screen: - Current objects: $currentObjects');
        
        if (currentObjects < effectiveCapacity) {
          debugPrint('AR Screen: ✅ Smart logic allows placement - OS will reuse memory');
          debugPrint('AR Screen: - Can place ${effectiveCapacity - currentObjects} more objects');
          
          // Note: _objectsRemovedSinceMemoryLimit will be decremented in placement success callback
          
          return true;
        } else {
          debugPrint('AR Screen: ❌ Smart logic blocks placement - at effective capacity');
          if (!isForRestoration) {
            _showMemoryWarning(
              'Maximumálny limit objektov prekročený ($currentObjects/$effectiveCapacity). Odstráňte niektoré modely.',
              isEmergency: false,
            );
          }
          return false;
        }
      }
      
      // CRITICAL FIX: Only set memory limits during actual NEW placement attempts, NOT during restoration
      if (isForRestoration) {
        debugPrint('AR Screen: 🔧 RESTORATION MODE - Memory checks for info only, not setting limits');
        
        // For restoration, just log the memory status but don't set limits
        if (!memoryInfo.canAddModel) {
          debugPrint('AR Screen: ⚠️ Memory warning during restoration: ${memoryInfo.usagePercentage.toStringAsFixed(1)}%');
        }
        
        final maxSafeModels = await ARMemoryManager.calculateMaxSafeModels();
        if (nodes.length >= maxSafeModels) {
          debugPrint('AR Screen: ⚠️ Max safe models warning during restoration: (${nodes.length}/$maxSafeModels)');
        }
        
        // Always allow restoration - we're just putting back what was there before
        debugPrint('AR Screen: ✅ Restoration allowed regardless of memory status');
        return true;
      }
      
      // Standard memory checks for NEW PLACEMENT ATTEMPTS ONLY
      if (!memoryInfo.canAddModel) {
        debugPrint('AR Screen: ❌ Cannot add model - Memory usage too high: ${memoryInfo.usagePercentage.toStringAsFixed(1)}%');
        
        // CRITICAL: Only now do we set the memory limit - we've actually hit it during NEW placement!
        // Current nodes.length represents the maximum number of objects we successfully placed
        debugPrint('AR Screen: 🔍 MEMORY LIMIT HIT - Current state:');
        debugPrint('AR Screen: - nodes.length (successfully placed): ${nodes.length}');
        debugPrint('AR Screen: - Current _maxObjectsReachedBeforeMemoryLimit: $_maxObjectsReachedBeforeMemoryLimit');
        debugPrint('AR Screen: - Will set to: ${nodes.length}');
        
        if (nodes.length > _maxObjectsReachedBeforeMemoryLimit) {
          _maxObjectsReachedBeforeMemoryLimit = nodes.length;
          debugPrint('AR Screen: 🎯 MEMORY LIMIT REACHED! Set max objects limit to: $_maxObjectsReachedBeforeMemoryLimit');
        } else {
          debugPrint('AR Screen: 🎯 MEMORY LIMIT REACHED! Keeping existing max: $_maxObjectsReachedBeforeMemoryLimit (current: ${nodes.length})');
        }

        await _sessionController.objectManager!.purgeCaches();
        await _sessionController.sessionManager!.softResetSession();
        
        _showMemoryWarning(
          'Cannot add more models. Memory usage is too high (${memoryInfo.usagePercentage.toStringAsFixed(1)}%).',
          isEmergency: memoryInfo.status == MemoryStatus.overLimit,
        );

        return false;
      }

      // Additional check: Calculate max safe models for NEW PLACEMENT ATTEMPTS ONLY
      final maxSafeModels = await ARMemoryManager.calculateMaxSafeModels();
      if (nodes.length >= maxSafeModels) {
        debugPrint('AR Screen: ❌ Cannot add model - Too many models (${nodes.length}/$maxSafeModels max safe)');
        
        // CRITICAL: Only now do we set the memory limit - we've actually hit it during NEW placement!
        // Current nodes.length represents the maximum number of objects we successfully placed
        debugPrint('AR Screen: 🔍 MAX SAFE MODELS HIT - Current state:');
        debugPrint('AR Screen: - nodes.length (successfully placed): ${nodes.length}');
        debugPrint('AR Screen: - Current _maxObjectsReachedBeforeMemoryLimit: $_maxObjectsReachedBeforeMemoryLimit');
        debugPrint('AR Screen: - Will set to: ${nodes.length}');
        
        if (nodes.length > _maxObjectsReachedBeforeMemoryLimit) {
          _maxObjectsReachedBeforeMemoryLimit = nodes.length;
          debugPrint('AR Screen: 🎯 MAX SAFE MODELS REACHED! Set max objects limit to: $_maxObjectsReachedBeforeMemoryLimit');
        } else {
          debugPrint('AR Screen: 🎯 MAX SAFE MODELS REACHED! Keeping existing max: $_maxObjectsReachedBeforeMemoryLimit (current: ${nodes.length})');
        }
        
        _showMemoryWarning(
          'Maximumálny limit objektov dosiahnutý (${nodes.length}/$maxSafeModels). Odstráňte niektoré modely.',
          isEmergency: false,
        );
        
        return false;
      }

      debugPrint('AR Screen: ✅ Safe to add model - Memory usage: ${memoryInfo.usagePercentage.toStringAsFixed(1)}%');
      return true;
      
    } catch (e) {
      debugPrint('AR Screen: Error checking memory safety: $e');
      // Be conservative on error, but use smart logic if available
      if (_maxObjectsReachedBeforeMemoryLimit > 0 && nodes.length < _maxObjectsReachedBeforeMemoryLimit) {
        debugPrint('AR Screen: Using fallback smart logic - allowing placement based on history');
        return true;
      }
      return nodes.length < 3; // Conservative fallback
    }
  }

  /// Clear AR scene state while preserving persistent model data
  void _clearARSceneState() {
    debugPrint('AR Screen: Clearing AR scene state (preserving persistent data)');
    
    // Clear local AR scene tracking
    nodes.clear();
    nodeCreationOrder.clear();
    selectedNode = null;
    hasPlacedInitialModel = false;
    detectedPlane = null;
    
    // Reset smart memory tracking when clearing scene
    _maxObjectsReachedBeforeMemoryLimit = 0;
    _objectsRemovedSinceMemoryLimit = 0;
    debugPrint('AR Screen: Reset smart memory tracking - fresh start for new AR session');
    
    // Update persistent models to reflect they're no longer in AR scene
    // but keep their data for future restoration
    // CRITICAL: Use getAllPersistentModels() to get all models regardless of current isPlaced status
    List<ARModelData> allModels = _modelManager.getAllPersistentModels();
    if (allModels.isNotEmpty) {
      debugPrint('AR Screen: Updating ${allModels.length} models - marking as not placed in AR scene but preserving data');
      
      for (ARModelData model in allModels) {
        // Only update if the model currently has an active node ID (is actually placed)
        if (model.activeNodeId != null) {
          _modelManager.updateModel(
            model.id,
            activeNodeId: null,
            isPlaced: false, // Mark as not currently placed in AR scene (but keep data for restoration)
          );
        }
      }
      
      debugPrint('AR Screen: ✅ AR scene state cleared, ${allModels.length} models preserved for restoration');
    } else {
      debugPrint('AR Screen: ✅ AR scene state cleared, no models to preserve');
    }
  }

  /// Pause AR session when app goes to background
  Future<void> _pauseARSession() async {
    if (_isARSessionPaused) {
      debugPrint('AR Screen: AR session already paused');
      return;
    }
    
    debugPrint('AR Screen: === PAUSING AR SESSION ===');
    
    try {
      _isARSessionPaused = true;
      
      // Use session controller to pause AR session
      await _sessionController.pauseSession();
      
      if (mounted) {
        setState(() {
          _shouldRenderARView = false;
        });
      }
      
      // Stop memory monitoring while paused
      _stopMemoryMonitoring();
      
      debugPrint('AR Screen: ✅ AR session paused successfully');
    } catch (e) {
      debugPrint('AR Screen: ❌ Error pausing AR session: $e');
      // In case of error, still disable rendering for safety
      if (mounted) {
        setState(() {
          _shouldRenderARView = false;
        });
      }
    }
  }

  /// Resume AR session when app returns to foreground  
  Future<void> _resumeARSession() async {
    if (!_isARSessionPaused) {
      debugPrint('AR Screen: AR session not paused, no need to resume');
      return;
    }
    
    debugPrint('AR Screen: === RESUMING AR SESSION ===');
    
    try {
      // Use session controller to resume AR session
      await _sessionController.resumeSession();
      
      if (mounted) {
        setState(() {
          _shouldRenderARView = true;
        });
      }
      
      // Resume memory monitoring
      _startMemoryMonitoring();
      
      // Allow some time for AR to reinitialize
      await Future.delayed(const Duration(milliseconds: 500));
      
      _isARSessionPaused = false;
      debugPrint('AR Screen: ✅ AR session resumed successfully');
    } catch (e) {
      debugPrint('AR Screen: ❌ Error resuming AR session: $e');
      debugPrint('AR Screen: Will attempt to reinitialize AR session');
      
      // Re-enable rendering so AR can reinitialize
      if (mounted) {
        setState(() {
          _shouldRenderARView = true;
        });
      }
      
      _isARSessionPaused = false;
    }
  }

  /// Enhanced pause method for navigation
  Future<void> _pauseARSessionForNavigation() async {
    if (_isARSessionPaused) return;
    
    debugPrint('AR Screen: === PAUSING AR SESSION FOR NAVIGATION ===');
    debugPrint('AR Screen: Preserving node tracking: $nodeCreationOrder');
    
    try {
      _isARSessionPaused = true;
      
      // Disable AR rendering but keep session alive
      await _sessionController.pauseSession();
      
      // Hide AR view but preserve all data (DO NOT clear scene state)
      if (mounted) {
        setState(() {
          _shouldRenderARView = false;
        });
      }
      
      // Stop memory monitoring temporarily
      _stopMemoryMonitoring();
      
      debugPrint('AR Screen: ✅ AR session paused for navigation - tracking preserved');
    } catch (e) {
      debugPrint('AR Screen: ❌ Error pausing for navigation: $e');
    }
  }

  /// Enhanced resume method for navigation return
  Future<void> _resumeARSessionFromNavigation() async {
    if (!_isARSessionPaused) return;
    
    debugPrint('AR Screen: === RESUMING AR SESSION FROM NAVIGATION ===');
    debugPrint('AR Screen: Pre-resume node tracking: $nodeCreationOrder');
    debugPrint('AR Screen: Checking for new product model: ${widget.product?.id}');
    
    try {
      // CRITICAL FIX: For Android, if we have a new product model, reset the entire AR scene
      // to avoid anchor hierarchy corruption
      bool hasNewProductModel = _hasNewProductModelSinceLastResume();
      
      if (Platform.isAndroid && hasNewProductModel) {
        debugPrint('AR Screen: 🔧 ANDROID NEW MODEL DETECTED - Performing full AR scene reset');
        await _performAndroidSceneResetForNewModel();
      } else {
        debugPrint('AR Screen: 📱 Standard session resume (no new model or iOS)');
        // Resume AR session
        await _sessionController.resumeSession();
        
        // Re-enable AR rendering
        if (mounted) {
          setState(() {
            _shouldRenderARView = true;
          });
        }
        
        // Resume memory monitoring
        _startMemoryMonitoring();
        
        // CRITICAL: Synchronize node tracking with actual AR scene
        await _synchronizeNodeTracking();
        
        // Allow AR to stabilize
        await Future.delayed(const Duration(milliseconds: 500));
      }
      
      _isARSessionPaused = false;
      debugPrint('AR Screen: ✅ AR session resumed from navigation - tracking synchronized');
      
      // Verify node tracking synchronization
      debugPrint('AR Screen: Post-resume node tracking verification:');
      debugPrint('AR Screen: - Available nodes: $nodeCreationOrder');
      debugPrint('AR Screen: - Selected node: $selectedNode');
      
    } catch (e) {
      debugPrint('AR Screen: ❌ Error resuming from navigation: $e');
    }
  }

  /// Initialize gesture isolation for multiple objects to prevent interference
  Future<void> _initializeGestureIsolation() async {
    debugPrint('AR Screen: === INITIALIZING GESTURE ISOLATION ===');
    
    try {
      // Safety check for AR session state
      if (_sessionController.objectManager == null) {
        debugPrint('AR Screen: ⚠️ Object manager unavailable, deferring gesture isolation');
        return;
      }
      
      // Check if AR tracking is stable before proceeding
      if (nodeCreationOrder.isEmpty) {
        debugPrint('AR Screen: No objects in scene, skipping gesture isolation');
        return;
      }
      
      // Clear any existing selection to reset gesture state
      if (selectedNode != null) {
        if (mounted) {
          setState(() {
            selectedNode = null;
          });
        }
        debugPrint('AR Screen: Cleared selection for gesture reset');
      }
      
      // Add small delay to let the gesture system stabilize
      await Future.delayed(const Duration(milliseconds: 200));
      
      // Force gesture controller reset for all objects with error handling
      debugPrint('AR Screen: Requesting gesture controller refresh for all objects');
      
      // This will help reset any corrupted gesture state between objects
      for (String nodeId in nodeCreationOrder) {
        try {
          debugPrint('AR Screen: Refreshing gesture state for node: $nodeId');
          // The native SceneForm will handle the actual refresh
        } catch (e) {
          debugPrint('AR Screen: ⚠️ Error refreshing gesture for node $nodeId: $e');
          // Continue with other nodes
        }
      }
      
      debugPrint('AR Screen: ✅ Gesture isolation initialized for ${nodeCreationOrder.length} objects');
    } catch (e) {
      debugPrint('AR Screen: ❌ Error during gesture isolation: $e');
      // Attempt recovery if initialization fails
      _recoverFromGestureFailure();
    }
  }

  /// Emergency gesture recovery when TransformableNode anchor errors are detected
  Future<void> _recoverFromGestureFailure() async {
    debugPrint('AR Screen: === EMERGENCY GESTURE RECOVERY ===');
    
    try {
      // Step 1: Clear all selections to reset gesture state
      if (selectedNode != null) {
        if (mounted) {
          setState(() {
            selectedNode = null;
          });
        }
        debugPrint('AR Screen: 🔧 Cleared selection for emergency recovery');
      }
      
      // Step 2: Check if AR session is still valid before attempting recovery
      if (_sessionController.objectManager == null) {
        debugPrint('AR Screen: ⚠️ AR session unavailable during recovery, skipping session reset');
        return;
      }
      
      // Step 3: Force pause and resume AR session to reset gesture controllers
      debugPrint('AR Screen: 🔧 Forcing AR session reset for gesture recovery...');
      try {
        await _sessionController.pauseSession();
        await Future.delayed(const Duration(milliseconds: 500)); // Longer delay for stability
        await _sessionController.resumeSession();
        debugPrint('AR Screen: ✅ AR session reset completed');
      } catch (e) {
        debugPrint('AR Screen: ⚠️ AR session reset failed: $e');
        // Continue with other recovery steps
      }
      
      // Step 4: Re-synchronize node tracking with error handling
      try {
        await _synchronizeNodeTracking();
        debugPrint('AR Screen: ✅ Node tracking synchronized');
      } catch (e) {
        debugPrint('AR Screen: ⚠️ Node synchronization failed: $e');
      }
      
      debugPrint('AR Screen: ✅ Emergency gesture recovery completed');
      
    } catch (e) {
      debugPrint('AR Screen: ❌ Emergency gesture recovery failed: $e');
      // Last resort: clear all tracking state
      try {
        if (mounted) {
          setState(() {
            selectedNode = null;
          });
        }
        debugPrint('AR Screen: 🔧 Performed last-resort state cleanup');
      } catch (stateError) {
        debugPrint('AR Screen: ❌ Last-resort cleanup failed: $stateError');
      }
    }
  }

  /// Check if there's a new product model since last resume
  bool _hasNewProductModelSinceLastResume() {
    // Check if we have a new product that wasn't processed before navigation
    if (widget.product?.id != null && currentUniqueProductId != widget.product?.id) {
      debugPrint('AR Screen: New product detected - Current: $currentUniqueProductId, New: ${widget.product?.id}');
      return true;
    }
    
    // Check if we have a new model URL that needs to be placed
    if (widget.product?.modelUrl != null && modelUri != widget.product?.modelUrl) {
      debugPrint('AR Screen: New model URL detected - Current: $modelUri, New: ${widget.product?.modelUrl}');
      return true;
    }
    
    return false;
  }

  /// Perform full Android AR scene reset when adding new model to avoid anchor hierarchy issues
  Future<void> _performAndroidSceneResetForNewModel() async {
    debugPrint('AR Screen: === ANDROID SCENE RESET FOR NEW MODEL ===');
    
    try {
      // Step 1: Store current models for restoration
      List<ARModelData> currentModels = _modelManager.getAllPersistentModels();
      debugPrint('AR Screen: Storing ${currentModels.length} existing models for restoration');
      
      // Step 2: CRITICAL FIX - Force complete AR session disposal with anchor cleanup
      debugPrint('AR Screen: 🔄 Performing complete AR session disposal with anchor cleanup...');
      
      // Force nukeAll to clear ALL anchors and nodes before disposing
      try {
        await _sessionController.sessionManager?.nukeAll(
          purgeCaches: true,
          removeExistingAnchors: true,
          resetTracking: true,
        );
        debugPrint('AR Screen: ✅ nukeAll completed - all anchors cleared');
        await Future.delayed(const Duration(milliseconds: 500)); // Let cleanup complete
      } catch (e) {
        debugPrint('AR Screen: ⚠️ nukeAll failed: $e');
      }
      
      // Force dispose current session completely
      await _sessionController.dispose();
      await Future.delayed(const Duration(milliseconds: 500));
      
      // Clear all local tracking state
      nodes.clear();
      nodeCreationOrder.clear();
      selectedNode = null;
      _isProcessingNodeSelection = false;
      
      // Step 3: Clear the model manager completely and re-add models
      // This ensures clean state without corrupted references
      _modelManager.clearAllModels();
      
      // Re-add the stored models to model manager (but not AR scene yet)
      for (ARModelData model in currentModels) {
        _modelManager.addModel(
          modelUri: model.modelUri,
          productId: model.productId,
          position: model.position,
          scale: model.scale,
          rotation: model.rotation,
          cachedPath: model.cachedPath,
          // Don't set activeNodeId - let them be restored fresh
        );
      }
      
      // Step 4: Re-enable AR rendering and force complete reinitialization
      if (mounted) {
        setState(() {
          _shouldRenderARView = true;
          _hasBeenDisposed = false; // Reset disposal flag
        });
      }
      
      // Step 5: Allow AR view to rebuild completely with fresh session
      await Future.delayed(const Duration(milliseconds: 800));
      
      // Step 6: Resume memory monitoring
      _startMemoryMonitoring();
      
      // Step 7: Handle the new product model first
      _handleNewProductModel();
      
      // Step 8: Start model download process if we have a new model
      if (modelUri != null && !hasPlacedInitialModel) {
        debugPrint('AR Screen: 🆕 Starting new model download after complete reset');
        _startModelDownloadProcess();
      }
      
      debugPrint('AR Screen: ✅ Complete Android scene reset completed - fresh session ready');
      
    } catch (e) {
      debugPrint('AR Screen: ❌ Error during complete Android scene reset: $e');
      
      // Fallback: Try standard resume
      try {
        await _sessionController.resumeSession();
        if (mounted) {
          setState(() {
            _shouldRenderARView = true;
          });
        }
        _startMemoryMonitoring();
      } catch (fallbackError) {
        debugPrint('AR Screen: ❌ Fallback resume also failed: $fallbackError');
      }
    }
  }

  Future<void> _synchronizeNodeTracking() async {
    debugPrint('AR Screen: === SYNCHRONIZING NODE TRACKING ===');
    
    try {
      // Get all persistent models that should be in the AR scene
      List<ARModelData> persistentModels = _modelManager.getAllPersistentModels();
      
      // Rebuild node tracking lists from persistent models with active nodes
      List<String> activeNodeIds = [];
      List<ARNode> activeNodes = [];
      
      for (ARModelData model in persistentModels) {
        if (model.activeNodeId != null && model.isPlaced) {
          activeNodeIds.add(model.activeNodeId!);
          
          // Find corresponding ARNode if it exists
          try {
            ARNode? existingNode = nodes.firstWhere(
              (node) => node.name == model.activeNodeId,
            );
            activeNodes.add(existingNode);
          } catch (e) {
            // Node not found in current list - this is expected after navigation
            debugPrint('AR Screen: Node ${model.activeNodeId} not found in current node list (expected after navigation)');
          }
        }
      }
      
      // Update tracking lists
      nodeCreationOrder.clear();
      nodeCreationOrder.addAll(activeNodeIds);
      
      nodes.clear();
      nodes.addAll(activeNodes);
      
      debugPrint('AR Screen: ✅ Node tracking synchronized');
      debugPrint('AR Screen: - Restored ${nodeCreationOrder.length} active nodes: $nodeCreationOrder');
      debugPrint('AR Screen: - Restored ${nodes.length} AR nodes');
      
      // Clear selection if the selected node is no longer valid
      if (selectedNode != null && !nodeCreationOrder.contains(selectedNode!)) {
        debugPrint('AR Screen: ⚠️ Selected node no longer valid, clearing selection');
        selectedNode = null;
      }
      
    } catch (e) {
      debugPrint('AR Screen: ❌ Error during node tracking synchronization: $e');
    }
  }

  /// Navigate to category page while preserving AR session
  Future<void> _navigateToCategory() async {
    debugPrint('AR Screen: === NAVIGATION WITH SESSION CONTINUITY ===');
    
    // PAUSE AR session instead of destroying it
    await _pauseARSessionForNavigation();
    
    // Set navigation state
    if (mounted) {
      context.read<ArNavigationProvider>().setGoFromAR();
    }
    
    // Navigate with result to know when user returns
    final result = await Navigator.of(context).pushNamed(
      '/category', 
      arguments: {'isSearchHeaderShow': true}
    );
    
    // RESUME AR session when returning
    if (mounted && result != null) {
      await _resumeARSessionFromNavigation();
      debugPrint('AR Screen: ✅ Returned from category - AR session resumed');
    }
  }

  /// Handle new product model from navigation
  void _handleNewProductModel() {
    String? productId = widget.product?.id;
    debugPrint('AR Screen: === HANDLING NEW PRODUCT MODEL ===');
    debugPrint('AR Screen: Product ID: $productId');
    debugPrint('AR Screen: Product: ${widget.product}');
    debugPrint('AR Screen: Product modelUrl: ${widget.product?.modelUrl}');
    debugPrint('AR Screen: Product assets: ${widget.product?.assets}');
    debugPrint('AR Screen: Assets count: ${widget.product?.assets.length ?? 0}');

    String? modelUrl;
    
    // Method 1: Direct modelUrl field
    if (widget.product != null && widget.product?.modelUrl != null && widget.product!.modelUrl.toString().isNotEmpty) {
      // Prefer a .glb from assets even if modelUrl field exists
      final candidate = widget.product?.modelUrl.toString() ?? '';
      debugPrint('AR Screen: Checking direct modelUrl: $candidate');
      
      if (candidate.toLowerCase().endsWith('.glb')) {
        modelUrl = candidate;
        debugPrint('AR Screen: ✅ Found GLB modelUrl directly: $modelUrl');
      } else {
        debugPrint('AR Screen: modelUrl is not GLB ($candidate), checking assets for GLB files...');
        final assets = widget.product?.assets;
        debugPrint('AR Screen: Assets from product: $assets');
        
        if (assets != null) {
          debugPrint('AR Screen: Searching through ${assets.length} assets...');
          for (int i = 0; i < assets.length; i++) {
            final asset = assets[i];
            debugPrint('AR Screen: Asset $i: ${asset.toString()}');
            debugPrint('AR Screen: - ID: ${asset.id}');
            debugPrint('AR Screen: - URL: ${asset.url}');
            debugPrint('AR Screen: - Type: ${asset.type}');
            
            if (asset.type == 'MODEL' && asset.url.toLowerCase().endsWith('.glb')) {
              modelUrl = asset.url;
              debugPrint('AR Screen: ✅ Found GLB in assets at index $i: $modelUrl');
              break;
            }
          }
        } else {
          debugPrint('AR Screen: ⚠️ Assets list is null');
        }
        
        // CRITICAL FIX: Only use GLB files - don't fall back to non-GLB modelUrl
        if (modelUrl == null) {
          debugPrint('AR Screen: ⚠️ No GLB model found. Original modelUrl: $candidate');
          debugPrint('AR Screen: Skipping product as it only has non-GLB models');
          // Don't set modelUrl - let it remain null to indicate no compatible model
        }
      }
    } else {
      debugPrint('AR Screen: No modelUrl field, checking assets only...');
      final assets = widget.product?.assets;
      debugPrint('AR Screen: Assets from product (no modelUrl): $assets');
      
      if (assets != null) {
        debugPrint('AR Screen: Searching through ${assets.length} assets for GLB...');
        for (int i = 0; i < assets.length; i++) {
          final asset = assets[i];
          debugPrint('AR Screen: Asset $i: ${asset.toString()}');
          debugPrint('AR Screen: - ID: ${asset.id}');
          debugPrint('AR Screen: - URL: ${asset.url}');
          debugPrint('AR Screen: - Type: ${asset.type}');
          
          if (asset.type == 'MODEL' && asset.url.toLowerCase().endsWith('.glb')) {
            modelUrl = asset.url;
            debugPrint('AR Screen: ✅ Found GLB in assets (no modelUrl field) at index $i: $modelUrl');
            break;
          }
        }
      } else {
        debugPrint('AR Screen: ⚠️ Assets list is null (no modelUrl field case)');
      }
    }

    String? productModelUrl = modelUrl;
    debugPrint('AR Screen: Final productModelUrl: $productModelUrl');
    
    if (modelUrl != null) {
      // Create unique product identifier with timestamp to allow multiple instances
      currentUniqueProductId = "${productId}_${DateTime.now().millisecondsSinceEpoch}";
      modelUri = modelUrl;
      
      // Reset placement flag to allow new model placement
      hasPlacedInitialModel = false;
      
      _checkModelCache();
    } else {
      currentUniqueProductId = null;
    }
  }

  /// Check if the current model is cached
  Future<void> _checkModelCache() async {
    if (modelUri == null) return;
    
    try {
      String? cachedPath = await ARModelCache.checkModelCache(modelUri!);
      
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {
              cachedModelPath = cachedPath;
              isModelCached = cachedPath != null;
            });
          }
        });
      }
      
      debugPrint('AR Screen: ✅ Model found in cache: $cachedPath');
        } catch (e) {
      debugPrint('AR Screen: Error checking model cache: $e');
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {
              cachedModelPath = null;
              isModelCached = false;
            });
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _buildBody(),
    );
  }

  /// Build the main body content
  Widget _buildBody() {
    if (!_shouldRenderARView || !_sessionController.isPluginAvailable) {
      return _buildErrorState();
    }

    return Stack(
      children: [
        _buildARView(),
        _buildLoadingOverlay(),
        _buildInstructionOverlay(),
        _buildMemoryStatusOverlay(),
        // _buildMemoryDebugOverlay(),
        _buildMemoryPlacementFailureOverlay(),
        _buildAndroidSingleObjectModeIndicator(),
        _buildBackButton(),
        _buildDeleteButton(),
        _buildAddButton(),
        _buildCameraButton(),
      ],
    );
  }

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
          debugPrint('AR Screen: Back button pressed - COMPLETE AR session disposal BEFORE navigation');
          
          // Memory monitoring BEFORE complete disposal
          MemoryInfo? memoryBefore;
          try {
            memoryBefore = await ARMemoryManager.getCurrentMemoryInfo();
            debugPrint('AR Screen: 📊 MEMORY BEFORE complete disposal: ${memoryBefore.usagePercentage.toStringAsFixed(1)}% (${memoryBefore.usedMemoryMB.toStringAsFixed(1)}MB)');
          } catch (e) {
            debugPrint('AR Screen: Error getting memory before disposal: $e');
          }
          
          // Complete AR session disposal for maximum memory cleanup
          if (!_nukeAllAlreadyCalled) {
            _nukeAllAlreadyCalled = true; // Prevent duplicate calls
            
            try {
              // Step 1: Force dispose the entire AR session (most aggressive cleanup)
              debugPrint('AR Screen: 🧨 COMPLETE AR SESSION DISPOSAL - Maximum memory cleanup');
              await _forceDisposeARSession(completeDisposal: true);
              
              // Step 2: Additional delay to allow complete native cleanup
              debugPrint('AR Screen: ⏳ Waiting for complete AR session disposal...');
              await Future.delayed(const Duration(milliseconds: 1000)); // Increased delay
              
              debugPrint('AR Screen: ✅ Complete AR session disposal completed');
              
              // Memory monitoring AFTER complete disposal
              try {
                final memoryAfter = await ARMemoryManager.getCurrentMemoryInfo();
                debugPrint('AR Screen: 📊 MEMORY AFTER complete disposal: ${memoryAfter.usagePercentage.toStringAsFixed(1)}% (${memoryAfter.usedMemoryMB.toStringAsFixed(1)}MB)');
                
                // Calculate memory freed using the before measurement
                if (memoryBefore != null) {
                  double memoryFreed = memoryBefore.usedMemoryMB - memoryAfter.usedMemoryMB;
                  debugPrint('AR Screen: 📊 MEMORY FREED by complete disposal: ${memoryFreed.toStringAsFixed(1)}MB');
                  
                  if (memoryFreed > 0) {
                    debugPrint('AR Screen: ✅ Successfully freed ${memoryFreed.toStringAsFixed(1)}MB of memory');
                  } else {
                    debugPrint('AR Screen: ⚠️ Memory cleanup was not effective (${memoryFreed.toStringAsFixed(1)}MB change)');
                  }
                }
              } catch (e) {
                debugPrint('AR Screen: Error getting memory after disposal: $e');
              }
              
            } catch (e) {
              debugPrint('AR Screen: ❌ Back button complete disposal error: $e');
            }
          } else {
            debugPrint('AR Screen: ⚠️ Back button - AR session already disposed, skipping duplicate');
          }
          
          // Navigate after complete cleanup
          if (mounted) {
            Navigator.of(context).pop();
          }
        },
      ),
      ),
    );
  }

  /// Build error state when AR is not available
  Widget _buildErrorState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 64, color: Colors.red),
          SizedBox(height: 16),
          Text(
            'AR engine unavailable',
            style: TextStyle(fontSize: 18, color: Colors.white),
          ),
          SizedBox(height: 8),
          Text(
            'Please restart the app',
            style: TextStyle(fontSize: 14, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  /// Build the AR view
  Widget _buildARView() {
    return ARView(
      onARViewCreated: _onARViewCreated,
      planeDetectionConfig: PlaneDetectionConfig.horizontal,
    );
  }

  /// Build loading overlay
  Widget _buildLoadingOverlay() {
    if (!isDownloadingModel) return const SizedBox.shrink();
    
    return Container(
      color: Colors.black54,
      child: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 16),
            Text(
              'Downloading model...',
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }

  /// Build instruction overlay
  Widget _buildInstructionOverlay() {
    if (!showInstructionMessage) return const SizedBox.shrink();
    
    return Positioned(
      top: 120,
      left: 20,
      right: 20,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Text(
          'Natočte kameru na rovný povrch a počkajte na zobrazenie objektu',
          style: TextStyle(color: Colors.white, fontSize: 14),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  /// Build memory status overlay
  Widget _buildMemoryPlacementFailureOverlay() {
    if (!_isShowingMemoryWarning) {
      return Container();
    }

    return Container(
      color: Colors.black.withOpacity(0.8),
      child: Center(
        child: Container(
          padding: EdgeInsets.all(20),
          margin: EdgeInsets.symmetric(horizontal: 40),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            'Nedostatok pamäte. Objekt sa nepodarilo pridať.\nOdstráňte niektoré objekty a skúste to znova.',
            style: TextStyle(
              color: Colors.black,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }

  Widget _buildMemoryStatusOverlay() {
    // Do not show memory status overlay if not needed
    if (true) return const SizedBox.shrink();
    // Only show memory status if we have memory info and it's concerning
    // if (_currentMemoryInfo == null) return const SizedBox.shrink();
    
    final memInfo = _currentMemoryInfo!;
    
    // Only show for warning level and above
    if (memInfo.status == MemoryStatus.safe) return const SizedBox.shrink();
    
    Color statusColor;
    IconData statusIcon;
    
    switch (memInfo.status) {
      case MemoryStatus.warning:
        statusColor = Colors.orange;
        statusIcon = Icons.warning_amber;
        break;
      case MemoryStatus.critical:
        statusColor = Colors.deepOrange;
        statusIcon = Icons.warning;
        break;
      case MemoryStatus.danger:
        statusColor = Colors.red[700]!;
        statusIcon = Icons.error;
        break;
      case MemoryStatus.overLimit:
        statusColor = Colors.red[900]!;
        statusIcon = Icons.dangerous;
        break;
      case MemoryStatus.safe:
        return const SizedBox.shrink();
    }
    
    return Positioned(
      top: MediaQuery.of(context).padding.top + 60.0, // Below the back button
      right: 20,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: statusColor.withAlpha((0.9 * 255).toInt()),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha((0.3 * 255).toInt()),
              spreadRadius: 1,
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              statusIcon,
              color: Colors.white,
              size: 16,
            ),
            const SizedBox(width: 4),
            Text(
              '${memInfo.usagePercentage.toStringAsFixed(0)}%',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Build comprehensive memory debug overlay (disabled for production)
  Widget _buildMemoryDebugOverlay() {
    // Memory debug overlay is disabled at this stage of development
    // To enable for debugging, change this condition to: kDebugMode && false
    if (true) return const SizedBox.shrink();
    
    // Debug overlay code preserved for future use
    if (_currentMemoryInfo == null || !kDebugMode) return const SizedBox.shrink();
    
    final memInfo = _currentMemoryInfo!;
    final trendAnalysis = ARMemoryManager.getMemoryTrendAnalysis();
    
    return Positioned(
      bottom: 120,
      left: 20,
      right: 20,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black.withAlpha((0.8 * 255).toInt()),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white30, width: 1),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '🧠 Memory Debug',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    if (kDebugMode) {
                      debugPrint('=== DETAILED MEMORY ANALYSIS ===');
                      debugPrint('Current Memory: ${memInfo.usedMemoryMB.toStringAsFixed(1)}MB / ${memInfo.totalMemoryMB.toStringAsFixed(1)}MB (${memInfo.usagePercentage.toStringAsFixed(1)}%)');
                      debugPrint('Status: ${memInfo.status}');
                      debugPrint('Message: ${memInfo.message}');
                      debugPrint(trendAnalysis);
                      debugPrint('===============================');
                    }
                  },
                  child: const Icon(
                    Icons.info_outline,
                    color: Colors.white70,
                    size: 16,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            
            // Memory status
            Row(
              children: [
                Icon(
                  _getStatusIcon(memInfo.status),
                  color: _getStatusColor(memInfo.status),
                  size: 16,
                ),
                const SizedBox(width: 6),
                Text(
                  '${memInfo.usedMemoryMB.toStringAsFixed(0)}MB / ${memInfo.totalMemoryMB.toStringAsFixed(0)}MB',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
                const Spacer(),
                Text(
                  '${memInfo.usagePercentage.toStringAsFixed(1)}%',
                  style: TextStyle(
                    color: _getStatusColor(memInfo.status),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            
            // Trend analysis (truncated for overlay)
            if (trendAnalysis != 'Baseline not set' && trendAnalysis != 'Insufficient data for trend analysis')
              Text(
                trendAnalysis.split('\n').take(3).join('\n'),
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 10,
                ),
              ),
            
            // Smart Memory Tracking Info
            if (_maxObjectsReachedBeforeMemoryLimit > 0)
              Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.blue.withAlpha((0.3 * 255).toInt()),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '🧩 Smart Memory Tracking',
                      style: TextStyle(
                        color: Colors.lightBlue,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      'Max reached: $_maxObjectsReachedBeforeMemoryLimit | Removed: $_objectsRemovedSinceMemoryLimit',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 9,
                      ),
                    ),
                    if (_objectsRemovedSinceMemoryLimit > 0)
                      Text(
                        'Can add ${_maxObjectsReachedBeforeMemoryLimit - nodes.length} more (OS reuse)',
                        style: const TextStyle(
                          color: Colors.lightGreen,
                          fontSize: 9,
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  IconData _getStatusIcon(MemoryStatus status) {
    switch (status) {
      case MemoryStatus.safe:
        return Icons.check_circle;
      case MemoryStatus.warning:
        return Icons.warning_amber;
      case MemoryStatus.critical:
        return Icons.warning;
      case MemoryStatus.danger:
        return Icons.error;
      case MemoryStatus.overLimit:
        return Icons.dangerous;
    }
  }

  Color _getStatusColor(MemoryStatus status) {
    switch (status) {
      case MemoryStatus.safe:
        return Colors.green;
      case MemoryStatus.warning:
        return Colors.orange;
      case MemoryStatus.critical:
        return Colors.deepOrange;
      case MemoryStatus.danger:
        return Colors.red[700]!;
      case MemoryStatus.overLimit:
        return Colors.red[900]!;
    }
  }

  /// Build delete button overlay
  Widget _buildDeleteButton() {
    if (selectedNode == null) {
      return const SizedBox.shrink();
    }
    
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
          onPressed: _removeSelectedModel,
          icon: const Icon(
            Icons.delete_outline,
            color: Color(0xFF22514C),
            size: 24,
          ),
          padding: EdgeInsets.zero,
        ),
      ),
    );
  }

  /// Build add/category button overlay
  Widget _buildAddButton() {
    // Smart memory-aware button visibility logic
    bool canShowButton = false;

    // Use smart memory tracking ONLY if we have actually hit memory limits before
    if (_maxObjectsReachedBeforeMemoryLimit > 0) {
      int currentObjects = nodes.length;
      int effectiveCapacity = _maxObjectsReachedBeforeMemoryLimit;
      int availableSlots = effectiveCapacity - currentObjects;
      
      if (availableSlots > 0) {
        canShowButton = true;
      } else {
        canShowButton = false;
      }
    } else {
      // No memory limit history yet - show button until we discover the actual limit
      canShowButton = true;
    }

    // If not safe to show button, hide it
    if (!canShowButton) {
      return const SizedBox.shrink();
    }

    return Positioned(
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
    );
  }

  /// Build camera button for taking AR screenshots
  Widget _buildCameraButton() {
    return Positioned(
      bottom: MediaQuery.of(context).padding.bottom + 16.0,
      left: MediaQuery.of(context).size.width / 2 - 32, // Center horizontally
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          color: const Color(0xFF22514C), // Green background as shown in the image
          borderRadius: BorderRadius.circular(32),
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
          onPressed: _takeARScreenshot,
          icon: const Icon(
            Icons.camera_alt,
            color: Colors.white,
            size: 28,
          ),
          padding: EdgeInsets.zero,
        ),
      ),
    );
  }

  /// Take screenshot of AR scene and save to gallery
  Future<void> _takeARScreenshot() async {
    if (_sessionController.sessionManager == null) {
      _showSnackBar('AR session not ready for screenshot');
      return;
    }

    try {
      debugPrint('AR Screen: Taking screenshot...');
      
      // Check permissions, but don't block if saver_gallery can handle it
      bool hasPermission = await _requestStoragePermission();
      debugPrint('AR Screen: Permission check result: $hasPermission');

      // Show loading indicator
      _showSnackBar('Capturing AR screenshot...');

      // Take screenshot using AR plugin
      ImageProvider imageProvider = await _sessionController.sessionManager!.snapshot();
      
      // Convert ImageProvider to bytes
      Uint8List? imageBytes;
      if (imageProvider is MemoryImage) {
        imageBytes = imageProvider.bytes;
      } else {
        _showSnackBar('Failed to capture AR screenshot');
        return;
      }

      // Try to save to gallery using saver_gallery package
      // Even if permission check failed, saver_gallery might still work
      try {
        final result = await SaverGallery.saveImage(
          imageBytes,
          quality: 100,
          fileName: "VirtualDom_AR_${DateTime.now().millisecondsSinceEpoch}",
          skipIfExists: false,
          androidRelativePath: "Pictures/VirtualDom",
        );

        if (result.isSuccess) {
          debugPrint('AR Screen: Screenshot saved to gallery');
          _showSnackBar('📸 AR screenshot saved to gallery!');
        } else {
          throw Exception('SaverGallery failed: ${result.errorMessage ?? "Unknown error"}');
        }
      } catch (saveError) {
        debugPrint('AR Screen: SaverGallery error: $saveError');
        
        // Provide specific error message
        if (saveError.toString().contains('permission')) {
          _showSnackBar('Permission needed: Please allow photo access in Settings to save screenshots.');
        } else {
          _showSnackBar('Failed to save screenshot. Please check your photo permissions.');
        }
      }
      
    } catch (e) {
      debugPrint('AR Screen: Error taking screenshot: $e');
      
      // Provide more specific error messages
      String errorMessage = 'Failed to save screenshot';
      if (e.toString().contains('permission')) {
        errorMessage = 'Permission denied. Please grant photo access in Settings.';
      } else if (e.toString().contains('storage')) {
        errorMessage = 'Not enough storage space available.';
      } else if (e.toString().contains('network')) {
        errorMessage = 'Network error. Please try again.';
      }
      
      _showSnackBar(errorMessage);
    }
  }

  /// Request storage permission for saving images - Minimal approach for saver_gallery
  Future<bool> _requestStoragePermission() async {
    try {
      // saver_gallery handles permissions internally, but we'll do a basic check
      if (Platform.isAndroid) {
        // Check if we have any storage-related permission
        final photosStatus = await Permission.photos.status;
        final storageStatus = await Permission.storage.status;
        
        // If we already have permission, return true
        if (photosStatus.isGranted || storageStatus.isGranted) {
          debugPrint('AR Screen: Android already has photo/storage permission');
          return true;
        }
        
        // Let saver_gallery handle the permission request internally
        debugPrint('AR Screen: Letting saver_gallery handle Android permissions');
        return true; // saver_gallery will handle permission requests
      } else if (Platform.isIOS) {
        // For iOS, check what we have and only request if absolutely necessary
        final addOnlyStatus = await Permission.photosAddOnly.status;
        final fullStatus = await Permission.photos.status;
        
        // If user already has any photo access, return true
        if (addOnlyStatus.isGranted || fullStatus.isGranted) {
          debugPrint('AR Screen: iOS already has photo permission');
          return true;
        }
        
        debugPrint('AR Screen: iOS requesting photosAddOnly permission');
        // Try to request add-only permission (minimal)
        final requestedStatus = await Permission.photosAddOnly.request();
        return requestedStatus.isGranted;
      }
      
      return true; // Default to allowing saver_gallery to handle it
    } catch (e) {
      debugPrint('AR Screen: Permission check error: $e, letting saver_gallery handle it');
      return true; // Let saver_gallery handle the permissions
    }
  }

  /// Build Android single-object mode indicator
  Widget _buildAndroidSingleObjectModeIndicator() {
    // Only show on Android when in single-object mode and there are multiple objects
    if (!Platform.isAndroid || !_isAndroidSingleObjectMode || _modelManager.getAllPersistentModels().length < 2) {
      return const SizedBox.shrink();
    }

    // Find which object number is currently active
    final allModels = _modelManager.getAllPersistentModels();
    int activeObjectIndex = -1;
    String activeObjectInfo = 'No selection';
    
    if (_activeTransformableNode != null) {
      // Find the index of the currently active object
      for (int i = 0; i < allModels.length; i++) {
        if (allModels[i].activeNodeId == _activeTransformableNode) {
          activeObjectIndex = i;
          activeObjectInfo = '${i + 1}/${allModels.length}';
          break;
        }
      }
    }

    return Positioned(
      top: MediaQuery.of(context).padding.top + 60.0,
      right: 16.0,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
        decoration: BoxDecoration(
          color: Colors.orange.withAlpha((0.9 * 255).toInt()),
          borderRadius: BorderRadius.circular(8.0),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha((0.2 * 255).toInt()),
              spreadRadius: 1,
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.touch_app,
                  size: 16,
                  color: Colors.white,
                ),
                SizedBox(width: 4),
                Text(
                  'Single Object Mode',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            if (_activeTransformableNode != null) ...[
              const SizedBox(height: 4),
              Text(
                'Selected object: $activeObjectInfo',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 2),
            const Text(
              'Tap another object to switch',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 9,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Show permission dialog to explain why permission is needed
  Future<bool> _showPermissionDialog(String title, String message, {bool showSettingsButton = false}) async {
    if (!mounted) return false;
    
    return await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(showSettingsButton ? 'Open Settings' : 'Grant Permission'),
            ),
          ],
        );
      },
    ) ?? false;
  }

  /// Show snackbar message to user
  void _showSnackBar(String message) {
    if (!mounted) return;
    
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
  }

  // =================================================================
  // AR View Callbacks and Event Handlers  
  // =================================================================

  /// Called when AR view is created and managers are available
  void _onARViewCreated(
    ARSessionManager sessionManager,
    ARObjectManager objectManager,
    ARAnchorManager anchorManager,
    ARLocationManager locationManager,
  ) async {
    debugPrint('AR Screen: === AR VIEW CREATED ===');
    
    try {
      // Guard against stale callbacks after disposal
      if (!_shouldRenderARView || !mounted) {
        debugPrint('AR Screen: Ignoring stale onARViewCreated callback');
        return;
      }
      
      // Test method channel communication before proceeding
      debugPrint('AR Screen: Testing method channel communication...');
      try {
        // Perform a simple test to ensure method channels are working
        await Future.delayed(const Duration(milliseconds: 10));
        // Test if we can access basic AR session properties
        debugPrint('AR Screen: ✅ Method channel test passed');
      } catch (channelError) {
        debugPrint('AR Screen: ❌ Method channel test failed: $channelError');
        debugPrint('AR Screen: This indicates a critical communication failure with native AR');
        return;
      }
      
      // Set up AR managers with error handling
      debugPrint('AR Screen: Setting AR managers...');
      try {
        _sessionController.setManagers(sessionManager, objectManager, anchorManager, locationManager);
        debugPrint('AR Screen: AR managers set successfully');
      } catch (managerError) {
        debugPrint('AR Screen: ❌ Failed to set AR managers: $managerError');
        return;
      }
      
      // Initialize AR session with robust error handling
      debugPrint('AR Screen: Initializing AR session...');
      bool success = false;
      try {
        success = await _sessionController.initializeSession(
          sessionManager,
          objectManager,
        );
        debugPrint('AR Screen: Session initialization result: $success');
      } catch (sessionError) {
        debugPrint('AR Screen: ❌ AR session initialization threw error: $sessionError');
        debugPrint('AR Screen: This likely indicates method channel communication failure');
        success = false;
      }
      
      if (success) {
        debugPrint('AR Screen: Setting up AR callbacks...');
        try {
          _setupARCallbacks();
          debugPrint('AR Screen: AR callbacks set up successfully');
        } catch (callbackError) {
          debugPrint('AR Screen: ❌ Failed to set up AR callbacks: $callbackError');
          // Continue anyway - callbacks are not critical for basic functionality
        }
        
        debugPrint('AR Screen: Calling onARSessionReady...');
        try {
          _onARSessionReady();
          debugPrint('AR Screen: onARSessionReady completed');
        } catch (readyError) {
          debugPrint('AR Screen: ❌ onARSessionReady failed: $readyError');
        }
      } else {
        debugPrint('AR Screen: ❌ AR session initialization failed');
        debugPrint('AR Screen: This usually indicates hardware or permission issues');
        // _showSnackBar('Failed to initialize AR session');
      }
      
    } catch (e, stackTrace) {
      debugPrint('AR Screen: ❌ Critical error in onARViewCreated: $e');
      debugPrint('AR Screen: Stack trace: $stackTrace');
      debugPrint('AR Screen: This is likely a method channel communication breakdown');
      //  _showSnackBar('AR initialization error: $e');
    }
  }

  /// Start model download process  
  Future<void> _startModelDownloadProcess() async {
    if (modelUri == null) return;
    
    debugPrint('AR Screen: Starting model download process');
    
    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            isDownloadingModel = true;
            isModelReadyForPlacement = false;
          });
        }
      });
    }
    
    try {
      String? downloadedPath;
      
      if (isModelCached && cachedModelPath != null) {
        debugPrint('AR Screen: Using cached model');
        downloadedPath = cachedModelPath;
      } else {
        debugPrint('AR Screen: Downloading model...');
        downloadedPath = await ARModelCache.downloadAndCacheModel(modelUri!);
        
        if (mounted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() {
                cachedModelPath = downloadedPath;
                isModelCached = true;
              });
            }
          });
        }
      }
      
      if (downloadedPath != null) {
        debugPrint('AR Screen: Model ready for placement');
        _onModelReadyForPlacement();
      } else {
        debugPrint('AR Screen: Model download failed');
        if (mounted) {
          // _showSnackBar('Failed to download model');
        }
      }
      
    } catch (e) {
      debugPrint('AR Screen: Error during model download: $e');
      if (mounted) {
        // _showSnackBar('Model download error: $e');
      }
    } finally {
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {
              isDownloadingModel = false;
            });
          }
        });
      }
    }
  }

  /// Setup AR callback handlers
  void _setupARCallbacks() {
    if (_sessionController.sessionManager != null) {
      _sessionController.sessionManager!.onPlaneOrPointTap = _onPlaneOrPointTapped;
      
      // Initialize onPlaneDetected to prevent LateInitializationError
      _sessionController.sessionManager!.onPlaneDetected = (dynamic plane) {
        // We handle plane detection through tap events instead
        // This callback is just to prevent initialization errors
      };
    }
    
    if (_sessionController.objectManager != null) {
      debugPrint('AR Screen: Setting up objectManager callbacks...');
      
      // Add test callback to verify method channel communication
      _sessionController.objectManager!.onNodeTap = (List<String> tappedNodes) {
        debugPrint('AR Screen: ✅ FLUTTER CALLBACK TRIGGERED!');
        debugPrint('AR Screen: Tapped nodes received: $tappedNodes');
        // Call our actual handler
        _onNodeTapped(tappedNodes);
      };
      
      debugPrint('AR Screen: ✅ onNodeTap callback set with debug wrapper');
      debugPrint('AR Screen: Testing callback communication with objectManager: ${_sessionController.objectManager}');
      
      // Verify callback registration
      if (_sessionController.objectManager!.onNodeTap != null) {
        debugPrint('AR Screen: ✅ Callback registration confirmed - onNodeTap is not null');
      } else {
        debugPrint('AR Screen: ❌ Callback registration failed - onNodeTap is null');
      }
      
      // Set up transform update callbacks to capture position/scale changes
      try {
        _sessionController.objectManager!.onPanStart = (String nodeId) {
          debugPrint('AR Screen: Pan started on node: $nodeId');
          // Add safety check to prevent rapid pan gesture issues
          if (nodeId.isNotEmpty && nodeCreationOrder.contains(nodeId)) {
            // Valid node ID, continue with pan handling
          } else {
            debugPrint('AR Screen: ⚠️ Invalid node ID in pan start: $nodeId');
          }
        };
        
        _sessionController.objectManager!.onPanChange = (String nodeId) {
          // Reduce logging frequency for pan changes to prevent spam and potential race conditions
          // debugPrint('AR Screen: Pan changed on node: $nodeId');
          
          // Add throttling to prevent overwhelming the system with pan events
          if (nodeId.isNotEmpty && nodeCreationOrder.contains(nodeId)) {
            // Valid node ID, pan change handled
          }
        };
        
        _sessionController.objectManager!.onPanEnd = (String nodeId, dynamic transform) {
          debugPrint('AR Screen: Pan ended on node: $nodeId, final transform captured');
          
          // Add safety checks before processing transform
          if (nodeId.isNotEmpty && nodeCreationOrder.contains(nodeId)) {
            try {
              _updateModelTransform(nodeId, transform);
            } catch (e) {
              debugPrint('AR Screen: ❌ Error in pan end transform update: $e');
            }
          } else {
            debugPrint('AR Screen: ⚠️ Invalid node ID in pan end: $nodeId');
          }
        };
        
        _sessionController.objectManager!.onRotationStart = (String nodeId) {
          debugPrint('AR Screen: Rotation started on node: $nodeId');
          // Add safety check for rotation gestures
          if (nodeId.isEmpty || !nodeCreationOrder.contains(nodeId)) {
            debugPrint('AR Screen: ⚠️ Invalid node ID in rotation start: $nodeId');
          }
        };
        
        _sessionController.objectManager!.onRotationChange = (String nodeId) {
          // Reduce logging frequency for rotation changes
          // debugPrint('AR Screen: Rotation changed on node: $nodeId');
          
          // Add safety check for rotation changes
          if (nodeId.isEmpty || !nodeCreationOrder.contains(nodeId)) {
            debugPrint('AR Screen: ⚠️ Invalid node ID in rotation change: $nodeId');
          }
        };
        
        _sessionController.objectManager!.onRotationEnd = (String nodeId, dynamic transform) {
          debugPrint('AR Screen: Rotation ended on node: $nodeId, final transform captured');
          
          // Add safety checks before processing transform
          if (nodeId.isNotEmpty && nodeCreationOrder.contains(nodeId)) {
            try {
              _updateModelTransform(nodeId, transform);
            } catch (e) {
              debugPrint('AR Screen: ❌ Error in rotation end transform update: $e');
            }
          } else {
            debugPrint('AR Screen: ⚠️ Invalid node ID in rotation end: $nodeId');
          }
        };
        
        debugPrint('AR Screen: ✅ Transform callbacks set up successfully');
      } catch (e) {
        debugPrint('AR Screen: ⚠️ Could not set up transform callbacks: $e');
        debugPrint('AR Screen: Continuing without transform tracking...');
      }
    }
  }

  /// Update model transform when user moves/rotates objects in AR
  void _updateModelTransform(String nodeId, dynamic transform) {
    try {
      // debugPrint('AR Screen: === UPDATING MODEL TRANSFORM ===');
      // debugPrint('AR Screen: Node ID: $nodeId');
      // debugPrint('AR Screen: Transform: $transform (${transform.runtimeType})');
      
      // Add safety checks to prevent race conditions
      if (nodeId.isEmpty) {
        // debugPrint('AR Screen: ⚠️ Empty node ID, skipping transform update');
        return;
      }
      
      if (!nodeCreationOrder.contains(nodeId)) {
        // debugPrint('AR Screen: ⚠️ Node ID not found in tracking list, may have been removed: $nodeId');
        return;
      }
      
      // Add throttling to prevent overwhelming the system with rapid updates
      DateTime now = DateTime.now();
      DateTime? lastUpdate = _lastTransformUpdate[nodeId];
      if (lastUpdate != null && now.difference(lastUpdate) < _transformUpdateThrottle) {
        debugPrint('AR Screen: 🔄 Throttling transform update for node: $nodeId');
        return;
      }
      _lastTransformUpdate[nodeId] = now;
      
      // Find the model by node ID with additional safety checks
      ARModelData? model;
      try {
        model = _modelManager.findModelByNodeId(nodeId);
      } catch (e) {
        debugPrint('AR Screen: ⚠️ Error finding model by node ID: $e');
        return;
      }
      
      if (model == null) {
        debugPrint('AR Screen: ⚠️ Could not find model with node ID: $nodeId');
        return;
      }
      
      // Safety check for transform object
      if (transform == null) {
        debugPrint('AR Screen: ⚠️ Transform is null, skipping update');
        return;
      }
      
      // Extract position from transform matrix if possible
      vm.Vector3? newPosition;
      vm.Vector3? newScale;
      
      if (transform is vm.Matrix4) {
        try {
          // Extract position from transformation matrix
          vm.Vector3 translation = transform.getTranslation();
          newPosition = vm.Vector3(
            translation.x.isFinite ? translation.x : model.position.x,
            translation.y.isFinite ? translation.y : model.position.y,
            translation.z.isFinite ? translation.z : model.position.z,
          );
          
          // FLOOR-LEVEL CORRECTION: Ensure objects stay on the detected floor
          // This prevents objects from floating or sinking when panned
          if (_planeManager.lowestPlaneY != null) {
            double originalY = newPosition.y;
            newPosition = vm.Vector3(
              newPosition.x, 
              _planeManager.lowestPlaneY!, // Force to floor level
              newPosition.z
            );
            
            if ((originalY - _planeManager.lowestPlaneY!).abs() > 0.1) {
              debugPrint('AR Screen: 🔧 Floor correction applied: Y ${originalY.toStringAsFixed(2)}m → ${_planeManager.lowestPlaneY!.toStringAsFixed(2)}m');
            }
          }
          
          // Apply distance constraints to prevent objects from being too close to camera
          // Ensure object is not placed closer than minimum distance (z is negative for objects in front)
          if (newPosition.z > ARConstants.minPlacementDistance) {
            debugPrint('AR Screen: ⚠️ Object too close to camera (z=${newPosition.z}), clamping to minimum distance');
            newPosition = vm.Vector3(newPosition.x, newPosition.y, ARConstants.minPlacementDistance);
          }
          // Ensure object is not placed too far (optional constraint)
          if (newPosition.z < ARConstants.maxPlacementDistance) {
            debugPrint('AR Screen: ⚠️ Object too far from camera (z=${newPosition.z}), clamping to maximum distance');
            newPosition = vm.Vector3(newPosition.x, newPosition.y, ARConstants.maxPlacementDistance);
          }
          
          // Extract scale from transformation matrix (approximate)
          double scaleX = transform.getColumn(0).length;
          double scaleY = transform.getColumn(1).length;
          double scaleZ = transform.getColumn(2).length;
          
          // Only update scale if it's not NaN and not zero
          if (scaleX.isFinite && scaleY.isFinite && scaleZ.isFinite &&
              scaleX > 0 && scaleY > 0 && scaleZ > 0) {
            newScale = vm.Vector3(scaleX, scaleY, scaleZ);
          }
          
          debugPrint('AR Screen: Extracted position: $newPosition');
          debugPrint('AR Screen: Extracted scale: $newScale');
          
        } catch (e) {
          debugPrint('AR Screen: ⚠️ Error extracting transform data: $e');
          return;
        }
      }
      
      // Update the model in persistent storage with additional safety checks
      if (newPosition != null || newScale != null) {
        try {
          _modelManager.updateModel(
            model.id,
            position: newPosition,
            scale: newScale,
          );
          
          debugPrint('AR Screen: ✅ Model ${model.productId} transform updated');
          debugPrint('AR Screen: - New position: ${newPosition ?? 'unchanged'}');
          debugPrint('AR Screen: - New scale: ${newScale ?? 'unchanged'}');
        } catch (e) {
          debugPrint('AR Screen: ❌ Error updating model in manager: $e');
        }
      }
      
    } catch (e) {
      debugPrint('AR Screen: ❌ Error updating model transform: $e');
      debugPrint('AR Screen: Node ID: $nodeId');
      debugPrint('AR Screen: Transform type: ${transform?.runtimeType}');
    }
  }

  /// Called when AR session is ready
  void _onARSessionReady() async {
    debugPrint('AR Screen: === AR SESSION READY ===');
    debugPrint('AR Screen: modelUri: $modelUri');
    debugPrint('AR Screen: currentUniqueProductId: $currentUniqueProductId');
    debugPrint('AR Screen: hasPlacedInitialModel: $hasPlacedInitialModel');
    
    // CRITICAL FIX: First, restore any previously placed models and WAIT for completion
    debugPrint('AR Screen: 🔧 Starting restoration process...');
    await _restorePreviouslyPlacedModels();
    debugPrint('AR Screen: 🔧 Restoration completed, nodes.length: ${nodes.length}');
    
    // Handle new product model if available - only AFTER restoration is complete
    if (modelUri != null && currentUniqueProductId != null) {
      debugPrint('AR Screen: New product available for placement');
      debugPrint('AR Screen: Starting model download process for: $currentUniqueProductId');
      _startModelDownloadProcess();
    } else {
      debugPrint('AR Screen: No new product to place');
      if (modelUri == null) {
        debugPrint('AR Screen: - modelUri is null');
      }
      if (currentUniqueProductId == null) {
        debugPrint('AR Screen: - currentUniqueProductId is null');
      }
      debugPrint('AR Screen: AR camera ready for manual product selection');
    }
  }

  /// Restore previously placed models from persistent storage
  Future<void> _restorePreviouslyPlacedModels() async {
    List<ARModelData> previousModels = _modelManager.getModelsForRestoration();
    
    if (previousModels.isEmpty) {
      debugPrint('AR Screen: No previously placed models to restore');
      return;
    }
    
    debugPrint('AR Screen: === RESTORING ${previousModels.length} PREVIOUSLY PLACED MODELS ===');
    
    // Set restoration flag to prevent concurrent auto-placement
    _isRestoringModels = true;
    
    for (int i = 0; i < previousModels.length; i++) {
      ARModelData modelData = previousModels[i];
      debugPrint('AR Screen: Restoring model ${i + 1}/${previousModels.length}: ${modelData.productId}');
      
      try {
        await _restoreModelToARScene(modelData);
        
        // Mark that we have placed initial models
        if (!hasPlacedInitialModel) {
          if (mounted) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                setState(() {
                  hasPlacedInitialModel = true;
                });
              }
            });
          }
        }
        
        // Small delay between model placements to avoid overwhelming the AR system
        if (i < previousModels.length - 1) {
          await Future.delayed(const Duration(milliseconds: 200));
        }
        
      } catch (e) {
        debugPrint('AR Screen: ❌ Failed to restore model ${modelData.productId}: $e');
        // Continue with next model even if one fails
      }
    }
    
    debugPrint('AR Screen: ✅ Model restoration completed');
    
    // Clear restoration flag - auto-placement can now proceed
    _isRestoringModels = false;
  }

  /// Restore a single model to the AR scene
  Future<void> _restoreModelToARScene(ARModelData modelData) async {
    debugPrint('AR Screen: === RESTORING MODEL TO AR SCENE ===');
    debugPrint('AR Screen: Product ID: ${modelData.productId}');
    debugPrint('AR Screen: Saved position: ${modelData.position}');
    debugPrint('AR Screen: Saved scale: ${modelData.scale}');
    debugPrint('AR Screen: Model URI: ${modelData.modelUri}');
    
    // CRITICAL FIX: Always use web URL for restoration to avoid corrupted cached models
    debugPrint('AR Screen: Using original web URL to avoid scale/position corruption');
    String webModelUri = modelData.modelUri; // Always use original web URL
    
    // Determine correct node type based on file extension
    NodeType nodeType = _getNodeTypeFromUri(webModelUri);
    debugPrint('AR Screen: Determined node type for restoration: $nodeType');
    
    // Get safe scale values (prevent NaN corruption)
    vm.Vector3 safeScale = _getSafeScaleForSaving(modelData.scale);
    debugPrint('AR Screen: Safe scale for restoration: $safeScale');
    
    // Create AR node with completely new Vector3 instances to prevent corruption
    ARNode node;
    try {
      // CRITICAL: Create completely new Vector3 instances to avoid NaN corruption
      vm.Vector3 cleanPosition = vm.Vector3(
        modelData.position.x.isFinite ? modelData.position.x : 0.0,
        modelData.position.y.isFinite ? modelData.position.y : -1.2,
        modelData.position.z.isFinite ? modelData.position.z : -0.8,
      );
      
      vm.Vector3 cleanScale = vm.Vector3(
        safeScale.x.isFinite ? safeScale.x : ARConstants.defaultScale,
        safeScale.y.isFinite ? safeScale.y : ARConstants.defaultScale,
        safeScale.z.isFinite ? safeScale.z : ARConstants.defaultScale,
      );
      
      vm.Vector4 cleanRotation = vm.Vector4(0.0, 0.0, 0.0, 1.0);
      
      node = ARNode(
        type: nodeType, // Use correct node type based on file extension
        uri: webModelUri, // Use web URL instead of cached file
        position: cleanPosition,
        scale: cleanScale,
        rotation: cleanRotation,
      );
      
      debugPrint('AR Screen: Restoration node created with clean vectors');
      debugPrint('AR Screen: - Final position: ${node.position}');
      debugPrint('AR Screen: - Final scale: ${node.scale}');
      
      // Verify the scale is still valid after creation
      if (node.scale.x.isNaN || node.scale.y.isNaN || node.scale.z.isNaN) {
        debugPrint('AR Screen: 🚨 Scale became NaN after ARNode creation! Using fallback approach');
        throw Exception('Scale corruption detected');
      }
      
    } catch (e) {
      debugPrint('AR Screen: ❌ Error creating restoration node: $e');
      // Create minimal node with only required properties
      node = ARNode(
        type: nodeType, // Use correct node type even in restoration fallback
        uri: webModelUri,
        position: vm.Vector3(
          modelData.position.x.isFinite ? modelData.position.x : 0.0,
          modelData.position.y.isFinite ? modelData.position.y : -1.2,
          modelData.position.z.isFinite ? modelData.position.z : -0.8,
        ),
        scale: vm.Vector3(ARConstants.defaultScale, ARConstants.defaultScale, ARConstants.defaultScale),
      );
      debugPrint('AR Screen: Created minimal restoration node');
      debugPrint('AR Screen: - Fallback scale: ${node.scale}');
    }
    
    // Add node to AR scene
    String? nodeId = await _addNodeToARScene(node);
    
    if (nodeId != null) {
      // Add to tracking lists
      nodes.add(node);
      nodeCreationOrder.add(nodeId);
      
      debugPrint('AR Screen: 🔍 RESTORATION DEBUG - After adding to tracking:');
      debugPrint('AR Screen: - nodes.length: ${nodes.length}');
      debugPrint('AR Screen: - nodeCreationOrder: $nodeCreationOrder');
      
      // Note: We don't update _maxObjectsReachedBeforeMemoryLimit during restoration
      // It should only be set when we actually hit memory limits during placement attempts
      
      // Update model manager with new node ID
      _modelManager.updateModel(
        modelData.id,
        activeNodeId: nodeId,
        isPlaced: true,
      );
      
      debugPrint('AR Screen: ✅ Model restored successfully with new node ID: $nodeId');
    } else {
      debugPrint('AR Screen: ❌ Failed to restore model to AR scene');
    }
  }

  /// Handle plane or point tap events
  void _onPlaneOrPointTapped(List<ARHitTestResult> hitTestResults) {
    debugPrint('AR Screen: === PLANE OR POINT TAPPED ===');
    
    if (hitTestResults.isEmpty || modelUri == null) {
      return;
    }
    
    var hitResult = hitTestResults.first;
    _planeManager.addDetectedPlane(hitResult);
    
    // If there's a selected node, deselect it instead of placing a new model
    if (selectedNode != null) {
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {
              selectedNode = null;
            });
          }
        });
      }
      return;
    }
    
    // Check if this is a floor plane for placement
    if (!_planeManager.isFloorPlane(hitResult)) {
      debugPrint('AR Screen: Plane not close to floor level, skipping placement');
      return;
    }
    
    // Place model at tapped location
    _placeModelAtHitResult(hitResult);
  }

  /// Handle node tap events
  Future<void> _onNodeTapped(List<String> tappedNodes) async {
    // ANDROID FIX: Ignore programmatic calls from our own enable/disable methods
    if (_isProcessingNodeSelection) {
      debugPrint('AR Screen: ⚠️ Ignoring programmatic tap event during node selection processing');
      return;
    }
    
    // Handle empty tap list (deselection) for Android single-object mode
    if (tappedNodes.isEmpty) {
      debugPrint('AR Screen: === EMPTY TAP (DESELECTION) ===');
      
      // Only process if this is a real user deselection, not programmatic
      if (_isAndroidSingleObjectMode && _activeTransformableNode != null) {
        debugPrint('AR Screen: 🔧 Processing user deselection in Android mode');
        
        if (mounted) {
          setState(() {
            selectedNode = null;
            _activeTransformableNode = null;
          });
        }
        
        debugPrint('AR Screen: ✅ User deselection completed');
      }
      return;
    }
    
    String? tappedNodeId = tappedNodes.firstOrNull;
    if (tappedNodeId == null) return;
    
    debugPrint('AR Screen: === NODE TAPPED ===');
    debugPrint('AR Screen: Tapped node ID: $tappedNodeId');
    debugPrint('AR Screen: Current selected node: $selectedNode');
    debugPrint('AR Screen: Available nodes: $nodeCreationOrder');
    
    // Prevent multiple simultaneous selections
    if (_isProcessingNodeSelection) {
      debugPrint('AR Screen: ⚠️ Already processing node selection, ignoring duplicate tap');
      return;
    }
    
    // Add safety check for AR session state
    if (_sessionController.objectManager == null) {
      debugPrint('AR Screen: ⚠️ Object manager unavailable during node selection');
      return;
    }
    
    // Check if tapped node exists in our tracking system
    if (!nodeCreationOrder.contains(tappedNodeId)) {
      debugPrint('AR Screen: ❌ Tapped node not found in nodeCreationOrder');
      debugPrint('AR Screen: This could be a stale node or tracking issue');
      debugPrint('AR Screen: Attempting automatic synchronization...');
      
      // Try to recover by synchronizing node tracking
      try {
        await _synchronizeNodeTracking();
        
        // Check again after synchronization
        if (nodeCreationOrder.contains(tappedNodeId)) {
          debugPrint('AR Screen: ✅ Node found after synchronization, proceeding with selection');
        } else {
          debugPrint('AR Screen: ❌ Node still not found after synchronization');
          
          // Check if this node belongs to a persistent model we should know about
          ARModelData? model = _modelManager.findModelByNodeId(tappedNodeId);
          if (model != null) {
            debugPrint('AR Screen: 🔄 Found model for tapped node, force-adding to tracking');
            nodeCreationOrder.add(tappedNodeId);
            debugPrint('AR Screen: ✅ Node force-added to tracking: $nodeCreationOrder');
          } else {
            debugPrint('AR Screen: ❌ Unknown node - clearing any stale selection');
            // Clear any stale selection
            if (selectedNode != null && mounted) {
              try {
                setState(() {
                  selectedNode = null;
                });
                debugPrint('AR Screen: ✅ Cleared stale selection');
              } catch (e) {
                debugPrint('AR Screen: ❌ Error clearing stale selection: $e');
              }
            }
            return;
          }
        }
      } catch (e) {
        debugPrint('AR Screen: ❌ Error during synchronization recovery: $e');
        return;
      }
    }
    
    debugPrint('AR Screen: ✅ Node found in tracking system, updating selection');
    
    // ANDROID SINGLE-OBJECT MODE: Handle special selection logic
    if (_isAndroidSingleObjectMode && nodeCreationOrder.length > 1) {
      debugPrint('AR Screen: 🤖 Android single-object mode activated');
      await _handleAndroidSingleObjectSelection(tappedNodeId);
      return;
    }
    
    // CRITICAL: For multiple objects, we need to handle selection more carefully
    if (nodeCreationOrder.length > 1) {
      debugPrint('AR Screen: 🔧 Multi-object environment detected, using enhanced selection logic');
      
      // Clear any existing selection first to prevent gesture conflicts
      if (selectedNode != null && selectedNode != tappedNodeId) {
        debugPrint('AR Screen: Clearing previous selection to prevent gesture interference');
        if (mounted) {
          setState(() {
            selectedNode = null;
          });
        }
        // Brief delay to let gesture system reset
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
    
    if (mounted) {
      _isProcessingNodeSelection = true;
      
      try {
        setState(() {
          String? previousSelection = selectedNode;
          
          // Enhanced toggle selection logic for multi-object support
          if (selectedNode == tappedNodeId) {
            selectedNode = null;
            debugPrint('AR Screen: Deselected node: $tappedNodeId');
          } else {
            selectedNode = tappedNodeId;
            debugPrint('AR Screen: Selected node: $tappedNodeId (was: $previousSelection)');
          }
          
          // Find model index for user feedback
          int nodeIndex = nodeCreationOrder.indexOf(tappedNodeId) + 1;
          debugPrint('AR Screen: Model ${selectedNode != null ? 'selected' : 'deselected'}: $nodeIndex/${nodeCreationOrder.length}');
        });
        
        debugPrint('AR Screen: ✅ Selection state updated successfully');
        
      } catch (e) {
        debugPrint('AR Screen: ❌ Error updating selection state: $e');
        // Clear selection state on error to prevent UI inconsistencies
        try {
          if (mounted) {
            setState(() {
              selectedNode = null;
            });
          }
        } catch (setStateError) {
          debugPrint('AR Screen: ❌ Error clearing selection after error: $setStateError');
        }
      } finally {
        // Reset processing flag after a short delay with better error handling
        try {
          Future.delayed(const Duration(milliseconds: 100), () {
            _isProcessingNodeSelection = false;
          });
        } catch (e) {
          debugPrint('AR Screen: ❌ Error in delayed processing reset: $e');
          _isProcessingNodeSelection = false;
        }
      }
    } else {
      debugPrint('AR Screen: ❌ Widget not mounted, skipping selection update');
    }
  }

  /// Handle single-object selection mode for Android to prevent anchor hierarchy corruption
  Future<void> _handleAndroidSingleObjectSelection(String tappedNodeId) async {
    debugPrint('AR Screen: === ANDROID SINGLE-OBJECT SELECTION ===');
    debugPrint('AR Screen: Tapped node: $tappedNodeId');
    debugPrint('AR Screen: Current active transformable: $_activeTransformableNode');
    debugPrint('AR Screen: All available nodes: $nodeCreationOrder');
    
    try {
      if (_activeTransformableNode == tappedNodeId) {
        // User tapped the same object - offer to switch to a different one
        if (nodeCreationOrder.length > 1) {
          debugPrint('AR Screen: 🔄 Same object tapped - switching to next available object');
          
          // Find the next object in the list
          String? nextNodeId = _getNextAvailableNode(tappedNodeId);
          
          if (nextNodeId != null) {
            debugPrint('AR Screen: Found next available node: $nextNodeId');
            
            // Disable current object
            await _disableTransformForNode(_activeTransformableNode!);
            
            // Enable next object
            await _enableTransformForNode(nextNodeId);
            
            // Update state
            if (mounted) {
              setState(() {
                selectedNode = nextNodeId;
                _activeTransformableNode = nextNodeId;
              });
            }
            
            int nodeIndex = nodeCreationOrder.indexOf(nextNodeId) + 1;
            debugPrint('AR Screen: ✅ Switched to object $nodeIndex/${nodeCreationOrder.length}');
            _showAndroidSingleObjectFeedback(nodeIndex, nodeCreationOrder.length);
            
          } else {
            // Only one object, deselect current
            debugPrint('AR Screen: 🔄 Only one object available - deselecting current');
            await _disableTransformForNode(_activeTransformableNode!);
            
            if (mounted) {
              setState(() {
                selectedNode = null;
                _activeTransformableNode = null;
              });
            }
            
            debugPrint('AR Screen: ✅ Object deselected - no active transformable nodes');
          }
        } else {
          // Only one object, deselect current
          debugPrint('AR Screen: 🔄 Deselecting current transformable object');
          await _disableTransformForNode(_activeTransformableNode!);
          
          if (mounted) {
            setState(() {
              selectedNode = null;
              _activeTransformableNode = null;
            });
          }
          
          debugPrint('AR Screen: ✅ Object deselected - no active transformable nodes');
        }
        
      } else {
        // Select new object (and disable previous if any)
        debugPrint('AR Screen: 🔄 Switching transformable object');
        
        // First disable current transformable node if any
        if (_activeTransformableNode != null) {
          debugPrint('AR Screen: Disabling gestures for previous node: $_activeTransformableNode');
          await _disableTransformForNode(_activeTransformableNode!);
        }
        
        // Enable gestures for new node
        debugPrint('AR Screen: Enabling gestures for new node: $tappedNodeId');
        await _enableTransformForNode(tappedNodeId);
        
        // Update state
        if (mounted) {
          setState(() {
            selectedNode = tappedNodeId;
            _activeTransformableNode = tappedNodeId;
          });
        }
        
        int nodeIndex = nodeCreationOrder.indexOf(tappedNodeId) + 1;
        debugPrint('AR Screen: ✅ Single-object mode: Selected object $nodeIndex/${nodeCreationOrder.length}');
        
        // Show user feedback
        _showAndroidSingleObjectFeedback(nodeIndex, nodeCreationOrder.length);
      }
      
    } catch (e) {
      debugPrint('AR Screen: ❌ Error in Android single-object selection: $e');
      
      // Reset state on error
      if (mounted) {
        setState(() {
          selectedNode = null;
          _activeTransformableNode = null;
        });
      }
    }
  }

  /// Get the next available node for cycling through objects
  String? _getNextAvailableNode(String currentNodeId) {
    if (nodeCreationOrder.isEmpty) return null;
    if (nodeCreationOrder.length == 1) return null;
    
    int currentIndex = nodeCreationOrder.indexOf(currentNodeId);
    if (currentIndex == -1) return nodeCreationOrder.first;
    
    // Get next node in circular fashion
    int nextIndex = (currentIndex + 1) % nodeCreationOrder.length;
    return nodeCreationOrder[nextIndex];
  }

  /// Enable transform gestures for a specific node (Android single-object mode)
  Future<void> _enableTransformForNode(String nodeId) async {
    try {
      debugPrint('AR Screen: 🔵 ENABLE TRANSFORM: Starting for node: $nodeId');
      debugPrint('AR Screen: 🔵 ENABLE TRANSFORM: Current nodeCreationOrder: $nodeCreationOrder');
      debugPrint('AR Screen: 🔵 ENABLE TRANSFORM: Current selectedNode: $selectedNode');
      
      if (_sessionController.objectManager == null) {
        debugPrint('AR Screen: ❌ ENABLE TRANSFORM: ObjectManager is null, cannot enable transforms');
        return;
      }
      
      // INSTANT FEEDBACK: Update UI state immediately for zero-delay user experience
      if (mounted) {
        setState(() {
          selectedNode = nodeId;
          _activeTransformableNode = nodeId;
        });
      }
      debugPrint('AR Screen: ⚡ INSTANT UPDATE: UI state updated immediately for zero-delay UX');
      
      // Verify that the nodeId exists in our tracking
      if (!nodeCreationOrder.contains(nodeId)) {
        debugPrint('AR Screen: ⚠️ ENABLE TRANSFORM: Node $nodeId not found in nodeCreationOrder');
        debugPrint('AR Screen: ⚠️ ENABLE TRANSFORM: Available nodes: $nodeCreationOrder');
        // Try to recover by checking if it's a known model node
        bool foundInModels = false;
        try {
          // Check if this node belongs to a persistent model
          for (var model in _modelManager.getAllPersistentModels()) {
            if (model.activeNodeId == nodeId) {
              debugPrint('AR Screen: 🔄 ENABLE TRANSFORM: Found node in persistent models, adding to tracking');
              nodeCreationOrder.add(nodeId);
              foundInModels = true;
              break;
            }
          }
        } catch (e) {
          debugPrint('AR Screen: ❌ ENABLE TRANSFORM: Error checking persistent models: $e');
        }
        
        if (!foundInModels) {
          debugPrint('AR Screen: ❌ ENABLE TRANSFORM: Node $nodeId not found anywhere, aborting');
          return;
        }
      }
      
      // Set processing flag to prevent callback interference
      _isProcessingNodeSelection = true;
      
      try {
        // OPTIMIZED APPROACH: Parallel operations for faster switching
        debugPrint('AR Screen: � ENABLE TRANSFORM: Using parallel operations for instant switching');
        
        // Parallel operations for faster response
        List<Future<void>> parallelOperations = [
          // Operation 1: Disable all other nodes
          _sessionController.objectManager!.deselectAllNodes().catchError((e) {
            debugPrint('AR Screen: ⚠️ Deselect all failed: $e');
          }),
          
          // Operation 2: Enable gestures for the specific node (can happen in parallel)
          _sessionController.objectManager!.enableTransformGestures(nodeId).then((success) {
            if (success) {
              debugPrint('AR Screen: ✅ ENABLE TRANSFORM: Native gesture enable successful for node: $nodeId');
            } else {
              debugPrint('AR Screen: ⚠️ ENABLE TRANSFORM: Native gesture enable failed for node: $nodeId');
            }
            return success;
          }).catchError((e) {
            debugPrint('AR Screen: ❌ ENABLE TRANSFORM: Error in parallel enable: $e');
          }),
        ];
        
        // Execute parallel operations with minimal delay
        await Future.wait(parallelOperations, eagerError: false);
        
        debugPrint('AR Screen: ✅ ENABLE TRANSFORM: Parallel operations completed for node: $nodeId');
        debugPrint('AR Screen: ✅ ENABLE TRANSFORM: Flutter state - selectedNode: $selectedNode, _activeTransformableNode: $_activeTransformableNode');
        
      } finally {
        // Clear processing flag with minimal delay
        _isProcessingNodeSelection = false;
      }
      
    } catch (e) {
      debugPrint('AR Screen: ❌ ENABLE TRANSFORM: Error enabling transforms for $nodeId: $e');
      _isProcessingNodeSelection = false;
    }
  }

  /// Disable transform gestures for a specific node (Android single-object mode)
  Future<void> _disableTransformForNode(String nodeId) async {
    try {
      debugPrint('AR Screen: � DISABLE TRANSFORM: Starting for node: $nodeId');
      debugPrint('AR Screen: 🔴 DISABLE TRANSFORM: Current nodeCreationOrder: $nodeCreationOrder');
      debugPrint('AR Screen: 🔴 DISABLE TRANSFORM: Current selectedNode: $selectedNode');
      
      if (_sessionController.objectManager == null) {
        debugPrint('AR Screen: ❌ DISABLE TRANSFORM: ObjectManager is null, cannot disable transforms');
        return;
      }
      
      // Verify that the nodeId exists in our tracking
      if (!nodeCreationOrder.contains(nodeId)) {
        debugPrint('AR Screen: ⚠️ DISABLE TRANSFORM: Node $nodeId not found in nodeCreationOrder');
        debugPrint('AR Screen: ⚠️ DISABLE TRANSFORM: Available nodes: $nodeCreationOrder');
        // Still proceed with disable attempt in case it exists in Android
      }
      
      // Set processing flag to prevent callback interference
      _isProcessingNodeSelection = true;
      
      try {
        // NEW APPROACH: Use native gesture control method for proper deselection
        debugPrint('AR Screen: 🔧 DISABLE TRANSFORM: Using native gesture control for Android single-object mode');
        
        // Step 1: Disable gestures for the specific node using native method
        debugPrint('AR Screen: 🔧 DISABLE TRANSFORM: Step 1: Disabling gestures for node: $nodeId');
        bool success = await _sessionController.objectManager!.disableTransformGestures(nodeId);
        
        // Step 2: Clear Flutter state
        if (mounted) {
          setState(() {
            selectedNode = null;
            _activeTransformableNode = null;
          });
        }
        
        if (success) {
          debugPrint('AR Screen: ✅ DISABLE TRANSFORM: Native transform disable successful for node: $nodeId');
          debugPrint('AR Screen: ✅ DISABLE TRANSFORM: Flutter state updated - selectedNode: $selectedNode, _activeTransformableNode: $_activeTransformableNode');
        } else {
          debugPrint('AR Screen: ⚠️ DISABLE TRANSFORM: Native transform disable failed for node: $nodeId');
          debugPrint('AR Screen: ⚠️ DISABLE TRANSFORM: This could indicate nodeId mismatch between Flutter and Android');
        }
        
        debugPrint('AR Screen: ✅ DISABLE TRANSFORM: Transform disable completed for node: $nodeId');
        
      } finally {
        // Clear processing flag
        await Future.delayed(const Duration(milliseconds: 50));
        _isProcessingNodeSelection = false;
      }
      
    } catch (e) {
      debugPrint('AR Screen: ❌ DISABLE TRANSFORM: Error disabling transforms for $nodeId: $e');
      _isProcessingNodeSelection = false;
    }
  }

  /// Show user feedback for Android single-object mode
  void _showAndroidSingleObjectFeedback(int selectedIndex, int totalObjects) {
    if (!mounted) return;
    
    String message = 'Android Mode: Object $selectedIndex/$totalObjects selected. Only one object can be moved at a time.';
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.blue[700],
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.only(bottom: 100, left: 16, right: 16),
      ),
    );
  }

  /// Remove the currently selected model from the AR scene
  void _removeSelectedModel() {
    debugPrint('AR Screen: === REMOVE SELECTED MODEL ===');
    debugPrint('AR Screen: 🗑️ REMOVE: selectedNode: $selectedNode');
    debugPrint('AR Screen: 🗑️ REMOVE: Current nodeCreationOrder: $nodeCreationOrder');
    debugPrint('AR Screen: 🗑️ REMOVE: Current nodes count: ${nodes.length}');
    debugPrint('AR Screen: 🗑️ REMOVE: _activeTransformableNode: $_activeTransformableNode');
    
    if (selectedNode == null) {
      debugPrint('AR Screen: ❌ REMOVE: No selected node to remove');
      return;
    }

    if (_sessionController.objectManager == null) {
      debugPrint('AR Screen: ❌ REMOVE: Object Manager not available, clearing local state only');
      _clearLocalModelState();
      return;
    }

    String nodeIdToRemove = selectedNode!;
    debugPrint('AR Screen: 🗑️ REMOVE: Attempting to remove SPECIFIC node: $nodeIdToRemove');
    debugPrint('AR Screen: 🔍 REMOVE SAFETY: Only this exact node should be removed, not all nodes!');

    // CRITICAL SAFETY CHECK: Verify the node exists before removal
    int selectedIndex = nodeCreationOrder.indexOf(nodeIdToRemove);
    debugPrint('AR Screen: 🗑️ REMOVE: Selected index in nodeCreationOrder: $selectedIndex');
    
    if (selectedIndex < 0 || selectedIndex >= nodes.length) {
      debugPrint('AR Screen: ❌ REMOVE SAFETY: Invalid index $selectedIndex for nodes.length ${nodes.length}');
      debugPrint('AR Screen: ❌ REMOVE SAFETY: Node $nodeIdToRemove not found in tracking, aborting removal');
      // Clear selection but don't remove anything
      if (mounted) {
        setState(() {
          selectedNode = null;
          _activeTransformableNode = null;
        });
      }
      return;
    }

    ARNode nodeToRemove = nodes[selectedIndex];
    debugPrint('AR Screen: ✅ REMOVE SAFETY: Found specific node to remove at index $selectedIndex');
    debugPrint('AR Screen: 🗑️ REMOVE: Specific node details - Name: ${nodeToRemove.name}, ID: $nodeIdToRemove');
    
    // CRITICAL: Clear selection FIRST to prevent UI issues
    String nodeIdBeingRemoved = nodeIdToRemove; // Store for async operations
    
    // Android single-object mode cleanup
    if (_isAndroidSingleObjectMode && _activeTransformableNode == nodeIdToRemove) {
      debugPrint('AR Screen: 🤖 REMOVE: Clearing Android single-object mode state');
      _activeTransformableNode = null;
    }
    
    if (mounted) {
      setState(() {
        selectedNode = null; // Clear selection immediately
        
        // Track object removal for smart memory management within setState
        debugPrint('AR Screen: 🔍 REMOVAL TRACKING - Before removal:');
        debugPrint('AR Screen: - _maxObjectsReachedBeforeMemoryLimit: $_maxObjectsReachedBeforeMemoryLimit');
        debugPrint('AR Screen: - _objectsRemovedSinceMemoryLimit: $_objectsRemovedSinceMemoryLimit');
        debugPrint('AR Screen: - Current nodes.length: ${nodes.length} (will be ${nodes.length - 1} after removal)');
        
        if (_maxObjectsReachedBeforeMemoryLimit > 0) {
          _objectsRemovedSinceMemoryLimit++;
          debugPrint('AR Screen: ✅ Updated removal tracking in setState - objects removed since limit: $_objectsRemovedSinceMemoryLimit');
          debugPrint('AR Screen: This allows placing $_objectsRemovedSinceMemoryLimit more objects before hitting memory limit again');
          debugPrint('AR Screen: Max reached : $_maxObjectsReachedBeforeMemoryLimit | removed: $_objectsRemovedSinceMemoryLimit Can add ${_maxObjectsReachedBeforeMemoryLimit - (nodes.length - 1)} more');
        } else {
          debugPrint('AR Screen: ⚠️ No memory limit history, not tracking removal');
        }
      });
      debugPrint('AR Screen: ✅ Selection cleared and tracking updated in UI');
    }
    
    // CRITICAL: Remove ONLY the specific node from tracking lists
    // Store the original state for comparison
    List<String> originalNodeOrder = List.from(nodeCreationOrder);
    List<ARNode> originalNodes = List.from(nodes);
    
    // SAFETY: Verify index is still valid before removal
    if (selectedIndex >= 0 && selectedIndex < nodes.length && selectedIndex < nodeCreationOrder.length) {
      // Remove ONLY the specific node at the correct index
      ARNode removedNode = nodes.removeAt(selectedIndex);
      String removedNodeId = nodeCreationOrder.removeAt(selectedIndex);
      
      debugPrint('AR Screen: ✅ REMOVE SPECIFIC: Removed specific node from local tracking lists');
      debugPrint('AR Screen: 🗑️ REMOVE SPECIFIC: Removed node: ${removedNode.name} with ID: $removedNodeId');
      debugPrint('AR Screen: 🗑️ REMOVE SPECIFIC: Before removal - nodes: ${originalNodes.length}, order: ${originalNodeOrder.length}');
      debugPrint('AR Screen: 🗑️ REMOVE SPECIFIC: After removal - nodes: ${nodes.length}, order: ${nodeCreationOrder.length}');
      debugPrint('AR Screen: 🗑️ REMOVE SPECIFIC: Remaining nodeCreationOrder: $nodeCreationOrder');
      
      // Verify we removed the correct node
      if (removedNodeId != nodeIdBeingRemoved) {
        debugPrint('AR Screen: 🚨 REMOVE ERROR: Removed wrong node! Expected: $nodeIdBeingRemoved, Got: $removedNodeId');
      } else {
        debugPrint('AR Screen: ✅ REMOVE VERIFICATION: Successfully removed correct node: $nodeIdBeingRemoved');
      }
      
    } else {
      debugPrint('AR Screen: ❌ REMOVE ERROR: Index validation failed during removal');
      debugPrint('AR Screen: - selectedIndex: $selectedIndex');
      debugPrint('AR Screen: - nodes.length: ${nodes.length}');
      debugPrint('AR Screen: - nodeCreationOrder.length: ${nodeCreationOrder.length}');
      return;
    }
    
    // Remove from model manager persistent storage
    debugPrint('AR Screen: 🗑️ REMOVE: Removing SPECIFIC node from model manager persistent storage: $nodeIdBeingRemoved');
    _modelManager.removeModelByNodeId(nodeIdBeingRemoved);
    debugPrint('AR Screen: ✅ REMOVE: Removed specific node from model manager');
    
    // Remove ONLY the specific node from AR scene (async operation)
    debugPrint('AR Screen: 🗑️ REMOVE: Starting async removal of SPECIFIC node from AR scene: $nodeIdBeingRemoved');
    _removeNodeFromARScene(nodeToRemove, nodeIdBeingRemoved);
    
    int remainingModels = nodes.length;
    debugPrint('AR Screen: ✅ REMOVE COMPLETE: Specific model removal completed. Remaining models: $remainingModels');
    debugPrint('AR Screen: 🗑️ REMOVE COMPLETE: Final nodeCreationOrder: $nodeCreationOrder');
    
    // Update memory information after model removal
    _updateMemoryInfo();
    // _showSnackBar('Model deleted. Remaining models: $remainingModels');
  }

  /// Remove node from AR scene (async operation)
  Future<void> _removeNodeFromARScene(ARNode nodeToRemove, String nodeId) async {
    try {
      debugPrint('AR Screen: === REMOVING NODE FROM AR SCENE ===');
      debugPrint('AR Screen: Node ID: $nodeId');
      debugPrint('AR Screen: Node URI: ${nodeToRemove.uri}');
      debugPrint('AR Screen: Node position: ${nodeToRemove.position}');
      
      // Add safety checks before method channel calls
      if (_sessionController.objectManager == null) {
        debugPrint('AR Screen: ❌ Object manager not available for node removal');
        return;
      }
      
      // Check if we have proper access to AR session
      try {
        // Test method channel availability before making critical calls
        if (_sessionController.sessionManager != null) {
          // This is a safe test to ensure method channels are responsive
          await Future.delayed(const Duration(milliseconds: 10));
        }
      } catch (e) {
        debugPrint('AR Screen: ❌ Method channel test failed, skipping native removal: $e');
        return;
      }
      
      debugPrint('AR Screen: Calling objectManager.removeNode()...');
      
      // CRITICAL: Pre-removal preparation for native resource cleanup
      debugPrint('AR Screen: 🧹 Preparing for clean native resource removal...');
      try {
        // Step 1: Give the native AR engine a moment to finish any ongoing operations
        await Future.delayed(const Duration(milliseconds: 50));
        
        // Step 2: Ensure the node is in a clean state before removal
        if (_sessionController.sessionManager != null) {
          // Allow any pending transformations or animations to complete
          await Future.delayed(const Duration(milliseconds: 30));
        }
        
        debugPrint('AR Screen: ✅ Pre-removal preparation completed');
      } catch (e) {
        debugPrint('AR Screen: ⚠️ Pre-removal preparation failed (proceeding anyway): $e');
      }
      
      // Now perform the actual removal with clean state
      debugPrint('AR Screen: 🗑️ Removing node with clean pre-state...');
      
      // Wrap method channel call in try-catch to prevent crashes
      try {
        await _sessionController.objectManager!.removeNodeDeep(nodeToRemove.name);
        debugPrint('AR Screen: ✅ removeNodeDeep() call completed successfully');
      } catch (methodChannelError) {
        debugPrint('AR Screen: ❌ Method channel error during removal: $methodChannelError');
        // Continue with cleanup even if native removal fails
        debugPrint('AR Screen: Continuing with local cleanup despite method channel failure');
      }
      
      // Track model removal in memory manager
      try {
        ARMemoryManager.onModelRemoved();
      } catch (e) {
        debugPrint('AR Screen: ⚠️ Memory manager tracking failed: $e');
      }
      
      // Add a small delay to ensure the removal is processed by the AR engine
      await Future.delayed(const Duration(milliseconds: 100));
      debugPrint('AR Screen: ✅ Node removal processing delay completed');
      
      // STEP 1: Explicit cache clearing before gentle cleanup
      debugPrint('AR Screen: 🧹 Clearing cached model data...');
      try {
        // Clear any cached textures or model data that might be lingering
        if (_sessionController.objectManager != null) {
          // Force internal cleanup - this varies by AR plugin but generally helps
          await Future.delayed(const Duration(milliseconds: 50));

          await _sessionController.objectManager!.purgeCaches();
          // Soft reset the session to clear any cached state
          await _sessionController.sessionManager!.softResetSession();
        }
        debugPrint('AR Screen: ✅ Cache clearing completed');
      } catch (e) {
        debugPrint('AR Screen: ⚠️ Cache clearing failed (non-critical): $e');
      }
      
      // CRITICAL: Safe memory cleanup approach - no memory pressure
      debugPrint('AR Screen: 🗑️ Starting safe native AR resource cleanup...');
      
      try {
        // STEP 1: Request memory cleanup suggestions from ARMemoryManager
        final currentMem = await ARMemoryManager.getCurrentMemoryInfo();
        final suggestions = ARMemoryManager.getMemoryCleanupSuggestions(currentMem);
        debugPrint('AR Screen: Memory cleanup suggestions: $suggestions');
        
        // STEP 2: Give iOS ARKit time to process native resource cleanup
        // This is the safest approach - no memory pressure, just waiting
        debugPrint('AR Screen: 🗑️ Allowing iOS ARKit to process native cleanup...');
        await Future.delayed(const Duration(milliseconds: 500));
        
        debugPrint('AR Screen: ✅ Safe native cleanup completed');
      } catch (e) {
        debugPrint('AR Screen: ⚠️ Safe cleanup failed (non-critical): $e');
      }
      
      // Additional cleanup: ensure no lingering references to the removed node
      // Clear any possible cached references in the AR plugin
      if (_sessionController.objectManager != null) {
        try {
          // Force a refresh of the AR session state
          await Future.delayed(const Duration(milliseconds: 50));
        } catch (e) {
          debugPrint('AR Screen: ⚠️ Minor cleanup operation failed: $e');
        }
      }
      
      // Update memory info after GC to see the effect
      try {
        final memoryInfo = await ARMemoryManager.getCurrentMemoryInfo();
        debugPrint('AR Screen: 📊 Memory after node removal and GC: ${memoryInfo.usagePercentage.toStringAsFixed(1)}% (${memoryInfo.usedMemoryMB.toStringAsFixed(1)}MB)');
        
        // Update the current memory info for UI
        if (mounted) {
          setState(() {
            _currentMemoryInfo = memoryInfo;
          });
        }
      } catch (e) {
        debugPrint('AR Screen: Warning: Could not update memory info after removal: $e');
      }
      
    } catch (e) {
      debugPrint('AR Screen: ❌ Error removing node from AR scene: $e');
      debugPrint('AR Screen: This is likely a method channel communication failure');
      debugPrint('AR Screen: Continuing with local cleanup to maintain UI consistency');
      // Even if removal fails, the node has been removed from our tracking
      // This ensures the UI and data consistency
    }
  }

  /// Clear local model state
  void _clearLocalModelState() {
    debugPrint('AR Screen: Clearing local model state (preserving persistent data)');
    _clearARSceneState(); // Use the same method to preserve consistency
  }

  /// Get safe scale values for saving (prevent NaN corruption)
  vm.Vector3 _getSafeScaleForSaving(vm.Vector3 scale) {
    // Check for NaN or invalid values
    if (scale.x.isNaN || scale.y.isNaN || scale.z.isNaN ||
        scale.x <= 0 || scale.y <= 0 || scale.z <= 0) {
      debugPrint('AR Screen: ⚠️ Scale contains invalid values: $scale, using safe default');
      return vm.Vector3(ARConstants.defaultScale, ARConstants.defaultScale, ARConstants.defaultScale);
    }
    
    // Return a clean copy to prevent reference issues
    return vm.Vector3(scale.x, scale.y, scale.z);
  }

  /// Determine the correct NodeType based on file extension
  NodeType _getNodeTypeFromUri(String uri) {
    String lowerUri = uri.toLowerCase();
    
    if (lowerUri.endsWith('.glb')) {
      debugPrint('AR Screen: Detected GLB file, using NodeType.webGLB');
      return NodeType.webGLB;
    } else if (lowerUri.endsWith('.gltf')) {
      debugPrint('AR Screen: Detected GLTF file, using NodeType.webGLB (GLTF support)');
      return NodeType.webGLB; // Use webGLB for GLTF files too
    } else if (lowerUri.endsWith('.obj')) {
      debugPrint('AR Screen: ⚠️ Detected OBJ file - OBJ format may not be supported by AR plugin');
      debugPrint('AR Screen: Using NodeType.webGLB as fallback (may cause issues)');
      return NodeType.webGLB; // Fallback - OBJ may not be supported
    } else {
      debugPrint('AR Screen: ⚠️ Unknown file extension for: $uri, defaulting to NodeType.webGLB');
      return NodeType.webGLB; // Default fallback
    }
  }

  /// Calculate position offset for new models to avoid overlaps
  vm.Vector3 _calculatePositionOffset(vm.Vector3 basePosition) {
    // Get currently placed models
    List<ARModelData> placedModels = _modelManager.getAllPersistentModels()
        .where((model) => model.isPlaced)
        .toList();
    
    if (placedModels.isEmpty) {
      debugPrint('AR Screen: No existing models, using base position');
      return basePosition;
    }
    
    debugPrint('AR Screen: Found ${placedModels.length} existing models, calculating offset');
    
    // Create a circular pattern around the base position
    int existingCount = placedModels.length;
    double angle = (existingCount * 60.0) * (3.14159 / 180.0); // 60 degrees apart
    double radius = 0.8; // 80cm radius from center
    
    double xOffset = radius * math.cos(angle);
    double zOffset = radius * math.sin(angle);
    
    vm.Vector3 offsetPosition = vm.Vector3(
      basePosition.x + xOffset,
      basePosition.y, // Keep same height
      basePosition.z + zOffset,
    );
    
    debugPrint('AR Screen: Calculated offset position: $offsetPosition');
    debugPrint('AR Screen: - Angle: ${(existingCount * 60.0)}°, Radius: ${radius}m');
    debugPrint('AR Screen: - Offset: X=${xOffset.toStringAsFixed(2)}, Z=${zOffset.toStringAsFixed(2)}');
    
    return offsetPosition;
  }

  /// Called when model is ready for placement
  void _onModelReadyForPlacement() {
    debugPrint('AR Screen: === MODEL READY FOR PLACEMENT ===');
    debugPrint('AR Screen: currentUniqueProductId: $currentUniqueProductId');
    
    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            isModelReadyForPlacement = true;
            showInstructionMessage = true;
          });
        }
      });
    }
    
    // Start plane detection after a short delay
    Future.delayed(ARConstants.modelPlacementDelay, () {
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {
              isPlaneDetectionActive = true;
              showInstructionMessage = false;
            });
          }
        });
      }
      
      // Auto-place the new product model - BUT only if not currently restoring
      if (currentUniqueProductId != null) {
        if (_isRestoringModels) {
          debugPrint('AR Screen: Skipping auto-placement during model restoration');
        } else {
          debugPrint('AR Screen: Auto-placing new product: $currentUniqueProductId');
          _autoPlaceModelInFrontOfCamera();
        }
      } else {
        debugPrint('AR Screen: No unique product ID, skipping auto-placement');
      }
    });
  }

  /// Place model at hit test result location
  void _placeModelAtHitResult(ARHitTestResult hitResult) {
    if (modelUri == null) return;
    
    vm.Vector3 worldPosition = _planeManager.getFloorPosition(hitResult);
    debugPrint('AR Screen: Placing model at position: $worldPosition');
    _placeObjectAtPosition(worldPosition);
  }

  /// Auto-place model in front of camera (for initial placement)
  /// Enhanced to ensure proper floor placement by waiting for adequate plane detection
  Future<void> _autoPlaceModelInFrontOfCamera() async {
    debugPrint('AR Screen: === AUTO-PLACING MODEL ===');
    debugPrint('AR Screen: currentUniqueProductId: $currentUniqueProductId');
    
    // Wait longer for AR to detect and stabilize floor plane detection
    // This prevents placing objects "floating" above the floor
    await Future.delayed(const Duration(seconds: 2));
    
    // Try multiple times to get a good floor plane detection
    vm.Vector3 autoPlacePosition;
    bool foundFloorPlane = false;
    
    for (int attempt = 0; attempt < 3; attempt++) {
      if (_planeManager.floorPlane != null && _planeManager.lowestPlaneY != null) {
        debugPrint('AR Screen: Found floor plane on attempt ${attempt + 1}');
        debugPrint('AR Screen: Floor Y-coordinate: ${_planeManager.lowestPlaneY!.toStringAsFixed(2)}m');
        foundFloorPlane = true;
        break;
      }
      
      debugPrint('AR Screen: Floor plane not ready, waiting... (attempt ${attempt + 1}/3)');
      await Future.delayed(const Duration(milliseconds: 500));
    }
    
    if (foundFloorPlane && _planeManager.lowestPlaneY != null) {
      debugPrint('AR Screen: Using detected LOWEST floor plane for precise positioning');
      
      // Create a synthetic hit result for the floor plane
      // Use the detected floor Y-coordinate but place object in front of camera
      autoPlacePosition = vm.Vector3(
        0.0, // Center horizontally
        _planeManager.lowestPlaneY!, // Use exact floor Y-coordinate
        ARConstants.autoPlacementDistance // Place in front of camera
      );
      
      debugPrint('AR Screen: Precise floor placement at Y=${_planeManager.lowestPlaneY!.toStringAsFixed(2)}m');
    } else {
      debugPrint('AR Screen: No stable floor plane detected, using conservative estimate');
      
      // More conservative estimate - assume camera is held at chest height (~1.2-1.4m above floor)
      // Place object slightly above estimated floor to avoid "underground" placement
      double estimatedFloorY = -1.3; // Conservative estimate
      
      autoPlacePosition = vm.Vector3(
        0.0, 
        estimatedFloorY, 
        ARConstants.autoPlacementDistance
      );
      
      debugPrint('AR Screen: Conservative floor estimate at Y=${estimatedFloorY}m');
    }
    
    debugPrint('AR Screen: Final auto-placement position: $autoPlacePosition');
    debugPrint('AR Screen: Distance from camera: ${ARConstants.autoPlacementDistance.abs()} meters');
    
    await _placeObjectAtPosition(autoPlacePosition);
    
    // Mark that we have successfully placed this product
    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            hasPlacedInitialModel = true;
          });
        }
      });
    }
    
    // Clear the current product so it doesn't get placed again
    currentUniqueProductId = null;
    modelUri = null;
    debugPrint('AR Screen: ✅ Auto-placement completed, cleared product state');
  }

  /// Place object at specified world position
  Future<void> _placeObjectAtPosition(vm.Vector3 position) async {
    if (modelUri == null || (currentUniqueProductId == null && widget.product?.id == null)) return;
    
    // Prevent object placement while AR session is paused
    if (_isARSessionPaused) {
      debugPrint('AR Screen: ❌ Cannot place object - AR session is paused');
      return;
    }
    
    debugPrint('AR Screen: === PLACING OBJECT ===');
    debugPrint('AR Screen: Base position: $position');
    debugPrint('AR Screen: 🔍 CRITICAL DEBUG - nodes.length at placement start: ${nodes.length}');
    debugPrint('AR Screen: 🔍 CRITICAL DEBUG - nodeCreationOrder: $nodeCreationOrder');
    debugPrint('AR Screen: 🔍 CRITICAL DEBUG - _maxObjectsReachedBeforeMemoryLimit: $_maxObjectsReachedBeforeMemoryLimit');
    
    // CRITICAL: Check memory safety before placing model
    debugPrint('AR Screen: Checking memory safety before placing model...');
    bool memoryIsSafe = await _canSafelyAddModel();
    
    if (!memoryIsSafe) {
      debugPrint('AR Screen: ❌ BLOCKED model placement due to memory constraints');
      
      // Show user-friendly memory warning message
      _showMemoryPlacementFailure();
      
      // Trigger UI update since we may have just discovered the memory limit
      if (mounted) {
        setState(() {
          // The setState will cause _buildAddButton to re-evaluate and potentially hide the button
        });
        debugPrint('AR Screen: Triggered UI update after discovering memory limit');
      }
      
      return; // Exit early if memory is not safe
    }
    
    debugPrint('AR Screen: ✅ Memory check passed, proceeding with model placement');
    
    // Calculate offset position to avoid overlapping existing models
    vm.Vector3 finalPosition = _calculatePositionOffset(position);
    debugPrint('AR Screen: Final position after offset: $finalPosition');
    
    // ALWAYS use original web URL to avoid cached file corruption issues
    String modelUriToUse = modelUri!; // Use original web URL
    debugPrint('AR Screen: Using original web URL: $modelUriToUse');
    
    // Determine correct node type based on file extension
    NodeType nodeType = _getNodeTypeFromUri(modelUriToUse);
    debugPrint('AR Screen: Determined node type: $nodeType for URI: $modelUriToUse');
    
    // Create AR node with completely new Vector3 instances to prevent NaN corruption
    debugPrint('AR Screen: Creating new placement node with clean Vector3 instances');
    
    ARNode node;
    
    try {
      // CRITICAL: Create completely new Vector3 instances to avoid NaN corruption
      // Add small upward offset for proper floor placement
      vm.Vector3 cleanPosition = vm.Vector3(
        finalPosition.x.isFinite ? finalPosition.x : 0.0,
        finalPosition.y.isFinite ? (finalPosition.y + 0.01) : -1.19, // Add 1cm floor offset
        finalPosition.z.isFinite ? finalPosition.z : -0.8,
      );
      
      debugPrint('AR Screen: Floor placement adjustment applied');
      debugPrint('AR Screen: - Original position: $finalPosition');
      debugPrint('AR Screen: - Floor-adjusted position: $cleanPosition');
      
      vm.Vector3 cleanScale = vm.Vector3(ARConstants.defaultScale, ARConstants.defaultScale, ARConstants.defaultScale);
      vm.Vector4 cleanRotation = vm.Vector4(0.0, 0.0, 0.0, 1.0);
      
      debugPrint('AR Screen: Creating ARNode with clean vectors');
      debugPrint('AR Screen: - Clean position: $cleanPosition');
      debugPrint('AR Screen: - Clean scale: $cleanScale');
      debugPrint('AR Screen: - Node type: $nodeType');
      
      node = ARNode(
        type: nodeType, // Use correct node type based on file extension
        uri: modelUriToUse,
        position: cleanPosition,
        scale: cleanScale,
        rotation: cleanRotation,
      );
      
      debugPrint('AR Screen: Node created successfully');
      debugPrint('AR Screen: - Final position: ${node.position}');
      debugPrint('AR Screen: - Final scale: ${node.scale}');
      
      // Verify the scale is still valid after creation
      if (node.scale.x.isNaN || node.scale.y.isNaN || node.scale.z.isNaN) {
        debugPrint('AR Screen: 🚨 Scale became NaN after ARNode creation! This is a critical issue');
        throw Exception('Scale corruption detected in ARNode constructor');
      }
      
    } catch (e) {
      debugPrint('AR Screen: ❌ Error creating ARNode: $e');
      debugPrint('AR Screen: Attempting fallback node creation...');
      
      try {
        // Fallback: Create minimal node with only required properties
        node = ARNode(
          type: nodeType, // Use correct node type even in fallback
          uri: modelUriToUse,
          position: vm.Vector3(
            finalPosition.x.isFinite ? finalPosition.x : 0.0,
            finalPosition.y.isFinite ? (finalPosition.y + 0.01) : -1.19, // Floor offset in fallback too
            finalPosition.z.isFinite ? finalPosition.z : -0.8,
          ),
          scale: vm.Vector3(ARConstants.defaultScale, ARConstants.defaultScale, ARConstants.defaultScale),
        );
        debugPrint('AR Screen: Fallback node created with floor offset - scale: ${node.scale}');
      } catch (fallbackError) {
        debugPrint('AR Screen: ❌ Fallback node creation also failed: $fallbackError');
        return;
      }
    }
    
    try {
      String? nodeId = await _addNodeToARScene(node);
      
      if (nodeId != null) {
        // Add to tracking lists
        nodes.add(node);
        nodeCreationOrder.add(nodeId);
        
        // Add to model manager - use safe scale values to prevent NaN corruption
        ARModelData modelData = _modelManager.addModel(
          modelUri: modelUri!,
          productId: currentUniqueProductId ?? widget.product?.id ?? 'unknown',
          position: finalPosition, // Use the offset position
          scale: _getSafeScaleForSaving(node.scale), // Use safe scale values
          rotation: vm.Vector4(0, 0, 0, 1), // Use default rotation
          cachedPath: null, // Don't save cached path to avoid corruption
          activeNodeId: nodeId,
        );
        
        debugPrint('AR Screen: ✅ Model placed successfully with ID: $nodeId');
        debugPrint('AR Screen: Model data saved: ${modelData.toString()}');
        
        // Note: We don't update _maxObjectsReachedBeforeMemoryLimit here
        // It should only be set when we actually hit memory limits during placement attempts
        
        // Update removed count since we're adding back (if we had removed objects before)
        if (mounted && _objectsRemovedSinceMemoryLimit > 0) {
          setState(() {
            _objectsRemovedSinceMemoryLimit = math.max(0, _objectsRemovedSinceMemoryLimit - 1);
            debugPrint('AR Screen: Updated removed count in setState: $_objectsRemovedSinceMemoryLimit');
          });
        }
        
        // Track model addition in memory manager
        ARMemoryManager.onModelAdded();
        
        // Update memory information after model placement
        _updateMemoryInfo();
        // _showSnackBar('Model placed successfully');
        
      } else {
        debugPrint('AR Screen: ❌ Failed to place model');
        // _showSnackBar('Failed to place model');
      }
      
    } catch (e) {
      debugPrint('AR Screen: ❌ Error placing model: $e');
      // _showSnackBar('Error placing model: $e');
    }
  }

  /// Add node to AR scene (platform-specific implementation)
  Future<String?> _addNodeToARScene(ARNode node) async {
    if (_sessionController.objectManager == null) {
      debugPrint('AR Screen: ❌ ObjectManager is null');
      return null;
    }
    
    debugPrint('AR Screen: Adding node to AR scene - Platform: ${Platform.isIOS ? 'iOS' : 'Android'}');
    debugPrint('AR Screen: Node details - URI: ${node.uri}');
    debugPrint('AR Screen: Node details - Type: ${node.type}');
    debugPrint('AR Screen: Node details - Position: ${node.position}');
    debugPrint('AR Screen: Node details - Scale: ${node.scale}');
    
    // CRITICAL: Final check and fix for NaN scale before adding to AR scene
    if (node.scale.x.isNaN || node.scale.y.isNaN || node.scale.z.isNaN) {
      debugPrint('AR Screen: 🚨 CRITICAL - Scale is NaN, this will cause rendering failure!');
      debugPrint('AR Screen: Attempting final emergency scale fix...');
      
      try {
        // Create a completely new ARNode with clean values
        vm.Vector3 cleanPosition = vm.Vector3(node.position.x, node.position.y, node.position.z);
        vm.Vector3 cleanScale = vm.Vector3(ARConstants.defaultScale, ARConstants.defaultScale, ARConstants.defaultScale);
        vm.Vector4 cleanRotation = vm.Vector4(0.0, 0.0, 0.0, 1.0);
        
        ARNode cleanNode = ARNode(
          type: node.type,
          uri: node.uri,
          position: cleanPosition,
          scale: cleanScale,
          rotation: cleanRotation,
        );
        
        debugPrint('AR Screen: Created clean replacement node - scale: ${cleanNode.scale}');
        
        // Verify the clean node doesn't have NaN
        if (cleanNode.scale.x.isNaN || cleanNode.scale.y.isNaN || cleanNode.scale.z.isNaN) {
          debugPrint('AR Screen: ❌ Even clean node has NaN scale! AR plugin issue detected');
          return null;
        }
        
        // Replace the node reference
        node = cleanNode;
        debugPrint('AR Screen: ✅ Using clean node for AR scene addition');
        
      } catch (e) {
        debugPrint('AR Screen: ❌ Emergency scale fix failed: $e');
        return null;
      }
    }
    
    try {
      // Test method channel communication before critical operations
      debugPrint('AR Screen: Testing method channel before node addition...');
      try {
        if (_sessionController.objectManager == null) {
          throw Exception('ObjectManager unavailable for method channel test');
        }
        // Small delay to ensure method channel readiness
        await Future.delayed(const Duration(milliseconds: 10));
        debugPrint('AR Screen: ✅ Method channel ready for node addition');
      } catch (channelTest) {
        debugPrint('AR Screen: ❌ Method channel test failed before node addition: $channelTest');
        return null;
      }
      
      if (Platform.isAndroid) {
        // CRITICAL FIX: Android requires individual anchor management for each object
        debugPrint('AR Screen: Android - Creating node with ISOLATED anchor hierarchy');
        
        // Generate unique node name with timestamp to avoid conflicts
        String nodeName = "ARObject_${DateTime.now().millisecondsSinceEpoch}";
        
        // CRITICAL: Each Android node MUST have its own isolated setup
        // This prevents anchor hierarchy corruption when multiple objects exist
        ARNode androidNode = ARNode(
          type: node.type,
          uri: node.uri,
          name: nodeName,
          position: node.position, // Use position directly
          scale: node.scale,
          // CRITICAL: Enable gestures for multi-object support
          isTransformable: true,     // Enable gestures
          enablePanGestures: true,   // Enable pan gestures
          enableRotationGestures: true, // Enable rotation gestures
        );
        
        debugPrint('AR Screen: Android - Created ISOLATED anchor node');
        debugPrint('AR Screen: - Node name: $nodeName');
        debugPrint('AR Screen: - Individual anchor hierarchy');
        debugPrint('AR Screen: - Position: ${node.position}');
        debugPrint('AR Screen: - Scale: ${node.scale}');
        debugPrint('AR Screen: - Object count in scene: ${nodes.length + 1}');
        
        // Add node with anchor hierarchy validation
        dynamic result;
        try {
          result = await _sessionController.objectManager!.addNode(androidNode);
          debugPrint('AR Screen: Android - Add node result: $result (type: ${result.runtimeType})');
          
          // Post-addition gesture isolation for multi-object scenes
          if (result != null && nodes.length >= 1) {
            debugPrint('AR Screen: 🔧 Initializing gesture isolation for multi-object scene...');
            await _initializeGestureIsolation();
          }
          
        } catch (addNodeError) {
          debugPrint('AR Screen: ❌ Android node addition failed: $addNodeError');
          
          // Check for specific anchor hierarchy errors
          if (addNodeError.toString().contains('AnchorNode') || 
              addNodeError.toString().contains('TransformableNode') ||
              addNodeError.toString().contains('parent hierarchy')) {
            debugPrint('AR Screen: 🚨 ANCHOR HIERARCHY CORRUPTION DETECTED');
            debugPrint('AR Screen: Attempting emergency anchor recovery...');
            
            // Emergency fix: Try with minimal configuration
            try {
              ARNode emergencyNode = ARNode(
                type: node.type,
                uri: node.uri,
                name: "${nodeName}_emergency",
                position: node.position,
                scale: vm.Vector3(1.0, 1.0, 1.0), // Use safe scale
                // Absolute minimal configuration to avoid anchor issues
                isTransformable: false, // Disable gestures as emergency measure
              );
              
              result = await _sessionController.objectManager!.addNode(emergencyNode);
              debugPrint('AR Screen: ✅ Emergency anchor recovery succeeded');
              
            } catch (emergencyError) {
              debugPrint('AR Screen: ❌ Emergency anchor recovery failed: $emergencyError');
              return null;
            }
          } else {
            return null;
          }
        }
        
        // CRITICAL: For Android, we need to be very careful about the node ID
        String returnedNodeId;
        if (result is String && result.isNotEmpty) {
          returnedNodeId = result;
          debugPrint('AR Screen: Android - Using returned string ID: $returnedNodeId');
        } else {
          returnedNodeId = nodeName;
          debugPrint('AR Screen: Android - Using generated name as ID: $returnedNodeId');
        }
        
        debugPrint('AR Screen: Android - Final node ID for tracking: $returnedNodeId');
        return returnedNodeId;
        
      } else {
        // iOS placement - simplified approach
        debugPrint('AR Screen: iOS - Adding node directly (simplified)');
        
        try {
          dynamic result = await _sessionController.objectManager!.addNode(node);
          debugPrint('AR Screen: iOS - Direct add node result: $result (type: ${result.runtimeType})');
          
          // Handle various return types
          if (result is String && result.isNotEmpty) {
            debugPrint('AR Screen: iOS - ✅ Node added with string ID: $result');
            return result;
          } else if (result is bool && result == true) {
            String generatedId = "ARObject_${DateTime.now().millisecondsSinceEpoch}";
            debugPrint('AR Screen: iOS - ✅ Node added with generated ID: $generatedId');
            return generatedId;
          } else if (result == null) {
            // Sometimes null doesn't mean failure, try generating ID
            String generatedId = "ARObject_${DateTime.now().millisecondsSinceEpoch}";
            debugPrint('AR Screen: iOS - ⚠️ Null result, attempting generated ID: $generatedId');
            return generatedId;
          } else {
            debugPrint('AR Screen: iOS - ❌ Unexpected result type: ${result.runtimeType}, value: $result');
            return null;
          }
        } catch (e) {
          debugPrint('AR Screen: iOS - ❌ Direct placement error: $e');
          return null;
        }
      }
    } catch (e) {
      debugPrint('AR Screen: ❌ Error adding node to AR scene: $e');
      return null;
    }
  }
}
