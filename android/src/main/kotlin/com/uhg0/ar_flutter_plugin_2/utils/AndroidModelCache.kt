package com.uhg0.ar_flutter_plugin_2.utils

import android.content.Context
import android.util.Log
import kotlinx.coroutines.*
import java.io.*
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

/**
 * Android model cache manager for downloading and storing 3D models locally
 * This solves texture loading issues by keeping models in device storage instead of memory
 */
class AndroidModelCache private constructor(private val context: Context) {
    
    companion object {
        private const val TAG = "AndroidModelCache"
        private const val CACHE_DIR_NAME = "ar_models"
        private const val MAX_CACHE_SIZE_MB = 200L // 200MB cache limit
        private const val MAX_DOWNLOAD_SIZE_MB = 50L // 50MB per model limit
        private const val CHUNK_SIZE = 8192 // 8KB chunks for downloads
        
        @Volatile
        private var INSTANCE: AndroidModelCache? = null
        
        fun getInstance(context: Context): AndroidModelCache {
            return INSTANCE ?: synchronized(this) {
                INSTANCE ?: AndroidModelCache(context.applicationContext).also { INSTANCE = it }
            }
        }
    }
    
    // Track active downloads to prevent duplicates
    private val activeDownloads = ConcurrentHashMap<String, CompletableDeferred<String?>>()
    
    // Get the cache directory
    private val cacheDir: File by lazy {
        File(context.cacheDir, CACHE_DIR_NAME).apply {
            if (!exists()) {
                mkdirs()
                Log.d(TAG, "Created cache directory: $absolutePath")
            }
        }
    }
    
    /**
     * Download and cache a model from URL
     * Returns the local file path on success, null on failure
     */
    suspend fun downloadAndCacheModel(modelUrl: String): String? = withContext(Dispatchers.IO) {
        Log.d(TAG, "📥 Requesting download for: $modelUrl")
        
        val cacheKey = generateCacheKey(modelUrl)
        val localFile = File(cacheDir, "$cacheKey.${getFileExtension(modelUrl)}")
        
        // Check if file already exists and is valid
        if (localFile.exists() && isValidModelFile(localFile)) {
            Log.d(TAG, "✅ Model already cached: ${localFile.absolutePath}")
            return@withContext localFile.absolutePath
        }
        
        // Check if download is already in progress
        activeDownloads[cacheKey]?.let { existingDownload ->
            Log.d(TAG, "⏳ Download already in progress for: $modelUrl")
            return@withContext existingDownload.await()
        }
        
        // Start new download
        val downloadDeferred = CompletableDeferred<String?>()
        activeDownloads[cacheKey] = downloadDeferred
        
        try {
            val downloadedPath = performDownload(modelUrl, localFile)
            downloadDeferred.complete(downloadedPath)
            downloadedPath
        } catch (e: Exception) {
            Log.e(TAG, "❌ Download failed for $modelUrl: ${e.message}")
            downloadDeferred.complete(null)
            null
        } finally {
            activeDownloads.remove(cacheKey)
        }
    }
    
    /**
     * Check if a model is cached locally
     * Returns the local file path if cached, null otherwise
     */
    fun checkModelCache(modelUrl: String): String? {
        val cacheKey = generateCacheKey(modelUrl)
        val localFile = File(cacheDir, "$cacheKey.${getFileExtension(modelUrl)}")
        
        return if (localFile.exists() && isValidModelFile(localFile)) {
            Log.d(TAG, "✅ Model found in cache: ${localFile.absolutePath}")
            // Update access time for LRU cleanup
            localFile.setLastModified(System.currentTimeMillis())
            localFile.absolutePath
        } else {
            Log.d(TAG, "❌ Model not in cache: $modelUrl")
            null
        }
    }
    
    /**
     * Clear all cached models
     */
    fun clearAllCache(): Boolean {
        return try {
            Log.d(TAG, "🧹 Clearing all cached models")
            val deleted = cacheDir.listFiles()?.map { it.delete() }?.all { it } ?: true
            if (deleted) {
                Log.d(TAG, "✅ Cache cleared successfully")
            } else {
                Log.w(TAG, "⚠️ Some files could not be deleted")
            }
            deleted
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error clearing cache: ${e.message}")
            false
        }
    }
    
    /**
     * Clean up old cached files to stay within size limits
     */
    fun cleanupCache() {
        try {
            val files = cacheDir.listFiles() ?: return
            val totalSize = files.sumOf { it.length() }
            val maxSizeBytes = MAX_CACHE_SIZE_MB * 1024 * 1024
            
            Log.d(TAG, "🔍 Cache size: ${totalSize / 1024 / 1024}MB / ${MAX_CACHE_SIZE_MB}MB")
            
            if (totalSize > maxSizeBytes) {
                Log.d(TAG, "🧹 Cache size exceeded, cleaning up old files")
                
                // Sort by last modified (LRU)
                val sortedFiles = files.sortedBy { it.lastModified() }
                var currentSize = totalSize
                
                for (file in sortedFiles) {
                    if (currentSize <= maxSizeBytes) break
                    
                    val fileSize = file.length()
                    if (file.delete()) {
                        currentSize -= fileSize
                        Log.d(TAG, "🗑️ Deleted old cache file: ${file.name}")
                    }
                }
                
                Log.d(TAG, "✅ Cache cleanup completed. New size: ${currentSize / 1024 / 1024}MB")
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error during cache cleanup: ${e.message}")
        }
    }
    
    /**
     * Get cache statistics
     */
    fun getCacheStats(): Map<String, Any> {
        return try {
            val files = cacheDir.listFiles() ?: emptyArray()
            val totalSize = files.sumOf { it.length() }
            
            mapOf(
                "fileCount" to files.size as Any,
                "totalSizeMB" to (totalSize / 1024.0 / 1024.0) as Any,
                "maxSizeMB" to MAX_CACHE_SIZE_MB as Any,
                "cacheDir" to cacheDir.absolutePath as Any
            )
        } catch (e: Exception) {
            mapOf("error" to (e.message as Any))
        }
    }
    
    // Private implementation methods
    
    private suspend fun performDownload(modelUrl: String, localFile: File): String? = withContext(Dispatchers.IO) {
        Log.d(TAG, "🔄 Starting download: $modelUrl -> ${localFile.absolutePath}")
        
        var connection: HttpURLConnection? = null
        var inputStream: InputStream? = null
        var outputStream: FileOutputStream? = null
        var tempFile: File? = null
        
        try {
            // Create temporary file for atomic download
            tempFile = File(localFile.parentFile, "${localFile.name}.tmp")
            
            // Setup connection
            val url = URL(modelUrl)
            connection = url.openConnection() as HttpURLConnection
            connection.apply {
                connectTimeout = 30000 // 30 seconds
                readTimeout = 60000 // 60 seconds
                requestMethod = "GET"
                setRequestProperty("Accept", "application/octet-stream, */*")
                setRequestProperty("User-Agent", "AR-Flutter-Plugin-Android")
            }
            
            val responseCode = connection.responseCode
            if (responseCode != HttpURLConnection.HTTP_OK) {
                Log.e(TAG, "❌ HTTP error $responseCode for $modelUrl")
                return@withContext null
            }
            
            val contentLength = connection.contentLengthLong
            val maxSizeBytes = MAX_DOWNLOAD_SIZE_MB * 1024 * 1024
            
            if (contentLength > maxSizeBytes) {
                Log.e(TAG, "❌ Model too large: ${contentLength / 1024 / 1024}MB > ${MAX_DOWNLOAD_SIZE_MB}MB")
                return@withContext null
            }
            
            inputStream = connection.inputStream
            outputStream = FileOutputStream(tempFile)
            
            val buffer = ByteArray(CHUNK_SIZE)
            var totalBytesRead = 0L
            var bytesRead: Int
            
            Log.d(TAG, "📥 Downloading ${contentLength / 1024 / 1024}MB...")
            
            while (inputStream.read(buffer).also { bytesRead = it } != -1) {
                outputStream.write(buffer, 0, bytesRead)
                totalBytesRead += bytesRead
                
                // Size safety check during download
                if (totalBytesRead > maxSizeBytes) {
                    Log.e(TAG, "❌ Download size exceeded limit during transfer")
                    return@withContext null
                }
                
                // Log progress for large files
                if (contentLength > 0 && totalBytesRead % (1024 * 1024) == 0L) {
                    val progress = (totalBytesRead * 100 / contentLength)
                    Log.d(TAG, "📥 Download progress: $progress%")
                }
            }
            
            outputStream.flush()
            outputStream.close()
            outputStream = null
            
            // Verify downloaded file
            if (!isValidModelFile(tempFile)) {
                Log.e(TAG, "❌ Downloaded file failed validation")
                return@withContext null
            }
            
            // Atomic move to final location
            if (tempFile.renameTo(localFile)) {
                Log.d(TAG, "✅ Download completed successfully: ${localFile.absolutePath}")
                Log.d(TAG, "📊 File size: ${localFile.length() / 1024 / 1024}MB")
                
                // Cleanup old files if needed
                cleanupCache()
                
                return@withContext localFile.absolutePath
            } else {
                Log.e(TAG, "❌ Failed to move temp file to final location")
                return@withContext null
            }
            
        } catch (e: Exception) {
            Log.e(TAG, "❌ Download exception: ${e.message}")
            return@withContext null
        } finally {
            try {
                outputStream?.close()
                inputStream?.close()
                connection?.disconnect()
                tempFile?.takeIf { it.exists() }?.delete()
            } catch (e: Exception) {
                Log.w(TAG, "⚠️ Error cleaning up download resources: ${e.message}")
            }
        }
    }
    
    private fun generateCacheKey(url: String): String {
        return try {
            val digest = MessageDigest.getInstance("SHA-256")
            val hashBytes = digest.digest(url.toByteArray())
            hashBytes.joinToString("") { "%02x".format(it) }.take(16) // Take first 16 chars
        } catch (e: Exception) {
            Log.w(TAG, "⚠️ Error generating cache key, using simple hash")
            url.hashCode().toString()
        }
    }
    
    private fun getFileExtension(url: String): String {
        return when {
            url.lowercase().contains(".glb") -> "glb"
            url.lowercase().contains(".gltf") -> "gltf"
            else -> "glb" // Default to GLB
        }
    }
    
    private fun isValidModelFile(file: File): Boolean {
        return try {
            file.exists() && 
            file.length() > 100 && // At least 100 bytes
            file.canRead() &&
            (file.name.endsWith(".glb") || file.name.endsWith(".gltf"))
        } catch (e: Exception) {
            Log.w(TAG, "⚠️ Error validating model file: ${e.message}")
            false
        }
    }
}