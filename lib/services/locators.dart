import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:amap_flutter_location/amap_flutter_location.dart';
import 'package:amap_flutter_location/amap_location_option.dart';
import 'package:geolocator/geolocator.dart';

import 'app_logger.dart';

/// 定位会话模式。
enum LocationMode { moving, stationary }

/// 定位来源：高德 SDK / 系统定位兜底。
enum LocationSource { amap, system }

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

  /// 该定位点来自哪个提供方（高德 / 系统兜底）。
  final LocationSource source;

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
    this.source = LocationSource.amap,
  });

  bool get isOk => errorCode == null && latitude != null && longitude != null;
}

/// 持续定位提供方抽象：高德与系统定位各自实现，
/// 由 LocationService 编排降级/回升。
abstract class ContinuousLocator {
  String get name;

  /// 归一化定位流（含携带 errorCode 的失败事件）。
  Stream<LocationFix> get fixes;

  /// 以 [intervalMs] 间隔开始连续定位（重复调用幂等：先停旧流再启）。
  Future<void> start({required int intervalMs});

  /// 运行中调整间隔（提供方内部按需重启自身）。
  Future<void> applyInterval(int intervalMs);

  /// 停止连续定位（保留实例可复用）。
  Future<void> stop();

  /// 彻底销毁（下次需重建实例）。
  Future<void> dispose();
}

/// 高德连续定位提供方。
///
/// ⚠️ 插件原生侧 stopLocation 会销毁 native client（onDestroy），
/// 下次 startLocation 自动重建，属正常路径；要清除插件侧残留状态
/// （EventSink 错乱、client 卡死等）必须 dispose 后换新实例（新 pluginKey）。
class AmapLocator implements ContinuousLocator {
  AMapFlutterLocation? _client;
  StreamSubscription<Map<String, Object>>? _sub;
  final _fixes = StreamController<LocationFix>.broadcast();

  int _intervalMs = 2000;

  @override
  String get name => 'amap';

  @override
  Stream<LocationFix> get fixes => _fixes.stream;

  /// 高德隐私合规：定位 SDK 要求先同意隐私政策（进程内一次即可，
  /// 每次启动前重复调用无害）。
  static void agreePrivacy() {
    AMapFlutterLocation.updatePrivacyShow(true, true);
    AMapFlutterLocation.updatePrivacyAgree(true);
  }

  @override
  Future<void> start({required int intervalMs}) async {
    _intervalMs = intervalMs;
    agreePrivacy();
    _client ??= AMapFlutterLocation();
    await _sub?.cancel();
    _sub = _client!.onLocationChanged().listen(_onRawEvent);
    _applyOption();
    _client!.startLocation();
    AppLogger.i('location', '高德连续定位已启动（间隔 ${_intervalMs}ms）');
  }

  @override
  Future<void> applyInterval(int intervalMs) async {
    _intervalMs = intervalMs;
    if (_client == null) return;
    // 高德 SDK 运行中间隔调整需重启定位使新 option 生效
    _client!.stopLocation();
    _applyOption();
    _client!.startLocation();
  }

  @override
  Future<void> stop() async {
    _client?.stopLocation();
    AppLogger.i('location', '高德连续定位已停止');
  }

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    // 注意：插件 Dart 侧 destroy() 的 MethodChannel 永远不会回包
    // （原生 handler 不调 result），不能 await，否则永久挂起。
    _client?.destroy();
    _client = null;
  }

  void _applyOption() {
    _client?.setLocationOption(AMapLocationOption(
      locationInterval: _intervalMs,
      locationMode: AMapLocationMode.Hight_Accuracy,
      needAddress: false,
    ));
  }

  void _onRawEvent(Map<String, Object> event) {
    final errorCode = event['errorCode'] == null
        ? null
        : (event['errorCode'] is int
            ? event['errorCode'] as int
            : int.tryParse('${event['errorCode']}'));
    _fixes.add(LocationFix(
      latitude: (event['latitude'] as num?)?.toDouble(),
      longitude: (event['longitude'] as num?)?.toDouble(),
      altitude: (event['altitude'] as num?)?.toDouble(),
      speed: (event['speed'] as num?)?.toDouble(),
      accuracy: (event['accuracy'] as num?)?.toDouble(),
      bearing: (event['bearing'] as num?)?.toDouble(),
      locationTime: DateTime.now(),
      errorCode: errorCode,
      errorInfo: event['errorInfo'] as String?,
      source: LocationSource.amap,
    ));
  }
}

/// 系统定位兜底提供方（geolocator：Android 自动选择
/// FusedLocationProvider / LocationManager，不依赖高德 Key）。
///
/// 不自带前台通知保活——App 自有 location 类型前台服务
/// （ForegroundService）已保证进程处于可收定位状态。
class SystemLocator implements ContinuousLocator {
  StreamSubscription<Position>? _sub;
  final _fixes = StreamController<LocationFix>.broadcast();

  int _intervalMs = 2000;

  @override
  String get name => 'system';

  @override
  Stream<LocationFix> get fixes => _fixes.stream;

  @override
  Future<void> start({required int intervalMs}) async {
    _intervalMs = intervalMs;
    await _sub?.cancel();
    _sub = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.best,
        intervalDuration: Duration(milliseconds: _intervalMs),
        distanceFilter: 0,
      ),
    ).listen(_onPosition, onError: (Object e) {
      AppLogger.w('location', '系统定位流错误：$e');
      _fixes.add(LocationFix(
        locationTime: DateTime.now(),
        errorCode: 1000,
        errorInfo: '系统定位错误：$e',
        source: LocationSource.system,
      ));
    });
    AppLogger.i('location', '系统定位兜底已启动（间隔 ${_intervalMs}ms）');
  }

  @override
  Future<void> applyInterval(int intervalMs) => start(intervalMs: intervalMs);

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    AppLogger.i('location', '系统定位兜底已停止');
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _fixes.close();
  }

  void _onPosition(Position p) {
    _fixes.add(LocationFix(
      latitude: p.latitude,
      longitude: p.longitude,
      altitude: p.altitude,
      speed: p.speed,
      accuracy: p.accuracy,
      bearing: p.heading,
      locationTime: p.timestamp,
      source: LocationSource.system,
    ));
  }
}
