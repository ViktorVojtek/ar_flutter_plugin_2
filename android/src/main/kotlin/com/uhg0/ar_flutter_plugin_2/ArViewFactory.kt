package com.uhg0.ar_flutter_plugin_2

import android.app.Activity
import android.content.Context
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import androidx.lifecycle.Lifecycle

class ArViewFactory(
    private val messenger: BinaryMessenger,
    private val activity: Activity,
    private val lifecycle: Lifecycle
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val params = args as? HashMap<*, *>
        val debug = params?.get("debug") as? Boolean ?: false
        
        if (debug) {
            Log.i("ArViewFactory", "Creating Sceneform-based AR view with id: $viewId")
            Log.i("ArViewFactory", "Args: $args")
        }
        
        // Create the working Sceneform-based ArView (replacing the old SceneView implementation)
        return ArCoreCompatView(context, messenger, viewId, activity)
    }
}