package com.uhg0.ar_flutter_plugin_2

import android.app.Activity
import android.util.Log
import android.content.Context
import androidx.activity.ComponentActivity
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import androidx.lifecycle.Lifecycle
import io.flutter.plugin.common.BinaryMessenger

class ArViewFactory(
    private val messenger: BinaryMessenger,
    private val activity: Activity,
    private val lifecycle: Lifecycle
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val componentActivity = when {
            activity is ComponentActivity -> activity as ComponentActivity
            context is ComponentActivity -> context
            else -> null
        }

        if (componentActivity == null) {
            Log.w("ArViewFactory", "Using ARSceneView without ComponentActivity host; lifecycle features may be limited.")
        }

        return ArCoreCompatView(context, messenger, viewId, componentActivity, lifecycle)
    }
}
