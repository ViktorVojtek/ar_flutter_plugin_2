// CRITICAL FIX FOR INSUFFICIENT MEMORY CLEANUP
// This addresses the 1022MB → 966MB issue (only 56MB reduction instead of returning to ~350MB)

// PROBLEM IDENTIFIED: The nukeAll() call is happening AFTER super.dispose()
// This means the widget context is gone and native calls may not execute properly.

// SOLUTION: Call nukeAll() BEFORE super.dispose() and improve scheduling

@override
Future<void> dispose() async {
  debugPrint('AR Screen: === DISPOSE CALLED ===');
  
  // Stop memory monitoring
  _stopMemoryMonitoring();
  
  // CRITICAL: Call nukeAll() FIRST, while widget is still mounted and context is available
  debugPrint('AR Screen: 🚀 CRITICAL FIX: Calling nukeAll() BEFORE super.dispose()');
  try {
    final success = await _sessionController.sessionManager?.nukeAll(
      purgeCaches: true,
      removeExistingAnchors: true,
      resetTracking: true,
    );
    
    if (success != null && success) {
      debugPrint('AR Screen: ✅ nukeAll completed successfully BEFORE disposal');
      // Give extra time for Phase 3 system cleanup
      await Future.delayed(const Duration(milliseconds: 500));
    } else {
      debugPrint('AR Screen: ❌ nukeAll failed or returned null');
    }
  } catch (e) {
    debugPrint('AR Screen: ❌ Error during nukeAll: $e');
  }
  
  // Force dispose the AR session AFTER nukeAll
  _forceDisposeARSession();
  
  // Remove observers and cleanup local state
  WidgetsBinding.instance.removeObserver(this);
  
  // Cleanup local variables
  nodes.clear();
  nodeCreationOrder.clear();
  selectedNode = null;
  _isProcessingNodeSelection = false;
  httpClient?.close();

  // NOW call super.dispose() AFTER everything is cleaned up
  super.dispose();
  
  debugPrint('AR Screen: ✅ Disposal sequence completed - memory should be at cold start levels');
}

// ADDITIONAL FIX: Improve back navigation disposal timing
Widget _buildBackButton() {
  return Positioned(
    top: MediaQuery.of(context).padding.top + 8.0,
    left: 16.0,
    child: Container(
      padding: const EdgeInsets.all(4.0),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha((0.5 * 255).toInt()),
        borderRadius: BorderRadius.circular(32.0),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha((0.2 * 255).toInt()),
            spreadRadius: 2,
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: IconButton(
        icon: const Icon(Icons.arrow_back, color: Colors.white),
        onPressed: () async {
          debugPrint('AR Screen: 🚀 CRITICAL FIX: Back button - immediate nukeAll before navigation');
          
          try {
            // Call nukeAll() immediately while context is still available
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
      ),
    ),
  );
}

// ADDITIONAL FIX: Improve category navigation disposal timing
void _navigateToCategory() async {
  debugPrint('AR Screen: 🚀 CRITICAL FIX: Category navigation - immediate nukeAll');
  
  try {
    // Call nukeAll() immediately while context is still available
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
    Navigator.of(context).pushReplacementNamed('/category', arguments: {'isSearchHeaderShow': true});
  }
}

// REMOVE the _scheduleDelayedARDisposal method entirely - it's causing the problem
// by delaying cleanup until the widget context is gone!

// REMOVE or simplify _forceDisposeARSession to avoid double cleanup
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
