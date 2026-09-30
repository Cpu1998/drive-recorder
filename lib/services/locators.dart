import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:geolocator/geolocator.dart';

import '../utils/geo_utils.dart';

/// 定位会话模式。
enum LocationMode { moving, stationary }

/// 单次定位结果（归一化）。
@immutable
class LocationFix {
  /// 纬度（GCJ-02，已与高德底图对齐）。
  final double? latitude;

  /// 经度（GCJ-02）。
  final double? longitude;
  final double? altitude;
  final double? speed; // m/s
  final double? accuracy; // 米
  final double? bearing; // 度
  final DateTime locationTime;

  /// 非 null 表示本次定位失败（ errorCode 见各提供方定义）。
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

/// 持续定位提供方抽象。
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

/// 系统定位提供方（geolocator AndroidSettings.forceLocationManager = true：
/// 走系统 LocationManager，不经 Google Play 服务，纯 GPS 也可工作；
/// 不依赖高德 Key 与网络）。
///
/// 坐标系：geolocator 输出 WGS-84，本类在出口处统一转换为 GCJ-02
/// （与高德 SDK / 高德底图一致），下游存储、里程、绘制、GPX 全链路
/// 无需再关心坐标系。
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
        // —— 息屏丢点修复：绕开 GMS 的 FusedLocationProviderClient ——
        //
        // 默认（false）时 geolocator 走 Google Play 服务的
        // FusedLocationProviderClient。它自带省电启发式：判定 App 处于
        // 后台/息屏态时会主动降频、批处理甚至长时间不发点（在 vivo/OPPO/
        // 小米等激进省电 ROM 上尤甚，geolocator 上游 issue #1091/#1215 同因）
        // ——表现为「熄屏后轨迹断续/停滞」，即本次要修的问题。前台服务与
        // WakeLock 均挡不住这一层：限流发生在 GMS 客户端内部，与进程
        // 是否存活无关。
        //
        // forceLocationManager: true 改走系统 LocationManager
        // （geolocator_android 5.x 在 Android 12+ 优先
        // LocationManager.FUSED_PROVIDER，退而 GPS_PROVIDER、NETWORK_PROVIDER），
        // 完全不经 GMS，采样节奏由 intervalDuration 直接决定、可预期，
        // 不受 GMS 后台限流影响。
        //
        // 代价：失去 GMS 的传感器融合（室内/城市峡谷收敛略慢），对以户外
        // 行车为主的场景可接受；且 LocationManager 仍支持 fused Provider
        //（系统级混合源），实际损失比“纯 GPS”更小。
        forceLocationManager: true,
        //
        // 不设 foregroundNotificationConfig：若设置，geolocator 会再起
        // 一个自带 location 前台服务并常驻通知，与 App 自有
        // ForegroundService（同样 foregroundServiceType=location，见
        // ForegroundService.kt）叠出双常驻通知。自有服务与定位流同进程，
        // 已满足「带 location 前台服务的进程可后台连续收点」的系统条件，
        // 故采用：自有前台服务保活 + geolocator 纯流订阅，不重复。
        //（geolocator 14 的 AndroidSettings 已无 enforceStrictMode 参数，
        // 该参数自 v10 起移除，无后台模式开关可调。）
      ),
    ).listen(_onPosition, onError: (Object e) {
      _fixes.add(LocationFix(
        locationTime: DateTime.now(),
        errorCode: 1000,
        errorInfo: '系统定位错误：$e',
      ));
    });
  }

  @override
  Future<void> applyInterval(int intervalMs) => start(intervalMs: intervalMs);

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _fixes.close();
  }

  void _onPosition(Position p) {
    // 境内 WGS-84 → GCJ-02（与高德底图对齐）；境外原样
    final (lat, lng) = GeoUtils.wgs84ToGcj02(p.latitude, p.longitude);
    _fixes.add(LocationFix(
      latitude: lat,
      longitude: lng,
      altitude: p.altitude,
      speed: p.speed,
      accuracy: p.accuracy,
      bearing: p.heading,
      locationTime: p.timestamp,
    ));
  }
}
