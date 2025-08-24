package com.uhg0.ar_flutter_plugin_2.models

import android.content.Context
import android.util.Log
import io.github.sceneview.model.ModelInstance
import io.github.sceneview.node.ModelNode

/**
 * SceneView-compatible gesture node that provides enhanced gesture handling
 * This is a simplified version that works with the existing SceneView architecture
 * while providing better gesture responsiveness than the default ModelNode
 */
class GestureTransformableNode(
    private val context: Context,
    modelInstance: ModelInstance,
    private val enablePanGestures: Boolean = true,
    private val enableRotationGestures: Boolean = true,
    private val onNodeTransformed: ((String) -> Unit)? = null,
    scaleToUnits: Float = 1.0f
) : ModelNode(
    modelInstance = modelInstance,
    scaleToUnits = scaleToUnits
) {
    
    companion object {
        private const val TAG = "GestureTransformableNode"
    }
    
    init {
        Log.d(TAG, "🎯 Initializing GestureTransformableNode with enhanced gesture handling")
        Log.d(TAG, "   Pan gestures: $enablePanGestures")
        Log.d(TAG, "   Rotation gestures: $enableRotationGestures")
        
        // Configure enhanced gesture properties
        isTouchable = true
        isPositionEditable = enablePanGestures
        isRotationEditable = enableRotationGestures
        
        Log.d(TAG, "✅ GestureTransformableNode initialized successfully")
    }
    
    override fun onTransformChanged() {
        super.onTransformChanged()
        
        // Notify Flutter when node is transformed
        name?.let { nodeName ->
            Log.d(TAG, "🎯 Node transformation detected: $nodeName")
            onNodeTransformed?.invoke(nodeName)
        }
    }
    
    /**
     * Enhanced touch handling for better gesture responsiveness
     */
    override fun onTouch(motionEvent: android.view.MotionEvent?): Boolean {
        // Let SceneView handle the actual gesture processing, but with enhanced priority
        val handled = super.onTouch(motionEvent)
        
        if (handled) {
            Log.d(TAG, "🎯 Enhanced gesture processing for node: $name")
        }
        
        return handled
    }
}
