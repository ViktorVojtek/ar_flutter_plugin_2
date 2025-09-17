import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_location_manager.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AR Snapshot Test',
      home: SnapshotTestScreen(),
    );
  }
}

class SnapshotTestScreen extends StatefulWidget {
  @override
  _SnapshotTestScreenState createState() => _SnapshotTestScreenState();
}

class _SnapshotTestScreenState extends State<SnapshotTestScreen> {
  ARSessionManager? arSessionManager;
  ARObjectManager? arObjectManager;
  ARView? arView;
  Uint8List? snapshotBytes;

  @override
  void dispose() {
    arSessionManager?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('AR Snapshot Test'),
      ),
      body: Container(
        child: Stack(
          children: [
            ARView(
              onARViewCreated: onARViewCreated,
            ),
            Positioned(
              bottom: 20,
              left: 20,
              right: 20,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton(
                    onPressed: takeSnapshot,
                    child: Text('Take Snapshot'),
                  ),
                  ElevatedButton(
                    onPressed: showSnapshot,
                    child: Text('Show Snapshot'),
                  ),
                ],
              ),
            ),
          ],
        ),
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

    // Configure session
    this.arSessionManager!.onInitialize(
      showFeaturePoints: false,
      showPlanes: true,
      showWorldOrigin: false,
      handleTaps: true,
    );

    this.arObjectManager!.onInitialize();
  }

  void takeSnapshot() async {
    if (arSessionManager != null) {
      try {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Taking snapshot...')),
        );

        ImageProvider imageProvider = await arSessionManager!.snapshot();
        
        if (imageProvider is MemoryImage) {
          setState(() {
            snapshotBytes = imageProvider.bytes;
          });
          
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Snapshot captured! Size: ${imageProvider.bytes.length} bytes'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        print('Error taking snapshot: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error taking snapshot: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void showSnapshot() {
    if (snapshotBytes != null) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('AR Snapshot'),
          content: Container(
            width: 300,
            height: 400,
            child: Image.memory(
              snapshotBytes!,
              fit: BoxFit.contain,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Close'),
            ),
          ],
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No snapshot available. Take a snapshot first!')),
      );
    }
  }
}