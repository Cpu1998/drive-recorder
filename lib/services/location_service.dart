import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'app_logger.dart';
import 'locators.dart';
import '../utils/constants.dart';

export 'locators.dart' show LocationFix, LocationMode, LocationSource;

/// 定位链路运行状态。
enum LocationRuntime {
  /// 未在定位。
  stopped,

  /// 高德定位正常供点。
  amap,

  /// 高德异常，正在重建客户端尝试恢复。
  amapRecovering,

  /// 已降级到系统定位兜底（期间仍会周期探测回升高德）。
  system,
}

typedef LocatorFactory = ContinuousLocator Function();

/// 定位编排中心：高德连续定位 + 停滞自愈 + 系统定位兜底（降级阶梯）。
///
/// 降级阶梯（Android 实测"高德突然无点"的自愈路径）：
/// 1. 高德停滞（超过 间隔+宽限期 无任何回调）或连续 3 次错误
///    → 重建高德客户端（换新实例，清除插件原生侧残留状态），最多
///    [LocationTuning.amapMaxRestarts] 次；
/// 2. 重建后仍停滞/报错 → 降级到系统定位（geolocator，不依赖高德
///    Key），轨迹点继续入库不断流；
/// 3. 降级期间按退避周期（120s 起、×2 封顶 900s）悄悄重启高德探测，
///    一旦拿到正常定位点立即切回高德、停掉系统流。
///
/// 行驶/静止自适应频率在任一提供方上都生效：
/// - 行驶中（速度 > 2 m/s）：2s 间隔；
/// - 静止（速度 < 1 m/s 连续 3 次）：30s 间隔。
///
/// Android 后台保活依赖 ForegroundServiceController 拉起的系统前台服务；
/// 本类自身不处理权限（由 PermissionGate 在记录开始前完成）。
class LocationService {
  LocationService({
    LocatorFactory? amapFactory,
    LocatorFactory? systemFactory,
    bool enableWatchdog = true,
    DateTime Function()? clock,
  })  : _amapFactory = amapFactory ?? (() => AmapLocator()),
        _systemFactory = systemFactory ?? (() => SystemLocator()),
        _enableWatchdog = enableWatchdog,
        _clock = clock ?? (() => DateTime.now());

  final LocatorFactory _amapFactory;
  final LocatorFactory _systemFactory;
  final bool _enableWatchdog;
  final DateTime Function() _clock;

  ContinuousLocator? _amap;
  ContinuousLocator? _system;
  StreamSubscription<LocationFix>? _amapSub;
  StreamSubscription<LocationFix>? _systemSub;

  /// 归一化定位流。
  final _fixes = StreamController<LocationFix>.broadcast();
  Stream<LocationFix> get fixes => _fixes.stream;

  /// 最近一次成功定位（手动打点取坐标用，任一来源）。
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

  // —— 自愈/降级簿记 ——
  int _amapRestarts = 0;
  int _consecutiveAmapErrors = 0;
  DateTime? _lastAmapEventAt;
  DateTime? _lastSystemEventAt;
  Timer? _watchdog;
  Timer? _escalationTimer;
  int _escalationBackoff = LocationTuning.escalateFirstMs;

  int get amapRestartCount => _amapRestarts;

  /// 开始连续定位（降级计数全部重置）。
  void start({LocationMode initial = LocationMode.moving}) {
    if (_running) return;
    _running = true;
    _mode = initial;
    _lowSpeedStreak = 0;
    _amapRestarts = 0;
    _consecutiveAmapErrors = 0;
    _escalationBackoff = LocationTuning.escalateFirstMs;
    unawaited(_startAmap());
    _startWatchdog();
    AppLogger.i('location', '连续定位已启动（模式 $_mode，降级守护已开启）');
  }

  /// 停止连续定位并释放两个提供方。
  void stop() {
    if (!_running) return;
    _running = false;
    _setRuntime(LocationRuntime.stopped);
    _watchdog?.cancel();
    _watchdog = null;
    _escalationTimer?.cancel();
    _escalationTimer = null;
    unawaited(_amapSub?.cancel());
    _amapSub = null;
    unawaited(_systemSub?.cancel());
    _systemSub = null;
    unawaited(_amap?.dispose());
    _amap = null;
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

  Future<void> _startAmap() async {
    final amap = _amapFactory();
    _amap = amap;
    _lastAmapEventAt = _clock();
    _consecutiveAmapErrors = 0;
    await _amapSub?.cancel();
    _amapSub = amap.fixes.listen(_onAmapFix);
    await amap.start(intervalMs: _intervalFor(_mode));
    _setRuntime(_system != null && _systemSub != null
        ? LocationRuntime.amapRecovering
        : LocationRuntime.amap);
  }

  void _onAmapFix(LocationFix fix) {
    _lastAmapEventAt = _clock();
    if (fix.isOk) {
      _consecutiveAmapErrors = 0;
      // 降级探测成功：立即切回高德，停掉系统兜底
      if (_runtime == LocationRuntime.amapRecovering && _system != null) {
        _stopSystemSink();
        _escalationBackoff = LocationTuning.escalateFirstMs;
        _setRuntime(LocationRuntime.amap);
        AppLogger.i('location', '高德定位已恢复，切回高德（系统兜底停止）');
      }
    } else {
      AppLogger.w('location',
          '高德定位失败 errorCode=${fix.errorCode} ${fix.errorInfo ?? ''}');
      _consecutiveAmapErrors++;
      if (_consecutiveAmapErrors >= LocationTuning.amapErrorThreshold) {
        _consecutiveAmapErrors = 0;
        _handleAmapFailure('连续 ${LocationTuning.amapErrorThreshold} 次定位错误');
      }
    }
    _emit(fix);
  }

  void _onSystemFix(LocationFix fix) {
    _lastSystemEventAt = _clock();
    if (!fix.isOk) {
      AppLogger.w('location', '系统定位失败：${fix.errorInfo ?? fix.errorCode}');
    }
    _emit(fix);
  }

  void _emit(LocationFix fix) {
    if (fix.isOk) lastFix = fix;
    _fixes.add(fix);
    _adaptInterval(fix);
  }

  Future<void> _degradeToSystem(String trigger) async {
    AppLogger.w('location', '定位降级（$trigger）：切换系统定位兜底');
    unawaited(_amapSub?.cancel());
    _amapSub = null;
    unawaited(_amap?.dispose());
    _amap = null;
    _system ??= _systemFactory();
    _lastSystemEventAt = _clock();
    await _systemSub?.cancel();
    _systemSub = _system!.fixes.listen(_onSystemFix);
    await _system!.start(intervalMs: _intervalFor(_mode));
    _setRuntime(LocationRuntime.system);
    _scheduleEscalation();
  }

  /// 降级期间周期探测回升高德（退避：120s → ×2 → 封顶 900s）。
  void _scheduleEscalation() {
    _escalationTimer?.cancel();
    final delay = Duration(milliseconds: _escalationBackoff);
    _escalationTimer = Timer(delay, () {
      if (!_running || _runtime != LocationRuntime.system) return;
      unawaited(escalateNow());
    });
  }

  /// 立即尝试回升高德（保持系统兜底运行直到高德供出第一个正常点）。
  /// 测试亦可直接调用。
  @visibleForTesting
  Future<void> escalateNow() async {
    if (!_running) return;
    if (_amap == null) {
      AppLogger.i('location', '开始回升高德（系统兜底继续，退避 ${_escalationBackoff ~/ 1000}s）');
      await _startAmap(); // runtime -> amapRecovering（system 仍在）
      _escalationBackoff =
          math.min(_escalationBackoff * 2, LocationTuning.escalateMaxMs);
    }
  }

  // ---------------------------------------------------------------------------
  // 看门狗：停滞检测与降级决策
  // ---------------------------------------------------------------------------

  void _startWatchdog() {
    if (!_enableWatchdog) return;
    _watchdog?.cancel();
    _watchdog = Timer.periodic(
        const Duration(milliseconds: LocationTuning.healthTickMs), (_) {
      checkHealth();
    });
  }

  /// 健康检查（看门狗每 [LocationTuning.healthTickMs] 调一次；测试直接驱动）。
  @visibleForTesting
  void checkHealth() {
    if (!_running) return;
    final now = _clock();

    // 高德停滞：无任何回调超过 间隔+宽限期（探测期用更短的探测窗口）
    final amap = _amap;
    if (amap != null && _lastAmapEventAt != null) {
      final window = _runtime == LocationRuntime.amapRecovering
          ? LocationTuning.probeStallMs
          : _intervalFor(_mode) + LocationTuning.stallGraceMs;
      if (now.difference(_lastAmapEventAt!).inMilliseconds > window) {
        _lastAmapEventAt = now; // 防止决策间隙重复触发
        _handleAmapFailure('停滞超 ${(window / 1000).toStringAsFixed(0)}s');
      }
    }

    // 系统兜底停滞：重建系统定位（一次新实例清掉卡死的原生流）
    final system = _system;
    if (system != null &&
        _lastSystemEventAt != null &&
        now.difference(_lastSystemEventAt!).inMilliseconds >
            _intervalFor(_mode) + LocationTuning.stallGraceMs + 20000) {
      _lastSystemEventAt = now;
      AppLogger.w('location', '系统定位兜底停滞，重建系统定位流');
      unawaited(system.start(intervalMs: _intervalFor(_mode)));
    }
  }

  void _handleAmapFailure(String trigger) {
    if (!_running || _amap == null) return;

    if (_runtime == LocationRuntime.amapRecovering && _system != null) {
      // 回升探测失败：保持系统兜底，退避后重试
      AppLogger.w('location', '高德回升探测失败（$trigger），继续系统兜底');
      unawaited(_amapSub?.cancel());
      _amapSub = null;
      unawaited(_amap?.dispose());
      _amap = null;
      _setRuntime(LocationRuntime.system);
      _scheduleEscalation();
      return;
    }

    if (_amapRestarts < LocationTuning.amapMaxRestarts) {
      _amapRestarts++;
      AppLogger.w('location',
          '高德异常（$trigger），重建客户端 第 $_amapRestarts/${LocationTuning.amapMaxRestarts} 次');
      unawaited(_amapSub?.cancel());
      _amapSub = null;
      unawaited(_amap?.dispose());
      _amap = null;
      unawaited(_startAmap());
      return;
    }

    unawaited(_degradeToSystem(trigger));
  }

  void _stopSystemSink() {
    unawaited(_systemSub?.cancel());
    _systemSub = null;
    unawaited(_system?.stop());
    _system = null;
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
    // 运行中间隔调整：让当前活跃的提供方重启到新间隔
    unawaited(_amap?.applyInterval(_intervalFor(newMode)));
    unawaited(_system?.applyInterval(_intervalFor(newMode)));
    if (kDebugMode) {
      print('[LocationService] mode -> ${newMode.name}');
    }
  }

  /// 供测试与 UI 观察：当前间隔（毫秒）。
  int get currentIntervalMs => _intervalFor(_mode);
}
