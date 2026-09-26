package com.example.scanner_pro

import android.content.ContentValues
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "scanner_pro/downloads"
    private var pendingOpenIntent: Intent? = null
    private var methodChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        pendingOpenIntent = intent
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        methodChannel!!
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getIncomingFile" -> {
                        val files = copyIncomingFiles()
                        result.success(
                            when (files.size) {
                                0 -> null
                                1 -> files.first()
                                else -> files
                            },
                        )
                    }
                    "saveFile" -> {
                        val fileName = call.argument<String>("fileName") ?: "download"
                        val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
                        val bytes = call.argument<ByteArray>("bytes") ?: byteArrayOf()

                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            val uniqueFileName = nextAvailableDisplayName(fileName)
                            val values = ContentValues().apply {
                                put(MediaStore.MediaColumns.DISPLAY_NAME, uniqueFileName)
                                put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                                put(
                                    MediaStore.MediaColumns.RELATIVE_PATH,
                                    Environment.DIRECTORY_DOWNLOADS,
                                )
                            }

                            val resolver = contentResolver
                            val uri = resolver.insert(
                                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                                values,
                            )
                            if (uri == null) {
                                result.error("SAVE_FAILED", "Could not create a Downloads entry", null)
                                return@setMethodCallHandler
                            }

                            try {
                                resolver.openOutputStream(uri)?.use { output ->
                                    output.write(bytes)
                                } ?: throw IllegalStateException("Could not open the Downloads entry")
                            } catch (error: Exception) {
                                resolver.delete(uri, null, null)
                                result.error("SAVE_FAILED", error.message, null)
                                return@setMethodCallHandler
                            }

                            result.success(
                                File(
                                    Environment.getExternalStoragePublicDirectory(
                                        Environment.DIRECTORY_DOWNLOADS,
                                    ),
                                    uniqueFileName,
                                ).absolutePath,
                            )
                        } else {
                            val file = File(
                                Environment.getExternalStoragePublicDirectory(
                                    Environment.DIRECTORY_DOWNLOADS,
                                ),
                                nextAvailableFileName(fileName),
                            )
                            file.parentFile?.mkdirs()
                            file.writeBytes(bytes)
                            result.success(file.absolutePath)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        pendingOpenIntent = intent
        methodChannel?.invokeMethod("incomingFileAvailable", null)
    }

    private fun copyIncomingFiles(): List<Map<String, String>> {
        val incomingIntent = pendingOpenIntent ?: return emptyList()
        pendingOpenIntent = null
        val resolver = contentResolver
        return incomingUris(incomingIntent).mapNotNull { uri ->
            val mimeType = resolver.getType(uri) ?: "application/octet-stream"
            val providerName = queryDisplayName(uri) ?: "imported_document"
            val providerExtension = providerName.substringAfterLast('.', "")
            val extension = providerExtension.takeIf { it.isNotEmpty() }
                ?: mimeTypeToExtension(mimeType)
            val displayName = if (providerExtension.isEmpty()) {
                "$providerName.$extension"
            } else {
                providerName
            }
            val target = File(
                cacheDir,
                "scanner_import_${System.currentTimeMillis()}_${uri.hashCode()}.$extension",
            )

            try {
                resolver.openInputStream(uri)?.use { input ->
                    target.outputStream().use { output -> input.copyTo(output) }
                } ?: return@mapNotNull null
                mapOf(
                    "path" to target.absolutePath,
                    "name" to displayName,
                    "mimeType" to mimeType,
                )
            } catch (_: Exception) {
                target.delete()
                null
            }
        }
    }

    private fun incomingUris(intent: Intent): List<Uri> {
        val uris = linkedSetOf<Uri>()
        intent.data?.let(uris::add)

        if (intent.action == Intent.ACTION_SEND) {
            val stream = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            }
            stream?.let(uris::add)
        }

        if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            val streams = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            }
            streams?.let(uris::addAll)
        }

        return uris.toList()
    }

    private fun queryDisplayName(uri: Uri): String? {
        return contentResolver.query(
            uri,
            arrayOf(android.provider.OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor: Cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
    }

    private fun mimeTypeToExtension(mimeType: String): String {
        return when (mimeType.lowercase()) {
            "application/pdf" -> "pdf"
            "image/jpeg" -> "jpg"
            "image/png" -> "png"
            "image/heic" -> "heic"
            else -> mimeType.substringAfterLast('/', "bin")
        }
    }

    private fun nextAvailableDisplayName(fileName: String): String {
        val resolver = contentResolver
        val relativePath = Environment.DIRECTORY_DOWNLOADS + "/"
        var candidate = fileName
        var suffix = 1
        while (resolver.query(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.MediaColumns._ID),
                "${MediaStore.MediaColumns.DISPLAY_NAME}=? AND ${MediaStore.MediaColumns.RELATIVE_PATH}=?",
                arrayOf(candidate, relativePath),
                null,
            )?.use { it.moveToFirst() } == true
        ) {
            candidate = addSuffix(fileName, suffix++)
        }
        return candidate
    }

    private fun nextAvailableFileName(fileName: String): String {
        val directory = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        var candidate = File(directory, fileName)
        var suffix = 1
        while (candidate.exists()) {
            candidate = File(directory, addSuffix(fileName, suffix++))
        }
        return candidate.name
    }

    private fun addSuffix(fileName: String, suffix: Int): String {
        val dot = fileName.lastIndexOf('.')
        return if (dot <= 0) {
            "${fileName}_$suffix"
        } else {
            "${fileName.substring(0, dot)}_$suffix${fileName.substring(dot)}"
        }
    }
}
