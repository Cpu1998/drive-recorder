import 'dart:async';

import 'package:amap_flutter_location/amap_flutter_location.dart';
import 'package:amap_flutter_location/amap_location_option.dart';
import 'package:flutter/foundation.dart';

import '../utils/constants.dart';

/// 定位会话模式。
enum LocationMode { moving, stationary }

/// 单次定位结果（归一化）。
@immutable
class LocationFix {
  final double? latitude;
  final double? longitude;
  final double? altitude;
  final double? speed; // m/s
  final double? accuracy; // 米
  final double? bearing; // 度
  final DateTime locationTime;

  /// 高德 errorCode（12=无定位权限等），null 表示成功。
  final int? errorCode;
  final String? errorInfo;

  const LocationFix({
    this.latitude,
    this.longitude,
    this.altitude,
    this.speed,
    this.accuracy,
    this.bearing,
    required this.locationTime,
    this.errorCode,
    this.errorInfo,
  });

  bool get isOk => errorCode == null && latitude != null && longitude != null;
}

/// 高德定位封装：后台连续定位 + 行驶/静止自适应频率。
///
/// - 行驶中（速度 > 2 m/s）：2s 间隔；
/// - 静止（速度 < 1 m/s 连续 3 次）：30s 间隔；
/// - 切换模式时通过 stop → setLocationOption → start 平滑生效。
///
/// Android 后台保活依赖 ForegroundServiceController 拉起的系统前台服务；
/// 本类自身不处理权限（由 PermissionGate 在记录开始前完成）。
class LocationService {
  AMapFlutterLocation? _client;
  StreamSubscription<Map<String, Object>>? _subscription;

  /// 归一化定位流。
  final _fixes = StreamController<LocationFix>.broadcast();
  Stream<LocationFix> get fixes => _fixes.stream;

  /// 最近一次成功定位（手动打点取坐标用）。
  LocationFix? lastFix;

  LocationMode _mode = LocationMode.moving;
  LocationMode get mode => _mode;
  final _modeController = StreamController<LocationMode>.broadcast();
  Stream<LocationMode> get modeStream => _modeController.stream;

  int _lowSpeedStreak = 0;
  bool _running = false;

  /// 高德隐私合规：Android 端定位 SDK 要求先同意隐私政策（一次即可）。
  static void agreePrivacy() {
    AMapFlutterLocation.updatePrivacyShow(true, true);
    AMapFlutterLocation.updatePrivacyAgree(true);
  }

  bool get isRunning => _running;

  /// 开始连续定位。
  void start({LocationMode initial = LocationMode.moving}) {
    if (_running) return;
    _running = true;
    _mode = initial;
    _lowSpeedStreak = 0;
    agreePrivacy();
    _client ??= AMapFlutterLocation();
    _subscription?.cancel();
    _subscription = _client!.onLocationChanged().listen(_onFix);
    _applyOption();
    _client!.startLocation();
  }

  /// 停止连续定位（不销毁客户端，便于复用）。
  void stop() {
    _running = false;
    _client?.stopLocation();
    _subscription?.cancel();
    _subscription = null;
    _lowSpeedStreak = 0;
  }

  /// 释放资源。
  void dispose() {
    stop();
    _client?.destroy();
    _client = null;
    _fixes.close();
    _modeController.close();
  }

  void _applyOption() {
    _client?.setLocationOption(AMapLocationOption(
      locationInterval: _mode == LocationMode.moving
          ? LocationTuning.movingIntervalMs
          : LocationTuning.stationaryIntervalMs,
      locationMode: AMapLocationMode.Hight_Accuracy,
      needAddress: false,
    ));
  }

  void _onFix(Map<String, Object> event) {
    final errorCode = event['errorCode'] == null
        ? null
        : (event['errorCode'] is int
            ? event['errorCode'] as int
            : int.tryParse('${event['errorCode']}'));
    final fix = LocationFix(
      latitude: (event['latitude'] as num?)?.toDouble(),
      longitude: (event['longitude'] as num?)?.toDouble(),
      altitude: (event['altitude'] as num?)?.toDouble(),
      speed: (event['speed'] as num?)?.toDouble(),
      accuracy: (event['accuracy'] as num?)?.toDouble(),
      bearing: (event['bearing'] as num?)?.toDouble(),
      locationTime: DateTime.now(),
      errorCode: errorCode,
      errorInfo: event['errorInfo'] as String?,
    );
    if (fix.isOk) lastFix = fix;
    _fixes.add(fix);
    _adaptInterval(fix);
  }

  /// 自适应频率（带滞回）：行驶→静止需连续 3 次低速，静止→行驶 1 次高速即切。
  void _adaptInterval(LocationFix fix) {
    final speed = fix.speed;
    if (speed == null) return;
    if (_mode == LocationMode.moving) {
      if (speed < LocationTuning.stationarySpeedThreshold) {
        _lowSpeedStreak++;
        if (_lowSpeedStreak >= LocationTuning.stationaryConfirmCount) {
          _switchMode(LocationMode.stationary);
        }
      } else {
        _lowSpeedStreak = 0;
      }
    } else {
      if (speed > LocationTuning.movingSpeedThreshold) {
        _switchMode(LocationMode.moving);
      }
    }
  }

  void _switchMode(LocationMode newMode) {
    if (newMode == _mode || !_running) return;
    _mode = newMode;
    _lowSpeedStreak = 0;
    _modeController.add(newMode);
    // 高德 SDK 运行中间隔调整需重启定位使新 option 生效
    _client?.stopLocation();
    _applyOption();
    _client?.startLocation();
    if (kDebugMode) {
      print('[LocationService] mode -> ${newMode.name}');
    }
  }

  /// 供测试与 UI 观察：当前间隔（毫秒）。
  int get currentIntervalMs => _mode == LocationMode.moving
      ? LocationTuning.movingIntervalMs
      : LocationTuning.stationaryIntervalMs;
}
