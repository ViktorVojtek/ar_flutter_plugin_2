import 'package:vector_math/vector_math_64.dart';

/// Represents a detected plane in the AR scene with comprehensive information
class ARPlane {
  /// Unique identifier for the plane
  final String identifier;

  /// Type of plane (horizontal, vertical, etc.)
  final String type;

  /// Center position of the plane in world coordinates
  final Vector3 center;

  /// Physical dimensions of the plane
  final ARPlaneExtent extent;

  /// 4x4 transformation matrix of the plane
  final Matrix4 transform;

  /// Alignment of the plane (horizontal, vertical)
  final String alignment;

  /// Height of the plane (Y coordinate) - most commonly needed value
  double get height => center.y;

  /// Width of the plane
  double get width => extent.width;

  /// Length/depth of the plane  
  double get length => extent.height;

  ARPlane({
    required this.identifier,
    required this.type,
    required this.center,
    required this.extent,
    required this.transform,
    required this.alignment,
  });

  /// Create ARPlane from platform data
  factory ARPlane.fromMap(Map<String, dynamic> map) {
    final centerMap = map['center'] as Map<String, dynamic>;
    final extentMap = map['extent'] as Map<String, dynamic>;
    final transformList = map['transform'] as List<dynamic>;

    // Convert transform list to Matrix4
    final transformMatrix = Matrix4.fromList(
      transformList.map((e) => (e as num).toDouble()).toList(),
    );

    return ARPlane(
      identifier: map['identifier'] as String,
      type: map['type'] as String,
      center: Vector3(
        (centerMap['x'] as num).toDouble(),
        (centerMap['y'] as num).toDouble(),
        (centerMap['z'] as num).toDouble(),
      ),
      extent: ARPlaneExtent(
        width: (extentMap['width'] as num).toDouble(),
        height: (extentMap['height'] as num).toDouble(),
      ),
      transform: transformMatrix,
      alignment: map['alignment'] as String,
    );
  }

  /// Convert to map for serialization
  Map<String, dynamic> toMap() {
    return {
      'identifier': identifier,
      'type': type,
      'center': {
        'x': center.x,
        'y': center.y,
        'z': center.z,
      },
      'extent': {
        'width': extent.width,
        'height': extent.height,
      },
      'transform': transform.storage.toList(),
      'alignment': alignment,
    };
  }

  @override
  String toString() {
    return 'ARPlane(id: $identifier, type: $type, height: ${height.toStringAsFixed(3)}m, size: ${width.toStringAsFixed(2)}x${length.toStringAsFixed(2)}m, alignment: $alignment)';
  }
}

/// Represents the physical extent/size of a detected plane
class ARPlaneExtent {
  /// Width of the plane in meters
  final double width;

  /// Height/length of the plane in meters
  final double height;

  ARPlaneExtent({
    required this.width,
    required this.height,
  });

  /// Area of the plane in square meters
  double get area => width * height;

  @override
  String toString() {
    return 'ARPlaneExtent(${width.toStringAsFixed(2)}m x ${height.toStringAsFixed(2)}m, area: ${area.toStringAsFixed(2)}m²)';
  }
}
