#!/bin/bash

echo "🧪 Testing AR Object Deselection Fix"
echo "======================================"

# Check if the auto_placement_test.dart file has the deselection logic
echo "✅ Checking for deselection logic in auto_placement_test.dart..."

if grep -q "_deselectCurrentObject" /Users/viktorvojtek/Projects/ar_flutter_plugin_2/example_app/lib/auto_placement_test.dart; then
    echo "✅ Found _deselectCurrentObject method"
else
    echo "❌ Missing _deselectCurrentObject method"
    exit 1
fi

if grep -q "if (_selectedNodeName != null)" /Users/viktorvojtek/Projects/ar_flutter_plugin_2/example_app/lib/auto_placement_test.dart; then
    echo "✅ Found deselection logic in onPlaneOrPointTap handler"
else
    echo "❌ Missing deselection logic in onPlaneOrPointTap handler"
    exit 1
fi

if grep -q "_selectedNodeName" /Users/viktorvojtek/Projects/ar_flutter_plugin_2/example_app/lib/auto_placement_test.dart; then
    echo "✅ Found selected node tracking variable"
else
    echo "❌ Missing selected node tracking variable"
    exit 1
fi

if grep -q "deselectAllNodes" /Users/viktorvojtek/Projects/ar_flutter_plugin_2/example_app/lib/auto_placement_test.dart; then
    echo "✅ Found call to deselectAllNodes API"
else
    echo "❌ Missing call to deselectAllNodes API"
    exit 1
fi

echo ""
echo "🎉 All deselection components are in place!"
echo ""
echo "📝 How to test the fix:"
echo "1. Run the auto_placement_test.dart app"
echo "2. Place some AR objects using the 'Place' button"
echo "3. Tap on an object to select it (should show green 'Selected:' text)"
echo "4. Tap on empty space/floor (should deselect and show 'Object deselected')"
echo "5. Verify selection UI updates correctly"
echo ""
echo "🔍 Expected behavior:"
echo "• Object tap: Shows 'Selected: [ObjectName]' and selection hint"
echo "• Empty space tap: Shows 'Object deselected - no object currently selected'"
echo "• Visual feedback: Green 'Selected:' text appears/disappears"
echo "• Native level: deselectAllNodes() is called on empty space tap"