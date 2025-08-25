# Keep all Sceneform classes
-keep class com.google.ar.sceneform.** { *; }
-dontwarn com.google.ar.sceneform.**

# Keep ARCore classes
-keep class com.google.ar.core.** { *; }
-dontwarn com.google.ar.core.**

# Keep animation classes
-keep class com.google.ar.sceneform.animation.** { *; }

# Keep asset loader classes
-keep class com.google.ar.sceneform.assets.** { *; }

# Keep rendering classes
-keep class com.google.ar.sceneform.rendering.** { *; }

# Keep utilities
-keep class com.google.ar.sceneform.utilities.** { *; }

# Keep our plugin classes
-keep class io.flutter.plugins.ar_flutter_plugin_2.** { *; }

# Keep Filament engine classes (used by Sceneform)
-keep class com.google.android.filament.** { *; }
-dontwarn com.google.android.filament.**

# Keep desugar runtime
-keep class com.google.devtools.build.android.desugar.runtime.** { *; }
