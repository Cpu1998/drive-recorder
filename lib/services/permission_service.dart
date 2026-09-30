import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// 运行时权限申请（记录/蓝牙各一次性打包申请）。
class PermissionService {
  /// 行车记录所需：精确定位 → 后台定位 → 通知。
  /// 返回是否全部就绪；部分拒绝时返回缺失描述供 UI 提示。
  Future<PermissionResult> ensureRecordingPermissions() async {
    final missing = <String>[];

    final fine = await Permission.locationWhenInUse.request();
    if (!fine.isGranted && !fine.isLimited) missing.add('精确定位');

    // Android 10+ 后台定位需在前台定位已授予后单独申请
    if (fine.isGranted || fine.isLimited) {
      final bg = await Permission.locationAlways.request();
      if (!bg.isGranted && !bg.isLimited) missing.add('后台定位');
    }

    final notif = await Permission.notification.request();
    if (!notif.isGranted && !notif.isLimited) missing.add('通知');

    return PermissionResult(ok: missing.isEmpty, missing: missing);
  }

  /// 车机蓝牙检测所需：Android 12+ 的 BLUETOOTH_CONNECT/SCAN。
  Future<PermissionResult> ensureBluetoothPermissions() async {
    final missing = <String>[];

    final connect = await Permission.bluetoothConnect.request();
    if (!connect.isGranted && !connect.isLimited) missing.add('蓝牙连接');

    final scan = await Permission.bluetoothScan.request();
    if (!scan.isGranted && !scan.isLimited) missing.add('蓝牙扫描');

    return PermissionResult(ok: missing.isEmpty, missing: missing);
  }

  /// 拍照所需：仅 iOS 需主动申请相机权限（Info.plist 已声明用途描述）；
  /// Android 走相机 intent，无需本应用声明 CAMERA 权限。
  Future<PermissionResult> ensureCameraPermission() async {
    if (!Platform.isIOS) {
      return const PermissionResult(ok: true, missing: []);
    }
    final camera = await Permission.camera.request();
    if (camera.isGranted || camera.isLimited) {
      return const PermissionResult(ok: true, missing: []);
    }
    return const PermissionResult(ok: false, missing: ['相机']);
  }

  // —— 息屏保活：电池优化豁免（Android 6+ Doze/App Standby 白名单）——
  // 息屏后系统的 Doze/省电机制会推迟或限流后台定位回调，即使 App 持有
  // location 前台服务也可能被厂商省电策略二次压制；授予「忽略电池优化」
  // 可解除 Android 原生那一层限制（vivo 自家限制仍需系统设置手动放行，
  // 由设置页引导文案说明）。

  /// 「忽略电池优化」当前是否已授予。
  /// 非 Android 平台无此概念，恒返回 true；查询失败（无平台通道的测试
  /// 环境等）保守返回 false，由 UI 引导手动设置。
  Future<bool> isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    try {
      return Permission.ignoreBatteryOptimizations.status.isGranted;
    } catch (_) {
      return false;
    }
  }

  /// 请求「忽略电池优化」（弹系统确认框；需 manifest 已声明
  /// REQUEST_IGNORE_BATTERY_OPTIMIZATIONS）。返回是否已豁免。
  Future<bool> requestIgnoreBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    try {
      final status = await Permission.ignoreBatteryOptimizations.request();
      return status.isGranted;
    } catch (_) {
      return false;
    }
  }
}

@immutable
class PermissionResult {
  final bool ok;
  final List<String> missing;
  const PermissionResult({required this.ok, required this.missing});
}
