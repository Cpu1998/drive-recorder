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
}

@immutable
class PermissionResult {
  final bool ok;
  final List<String> missing;
  const PermissionResult({required this.ok, required this.missing});
}
