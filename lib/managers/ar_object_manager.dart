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

/// ARCore-style gesture callback for transformed nodes
typedef NodeTransformedHandler = void Function(String nodeName, Vector3 position, Vector4 rotation);

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

  /// ARCore-style gesture callback for when a transformable node is moved via gestures
  NodeTransformedHandler? onNodeTransformed;

  ARObjectManager(int id, {this.debug = false}) {
    print("🏗️ ARObjectManager constructor called with id: $id");
    _channel = MethodChannel('arobjects_$id');
    _channel.setMethodCallHandler(_platformCallHandler);
    print("📡 Method channel 'arobjects_$id' set up");
    if (debug) {
      print("ARObjectManager initialized");
    }
    print("✅ ARObjectManager constructor completed");
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
        case 'onEmptySpaceTap':
          // Fallback event for when normal plane/point tap fails
          // This can be used for deselecting objects
          if (debug) {
            print('🎯 Received onEmptySpaceTap - this can be used for deselecting objects');
          }
          // You can add a callback here for empty space taps if needed
          // For example: onEmptySpaceTap?.call();
          break;
        case 'onNodeTransformed':
          if (onNodeTransformed != null) {
            if (debug) {
              print('[ARObjectManager] Received onNodeTransformed callback');
            }
            try {
              final args = call.arguments;
              if (args != null && args is Map) {
                final Map<String, dynamic> argsMap = Map<String, dynamic>.from(args);
                final String nodeName = argsMap['nodeName'] as String;
                
                final List positionList = argsMap['position'] as List;
                final Vector3 position = Vector3(
                  (positionList[0] as num).toDouble(),
                  (positionList[1] as num).toDouble(), 
                  (positionList[2] as num).toDouble()
                );
                
                final List rotationList = argsMap['rotation'] as List;
                final Vector4 rotation = Vector4(
                  (rotationList[0] as num).toDouble(),
                  (rotationList[1] as num).toDouble(),
                  (rotationList[2] as num).toDouble(),
                  (rotationList[3] as num).toDouble()
                );
                
                if (debug) {
                  print('[ARObjectManager] Node $nodeName transformed - Position: $position, Rotation: $rotation');
                }
                onNodeTransformed!(nodeName, position, rotation);
              }
            } catch (e) {
              if (debug) {
                print('[ARObjectManager] Error handling onNodeTransformed: $e');
              }
            }
          } else if (debug) {
            print('[ARObjectManager] WARNING: onNodeTransformed callback received but no handler set!');
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
    print("🎯 ARObjectManager.onInitialize called");
    print("📤 Calling _channel.invokeMethod('init', {})");
    _channel.invokeMethod<void>('init', {});
    print("📤 ARObjectManager init method call completed");
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

  /// Deep-destroy native + GPU resources for this node
  Future<bool> removeNodeDeep(String nodeId) async {
    try {
      final result = await _channel.invokeMethod<bool>('removeNodeDeep', {'nodeId': nodeId});
      return result ?? false;
    } catch (e) {
      if (debug) {
        print('Error in removeNodeDeep: $e');
      }
      return false;
    }
  }

  /// Purge GLTF/material/texture caches on the native side
  Future<bool> purgeCaches() async {
    try {
      final result = await _channel.invokeMethod<bool>('purgeCaches', {});
      return result ?? false;
    } catch (e) {
      if (debug) {
        print('Error in purgeCaches: $e');
      }
      return false;
    }
  }

  /// Create node that SHARES already-decoded asset by URI (no duplicate decode)
  Future<String?> createNodeFromAsset({
    required String uri,
    required Float64List transformMatrix,
  }) async {
    try {
      final result = await _channel.invokeMethod<String>('createNodeFromAsset', {
        'uri': uri,
        'transformMatrix': transformMatrix,
      });
      return result;
    } catch (e) {
      if (debug) {
        print('Error in createNodeFromAsset: $e');
      }
      return null;
    }
  }

  /// Optional: expose memory info for diagnostics
  Future<Map<String, dynamic>> getMemoryInfo() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('getMemoryInfo', {});
      return Map<String, dynamic>.from(result ?? {});
    } catch (e) {
      if (debug) {
        print('Error in getMemoryInfo: $e');
      }
      return {};
    }
  }
}
