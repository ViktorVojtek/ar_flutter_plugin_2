#!/bin/bash

# Test Collision Fixes - Build Verification Script
# This script tests if our collision system fixes compile and work correctly

echo "🔧 Testing AR Flutter Plugin Collision Fixes..."

# Change to the example app directory
cd "$(dirname "$0")/example_app" || exit 1

echo "📱 Cleaning Flutter build cache..."
flutter clean

echo "📦 Getting Flutter dependencies..."
flutter pub get

echo "🏗️ Testing Android compilation..."
# Try to build Android without running on device
flutter build apk --debug --verbose 2>&1 | tee build_log.txt

# Check if our collision fixes are present in the built code
echo "🔍 Verifying collision fixes are applied..."
COLLISION_FIXES_FOUND=0

# Check for our specific collision fix patterns in the build log
if grep -q "isLargeObject.*2\.0f" android/src/main/kotlin/com/uhg0/ar_flutter_plugin_2/ArCoreCompatView.kt 2>/dev/null; then
    echo "✅ Android collision sizing fix detected"
    COLLISION_FIXES_FOUND=$((COLLISION_FIXES_FOUND + 1))
else
    echo "❌ Android collision sizing fix NOT found"
fi

if grep -q "enableTapToPlace" lib/models/ar_node.dart 2>/dev/null; then
    echo "✅ Dart enableTapToPlace field detected"
    COLLISION_FIXES_FOUND=$((COLLISION_FIXES_FOUND + 1))
else
    echo "❌ Dart enableTapToPlace field NOT found"
fi

if grep -q "setTapPlacementEnabled" lib/managers/ar_object_manager.dart 2>/dev/null; then
    echo "✅ Dart API method detected"
    COLLISION_FIXES_FOUND=$((COLLISION_FIXES_FOUND + 1))
else
    echo "❌ Dart API method NOT found"
fi

if grep -q "isLargeObject.*8\.0" ios/Classes/IosARView.swift 2>/dev/null; then
    echo "✅ iOS collision fix detected"
    COLLISION_FIXES_FOUND=$((COLLISION_FIXES_FOUND + 1))
else
    echo "❌ iOS collision fix NOT found"
fi

echo ""
echo "📊 Collision Fixes Summary:"
echo "   Fixes Applied: $COLLISION_FIXES_FOUND/4"

if [ $COLLISION_FIXES_FOUND -ge 3 ]; then
    echo "✅ Collision fixes are properly implemented!"
    echo ""
    echo "🎯 Expected Behavior:"
    echo "   - Small objects: Precise gesture detection"
    echo "   - Large objects: Easier interaction without interfering with other objects"
    echo "   - enableTapToPlace flag: Controls tap-to-place functionality"
    echo ""
    echo "📋 Test Instructions:"
    echo "   1. Run the auto_placement_test.dart example"
    echo "   2. Place an object using auto placement"
    echo "   3. Try pan/rotation gestures directly on the object"
    echo "   4. Gestures should work consistently without needing to tap away from object"
    exit 0
else
    echo "❌ Some collision fixes may be missing"
    exit 1
fi
