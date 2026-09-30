package com.zhangkeyou.drive_recorder

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

open class MainActivity : FlutterActivity() {
    private companion object {
        const val FG_CHANNEL = "drive_recorder/foreground"
        const val BT_CHANNEL = "drive_recorder/bluetooth"
        const val DL_CHANNEL = "drive_recorder/downloads"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ---- 前台服务启停通道 ----
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FG_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        ForegroundService.start(applicationContext)
                        result.success(true)
                    }
                    "stop" -> {
                        ForegroundService.stop(applicationContext)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        // ---- 已连接经典蓝牙设备查询通道 ----
        // flutter_blue_plus 只覆盖 BLE；车机多媒体连接（A2DP/HFP）属经典蓝牙，
        // 这里用 BluetoothManager.getConnectedDevices(profile) 补齐。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BT_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getConnectedClassicDevices" -> {
                        result.success(getConnectedClassicDevices())
                    }
                    "isBluetoothEnabled" -> {
                        val bm = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
                        result.success(bm.adapter?.isEnabled == true)
                    }
                    else -> result.notImplemented()
                }
            }

        // ---- 公共下载目录写入通道 ----
        // media_store_plus 插件已停更，在 Android 16（SDK 36）上 saveFile
        // 恒返回 null（用户实测「保存失败」）。这里自实现：Android 10+ 走
        // MediaStore.Downloads 免权限插入；Android 9- 走遗留公共目录直写。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DL_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveFileToDownloads" -> {
                        val filePath = call.argument<String>("filePath")
                        val subDir = call.argument<String>("subDir") ?: "DriveRecorder"
                        val mime = call.argument<String>("mime") ?: "application/octet-stream"
                        if (filePath == null) {
                            result.error("ARG", "filePath is null", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val name = saveFileToDownloads(filePath, subDir, mime)
                            result.success(name)
                        } catch (e: Exception) {
                            result.error("SAVE_FAILED", e.message ?: e.javaClass.simpleName, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 把本地文件复制到公共下载目录 Download/[subDir]/，返回实际落盘文件名
     * （同名文件被系统自动重编号时与请求名不同）。
     */
    private fun saveFileToDownloads(filePath: String, subDir: String, mime: String): String {
        val src = File(filePath)
        if (!src.exists()) throw IllegalArgumentException("源文件不存在: $filePath")
        val fileName = src.name

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(
                    MediaStore.MediaColumns.RELATIVE_PATH,
                    Environment.DIRECTORY_DOWNLOADS + "/" + subDir
                )
            }
            val resolver = contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("MediaStore insert 返回空")
            try {
                resolver.openOutputStream(uri)?.use { out ->
                    src.inputStream().use { it.copyTo(out) }
                } ?: throw IllegalStateException("打开输出流失败")
            } catch (e: Exception) {
                // 写入失败要清掉半成品行，避免留下 0 字节占位
                runCatching { resolver.delete(uri, null, null) }
                throw e
            }
            // 重名时系统会改名（如 name (1).gpx），查回真实文件名
            var actual = fileName
            runCatching {
                resolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)
                    ?.use { c ->
                        if (c.moveToFirst()) c.getString(0)?.let { actual = it }
                    }
            }
            actual
        } else {
            @Suppress("DEPRECATION")
            val dir = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                subDir
            )
            if (!dir.exists()) dir.mkdirs()
            val dst = File(dir, fileName)
            FileOutputStream(dst).use { out -> src.inputStream().use { it.copyTo(out) } }
            fileName
        }
    }

    /**
     * 返回当前通过 A2DP（音频）或 HEADSET（通话）连接的经典蓝牙设备列表。
     * 需要 BLUETOOTH_CONNECT 权限（S+），Dart 侧负责先申请权限。
     */
    @SuppressLint("MissingPermission")
    private fun getConnectedClassicDevices(): List<Map<String, String>> {
        val bm = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val adapter = bm.adapter ?: return emptyList()
        if (!adapter.isEnabled) return emptyList()

        val devices = LinkedHashMap<String, Map<String, String>>() // address -> device, 去重
        val profiles = listOf(BluetoothProfile.A2DP, BluetoothProfile.HEADSET)
        for (profile in profiles) {
            try {
                bm.getConnectedDevices(profile).forEach { device ->
                    val address = device.address ?: return@forEach
                    if (!devices.containsKey(address)) {
                        devices[address] = mapOf(
                            "name" to (device.name ?: address),
                            "address" to address
                        )
                    }
                }
            } catch (_: SecurityException) {
                // 权限未授予：返回空列表，由 Dart 侧提示
            } catch (_: Exception) {
            }
        }
        return devices.values.toList()
    }
}
