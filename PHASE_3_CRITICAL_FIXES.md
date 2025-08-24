// CRITICAL PHASE 3 MEMORY FIXES FOR AR SCREEN
// Addresses: 1022MB → 966MB (only 56MB reduction) instead of cold start ~350MB

// ==================================================
// FIX 1: DISPOSAL METHOD - Call nukeAll() BEFORE super.dispose()
// ==================================================

/*
REPLACE YOUR CURRENT dispose() METHOD WITH THIS:
*/

@override
Future<void> dispose() async {
  debugPrint('AR Screen: === DISPOSE CALLED ===');
  
  // Stop memory monitoring
  _stopMemoryMonitoring();
  
  // 🚀 CRITICAL FIX: Call nukeAll() FIRST, while widget is still mounted
  debugPrint('AR Screen: 🚀 CRITICAL: Calling nukeAll() BEFORE super.dispose()');
  try {
    final success = await _sessionController.sessionManager?.nukeAll(
      purgeCaches: true,
      removeExistingAnchors: true,
      resetTracking: true,
    );
    
    if (success != null && success) {
      debugPrint('AR Screen: ✅ nukeAll completed BEFORE disposal');
      // Extended wait for Phase 3 system cleanup
      await Future.delayed(const Duration(milliseconds: 500));
    } else {
      debugPrint('AR Screen: ❌ nukeAll failed or returned null');
    }
  } catch (e) {
    debugPrint('AR Screen: ❌ Error during pre-disposal nukeAll: $e');
  }
  
  // Force dispose AR session after nukeAll
  _forceDisposeARSession();
  
  // Remove observers and cleanup
  WidgetsBinding.instance.removeObserver(this);
  
  // Cleanup local state
  nodes.clear();
  nodeCreationOrder.clear();
  selectedNode = null;
  _isProcessingNodeSelection = false;
  httpClient?.close();

  // NOW call super.dispose() AFTER everything is cleaned up
  super.dispose();
  
  debugPrint('AR Screen: ✅ Complete disposal - memory should approach cold start levels');
}

// ==================================================
// FIX 2: BACK BUTTON - Immediate nukeAll() before navigation
// ==================================================

/*
REPLACE YOUR _buildBackButton() onPressed HANDLER WITH:
*/

onPressed: () async {
  debugPrint('AR Screen: 🚀 CRITICAL FIX: Back button - immediate nukeAll');
  
  try {
    // Call nukeAll() immediately while context is available
    final success = await _sessionController.sessionManager?.nukeAll(
      purgeCaches: true,
      removeExistingAnchors: true,
      resetTracking: true,
    );
    
    if (success != null && success) {
      debugPrint('AR Screen: ✅ Back navigation nukeAll completed');
      await Future.delayed(const Duration(milliseconds: 300));
    }
  } catch (e) {
    debugPrint('AR Screen: ❌ Back navigation nukeAll error: $e');
  }
  
  // NOW navigate
  if (mounted) {
    Navigator.of(context).pop();
  }
},

// ==================================================
// FIX 3: CATEGORY NAVIGATION - Immediate nukeAll() before navigation
// ==================================================

/*
REPLACE YOUR _navigateToCategory() METHOD WITH:
*/

void _navigateToCategory() async {
  debugPrint('AR Screen: 🚀 CRITICAL FIX: Category navigation - immediate nukeAll');
  
  try {
    // Call nukeAll() immediately while context is available
    final success = await _sessionController.sessionManager?.nukeAll(
      purgeCaches: true,
      removeExistingAnchors: true,
      resetTracking: true,
    );
    
    if (success != null && success) {
      debugPrint('AR Screen: ✅ Category navigation nukeAll completed');
      await Future.delayed(const Duration(milliseconds: 300));
    }
  } catch (e) {
    debugPrint('AR Screen: ❌ Category navigation nukeAll error: $e');
  }
  
  // NOW navigate
  if (mounted) {
    Navigator.of(context).pushReplacementNamed('/category', 
      arguments: {'isSearchHeaderShow': true});
  }
}

// ==================================================
// FIX 4: REMOVE DELAYED DISPOSAL - It's causing the problem!
// ==================================================

/*
REMOVE THESE METHODS ENTIRELY - they delay cleanup until context is gone:
- _scheduleDelayedARDisposal()  <-- DELETE THIS METHOD
- All calls to _scheduleDelayedARDisposal()  <-- REMOVE ALL CALLS

These delayed calls are the root cause of your memory issue because they
try to call nukeAll() after the widget is unmounted.
*/

// ==================================================
// FIX 5: SIMPLIFIED _forceDisposeARSession()
// ==================================================

/*
REPLACE YOUR _forceDisposeARSession() METHOD WITH:
*/

Future<void> _forceDisposeARSession() async {
  debugPrint('AR Screen: === FORCE DISPOSING AR SESSION ===');
  
  if (_hasBeenDisposed) {
    debugPrint('AR Screen: Already disposed, skipping');
    return;
  }
  
  _shouldRenderARView = false;
  _sessionController.forceDispose();
  _clearARSceneState();
  _hasBeenDisposed = true;

  debugPrint('AR Screen: ✅ AR session forced disposal completed');
}

// ==================================================
// TESTING INSTRUCTIONS
// ==================================================

/*
1. Apply all the above fixes to your AR screen
2. Test the memory cycle:
   - Start app (note baseline memory ~350MB)
   - Navigate to AR screen
   - Add one model (memory jumps to ~1022MB)
   - Remove model from AR scene
   - Navigate away using back button or category navigation
   - Check memory - it should now drop much closer to 350MB instead of staying at 966MB

3. If still insufficient, check console logs for:
   - "📍 ARSessionManager: === PHASE 3 SYSTEM-LEVEL NUKE ALL ==="
   - "✅ nukeAll completed BEFORE disposal"
   - Any error messages during cleanup

4. The key difference: nukeAll() now executes BEFORE the widget unmounts,
   so the native memory pressure simulation can work properly.
*/

// ROOT CAUSE ANALYSIS:
// Your original code called nukeAll() AFTER super.dispose(), meaning:
// 1. Widget was unmounted
// 2. Flutter context was gone  
// 3. Native method channel calls might not execute properly
// 4. Phase 3 system memory pressure couldn't take effect
// 5. Result: Only partial cleanup (56MB reduction vs full ~672MB needed)

// SOLUTION:
// Call nukeAll() BEFORE super.dispose() so:
// 1. Widget is still mounted
// 2. Flutter context is available
// 3. Native calls execute properly  
// 4. Phase 3 system pressure can work
// 5. Result: Should achieve much better memory reduction closer to cold start
