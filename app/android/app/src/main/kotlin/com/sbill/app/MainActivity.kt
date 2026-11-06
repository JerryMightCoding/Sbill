package com.sbill.app

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import java.io.ByteArrayOutputStream
import java.io.InputStream
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "com.sbill.app/fileshare"
    private var pendingIncomingPayload: String? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var pendingPicker: MethodChannel.Result? = null
    private var pendingScanner: MethodChannel.Result? = null
    private val pickRequestCode = 641
    private val scanRequestCode = 642
    private val cameraPermRequestCode = 643

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        extractIncomingIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        extractIncomingIntent(intent)
    }

    override fun onDestroy() {
        releaseLanMulticastLock()
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "shareTripDeltaFile" -> {
                        val fileName = call.argument<String>("fileName") ?: "sbill_sync.tripdelta"
                        val content = call.argument<String>("content") ?: ""
                        try {
                            require(File(fileName).name == fileName) { "Invalid file name" }
                            val shareDir = File(cacheDir, "sync_shares").apply { mkdirs() }
                            val outFile = File(shareDir, fileName)
                            outFile.writeText(content, Charsets.UTF_8)
                            val uri = FileProvider.getUriForFile(this, "$packageName.files", outFile)
                            val sendIntent = Intent(Intent.ACTION_SEND).apply {
                                type = "application/octet-stream"
                                putExtra(Intent.EXTRA_SUBJECT, fileName)
                                putExtra(Intent.EXTRA_STREAM, uri)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                clipData = android.content.ClipData.newRawUri(fileName, uri)
                            }
                            startActivity(
                                Intent.createChooser(
                                    sendIntent,
                                    "通过小米互传 / Quick Share / 系统分享同步包"
                                )
                            )
                            result.success(outFile.absolutePath)
                        } catch (e: Exception) {
                            result.error("SHARE_FAILED", e.message, null)
                        }
                    }
                    "pickTripDeltaFile" -> {
                        if (pendingPicker != null) {
                            result.error("PICKER_BUSY", "文件选择器已打开", null)
                        } else {
                            pendingPicker = result
                            try {
                                startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                    type = "*/*"
                                    addCategory(Intent.CATEGORY_OPENABLE)
                                }, pickRequestCode)
                            } catch (e: Exception) {
                                pendingPicker = null
                                result.error("PICK_FAILED", e.message, null)
                            }
                        }
                    }
                    "consumeIncomingTripDelta" -> {
                        val payload = pendingIncomingPayload
                        pendingIncomingPayload = null
                        result.success(payload)
                    }
                    "getDatabasePath" -> {
                        val profile = if (BuildConfig.SBILL_TEST_TOOLS) activeTestProfile() else "primary"
                        result.success(testProfileFile(profile).absolutePath)
                    }
                    "getTestConsoleConfig" -> {
                        result.success(mapOf("enabled" to BuildConfig.SBILL_TEST_TOOLS,
                            "active_profile" to if (BuildConfig.SBILL_TEST_TOOLS) activeTestProfile() else "primary"))
                    }
                    "getTestProfileDatabasePath", "persistTestProfile" -> {
                        if (!BuildConfig.SBILL_TEST_TOOLS) {
                            result.error("TEST_TOOLS_DISABLED", "普通版不开放测试身份", null)
                        } else {
                            val profile = call.argument<String>("profile")
                            if (profile !in testProfiles) {
                                result.error("INVALID_PROFILE", "未知的测试身份", null)
                            } else if (call.method == "getTestProfileDatabasePath") {
                                result.success(testProfileFile(profile!!).absolutePath)
                            } else {
                                val saved = getSharedPreferences("test_console", Context.MODE_PRIVATE)
                                    .edit().putString("active_profile", profile).commit()
                                if (saved) result.success(true)
                                else result.error("PROFILE_SAVE_FAILED", "无法保存测试身份选择", null)
                            }
                        }
                    }
                    "setMulticastLock" -> {
                        val enable = call.argument<Boolean>("enable") ?: true
                        if (enable) {
                            acquireLanMulticastLock()
                        } else {
                            releaseLanMulticastLock()
                        }
                        result.success(multicastLock?.isHeld == true)
                    }
                    "scanQrCode" -> {
                        if (pendingScanner != null) {
                            result.error("SCANNER_BUSY", "扫码器已打开", null)
                        } else {
                            if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
                                != PackageManager.PERMISSION_GRANTED
                            ) {
                                pendingScanner = result
                                ActivityCompat.requestPermissions(
                                    this,
                                    arrayOf(Manifest.permission.CAMERA),
                                    cameraPermRequestCode
                                )
                            } else {
                                launchQrScannerOrFallback(result)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private val testProfiles = setOf("primary", "peer_b", "peer_c", "viewer")

    private fun activeTestProfile(): String {
        val profile = getSharedPreferences("test_console", Context.MODE_PRIVATE)
            .getString("active_profile", "primary") ?: "primary"
        return if (profile in testProfiles) profile else "primary"
    }

    private fun testProfileFile(profile: String): File {
        require(profile in testProfiles)
        if (profile == "primary") return File(filesDir, "sbill_ledger_v1.sqlite3")
        check(BuildConfig.SBILL_TEST_TOOLS) { "Test profiles are disabled" }
        val directory = File(filesDir, "test_profiles/$profile")
        check(directory.exists() || directory.mkdirs()) { "Cannot create test profile directory" }
        return File(directory, "sbill_ledger_v1.sqlite3")
    }

    private fun launchQrScannerOrFallback(result: MethodChannel.Result) {
        val scanIntent = Intent("com.google.zxing.client.android.SCAN").apply {
            putExtra("SCAN_MODE", "QR_CODE_MODE")
        }
        if (scanIntent.resolveActivity(packageManager) != null) {
            pendingScanner = result
            try {
                startActivityForResult(scanIntent, scanRequestCode)
                return
            } catch (_: Exception) {
                pendingScanner = null
            }
        }
        result.success("CAMERA_READY_USE_STREAM")
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != cameraPermRequestCode) return
        val result = pendingScanner ?: return
        pendingScanner = null
        if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            launchQrScannerOrFallback(result)
        } else {
            result.error("CAMERA_PERMISSION_DENIED", "未授予相机权限，可粘贴扫码流或使用文件同步", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == scanRequestCode) {
            val result = pendingScanner ?: return
            pendingScanner = null
            if (resultCode == Activity.RESULT_OK && data != null) {
                result.success(data.getStringExtra("SCAN_RESULT"))
            } else {
                result.success(null)
            }
            return
        }
        if (requestCode != pickRequestCode) return
        val result = pendingPicker ?: return
        pendingPicker = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(null)
            return
        }
        try {
            val text = contentResolver.openInputStream(data.data!!)?.use { readBounded(it) }
                ?: throw IllegalArgumentException("无法打开文件")
            result.success(text)
        } catch (e: Exception) {
            result.error("READ_FAILED", e.message, null)
        }
    }

    private fun readBounded(stream: InputStream): String {
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            val count = stream.read(buffer)
            if (count < 0) break
            require(out.size() + count <= 20 * 1024 * 1024) { "同步文件超过 20 MiB" }
            out.write(buffer, 0, count)
        }
        return out.toString("UTF-8")
    }

    private fun acquireLanMulticastLock() {
        try {
            if (multicastLock == null) {
                val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                multicastLock = wifi?.createMulticastLock("sbill_lan_mdns_lock")?.apply {
                    setReferenceCounted(false)
                }
            }
            if (multicastLock?.isHeld == false) {
                multicastLock?.acquire()
            }
        } catch (_: Exception) {
        }
    }

    private fun releaseLanMulticastLock() {
        try {
            if (multicastLock?.isHeld == true) {
                multicastLock?.release()
            }
        } catch (_: Exception) {
        }
    }

    private fun extractIncomingIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action
        if (Intent.ACTION_VIEW == action || Intent.ACTION_SEND == action) {
            val textExtra = intent.getStringExtra(Intent.EXTRA_TEXT)
            if (!textExtra.isNullOrBlank()) {
                pendingIncomingPayload = textExtra
                return
            }
            val uri: Uri? = intent.data ?: intent.getParcelableExtra(Intent.EXTRA_STREAM)
            if (uri != null) {
                try {
                    contentResolver.openInputStream(uri)?.use { stream ->
                        pendingIncomingPayload = readBounded(stream)
                    }
                } catch (_: Exception) {
                }
            }
        }
    }
}
