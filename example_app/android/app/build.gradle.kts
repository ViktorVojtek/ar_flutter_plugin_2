plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.example_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.example_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 28  // Updated to match ar_flutter_plugin_2 requirement
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        
        // Exclude 32-bit ABIs to comply with Google Play's 16KB page size requirement
        // ARCore SDK 1.44.0 has non-compliant 32-bit libraries (armeabi-v7a)
        // Modern Android devices (2019+) are 64-bit, so this only affects very old devices
        ndk {
            abiFilters.addAll(listOf("arm64-v8a", "x86_64"))
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
    
    packaging {
        // Forcefully exclude 32-bit native libraries at packaging stage
        // This ensures ARCore SDK's 32-bit libraries are not included in the APK/AAB
        jniLibs {
            excludes.add("lib/armeabi-v7a/**")
            excludes.add("lib/x86/**")
        }
        resources {
            excludes.add("/META-INF/{AL2.0,LGPL2.1}")
        }
    }
}

flutter {
    source = "../.."
}
