package com.uhg0.ar_flutter_plugin_2.services

import android.content.Context
import android.util.Log
import com.uhg0.ar_flutter_plugin_2.utils.AndroidModelCache
import kotlinx.coroutines.*
import java.util.concurrent.ConcurrentHashMap

/**
 * Service for managing model downloads and caching for AR scenes
 * Handles automatic downloading, validation, and local storage management
 */
class ModelDownloadService(private val context: Context) {
    
    companion object {
        private const val TAG = "ModelDownloadService"
        
        @Volatile
        private var INSTANCE: ModelDownloadService? = null
        
        fun getInstance(context: Context): ModelDownloadService {
            return INSTANCE ?: synchronized(this) {
                INSTANCE ?: ModelDownloadService(context.applicationContext).also { INSTANCE = it }
            }
        }
    }
    
    private val modelCache = AndroidModelCache.getInstance(context)
    private val downloadScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    
    // Track download progress for UI updates
    private val downloadProgress = ConcurrentHashMap<String, DownloadProgress>()
    
    data class DownloadProgress(
        val url: String,
        val isDownloading: Boolean,
        val progress: Float, // 0.0 to 1.0
        val error: String? = null
    )
    
    data class ModelInfo(
        val originalUrl: String,
        val localPath: String,
        val fileSize: Long,
        val downloadTime: Long,
        val isValid: Boolean
    )
    
    /**
     * Download model if not cached, return local path
     */
    suspend fun ensureModelAvailable(modelUrl: String, onProgress: ((Float) -> Unit)? = null): String? {
        Log.d(TAG, "🎯 Ensuring model available: $modelUrl")
        
        // First check if already cached
        modelCache.checkModelCache(modelUrl)?.let { cachedPath ->
            Log.d(TAG, "✅ Model already available locally: $cachedPath")
            onProgress?.invoke(1.0f)
            return cachedPath
        }
        
        // Need to download
        Log.d(TAG, "📥 Model not cached, starting download...")
        
        return try {
            // Update progress
            updateDownloadProgress(modelUrl, true, 0.0f)
            onProgress?.invoke(0.1f)
            
            val startTime = System.currentTimeMillis()
            val localPath = modelCache.downloadAndCacheModel(modelUrl)
            val downloadTime = System.currentTimeMillis() - startTime
            
            if (localPath != null) {
                Log.d(TAG, "✅ Model download completed in ${downloadTime}ms: $localPath")
                updateDownloadProgress(modelUrl, false, 1.0f)
                onProgress?.invoke(1.0f)
                localPath
            } else {
                Log.e(TAG, "❌ Model download failed: $modelUrl")
                updateDownloadProgress(modelUrl, false, 0.0f, "Download failed")
                onProgress?.invoke(0.0f)
                null
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ Exception during model download: ${e.message}")
            updateDownloadProgress(modelUrl, false, 0.0f, e.message)
            onProgress?.invoke(0.0f)
            null
        }
    }
    
    /**
     * Pre-download models in background for better performance
     */
    fun predownloadModels(modelUrls: List<String>) {
        Log.d(TAG, "🚀 Starting predownload for ${modelUrls.size} models")
        
        downloadScope.launch {
            modelUrls.forEach { url ->
                try {
                    // Check if not already cached
                    if (modelCache.checkModelCache(url) == null) {
                        Log.d(TAG, "📥 Predownloading: $url")
                        ensureModelAvailable(url)
                    } else {
                        Log.d(TAG, "⏭️ Skipping predownload (already cached): $url")
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "⚠️ Predownload failed for $url: ${e.message}")
                }
            }
        }
    }
    
    /**
     * Get information about a cached model
     */
    fun getModelInfo(modelUrl: String): ModelInfo? {
        val localPath = modelCache.checkModelCache(modelUrl) ?: return null
        
        return try {
            val file = java.io.File(localPath)
            ModelInfo(
                originalUrl = modelUrl,
                localPath = localPath,
                fileSize = file.length(),
                downloadTime = 0, // Not tracked for existing files
                isValid = file.exists() && file.canRead()
            )
        } catch (e: Exception) {
            Log.w(TAG, "⚠️ Error getting model info: ${e.message}")
            null
        }
    }
    
    /**
     * Get download progress for a specific URL
     */
    fun getDownloadProgress(modelUrl: String): DownloadProgress? {
        return downloadProgress[modelUrl]
    }
    
    /**
     * Get all current download progress
     */
    fun getAllDownloadProgress(): Map<String, DownloadProgress> {
        return downloadProgress.toMap()
    }
    
    /**
     * Clear specific model from cache
     */
    fun clearModel(modelUrl: String): Boolean {
        Log.d(TAG, "🗑️ Clearing cached model: $modelUrl")
        val localPath = modelCache.checkModelCache(modelUrl) ?: return true
        
        return try {
            val file = java.io.File(localPath)
            val deleted = file.delete()
            if (deleted) {
                Log.d(TAG, "✅ Model deleted from cache: $localPath")
                downloadProgress.remove(modelUrl)
            } else {
                Log.w(TAG, "⚠️ Failed to delete model: $localPath")
            }
            deleted
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error deleting model: ${e.message}")
            false
        }
    }
    
    /**
     * Clear all cached models
     */
    fun clearAllModels(): Boolean {
        Log.d(TAG, "🧹 Clearing all cached models")
        val success = modelCache.clearAllCache()
        if (success) {
            downloadProgress.clear()
        }
        return success
    }
    
    /**
     * Get cache statistics
     */
    fun getCacheStats(): Map<String, Any> {
        val cacheStats = modelCache.getCacheStats().toMutableMap()
        cacheStats["activeDownloads"] = downloadProgress.size
        cacheStats["downloadProgress"] = downloadProgress.values.map { 
            mapOf(
                "url" to it.url,
                "isDownloading" to it.isDownloading,
                "progress" to it.progress,
                "error" to it.error
            )
        }
        return cacheStats
    }
    
    /**
     * Cleanup cache and free memory
     */
    fun performMaintenance() {
        Log.d(TAG, "🔧 Performing cache maintenance")
        
        downloadScope.launch {
            try {
                // Clean up old files
                modelCache.cleanupCache()
                
                // Remove completed download progress entries older than 5 minutes
                val fiveMinutesAgo = System.currentTimeMillis() - (5 * 60 * 1000)
                downloadProgress.entries.removeAll { (_, progress) ->
                    !progress.isDownloading && System.currentTimeMillis() > fiveMinutesAgo
                }
                
                Log.d(TAG, "✅ Cache maintenance completed")
            } catch (e: Exception) {
                Log.e(TAG, "❌ Error during maintenance: ${e.message}")
            }
        }
    }
    
    /**
     * Shutdown the service and cancel all downloads
     */
    fun shutdown() {
        Log.d(TAG, "🛑 Shutting down ModelDownloadService")
        downloadScope.cancel()
        downloadProgress.clear()
    }
    
    // Private helper methods
    
    private fun updateDownloadProgress(url: String, isDownloading: Boolean, progress: Float, error: String? = null) {
        downloadProgress[url] = DownloadProgress(url, isDownloading, progress, error)
        
        if (!isDownloading) {
            // Remove completed downloads after a delay to allow UI to show completion
            downloadScope.launch {
                delay(2000) // 2 seconds
                downloadProgress.remove(url)
            }
        }
    }
}