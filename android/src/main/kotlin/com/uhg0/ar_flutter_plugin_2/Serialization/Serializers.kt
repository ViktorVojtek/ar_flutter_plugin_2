package com.uhg0.ar_flutter_plugin_2.Serialization

import com.google.ar.core.HitResult
import com.google.ar.core.Plane
import com.google.ar.core.Pose
import io.github.sceneview.math.Position as ScenePosition
import io.github.sceneview.math.Rotation as SceneRotation
import io.github.sceneview.node.ModelNode
import kotlin.math.sqrt
import kotlin.math.cos
import kotlin.math.sin

fun serializeARCoreHitResult(hitResult: HitResult): HashMap<String, Any> {
    val serializedHit = HashMap<String, Any>()
    
    try {
        // Determine type based on trackable
        when (hitResult.trackable) {
            is Plane -> serializedHit["type"] = 1 // Type plane
            else -> serializedHit["type"] = 2 // Type point (feature points, depth points)
        }
        
        // Calculate distance from camera
        val pose = hitResult.hitPose
        val translation = pose.translation
        val distance = sqrt(
            translation[0] * translation[0] +
            translation[1] * translation[1] +
            translation[2] * translation[2]
        ).toDouble()
        serializedHit["distance"] = distance
        
        // Serialize the world transform matrix
        serializedHit["worldTransform"] = serializePose(pose)
        
    } catch (e: Exception) {
        // Fallback values in case of error
        serializedHit["type"] = 2 // Default to point
        serializedHit["distance"] = 0.0
        serializedHit["worldTransform"] = DoubleArray(16) { if (it % 5 == 0) 1.0 else 0.0 } // Identity matrix
    }
    
    return serializedHit
}

fun serializeHitResult(hit: Map<String, Any>): HashMap<String, Any> {
    val serializedHit = HashMap<String, Any>()
    
    serializedHit["type"] = hit["type"] as Int
    serializedHit["distance"] = hit["distance"] as Double
    
    val position = hit["position"] as Map<String, Double>
    val pose = Pose(
        floatArrayOf(
            position["x"]?.toFloat() ?: 0f,
            position["y"]?.toFloat() ?: 0f,
            position["z"]?.toFloat() ?: 0f
        ),
        floatArrayOf(0f, 0f, 0f, 1f)
    )
    
    serializedHit["worldTransform"] = serializePose(pose)
    return serializedHit
}

fun serializePose(pose: Pose): DoubleArray {
    val serializedPose = FloatArray(16)
    pose.toMatrix(serializedPose, 0)
    return DoubleArray(16) { serializedPose[it].toDouble() }
} 

fun serializeLocalTransformation(node: ModelNode?): Map<String, Any?>? {
    // Return null if node is null to avoid sending null values to Flutter
    if (node?.name == null) {
        return null
    }
    
    val transform = node.transform
    val pos = transform.position
    val rot = transform.rotation
    val scale = transform.scale
    
    // Create transformation matrix from position, rotation, and scale
    // This is a simplified version that mainly preserves position
    val matrix = floatArrayOf(
        scale.x, 0.0f, 0.0f, pos.x,
        0.0f, scale.y, 0.0f, pos.y,
        0.0f, 0.0f, scale.z, pos.z,
        0.0f, 0.0f, 0.0f, 1.0f
    )
    
    return mapOf(
        "name" to node.name,
        "transform" to matrix.map { it.toDouble() }
    )
}