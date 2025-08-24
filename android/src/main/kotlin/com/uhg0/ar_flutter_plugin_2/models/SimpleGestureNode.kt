package com.uhg0.ar_flutter_plugin_2.models

import android.content.Context
import android.util.Log
import io.github.sceneview.model.ModelInstance
import io.github.sceneview.node.ModelNode

/**
 * Simple gesture node with basic SceneView compatibility
 * Fallback implementation for basic gesture handling
 */
class SimpleGestureNode(
    private val context: Context,
    modelInstance: ModelInstance,
    scaleToUnits: Float = 1.0f
) : ModelNode(
    modelInstance = modelInstance,
    scaleToUnits = scaleToUnits
) {
    
    companion object {
        private const val TAG = "SimpleGestureNode"
    }
    
    init {
        Log.d(TAG, "🎯 Initializing SimpleGestureNode")
        
        // Configure basic gesture properties
        isTouchable = true
        isPositionEditable = true
        isRotationEditable = true
        
        Log.d(TAG, "✅ SimpleGestureNode initialized")
    }
}
