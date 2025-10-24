import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:flutter/material.dart';

/// Simple example showing basic light estimation usage
void main() {
  runApp(MaterialApp(
    home: SimpleLightEstimationExample(),
  ));
}

class SimpleLightEstimationExample extends StatefulWidget {
  @override
  State<SimpleLightEstimationExample> createState() => _SimpleLightEstimationExampleState();
}

class _SimpleLightEstimationExampleState extends State<SimpleLightEstimationExample> {
  ARSessionManager? arSessionManager;
  String lightingMessage = "Initializing AR...";
  Color backgroundColor = Colors.blue;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Simple Light Estimation')),
      body: Stack(
        children: [
          // AR View
          ARView(
            onARViewCreated: (sessionManager, objectManager, anchorManager, locationManager) {
              arSessionManager = sessionManager;
              
              // Initialize AR
              sessionManager.onInitialize(showPlanes: true);
              
              // Set up lighting callback
              sessionManager.onLightingConditionChanged = (lightData) {
                final isLowLight = lightData['isLowLight'] ?? false;
                final intensity = (lightData['pixelIntensity'] ?? 
                                  lightData['normalizedIntensity'] ?? 0.0) * 100;
                
                setState(() {
                  if (isLowLight) {
                    lightingMessage = "⚠️ Low Light: ${intensity.toStringAsFixed(0)}%";
                    backgroundColor = Colors.orange;
                  } else {
                    lightingMessage = "✅ Good Light: ${intensity.toStringAsFixed(0)}%";
                    backgroundColor = Colors.green;
                  }
                });
              };
              
              // Start monitoring every second
              sessionManager.enableLightingMonitoring(enable: true, intervalMs: 1000);
            },
          ),
          
          // Simple status indicator
          Positioned(
            top: 20,
            left: 20,
            right: 20,
            child: Container(
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: backgroundColor.withOpacity(0.9),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                lightingMessage,
                style: TextStyle(color: Colors.white, fontSize: 16),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  @override
  void dispose() {
    arSessionManager?.enableLightingMonitoring(enable: false);
    arSessionManager?.dispose();
    super.dispose();
  }
}
