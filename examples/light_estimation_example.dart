import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin_2/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin_2/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:flutter/material.dart';

/// Example demonstrating light estimation capabilities in AR scenes
/// 
/// This example shows how to:
/// 1. Enable automatic lighting condition monitoring
/// 2. Get on-demand light estimates
/// 3. Display warnings when lighting is insufficient
/// 4. React to lighting changes in real-time
class LightEstimationExample extends StatefulWidget {
  const LightEstimationExample({Key? key}) : super(key: key);

  @override
  State<LightEstimationExample> createState() => _LightEstimationExampleState();
}

class _LightEstimationExampleState extends State<LightEstimationExample> {
  ARSessionManager? arSessionManager;
  ARObjectManager? arObjectManager;
  ARAnchorManager? arAnchorManager;
  ARLocationManager? arLocationManager;

  // Lighting state
  bool _isLowLight = false;
  bool _isVeryLowLight = false;
  double _lightIntensity = 0.0;
  String _lightingStatus = "Initializing...";
  Color _statusColor = Colors.blue;
  
  // Monitoring state
  bool _isMonitoring = false;

  @override
  void dispose() {
    // Stop monitoring when leaving the screen
    arSessionManager?.enableLightingMonitoring(enable: false);
    arSessionManager?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Light Estimation Example'),
        actions: [
          // Toggle monitoring button
          IconButton(
            icon: Icon(_isMonitoring ? Icons.stop : Icons.play_arrow),
            onPressed: _toggleMonitoring,
            tooltip: _isMonitoring ? 'Stop Monitoring' : 'Start Monitoring',
          ),
        ],
      ),
      body: Stack(
        children: [
          // AR View
          ARView(
            onARViewCreated: _onARViewCreated,
            planeDetectionConfig: PlaneDetectionConfig.horizontalAndVertical,
          ),

          // Lighting information overlay
          Positioned(
            top: 20,
            left: 20,
            right: 20,
            child: _buildLightingInfoCard(),
          ),

          // Control buttons
          Positioned(
            bottom: 40,
            left: 20,
            right: 20,
            child: _buildControlButtons(),
          ),
        ],
      ),
    );
  }

  /// Build the lighting information card
  Widget _buildLightingInfoCard() {
    return Card(
      color: _statusColor.withOpacity(0.9),
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _getStatusIcon(),
                  color: Colors.white,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _lightingStatus,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildLightingDetails(),
            if (_isLowLight) ...[
              const SizedBox(height: 12),
              _buildLightingSuggestion(),
            ],
          ],
        ),
      ),
    );
  }

  /// Build detailed lighting metrics
  Widget _buildLightingDetails() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          _buildMetricRow('Light Intensity', '${(_lightIntensity * 100).toStringAsFixed(0)}%'),
          const SizedBox(height: 8),
          _buildMetricRow('Monitoring', _isMonitoring ? 'Active' : 'Inactive'),
          const SizedBox(height: 8),
          _buildLightingBar(),
        ],
      ),
    );
  }

  /// Build a single metric row
  Widget _buildMetricRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  /// Build visual lighting intensity bar
  Widget _buildLightingBar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Quality',
          style: TextStyle(color: Colors.white70, fontSize: 12),
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: _lightIntensity,
            backgroundColor: Colors.white24,
            valueColor: AlwaysStoppedAnimation<Color>(
              _isVeryLowLight
                  ? Colors.red
                  : _isLowLight
                      ? Colors.orange
                      : Colors.green,
            ),
            minHeight: 8,
          ),
        ),
      ],
    );
  }

  /// Build lighting improvement suggestion
  Widget _buildLightingSuggestion() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black38,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        children: [
          const Icon(Icons.tips_and_updates, color: Colors.white70, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _isVeryLowLight
                  ? 'Move to a brighter area for better AR tracking'
                  : 'Consider improving lighting for optimal experience',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Build control buttons
  Widget _buildControlButtons() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        ElevatedButton.icon(
          onPressed: _checkLightingNow,
          icon: const Icon(Icons.wb_sunny),
          label: const Text('Check Now'),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
        ),
        ElevatedButton.icon(
          onPressed: _toggleMonitoring,
          icon: Icon(_isMonitoring ? Icons.stop : Icons.play_arrow),
          label: Text(_isMonitoring ? 'Stop' : 'Start'),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            backgroundColor: _isMonitoring ? Colors.red : Colors.green,
          ),
        ),
      ],
    );
  }

  /// Get status icon based on lighting condition
  IconData _getStatusIcon() {
    if (_isVeryLowLight) return Icons.warning_amber;
    if (_isLowLight) return Icons.wb_twilight;
    return Icons.wb_sunny;
  }

  /// Initialize AR view and set up lighting monitoring
  void _onARViewCreated(
    ARSessionManager sessionManager,
    ARObjectManager objectManager,
    ARAnchorManager anchorManager,
    ARLocationManager locationManager,
  ) {
    arSessionManager = sessionManager;
    arObjectManager = objectManager;
    arAnchorManager = anchorManager;
    arLocationManager = locationManager;

    // Initialize AR session
    arSessionManager!.onInitialize(
      showAnimatedGuide: true,
      showPlanes: true,
      handleTaps: true,
    );

    // Set up lighting condition callback
    arSessionManager!.onLightingConditionChanged = _onLightingChanged;

    // Start monitoring automatically
    _startMonitoring();
  }

  /// Handle lighting condition changes
  void _onLightingChanged(Map<String, dynamic> lightData) {
    if (!mounted) return;

    setState(() {
      // Get platform-specific intensity value
      // Android: pixelIntensity (0.0 - 1.0+)
      // iOS: normalizedIntensity (0.0 - 1.0)
      _lightIntensity = (lightData['pixelIntensity'] ??
              lightData['normalizedIntensity'] ??
              0.0) as double;

      _isLowLight = lightData['isLowLight'] as bool? ?? false;
      _isVeryLowLight = lightData['isVeryLowLight'] as bool? ?? false;

      // Update status
      if (_isVeryLowLight) {
        _lightingStatus = '⚠️ Very Low Light (${(_lightIntensity * 100).toStringAsFixed(0)}%)';
        _statusColor = Colors.red.shade700;
      } else if (_isLowLight) {
        _lightingStatus = '⚠️ Low Light (${(_lightIntensity * 100).toStringAsFixed(0)}%)';
        _statusColor = Colors.orange.shade700;
      } else {
        _lightingStatus = '✅ Good Lighting (${(_lightIntensity * 100).toStringAsFixed(0)}%)';
        _statusColor = Colors.green.shade700;
      }
    });

    // Optional: Log additional platform-specific data
    if (lightData.containsKey('colorCorrection')) {
      // Android-specific color correction data
      final colorCorrection = lightData['colorCorrection'] as List?;
      debugPrint('Color Correction: $colorCorrection');
    }
    if (lightData.containsKey('ambientColorTemperature')) {
      // iOS-specific color temperature
      final temperature = lightData['ambientColorTemperature'];
      debugPrint('Color Temperature: $temperature K');
    }
  }

  /// Start automatic lighting monitoring
  Future<void> _startMonitoring() async {
    await arSessionManager?.enableLightingMonitoring(
      enable: true,
      intervalMs: 1000, // Check every second
    );
    
    setState(() {
      _isMonitoring = true;
      _lightingStatus = 'Monitoring lighting...';
    });
  }

  /// Stop automatic lighting monitoring
  Future<void> _stopMonitoring() async {
    await arSessionManager?.enableLightingMonitoring(enable: false);
    
    setState(() {
      _isMonitoring = false;
      _lightingStatus = 'Monitoring stopped';
      _statusColor = Colors.grey.shade700;
    });
  }

  /// Toggle monitoring on/off
  Future<void> _toggleMonitoring() async {
    if (_isMonitoring) {
      await _stopMonitoring();
    } else {
      await _startMonitoring();
    }
  }

  /// Check lighting conditions immediately
  Future<void> _checkLightingNow() async {
    try {
      final lightData = await arSessionManager?.getLightEstimate();
      
      if (lightData != null) {
        _onLightingChanged(lightData);
        
        // Show feedback
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Current light intensity: ${(_lightIntensity * 100).toStringAsFixed(0)}%'),
            duration: const Duration(seconds: 2),
            backgroundColor: _statusColor,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Light estimate not available yet'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error checking lighting: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}
