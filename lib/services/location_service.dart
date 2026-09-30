import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_logger.dart';
import 'locators.dart';
import '../utils/constants.dart';

export 'locators.dart' show LocationFix, LocationMode;

/// 定位链路运行状态。
enum LocationRuntime {
  /// 未在定位。
  stopped,

  /// 系统定位供点中。
  running,
}

typedef LocatorFactory = ContinuousLocator Function();

/// 定位编排中心：系统定位（geolocator：系统 LocationManager，绕开 GMS
/// 息屏限流）+ 行驶/静止自适应频率 + 停滞看门狗。
///
/// 不再使用高德定位 SDK：不依赖高德 Key 与网络，纯 GPS 即可出点。
///
/// - 行驶中（速度 > 2 m/s）：2s 间隔；
/// - 静止（速度 < 1 m/s 连续 3 次）：30s 间隔；
/// - 看门狗：超过「当前间隔 + 宽限期」无任何回调 → 重建定位流
///   （一次新实例清掉可能卡死的原生流）。
///
/// Android 后台保活依赖 ForegroundServiceController 拉起的系统前台服务；
/// 本类自身不处理权限（由 PermissionGate 在记录开始前完成）。
class LocationService {
  LocationService({
    LocatorFactory? systemFactory,
    bool enableWatchdog = true,
    DateTime Function()? clock,
  })  : _systemFactory = systemFactory ?? (() => SystemLocator()),
        _enableWatchdog = enableWatchdog,
        _clock = clock ?? (() => DateTime.now());

  final LocatorFactory _systemFactory;
  final bool _enableWatchdog;
  final DateTime Function() _clock;

  ContinuousLocator? _system;
  StreamSubscription<LocationFix>? _systemSub;

  /// 归一化定位流。
  final _fixes = StreamController<LocationFix>.broadcast();
  Stream<LocationFix> get fixes => _fixes.stream;

  /// 最近一次成功定位（手动打点取坐标用）。
  LocationFix? lastFix;

  LocationRuntime _runtime = LocationRuntime.stopped;
  LocationRuntime get runtime => _runtime;

  /// 运行状态变化流（UI 监听用）。
  final _runtimeController = StreamController<LocationRuntime>.broadcast();
  Stream<LocationRuntime> get runtimeStream => _runtimeController.stream;

  LocationMode _mode = LocationMode.moving;
  LocationMode get mode => _mode;
  final _modeController = StreamController<LocationMode>.broadcast();
  Stream<LocationMode> get modeStream => _modeController.stream;

  int _lowSpeedStreak = 0;
  bool _running = false;
  bool get isRunning => _running;

  // —— 看门狗簿记 ——
  DateTime? _lastSystemEventAt;
  Timer? _watchdog;
  int _stallRestarts = 0;

  /// 供测试与 UI 观察：当前间隔（毫秒）。
  int get currentIntervalMs => _intervalFor(_mode);

  /// 开始连续定位。
  void start({LocationMode initial = LocationMode.moving}) {
    if (_running) return;
    _running = true;
    _mode = initial;
    _lowSpeedStreak = 0;
    _stallRestarts = 0;
    unawaited(_startSystem());
    _startWatchdog();
    AppLogger.i('location', '连续定位已启动（模式 $_mode，系统定位，看门狗已开启）');
  }

  /// 停止连续定位并释放提供方。
  void stop() {
    if (!_running) return;
    _running = false;
    _setRuntime(LocationRuntime.stopped);
    _watchdog?.cancel();
    _watchdog = null;
    unawaited(_systemSub?.cancel());
    _systemSub = null;
    unawaited(_system?.stop());
    _system = null;
    AppLogger.i('location', '连续定位已停止');
  }

  /// 释放资源。
  void dispose() {
    stop();
    unawaited(_system?.dispose());
    _fixes.close();
    _modeController.close();
    _runtimeController.close();
  }

  // ---------------------------------------------------------------------------
  // 提供方接入
  // ---------------------------------------------------------------------------

  Future<void> _startSystem() async {
    _system ??= _systemFactory();
    _lastSystemEventAt = _clock();
    await _systemSub?.cancel();
    _systemSub = _system!.fixes.listen(_onSystemFix);
    await _system!.start(intervalMs: _intervalFor(_mode));
    _setRuntime(LocationRuntime.running);
    AppLogger.i('location', '系统定位已启动（间隔 ${_intervalFor(_mode)}ms）');
  }

  void _onSystemFix(LocationFix fix) {
    _lastSystemEventAt = _clock();
    if (!fix.isOk) {
      AppLogger.w('location', '系统定位失败：${fix.errorInfo ?? fix.errorCode}');
    }
    if (fix.isOk) lastFix = fix;
    _fixes.add(fix);
    _adaptInterval(fix);
  }

  // ---------------------------------------------------------------------------
  // 看门狗：停滞检测与重建
  // ---------------------------------------------------------------------------

  void _startWatchdog() {
    if (!_enableWatchdog) return;
    _watchdog?.cancel();
    _watchdog = Timer.periodic(
        const Duration(milliseconds: LocationTuning.healthTickMs), (_) {
      checkHealth();
    });
  }

  /// 停滞检查（看门狗每 [LocationTuning.healthTickMs] 调一次；测试直接驱动）。
  /// 超过「当前间隔 + 宽限期」无任何回调 → 重建定位流（新实例清掉
  /// 可能卡死的原生流），重建失败不重试计数封顶（下次停滞再试）。
  @visibleForTesting
  void checkHealth() {
    if (!_running) return;
    final system = _system;
    final lastAt = _lastSystemEventAt;
    if (system == null || lastAt == null) return;
    final now = _clock();
    final window = _intervalFor(_mode) +
        LocationTuning.stallGraceMs +
        LocationTuning.stallExtraGraceMs;
    if (now.difference(lastAt).inMilliseconds > window) {
      _lastSystemEventAt = now; // 防止决策间隙重复触发
      _stallRestarts++;
      AppLogger.w('location',
          '系统定位停滞超 ${(window / 1000).toStringAsFixed(0)}s，重建定位流（第 $_stallRestarts 次）');
      unawaited(system.start(intervalMs: _intervalFor(_mode)));
    }
  }

  void _setRuntime(LocationRuntime r) {
    if (r == _runtime) return;
    _runtime = r;
    if (!_runtimeController.isClosed) _runtimeController.add(r);
  }

  // ---------------------------------------------------------------------------
  // 行驶/静止自适应频率
  // ---------------------------------------------------------------------------

  int _intervalFor(LocationMode m) => m == LocationMode.moving
      ? LocationTuning.movingIntervalMs
      : LocationTuning.stationaryIntervalMs;

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
    // 运行中间隔调整：让提供方重启到新间隔
    unawaited(_system?.applyInterval(_intervalFor(newMode)));
    if (kDebugMode) {
      print('[LocationService] mode -> ${newMode.name}');
    }
  }
}
