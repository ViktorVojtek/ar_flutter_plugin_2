import 'package:flutter/material.dart';
import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_2/datatypes/config_planedetection.dart';
import 'dart:developer' as developer;

/// Enhanced debug example for testing nukeAll with plugin state monitoring.
/// This helps identify what resources remain alive after cleanup and 
/// verify memory returns to cold start levels.
/// 
/// Usage:
/// 1. Launch app (measure cold start memory ~350MB)  
/// 2. Tap "Initialize AR" (memory rises to ~1.7GB)
/// 3. Tap "Debug State" to see what's alive
/// 4. Tap "NUKE ALL" (should drop to ~350MB)
/// 5. Tap "Debug State" again to verify cleanup
/// 6. Remove from widget tree for 1-2 frames to complete surface teardown

class NukeAllDebugPage extends StatefulWidget {
  const NukeAllDebugPage({Key? key}) : super(key: key);

  @override
  State<NukeAllDebugPage> createState() => _NukeAllDebugPageState();
}

class _NukeAllDebugPageState extends State<NukeAllDebugPage> {
  ARSessionManager? arSessionManager;
  ARObjectManager? arObjectManager;
  ARAnchorManager? arAnchorManager;
  ARLocationManager? arLocationManager;
  bool _showARView = false;
  bool _arInitialized = false;
  Map<String, dynamic>? _lastPluginState;

  @override
  void dispose() {
    arSessionManager?.dispose();
    super.dispose();
  }

  Future<void> _initializeAR() async {
    try {
      setState(() {
        _showARView = true;
      });
      
      // Wait for AR initialization
      await Future.delayed(const Duration(milliseconds: 500));
      
      if (arSessionManager != null) {
        developer.log('🎯 AR Session initialized successfully');
        setState(() {
          _arInitialized = true;
        });
      }
    } catch (e) {
      developer.log('❌ Failed to initialize AR: $e');
      _showErrorDialog('Failed to initialize AR: $e');
    }
  }

  Future<void> _debugPluginState() async {
    if (arSessionManager == null) {
      _showInfoDialog('AR Session not initialized yet');
      return;
    }

    try {
      final state = await arSessionManager!.getPluginState();
      setState(() {
        _lastPluginState = state;
      });
      
      if (state != null) {
        final buffer = StringBuffer('🔍 Plugin State:\n\n');
        state.forEach((key, value) {
          buffer.writeln('$key: $value');
        });
        
        developer.log('Plugin State: $state');
        _showInfoDialog(buffer.toString());
      } else {
        _showErrorDialog('Failed to get plugin state');
      }
    } catch (e) {
      developer.log('❌ Error getting plugin state: $e');
      _showErrorDialog('Error getting plugin state: $e');
    }
  }

  Future<void> _executeNukeAll() async {
    if (arSessionManager == null) {
      _showErrorDialog('AR Session not initialized');
      return;
    }

    try {
      developer.log('🚨 Starting NUKE ALL operation...');
      
      final success = await arSessionManager!.nukeAll(
        purgeCaches: true,
        removeExistingAnchors: true,
        resetTracking: true,
      );

      if (success) {
        developer.log('✅ NUKE ALL completed successfully');
        
        // Get post-nuke state
        final postState = await arSessionManager!.getPluginState();
        setState(() {
          _lastPluginState = postState;
          _arInitialized = false;
        });
        
        _showInfoDialog('✅ NUKE ALL successful!\n\n'
            'Memory should now be near cold start levels.\n\n'
            'Next: Remove ARView from widget tree for 1-2 frames '
            'to complete surface teardown, then check memory usage.');
            
      } else {
        developer.log('❌ NUKE ALL failed');
        _showErrorDialog('❌ NUKE ALL operation failed');
      }
    } catch (e) {
      developer.log('❌ Error in NUKE ALL: $e');
      _showErrorDialog('Error in NUKE ALL: $e');
    }
  }

  Future<void> _removeARView() async {
    setState(() {
      _showARView = false;
      _arInitialized = false;
    });
    
    // Wait a couple frames for OS to deallocate surfaces
    await Future.delayed(const Duration(milliseconds: 100));
    
    _showInfoDialog('🔧 ARView removed from widget tree.\n\n'
        'Surface teardown complete. Check memory usage now.\n\n'
        'You can tap "Initialize AR" to start a new cycle.');
  }

  void _showInfoDialog(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Info'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showErrorDialog(String error) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Error'),
        content: Text(error),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('NUKE ALL Debug'),
        backgroundColor: Colors.red.shade700,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          // Control Panel
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.grey.shade100,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Memory Debug Cycle:',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 8),
                Text(
                  '1. Cold start: ~350MB\n'
                  '2. Initialize AR: ~1.7GB\n' 
                  '3. NUKE ALL: Should return to ~350MB\n'
                  '4. Remove ARView: Complete surface cleanup',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 16),
                
                // Control Buttons
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _showARView ? null : _initializeAR,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Initialize AR'),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                    ),
                    ElevatedButton.icon(
                      onPressed: _arInitialized ? _debugPluginState : null,
                      icon: const Icon(Icons.bug_report),
                      label: const Text('Debug State'),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
                    ),
                    ElevatedButton.icon(
                      onPressed: _arInitialized ? _executeNukeAll : null,
                      icon: Icon(Icons.warning),
                      label: const Text('NUKE ALL'),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                    ),
                    ElevatedButton.icon(
                      onPressed: _showARView ? _removeARView : null,
                      icon: const Icon(Icons.remove_circle),
                      label: const Text('Remove ARView'),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                    ),
                  ],
                ),
              ],
            ),
          ),
          
          // AR View Area
          Expanded(
            child: _showARView
                ? ARView(
                    onARViewCreated: (ARSessionManager arSessionManager, 
                                    ARObjectManager arObjectManager,
                                    ARAnchorManager arAnchorManager,
                                    ARLocationManager arLocationManager) {
                      this.arSessionManager = arSessionManager;
                      this.arObjectManager = arObjectManager;
                      this.arAnchorManager = arAnchorManager;
                      this.arLocationManager = arLocationManager;

                      // Configure session
                      this.arSessionManager!.onInitialize(
                        showFeaturePoints: false,
                        showPlanes: false,
                        showWorldOrigin: false,
                        handlePans: false,
                        handleRotation: false,
                      );
                    },
                    planeDetectionConfig: PlaneDetectionConfig.none,
                  )
                : Container(
                    color: Colors.grey.shade300,
                    child: const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.camera_alt, size: 64, color: Colors.grey),
                          SizedBox(height: 16),
                          Text(
                            'AR View Not Active',
                            style: TextStyle(fontSize: 18, color: Colors.grey),
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Tap "Initialize AR" to start',
                            style: TextStyle(fontSize: 14, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
          
          // Status Bar
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.grey.shade800,
            child: Row(
              children: [
                Icon(
                  _arInitialized ? Icons.check_circle : Icons.circle_outlined,
                  color: _arInitialized ? Colors.green : Colors.grey,
                ),
                const SizedBox(width: 8),
                Text(
                  _arInitialized ? 'AR Initialized' : 'AR Not Initialized',
                  style: const TextStyle(color: Colors.white),
                ),
                const Spacer(),
                if (_lastPluginState?['usedMemoryMB'] != null)
                  Text(
                    'Memory: ${_lastPluginState!['usedMemoryMB']}MB',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
