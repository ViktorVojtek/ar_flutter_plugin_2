import 'dart:typed_data';

import 'package:ar_flutter_plugin_2/models/ar_anchor.dart';
import 'package:ar_flutter_plugin_2/models/ar_node.dart';
import 'package:ar_flutter_plugin_2/utils/json_converters.dart';
import 'package:flutter/services.dart';
import 'package:vector_math/vector_math_64.dart';

// Type definitions to enforce a consistent use of the API
typedef NodeTapResultHandler = void Function(List<String> nodes);
typedef NodePanStartHandler = void Function(String node);
typedef NodePanChangeHandler = void Function(String node);
typedef NodePanEndHandler = void Function(String node, Matrix4 transform);
typedef NodeRotationStartHandler = void Function(String node);
typedef NodeRotationChangeHandler = void Function(String node);
typedef NodeRotationEndHandler = void Function(String node, Matrix4 transform);

/// Manages the all node-related actions of an [ARView]
class ARObjectManager {
  /// Platform channel used for communication from and to [ARObjectManager]
  late MethodChannel _channel;

  /// Debugging status flag. If true, all platform calls are printed. Defaults to false.
  final bool debug;

  /// Callback function that is invoked when the platform detects a tap on a node
  NodeTapResultHandler? onNodeTap;
  NodePanStartHandler? onPanStart;
  NodePanChangeHandler? onPanChange;
  NodePanEndHandler? onPanEnd;
  NodeRotationStartHandler? onRotationStart;
  NodeRotationChangeHandler? onRotationChange;
  NodeRotationEndHandler? onRotationEnd;

  ARObjectManager(int id, {this.debug = false}) {
    _channel = MethodChannel('arobjects_$id');
    _channel.setMethodCallHandler(_platformCallHandler);
    if (debug) {
      print("ARObjectManager initialized");
    }
  }

  Future<void> _platformCallHandler(MethodCall call) {
    if (debug) {
      print('_platformCallHandler call ${call.method} ${call.arguments}');
    }
    try {
      switch (call.method) {
        case 'onError':
          print(call.arguments);
          break;
        case 'onNodeTap':
          if (onNodeTap != null) {
            try {
              // Handle the arguments more flexibly to avoid casting issues
              final arguments = call.arguments;
              if (arguments != null) {
                List<String> tappedNodes;
                if (arguments is List) {
                  tappedNodes = arguments.map((tappedNode) => tappedNode.toString()).toList();
                } else {
                  // Single node case - wrap in list
                  tappedNodes = [arguments.toString()];
                }
                onNodeTap!(tappedNodes);
              }
            } catch (e) {
              if (debug) {
                print('Error in onNodeTap: $e');
                print('Arguments: ${call.arguments}');
                print('Arguments type: ${call.arguments.runtimeType}');
              }
            }
          }
          break;
        case 'onPanStart':
          if (onPanStart != null) {
            final tappedNode = call.arguments as String?;
            if (tappedNode != null) {
              // Notify callback
              onPanStart!(tappedNode);
            }
          }
          break;
        case 'onPanChange':
          if (onPanChange != null) {
            final tappedNode = call.arguments as String?;
            if (tappedNode != null) {
              // Notify callback
              onPanChange!(tappedNode);
            }
          }
          break;
        case 'onPanEnd':
          if (onPanEnd != null) {
            // Handle arguments more flexibly to support iOS _Map<Object?, Object?> type
            final args = call.arguments;
            if (args != null && args is Map) {
              final Map<String, dynamic> argsMap = Map<String, dynamic>.from(args);
              if (argsMap["name"] != null) {
                final tappedNodeName = argsMap["name"] as String;
                final transform =
                    MatrixConverter().fromJson(argsMap['transform'] as List);

                // Notify callback
                onPanEnd!(tappedNodeName, transform);
              }
            }
          }
          break;
        case 'onRotationStart':
          if (onRotationStart != null) {
            final tappedNode = call.arguments as String?;
            if (tappedNode != null) {
              onRotationStart!(tappedNode);
            }
          }
          break;
        case 'onRotationChange':
          if (onRotationChange != null) {
            final tappedNode = call.arguments as String?;
            if (tappedNode != null) {
              onRotationChange!(tappedNode);
            }
          }
          break;
        case 'onRotationEnd':
          if (onRotationEnd != null) {
            // Handle arguments more flexibly to support iOS _Map<Object?, Object?> type
            final args = call.arguments;
            if (args != null && args is Map) {
              final Map<String, dynamic> argsMap = Map<String, dynamic>.from(args);
              if (argsMap["name"] != null) {
                final tappedNodeName = argsMap["name"] as String;
                final transform =
                    MatrixConverter().fromJson(argsMap['transform'] as List);

                // Notify callback
                onRotationEnd!(tappedNodeName, transform);
              }
            }
          }
          break;
        default:
          if (debug) {
            print('Unimplemented method ${call.method} ');
          }
      }
    } catch (e) {
      print('Error caught: ' + e.toString());
    }
    return Future.value();
  }

  /// Sets up the AR Object Manager
  onInitialize() {
    _channel.invokeMethod<void>('init', {});
  }

  /// Add given node to the given anchor of the underlying AR scene (or to its top-level if no anchor is given) and listen to any changes made to its transformation
  Future<String?> addNode(ARNode node, {ARPlaneAnchor? planeAnchor}) async {
    try {
      node.transformNotifier.addListener(() {
        _channel.invokeMethod<void>('transformationChanged', {
          'name': node.name,
          'transformation':
              MatrixValueNotifierConverter().toJson(node.transformNotifier)
        });
      });
      if (planeAnchor != null) {
        planeAnchor.childNodes.add(node.name);
        String? nodeName = await _channel.invokeMethod<String>('addNodeToPlaneAnchor',
            {'node': node.toMap(), 'anchor': planeAnchor.toJson()});
        return nodeName; // Return the node name directly from native side
      } else {
        String? nodeName = await _channel.invokeMethod<String>('addNode', node.toMap());
        return nodeName; // Return the node name directly from native side
      }
    } on PlatformException catch (e) {
      return null;
    }
  }

  /// Remove given node from the AR Scene
  removeNode(ARNode node) {
    _channel.invokeMethod<String>('removeNode', {'name': node.name});
  }
}
