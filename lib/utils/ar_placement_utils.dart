import 'package:vector_math/vector_math_64.dart';
import 'dart:math' as math;

/// Utility class for calculating optimal AR object placement based on object characteristics
class ARObjectPlacementUtils {
  
  /// Calculate optimal placement position based on object scale and size type
  /// 
  /// This addresses the issue where large objects (pergolas) are placed too close
  /// and small objects (grills) might be placed too far away.
  /// 
  /// [objectScale] - The scale vector of the object
  /// [sizeType] - Size category: 'BIG', 'MEDIUM', 'SMALL' (default: 'MEDIUM')
  /// [userHeight] - Estimated user height for better positioning (default 1.7m)
  static Vector3 calculateOptimalPlacement(
    Vector3 objectScale, {
    String sizeType = 'MEDIUM',
    double userHeight = 1.7,
  }) {
    // Calculate object size (max dimension)
    double maxDimension = math.max(
      math.max(objectScale.x, objectScale.y), 
      objectScale.z
    );
    
    // Calculate volume for better size estimation
    double volume = objectScale.x * objectScale.y * objectScale.z;
    
    // Determine placement distance based on object characteristics
    double distance;
    double height;
    
    // Apply size type specific adjustments first
    switch (sizeType.toUpperCase()) {
      case 'BIG':
        distance = 4.0 + (maxDimension * 0.4); // Place far away (4+ meters in front)
        height = 0.2; // Slightly above ground
        break;
      case 'SMALL':
        distance = 1.5 + (maxDimension * 0.3); // Place closer (1.5+ meters in front)
        height = 0.0; // At ground level
        break;
      case 'MEDIUM':
      default:
        distance = 2.5 + (maxDimension * 0.4); // Medium distance (2.5+ meters in front)
        height = 0.1; // Slightly above ground
        break;
    }
    
    // Fine-tune based on actual dimensions
    if (maxDimension > 3.0 || volume > 8.0) {
      // Very large objects: ensure they're placed far enough
      distance = math.max(distance, 4.5); // At least 4.5m in front
      height = 0.3; // Above ground
    } else if (maxDimension > 2.0 || volume > 2.0) {
      // Large objects: moderate adjustments
      distance = math.max(distance, 3.0); // At least 3.0m in front
      height = 0.2; // Slightly above ground
    } else if (maxDimension > 1.0 || volume > 0.5) {
      // Medium objects: minor adjustments
      distance = math.min(distance, 2.5); // Max 2.5m in front
      height = 0.1; // Just above ground
    } else {
      // Small objects: bring closer if needed
      distance = math.min(distance, 1.5); // Max 1.5m in front
      height = 0.0; // At ground level
    }
    
    // Ensure reasonable bounds
    distance = math.min(distance, 6.0); // Never farther than 6m in front
    distance = math.max(distance, 1.0); // Never closer than 1m in front
    height = math.min(height, 1.0); // Never too high
    height = math.max(height, 0.0); // Never below ground
    
    return Vector3(0.0, height, distance); // X=0, Y=height above ground, Z=distance in front of camera
  }
  
  /// Calculate optimal distance from camera based on size type and scale
  static double calculateOptimalDistance(String sizeType, Vector3 objectScale) {
    double maxDimension = math.max(
      math.max(objectScale.x, objectScale.y), 
      objectScale.z
    );
    
    double distance;
    switch (sizeType.toUpperCase()) {
      case 'BIG':
        distance = 4.0 + (maxDimension * 0.5); // Place far away
        break;
      case 'SMALL':
        distance = 1.5 + (maxDimension * 0.3); // Place closer
        break;
      case 'MEDIUM':
      default:
        distance = 2.5 + (maxDimension * 0.4); // Medium distance
        break;
    }
    
    // Ensure reasonable bounds
    distance = math.min(distance, 6.0); // Never farther than 6m
    distance = math.max(distance, 1.0); // Never closer than 1m
    
    return distance;
  }
  
  /// Calculate height offset above ground based on size type and scale
  static double calculateHeightOffset(String sizeType, Vector3 objectScale) {
    // For now, place all objects on the ground
    // Future enhancement: could adjust based on object type or size
    double height;
    switch (sizeType.toUpperCase()) {
      case 'BIG':
        height = 0.0; // Place on ground for large objects
        break;
      case 'SMALL':
        height = 0.0; // Place on ground for small objects
        break;
      case 'MEDIUM':
      default:
        height = 0.0; // Place on ground by default
        break;
    }
    
    // Ensure reasonable bounds
    height = math.min(height, 0.5); // Never more than 0.5m above ground
    height = math.max(height, 0.0); // Never below ground
    
    return height;
  }
  
  /// Calculate collision size multiplier based on object characteristics
  /// 
  /// This helps make large objects easier to select and manipulate
  /// 
  /// [objectScale] - The scale vector of the object
  /// Returns multiplier for collision box size (1.0 = no change, >1.0 = larger)
  static double calculateCollisionMultiplier(Vector3 objectScale) {
    double maxDimension = math.max(
      math.max(objectScale.x, objectScale.y), 
      objectScale.z
    );
    
    // Larger objects get larger collision multipliers for easier interaction
    if (maxDimension > 3.0) {
      return 2.0; // Very large objects: 2x collision size
    } else if (maxDimension > 2.0) {
      return 1.7; // Large objects: 1.7x collision size
    } else if (maxDimension > 1.0) {
      return 1.4; // Medium objects: 1.4x collision size
    } else {
      return 1.1; // Small objects: 1.1x collision size
    }
  }
  
  /// Get recommended minimum distance from camera for an object
  /// 
  /// [objectScale] - The scale vector of the object
  /// Returns minimum safe distance in meters
  static double getMinimumViewingDistance(Vector3 objectScale) {
    double maxDimension = math.max(
      math.max(objectScale.x, objectScale.y), 
      objectScale.z
    );
    
    // Rule of thumb: minimum distance should be 1.5x the largest dimension
    // but at least 1 meter and at most 5 meters
    double minDistance = maxDimension * 1.5;
    return math.max(1.0, math.min(minDistance, 5.0));
  }
  
  /// Check if an object is considered "large" and needs special handling
  /// 
  /// [objectScale] - The scale vector of the object
  /// Returns true if object should be treated as large
  static bool isLargeObject(Vector3 objectScale) {
    double maxDimension = math.max(
      math.max(objectScale.x, objectScale.y), 
      objectScale.z
    );
    double volume = objectScale.x * objectScale.y * objectScale.z;
    
    return maxDimension > 2.0 || volume > 2.0;
  }
  
  /// Get object size category for logging/debugging
  /// 
  /// [objectScale] - The scale vector of the object
  /// Returns size category as string
  static String getObjectSizeCategory(Vector3 objectScale) {
    double maxDimension = math.max(
      math.max(objectScale.x, objectScale.y), 
      objectScale.z
    );
    
    if (maxDimension > 3.0) {
      return "Very Large";
    } else if (maxDimension > 2.0) {
      return "Large";
    } else if (maxDimension > 1.0) {
      return "Medium";
    } else {
      return "Small";
    }
  }
}
