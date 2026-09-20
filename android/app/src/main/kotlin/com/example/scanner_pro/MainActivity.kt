package com.example.scanner_pro

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "scanner_pro/downloads"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
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
