import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin_2/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_2/models/ar_plane.dart';
import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

/// Example showing how to use the enhanced plane detection with position and height information
class PlaneDetectionExample extends StatefulWidget {
  const PlaneDetectionExample({Key? key}) : super(key: key);

  @override
  State<PlaneDetectionExample> createState() => _PlaneDetectionExampleState();
}

class _PlaneDetectionExampleState extends State<PlaneDetectionExample> {
  ARSessionManager? arSessionManager;
  ARObjectManager? arObjectManager;
  ARLocationManager? arLocationManager;
  
  List<ARPlane> detectedPlanes = [];
  String planeInfo = "No planes detected yet";

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Enhanced Plane Detection'),
        backgroundColor: Colors.blue,
      ),
      body: Column(
        children: [
          // Plane information display
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.grey[100],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Detected Planes: ${detectedPlanes.length}',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(planeInfo),
                if (detectedPlanes.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text('Latest Planes:', style: TextStyle(fontWeight: FontWeight.bold)),
                  ...detectedPlanes.take(3).map((plane) => Padding(
                    padding: const EdgeInsets.only(left: 8, top: 4),
                    child: Text(
                      '• ${plane.alignment} plane at height ${plane.height.toStringAsFixed(3)}m, '
                      'size: ${plane.width.toStringAsFixed(2)}×${plane.length.toStringAsFixed(2)}m',
                      style: const TextStyle(fontSize: 12),
                    ),
                  )),
                ],
              ],
            ),
          ),
          // AR View
          Expanded(
            child: ARView(
              onARViewCreated: onARViewCreated,
              planeDetectionConfig: PlaneDetectionConfig.horizontalAndVertical,
            ),
          ),
        ],
      ),
    );
  }

  void onARViewCreated(
    ARSessionManager arSessionManager,
    ARObjectManager arObjectManager,
    ARAnchorManager arAnchorManager,
    ARLocationManager arLocationManager,
  ) {
    this.arSessionManager = arSessionManager;
    this.arObjectManager = arObjectManager;
    this.arLocationManager = arLocationManager;

    // Set up session configuration
    this.arSessionManager!.onInitialize(
      showFeaturePoints: false,
      showPlanes: true,
      customPlaneTexturePath: null,
      showWorldOrigin: false,
      handleTaps: true,
      handlePans: false,
      handleRotation: false,
    );

    // Set up enhanced plane detection handler
    this.arSessionManager!.onPlaneDetected = onPlaneDetected;
  }

  /// Enhanced plane detection handler with comprehensive plane information
  void onPlaneDetected(ARPlane plane) {
    setState(() {
      // Add the new plane to our list
      detectedPlanes.add(plane);
      
      // Update plane information display
      final groundPlanes = detectedPlanes.where((p) => p.alignment == 'horizontal' && p.height < 0.5).length;
      final wallPlanes = detectedPlanes.where((p) => p.alignment == 'vertical').length;
      final elevatedPlanes = detectedPlanes.where((p) => p.alignment == 'horizontal' && p.height >= 0.5).length;
      
      // Find the lowest and highest planes for height range
      final heights = detectedPlanes.map((p) => p.height).toList();
      final minHeight = heights.isEmpty ? 0.0 : heights.reduce((a, b) => a < b ? a : b);
      final maxHeight = heights.isEmpty ? 0.0 : heights.reduce((a, b) => a > b ? a : b);
      
      planeInfo = '''Latest plane detected:
Type: ${plane.type}
Alignment: ${plane.alignment}
Height: ${plane.height.toStringAsFixed(3)}m
Position: (${plane.center.x.toStringAsFixed(2)}, ${plane.center.y.toStringAsFixed(2)}, ${plane.center.z.toStringAsFixed(2)})
Size: ${plane.width.toStringAsFixed(2)}m × ${plane.length.toStringAsFixed(2)}m
Area: ${plane.extent.area.toStringAsFixed(2)}m²

Summary:
• Ground planes (< 0.5m): $groundPlanes
• Elevated surfaces (≥ 0.5m): $elevatedPlanes  
• Walls/vertical: $wallPlanes
• Height range: ${minHeight.toStringAsFixed(2)}m to ${maxHeight.toStringAsFixed(2)}m''';
    });
    
    // Log detailed plane information for debugging
    print('🎯 New plane detected: $plane');
    print('   Height: ${plane.height}m, Size: ${plane.width}×${plane.length}m');
    print('   Total planes detected: ${detectedPlanes.length}');
  }

  @override
  void dispose() {
    arSessionManager?.dispose();
    super.dispose();
  }
}

/// Usage example showing how to filter planes by height
class PlaneHeightFilterExample {
  static List<ARPlane> getGroundPlanes(List<ARPlane> planes, {double maxHeight = 0.3}) {
    return planes.where((plane) => 
      plane.alignment == 'horizontal' && 
      plane.height <= maxHeight
    ).toList();
  }
  
  static List<ARPlane> getTableSurfaces(List<ARPlane> planes) {
    return planes.where((plane) => 
      plane.alignment == 'horizontal' && 
      plane.height >= 0.5 && 
      plane.height <= 1.2
    ).toList();
  }
  
  static List<ARPlane> getWalls(List<ARPlane> planes) {
    return planes.where((plane) => plane.alignment == 'vertical').toList();
  }
  
  static ARPlane? findNearestPlane(List<ARPlane> planes, vm.Vector3 position) {
    if (planes.isEmpty) return null;
    
    ARPlane? nearest;
    double minDistance = double.infinity;
    
    for (final plane in planes) {
      final distance = (plane.center - position).length;
      if (distance < minDistance) {
        minDistance = distance;
        nearest = plane;
      }
    }
    
    return nearest;
  }
}
