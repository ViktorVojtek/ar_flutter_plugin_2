package com.uhg0.ar_flutter_plugin_2.Serialization

import com.google.ar.core.HitResult
import com.google.ar.core.Plane
import com.google.ar.core.Pose
import io.github.sceneview.math.Position as ScenePosition
import io.github.sceneview.math.Rotation as SceneRotation
import io.github.sceneview.node.ModelNode
import kotlin.math.sqrt

fun serializeARCoreHitResult(hitResult: HitResult): HashMap<String, Any> {
    val serializedHit = HashMap<String, Any>()
    
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
    val matrix = floatArrayOf(
        transform.matrix.get(0, 0), transform.matrix.get(0, 1), transform.matrix.get(0, 2), transform.matrix.get(0, 3),
        transform.matrix.get(1, 0), transform.matrix.get(1, 1), transform.matrix.get(1, 2), transform.matrix.get(1, 3),
        transform.matrix.get(2, 0), transform.matrix.get(2, 1), transform.matrix.get(2, 2), transform.matrix.get(2, 3),
        transform.matrix.get(3, 0), transform.matrix.get(3, 1), transform.matrix.get(3, 2), transform.matrix.get(3, 3)
    )
    
    return mapOf(
        "name" to node.name,
        "transform" to matrix.map { it.toDouble() }
    )
}