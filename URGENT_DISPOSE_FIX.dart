// URGENT: Replace your current dispose() method with this corrected version

@override
Future<void> dispose() async {
  debugPrint('AR Screen: === DISPOSE CALLED ===');
  
  // Stop memory monitoring
  _stopMemoryMonitoring();
  
  // 🚀 CRITICAL: Call nukeAll() FIRST, while widget is still mounted
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

  // 🚀 CRITICAL: NOW call super.dispose() AFTER everything is cleaned up
  super.dispose();
  
  debugPrint('AR Screen: ✅ Complete disposal - memory should approach cold start levels');
}

// ALSO fix your _forceDisposeARSession method to be simpler:
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
