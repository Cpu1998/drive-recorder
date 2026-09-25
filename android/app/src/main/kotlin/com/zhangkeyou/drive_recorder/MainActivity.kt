package com.zhangkeyou.drive_recorder

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private companion object {
        const val FG_CHANNEL = "drive_recorder/foreground"
        const val BT_CHANNEL = "drive_recorder/bluetooth"
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
