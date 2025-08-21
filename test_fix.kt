// Test file to validate the Pose.toMatrix fix
import com.google.ar.core.Pose

fun testPoseMatrix(pose: Pose): List<Double> {
    // This is the pattern we fixed - using toMatrix() method
    return run {
        val matrix = FloatArray(16)
        pose.toMatrix(matrix, 0)
        matrix.map { it.toDouble() }
    }
}

// This would be the broken pattern that caused the original error:
// fun testPoseMatrixBroken(pose: Pose): List<Any> {
//     return listOf(
//         pose.matrix[0], pose.matrix[1], pose.matrix[2], pose.matrix[3],
//         pose.matrix[4], pose.matrix[5], pose.matrix[6], pose.matrix[7],
//         pose.matrix[8], pose.matrix[9], pose.matrix[10], pose.matrix[11],
//         pose.matrix[12], pose.matrix[13], pose.matrix[14], pose.matrix[15]
//     )
// }
