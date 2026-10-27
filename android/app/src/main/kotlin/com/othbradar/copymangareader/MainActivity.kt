package com.othbradar.copymangareader

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private companion object {
        const val CHANNEL = "com.othbradar.copymangareader/external_library"
        const val DEVICE_CHANNEL = "com.othbradar.copymangareader/device_identity"
        const val REQUEST_MANAGE_STORAGE = 7101
        const val REQUEST_DIRECTORY = 7102
        const val PREFERENCES = "external_library_access"
        const val URI_KEY = "directory_uri"
    }

    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler(::handleMethodCall)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "getDeviceIdentity") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                result.success(
                    mapOf(
                        "device" to Build.MODEL,
                        "deviceInfo" to "${Build.MODEL}-${Build.DEVICE}",
                        // Official device_info_plus id, not Settings.Secure.ANDROID_ID.
                        "platformId" to Build.ID,
                    ),
                )
            }
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickLibraryDirectory" -> beginDirectorySelection(result)
            "restoreLibraryDirectoryAccess" -> restoreDirectory(result)
            "releaseLibraryDirectoryAccess" -> {
                releaseStoredPermission()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun beginDirectorySelection(result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("PICKER_BUSY", "目录选择器已打开", null)
            return
        }
        pendingResult = result
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            !Environment.isExternalStorageManager()
        ) {
            val packageUri = Uri.parse("package:$packageName")
            val intent = Intent(
                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                packageUri,
            )
            try {
                startActivityForResult(intent, REQUEST_MANAGE_STORAGE)
            } catch (_: Exception) {
                startActivityForResult(
                    Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION),
                    REQUEST_MANAGE_STORAGE,
                )
            }
            return
        }
        openDirectoryPicker()
    }

    private fun openDirectoryPicker() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
            )
            putExtra("android.content.extra.SHOW_ADVANCED", true)
        }
        startActivityForResult(intent, REQUEST_DIRECTORY)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            REQUEST_MANAGE_STORAGE -> {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R ||
                    Environment.isExternalStorageManager()
                ) {
                    openDirectoryPicker()
                } else {
                    finishWithError(
                        "STORAGE_PERMISSION_DENIED",
                        "需要“所有文件访问权限”才能直接读取 SQLite 和章节 ZIP",
                    )
                }
            }
            REQUEST_DIRECTORY -> {
                if (resultCode != Activity.RESULT_OK || data?.data == null) {
                    pendingResult?.success(null)
                    pendingResult = null
                    return
                }
                val uri = data.data!!
                val flags = data.flags and (
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    )
                try {
                    contentResolver.takePersistableUriPermission(uri, flags)
                    val path = directPath(uri)
                        ?: throw IllegalArgumentException("请选择内部存储或 USB 外置盘目录")
                    replaceStoredPermission(uri)
                    pendingResult?.success(path)
                    pendingResult = null
                } catch (exception: Exception) {
                    finishWithError(
                        "DIRECTORY_ACCESS_FAILED",
                        exception.message ?: "无法取得目录权限",
                    )
                }
            }
        }
    }

    private fun restoreDirectory(result: MethodChannel.Result) {
        val stored = getSharedPreferences(PREFERENCES, MODE_PRIVATE)
            .getString(URI_KEY, null)
        if (stored.isNullOrBlank()) {
            result.success(null)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            !Environment.isExternalStorageManager()
        ) {
            result.success(null)
            return
        }
        val uri = Uri.parse(stored)
        val granted = contentResolver.persistedUriPermissions.any {
            it.uri == uri && it.isReadPermission
        }
        result.success(if (granted) directPath(uri) else null)
    }

    private fun replaceStoredPermission(uri: Uri) {
        val preferences = getSharedPreferences(PREFERENCES, MODE_PRIVATE)
        val previous = preferences.getString(URI_KEY, null)?.let(Uri::parse)
        if (previous != null && previous != uri) releasePermission(previous)
        preferences.edit().putString(URI_KEY, uri.toString()).apply()
    }

    private fun releaseStoredPermission() {
        val preferences = getSharedPreferences(PREFERENCES, MODE_PRIVATE)
        preferences.getString(URI_KEY, null)?.let {
            releasePermission(Uri.parse(it))
        }
        preferences.edit().remove(URI_KEY).apply()
    }

    private fun releasePermission(uri: Uri) {
        val permission = contentResolver.persistedUriPermissions.firstOrNull {
            it.uri == uri
        } ?: return
        var flags = 0
        if (permission.isReadPermission) {
            flags = flags or Intent.FLAG_GRANT_READ_URI_PERMISSION
        }
        if (permission.isWritePermission) {
            flags = flags or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        }
        try {
            contentResolver.releasePersistableUriPermission(uri, flags)
        } catch (_: SecurityException) {
            // The system may already have revoked a removed USB volume.
        }
    }

    private fun directPath(uri: Uri): String? {
        if (uri.authority != "com.android.externalstorage.documents" ||
            !DocumentsContract.isTreeUri(uri)
        ) {
            return null
        }
        val documentId = DocumentsContract.getTreeDocumentId(uri)
        val parts = documentId.split(":", limit = 2)
        val volume = parts.firstOrNull()?.trim().orEmpty()
        val relative = parts.getOrNull(1)?.trim('/').orEmpty()
        val base = when {
            volume.equals("primary", ignoreCase = true) ->
                Environment.getExternalStorageDirectory()
            volume.equals("home", ignoreCase = true) ->
                File(Environment.getExternalStorageDirectory(), "Documents")
            volume.isNotEmpty() -> File("/storage", volume)
            else -> return null
        }
        val selected = if (relative.isEmpty()) base else File(base, relative)
        return try {
            selected.canonicalPath
        } catch (_: Exception) {
            selected.absolutePath
        }
    }

    private fun finishWithError(code: String, message: String) {
        pendingResult?.error(code, message, null)
        pendingResult = null
    }
}
