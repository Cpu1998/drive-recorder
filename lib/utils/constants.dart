/// 全局常量：偏好键、定位参数、阈值默认值等。
library;

/// SharedPreferences 键。
class PrefKeys {
  static const brakingThreshold = 'braking_threshold'; // m/s²，默认 3.0
  static const collisionThreshold = 'collision_threshold'; // m/s²，默认 60.0
  static const btAutoEnabled = 'bt_auto_enabled';
  static const btDeviceName = 'bt_device_name';
  static const btDeviceAddress = 'bt_device_address';
  static const syncEnabled = 'sync_enabled';
  static const amapPrivacyAgreed = 'amap_privacy_agreed';

  /// 高德 Android Key（App 内配置，运行时注入地图/定位 SDK）。
  static const amapKey = 'amap_android_key';
}

/// 定位自适应频率。
class LocationTuning {
  /// 行驶中（速度 > movingSpeedThreshold）定位间隔：2 秒
  static const movingIntervalMs = 2000;

  /// 静止（速度 < stationarySpeedThreshold 连续 N 次）定位间隔：30 秒
  static const stationaryIntervalMs = 30000;

  /// 判定为行驶中的速度阈值（m/s，约 7.2 km/h）
  static const movingSpeedThreshold = 2.0;

  /// 判定为静止的速度阈值（m/s，约 3.6 km/h）
  static const stationarySpeedThreshold = 1.0;

  /// 连续低速定位次数达到该值后切换到静止频率（滞回防抖）
  static const stationaryConfirmCount = 3;
}

/// 驾驶事件检测默认参数（设置页可调两项阈值）。
class DetectionDefaults {
  /// 急刹：减速度阈值（m/s²）
  static const brakingThreshold = 3.0;

  /// 急刹：需持续的最短时间
  static const brakingMinDuration = Duration(milliseconds: 500);

  /// 碰撞：合成加速度尖峰阈值（m/s²）
  static const collisionThreshold = 60.0;

  /// 碰撞：峰值统计窗口
  static const collisionWindow = Duration(milliseconds: 80);

  /// 同类事件去抖合并窗口
  static const debounceWindow = Duration(seconds: 10);
}

/// 蓝牙车机自动启停。
class BluetoothTuning {
  /// 断开宽限期：车机蓝牙瞬断后等待重连的时间，超时才自动停止记录
  static const disconnectGrace = Duration(seconds: 30);

  /// 已连接设备轮询间隔
  static const pollInterval = Duration(seconds: 5);
}

/// 高德 Key（占位符；Android 端实际读取 AndroidManifest.xml 的 meta-data，
/// iOS 端读取 Info.plist 的 com.amap.api.ioskey，无需在此配置）。
class AMapKeys {
  /// Android Key：配置在 android/app/src/main/AndroidManifest.xml
  static const androidManifestPlaceholder = 'YOUR_AMAP_ANDROID_KEY';

  /// iOS Key：配置在 ios/Runner/Info.plist
  static const iosPlistPlaceholder = 'YOUR_AMAP_IOS_KEY';
}

/// 应用版本（与 pubspec version 同步维护；用于启动日志等展示）。
class AppInfo {
  static const String version = '1.3.3';
}
