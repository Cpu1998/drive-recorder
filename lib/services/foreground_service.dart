import 'package:flutter/services.dart';

/// Android 前台服务（foregroundServiceType=location）启停封装。
///
/// 见 android/.../ForegroundService.kt：纯保活壳 + 常驻通知 + partial WakeLock。
class ForegroundServiceController {
  static const _channel = MethodChannel('drive_recorder/foreground');

  /// 开启前台服务（记录开始时调用）。
  Future<void> start() async {
    try {
      await _channel.invokeMethod<bool>('start');
    } on PlatformException catch (e) {
      throw ForegroundServiceException(e.code, e.message);
    } on MissingPluginException {
      // 非 Android 平台（iOS 无前台服务概念，后台依赖 UIBackgroundModes）
    }
  }

  /// 停止前台服务（记录结束时调用）。
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<bool>('stop');
    } on PlatformException catch (e) {
      throw ForegroundServiceException(e.code, e.message);
    } on MissingPluginException {
      // 非 Android 平台
    }
  }
}

class ForegroundServiceException implements Exception {
  final String code;
  final String? message;
  const ForegroundServiceException(this.code, this.message);

  @override
  String toString() => 'ForegroundServiceException($code): $message';
}
