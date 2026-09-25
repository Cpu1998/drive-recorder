import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/drive_event.dart';
import '../models/track.dart';
import '../models/track_point.dart';
import '../services/app_logger.dart';
import '../services/database/app_database.dart';
import '../services/driving_event_detector.dart';
import '../services/foreground_service.dart';
import '../services/location_service.dart';
import '../services/permission_service.dart';
import '../services/photo_service.dart';
import '../services/sensor_service.dart';
import '../services/settings_service.dart';
import '../utils/formatters.dart';
import '../utils/geo_utils.dart';
import 'settings_provider.dart';
import 'tracks_provider.dart';

/// 记录会话状态。
enum RecordingState { idle, recording }

/// 记录编排中心：
/// - 定位（自适应频率）→ 批量缓冲 → SQLite 事务写入；
/// - 传感器事件（急刹/碰撞）→ 去抖合并入库；
/// - 手动打点（取最近定位，无定位打 degraded 标记）；
/// - 车机蓝牙连/断 → 自动开始 / 宽限 30s 后自动停止；
/// - Android 前台服务保活。
class RecordingProvider extends ChangeNotifier {
  final AppDatabase db;
  final SettingsService settings;
  final LocationService location;
  final SensorService sensors;
  final ForegroundServiceController foreground;
  final PermissionService permissions;
  final PhotoService photos;

  RecordingProvider({
    required this.db,
    required this.settings,
    required this.settingsProvider,
    required this.tracks,
    LocationService? locationService,
    SensorService? sensorService,
    ForegroundServiceController? foregroundService,
    PermissionService? permissionService,
    PhotoService? photoService,
  })  : location = locationService ?? LocationService(),
        photos = photoService ?? PhotoService(),
        sensors = sensorService ??
            SensorService(detector: DrivingEventDetector(
              brakingThreshold: settings.brakingThreshold,
              collisionThreshold: settings.collisionThreshold,
            )),
        foreground = foregroundService ?? ForegroundServiceController(),
        permissions = permissionService ?? PermissionService();

  final SettingsProvider settingsProvider;
  final TracksProvider tracks;

  // —— 状态 ——
  RecordingState _state = RecordingState.idle;
  RecordingState get state => _state;
  bool get isRecording => _state == RecordingState.recording;

  Track? _currentTrack;
  Track? get currentTrack => _currentTrack;

  double? _currentSpeed;
  double? get currentSpeed => _currentSpeed;

  DateTime? _lastFixAt;
  DateTime? get lastFixAt => _lastFixAt;

  /// 当前是否有可用的 GPS 定位（手动打点用）。
  bool get hasGpsFix => location.lastFix?.isOk == true;

  bool get gpsDegraded =>
      isRecording && (_lastFixAt == null ||
          DateTime.now().difference(_lastFixAt!) > const Duration(seconds: 30));

  int _manualEvents = 0;
  int _sensorEvents = 0;
  int _photoEvents = 0;
  int get manualEventCount => _manualEvents;
  int get sensorEventCount => _sensorEvents;
  int get photoEventCount => _photoEvents;

  String? _statusMessage;
  String? get statusMessage => _statusMessage;

  StreamSubscription? _fixSub;
  StreamSubscription? _sensorEventSub;

  // —— 轨迹点缓冲 ——
  final List<TrackPoint> _buffer = [];
  double _pendingDistance = 0;
  TrackPoint? _lastWritten;
  Timer? _flushTimer;

  /// 去抖合并簿记：type -> 最近一条已入库事件
  final Map<DriveEventType, DriveEvent> _recentEvents = {};

  // ---------------------------------------------------------------------------
  // 启动装配
  // ---------------------------------------------------------------------------

  /// 由外部（main.dart）注入蓝牙车机连/断事件流，避免服务间硬耦合。
  /// 连接且开启自动启停 → 自动开始；断开宽限 30s 后若未重连 → 自动停止
  /// （仅对由蓝牙自动开启的记录生效，手动开始的手动停）。
  StreamSubscription? _btConnectionSub;

  void attachBluetoothEvents(Stream<bool> events) {
    _btConnectionSub?.cancel();
    _btConnectionSub = events.listen((connected) {
      if (connected) {
        if (!isRecording && settingsProvider.btAutoEnabled) {
          start(source: 'bluetooth');
        }
      } else {
        if (isRecording &&
            settingsProvider.btAutoEnabled &&
            _currentTrack?.source == 'bluetooth') {
          stop();
        }
      }
    });
  }

  // ---------------------------------------------------------------------------
  // 记录开始 / 结束
  // ---------------------------------------------------------------------------

  /// 开始记录。[source]：manual / bluetooth。
  Future<bool> start({String source = 'manual'}) async {
    if (isRecording) return true;

    final perm = await permissions.ensureRecordingPermissions();
    if (!perm.ok) {
      _statusMessage = '缺少权限：${perm.missing.join('、')}';
      AppLogger.w('record', '开始记录被拒：缺少 ${perm.missing.join('、')}');
      notifyListeners();
      return false;
    }
    AppLogger.i('record', '开始记录（来源 $source）');

    final now = DateTime.now();
    var track = Track(
      startTime: now,
      source: source,
      name: defaultTrackName(now),
    );
    track = await db.insertTrack(track);
    AppLogger.i('record', '轨迹 #${track.id} 已创建');
    _currentTrack = track;
    _manualEvents = 0;
    _sensorEvents = 0;
    _photoEvents = 0;
    _recentEvents.clear();
    _buffer.clear();
    _pendingDistance = 0;
    _lastWritten = null;
    _currentSpeed = null;
    _lastFixAt = null;

    // Android 前台服务保活（iOS 走 UIBackgroundModes，忽略）
    await foreground.start();

    // 定位
    _fixSub?.cancel();
    _fixSub = location.fixes.listen(_onFix);
    location.start();

    // 传感器（重建 detector 以应用最新阈值）
    sensors.detector
      ..brakingThreshold = settingsProvider.brakingThreshold
      ..collisionThreshold = settingsProvider.collisionThreshold;
    _sensorEventSub?.cancel();
    _sensorEventSub = sensors.events.listen(_onDetectedEvent);
    sensors.start();

    // 定期批量落库（10s 或缓冲满 20 点）
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(const Duration(seconds: 10), (_) => _flush());

    _state = RecordingState.recording;
    _statusMessage = null;
    notifyListeners();
    return true;
  }

  /// 结束记录并结算。
  Future<void> stop() async {
    if (!isRecording) return;

    await _flush();
    AppLogger.i('record', '停止记录：${_currentTrack?.name ?? ''}，'
        '点数 ${_currentTrack?.pointCount ?? 0}，事件 ${_currentTrack?.eventCount ?? 0}');
    location.stop();
    sensors.stop();
    await _fixSub?.cancel();
    await _sensorEventSub?.cancel();
    _fixSub = null;
    _sensorEventSub = null;
    _flushTimer?.cancel();
    _flushTimer = null;
    await foreground.stop();

    final track = _currentTrack;
    if (track != null && track.id != null) {
      final finished = track.copyWith(endTime: DateTime.now());
      await db.updateTrack(finished);
      _currentTrack = finished;
      await tracks.maybeUpload(finished);
    }

    _state = RecordingState.idle;
    notifyListeners();
    await tracks.refresh();
  }

  // ---------------------------------------------------------------------------
  // 定位回调
  // ---------------------------------------------------------------------------

  Future<void> _onFix(LocationFix fix) async {
    if (!isRecording) return;
    final track = _currentTrack;
    if (track?.id == null) return;

    final point = TrackPoint(
      trackId: track!.id!,
      timestamp: fix.locationTime,
      latitude: fix.latitude,
      longitude: fix.longitude,
      altitude: fix.altitude,
      speed: fix.speed,
      accuracy: fix.accuracy,
      bearing: fix.bearing,
      degraded: !fix.isOk,
    );

    // 里程累计（仅相邻两点均有定位）
    if (fix.isOk && _lastWritten != null && _lastWritten!.hasFix) {
      _pendingDistance += GeoUtils.distance(
        _lastWritten!.latitude!,
        _lastWritten!.longitude!,
        fix.latitude!,
        fix.longitude!,
      );
    }

    _buffer.add(point);
    _lastWritten = point;
    if (fix.isOk) {
      _lastFixAt = DateTime.now();
      _currentSpeed = fix.speed;
      if (fix.speed != null) sensors.feedSpeed(fix.speed!);
    }
    if (_buffer.length >= 20) await _flush();
    notifyListeners();
  }

  /// 批量事务写入缓冲点 + 里程。
  Future<void> _flush() async {
    final track = _currentTrack;
    if (track?.id == null) return;
    final points = List<TrackPoint>.of(_buffer);
    final distance = _pendingDistance;
    if (points.isEmpty && distance <= 0) return;
    _buffer.clear();
    _pendingDistance = 0;

    final stored = await db.insertPoints(points, distance);
    if (stored.isNotEmpty) {
      _lastWritten = stored.last;
    }
    if (isRecording) notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 事件
  // ---------------------------------------------------------------------------

  /// 手动打点：取当前最新定位 + 时间戳；无定位记 null 坐标 + degraded。
  Future<bool> manualEvent() async {
    final track = _currentTrack;
    if (!isRecording || track?.id == null) return false;

    final fix = location.lastFix;
    final now = DateTime.now();
    await db.insertEvent(DriveEvent(
      trackId: track!.id!,
      timestamp: now,
      type: DriveEventType.manual,
      latitude: fix?.latitude,
      longitude: fix?.longitude,
      degraded: fix == null || !fix.isOk,
      note: fix == null || !fix.isOk ? '无定位信号' : null,
    ));
    _manualEvents++;
    notifyListeners();
    return true;
  }

  /// 拍照事件：把拍照产物落盘到 `photos/<trackId>/`，并写入 photo 事件。
  /// 坐标逻辑同手动打点：取当前最新定位，无定位记 null + degraded。
  Future<bool> photoEvent(String sourcePath) async {
    final track = _currentTrack;
    if (!isRecording || track?.id == null) return false;

    final now = DateTime.now();
    final dest = await photos.persist(sourcePath, track!.id!, now);

    final fix = location.lastFix;
    await db.insertEvent(DriveEvent(
      trackId: track.id!,
      timestamp: now,
      type: DriveEventType.photo,
      latitude: fix?.latitude,
      longitude: fix?.longitude,
      degraded: fix == null || !fix.isOk,
      note: fix == null || !fix.isOk ? '无定位信号' : null,
      photoPath: dest,
    ));
    _photoEvents++;
    notifyListeners();
    return true;
  }

  /// 传感器检测事件（急刹/碰撞）：10s 去抖合并进上一条，否则新增。
  Future<void> _onDetectedEvent(DetectedEvent e) async {
    final track = _currentTrack;
    if (!isRecording || track == null || track.id == null) return;

    // 关联最近轨迹点坐标（尽力而为）
    final near = _lastWritten ?? await db.lastPointOfTrack(track.id!);
    final lat = near?.latitude;
    final lon = near?.longitude;

    final recent = _recentEvents[e.type];
    if (e.mergedIntoPrevious && recent?.id != null) {
      final merged = await db.mergeEventPeak(recent!, e.peakIntensity.abs());
      _recentEvents[e.type] = merged;
    } else {
      final inserted = await db.insertEvent(DriveEvent(
        trackId: track.id!,
        timestamp: e.timestamp,
        type: e.type,
        peakIntensity: e.peakIntensity,
        latitude: lat,
        longitude: lon,
        degraded: lat == null || lon == null,
      ));
      _recentEvents[e.type] = inserted;
      _sensorEvents++;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _fixSub?.cancel();
    _sensorEventSub?.cancel();
    _btConnectionSub?.cancel();
    _flushTimer?.cancel();
    super.dispose();
  }
}
