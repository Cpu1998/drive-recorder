import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:vector_math/vector_math.dart';

import '../models/drive_event.dart';

/// 检测到的原始事件（尚未入库）。
@immutable
class DetectedEvent {
  final DriveEventType type;

  /// 强度峰值：急刹为负向减速度（m/s²），碰撞为合成加速度（m/s²）。
  final double peakIntensity;
  final DateTime timestamp;

  /// 与上一次同类事件的合并标记：true 表示处于 10s 去抖窗口内，
  /// 应合并进上一条事件（更新峰值、保留首次时间戳）而不是新插入。
  final bool mergedIntoPrevious;

  const DetectedEvent({
    required this.type,
    required this.peakIntensity,
    required this.timestamp,
    this.mergedIntoPrevious = false,
  });
}

/// 驾驶事件检测器（纯逻辑，可单测）。
///
/// 输入两路 50Hz 传感器流：
/// - [onUserAccel]：user_accelerometer（已去重力），用于急刹检测；
/// - [onAccel]：accelerometer（含重力），用于碰撞检测；
/// - [onSpeed]：GPS 速度（m/s，约 0.5~2s 一次），用于急刹方向判别。
///
/// ## 急刹
/// 1. 候选窗口：|user_accelerometer| 合成幅值 ≥ 阈值（默认 3 m/s²）连续持续
///    ≥ 500ms（样本间隔 > 250ms 视为断流，窗口作废）；
/// 2. 方向判别（区分加速/刹车）：
///    a. 若窗口期间 GPS 速度净下降 ≥ 0.5 m/s → 判为急刹；
///    b. 若速度净上升 ≥ 0.5 m/s → 判为起步加速，忽略；
///    c. 无速度数据时，回退到"前行轴投影"：用低通滤波（EMA，半衰期 3s）估计
///       车身前行方向，窗口平均加速度与前行轴点积 < 0 → 急刹；前行轴未建立则忽略；
/// 3. 事件强度 = 窗口内最大合成幅值，输出为负值（-m/s²）。
///
/// ## 碰撞
/// accelerometer 合成幅值在 80ms 窗口内出现 > 阈值（默认 60 m/s²）的尖峰即触发，
/// 事件强度 = 窗口内峰值。碰撞与重力分量（约 9.8）叠加，阈值已考虑。
///
/// ## 去抖
/// 同类事件 10s 内再次触发 → 合并进上一条（[DetectedEvent.mergedIntoPrevious]），
/// 峰值取绝对值更大者，时间戳保留首次。
class DrivingEventDetector {
  /// 急刹阈值（m/s²），运行时可由设置更新。
  double brakingThreshold;

  /// 急刹需持续的的最短时间。
  Duration brakingMinDuration;

  /// 碰撞尖峰阈值（m/s²），运行时可由设置更新。
  double collisionThreshold;

  Duration collisionWindow;
  Duration debounceWindow;

  // —— 急刹状态 ——
  DateTime? _brakeWindowStart;
  DateTime? _brakeWindowLastSample;
  double _brakePeak = 0;
  Vector3 _brakeWindowSum = Vector3.zero();
  int _brakeWindowSamples = 0;

  // —— 前行轴（EMA 估计）——
  Vector3 _ema = Vector3.zero();
  Vector3? _forwardAxis;

  // —— 速度上下文 ——
  double? _windowStartSpeed;
  double? _lastSpeed;

  // —— 碰撞状态 ——
  DateTime? _collisionWindowStart;
  double _collisionPeak = 0;

  // —— 去抖簿记 ——
  final Map<DriveEventType, DateTime> _lastEmittedAt = {};

  /// 样本最大允许间隔：超过视为断流，重置急刹候选窗口。
  static const Duration maxSampleGap = Duration(milliseconds: 250);

  /// EMA 半衰期。
  static const Duration emaHalfLife = Duration(seconds: 3);

  /// 前行轴建立所需的最小稳态加速度幅值（m/s²）。
  static const double axisMinMagnitude = 0.8;

  /// 无速度数据时，窗口平均加速度与前行轴点积小于该负值才判为急刹。
  static const double axisProjectionMargin = -0.5;

  /// 速度净变化判定阈值（m/s）。
  static const double speedNetChangeThreshold = 0.5;

  DrivingEventDetector({
    this.brakingThreshold = 3.0,
    this.brakingMinDuration = const Duration(milliseconds: 500),
    this.collisionThreshold = 60.0,
    this.collisionWindow = const Duration(milliseconds: 80),
    this.debounceWindow = const Duration(seconds: 10),
  });

  /// 喂入 GPS 速度（m/s），供急刹方向判别。
  void onSpeed(double speedMps, DateTime at) => _lastSpeed = speedMps;

  /// 喂入 user_accelerometer 样本（m/s²，已去重力）；可能返回急刹事件。
  DetectedEvent? onUserAccel(Vector3 accel, DateTime at) {
    _updateEma(accel, at);

    // —— 窗口维护 ——
    final last = _brakeWindowLastSample;
    final magnitude = accel.length;
    final gapTooLarge =
        last != null && at.difference(last) > maxSampleGap;
    if (magnitude < brakingThreshold || gapTooLarge) {
      final event = gapTooLarge || magnitude < brakingThreshold
          ? _closeBrakeWindow(at, reachedMinDuration: false)
          : null;
      _brakeWindowLastSample = at;
      if (magnitude >= brakingThreshold && _brakeWindowStart == null) {
        // 断流后立刻重新开始新窗口
        _openBrakeWindow(accel, at);
      }
      return event;
    }

    if (_brakeWindowStart == null) _openBrakeWindow(accel, at);
    _brakeWindowLastSample = at;
    _brakePeak = math.max(_brakePeak, magnitude);
    _brakeWindowSum += accel;
    _brakeWindowSamples++;

    // 达到最短持续时间即可立刻结算（不等窗口结束，尽早暴露事件）
    if (at.difference(_brakeWindowStart!) >= brakingMinDuration) {
      return _closeBrakeWindow(at, reachedMinDuration: true);
    }
    return null;
  }

  /// 喂入 accelerometer 样本（m/s²，含重力）；可能返回碰撞事件。
  DetectedEvent? onAccel(Vector3 accel, DateTime at) {
    final magnitude = accel.length;
    if (_collisionWindowStart != null) {
      _collisionPeak = math.max(_collisionPeak, magnitude);
      if (at.difference(_collisionWindowStart!) >= collisionWindow) {
        return _emit(
          DriveEventType.collision,
          _collisionPeak,
          _collisionWindowStart!,
        );
      }
      return null;
    }
    if (magnitude > collisionThreshold) {
      _collisionWindowStart = at;
      _collisionPeak = magnitude;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // 内部实现
  // ---------------------------------------------------------------------------

  void _openBrakeWindow(Vector3 accel, DateTime at) {
    _brakeWindowStart = at;
    _brakePeak = accel.length;
    _brakeWindowSum = Vector3.copy(accel);
    _brakeWindowSamples = 1;
    _windowStartSpeed = _lastSpeed;
  }

  DetectedEvent? _closeBrakeWindow(DateTime at,
      {required bool reachedMinDuration}) {
    if (_brakeWindowStart == null) return null;
    final windowStart = _brakeWindowStart!;
    final samples = _brakeWindowSamples;
    final sum = _brakeWindowSum;
    final peak = _brakePeak;
    final startSpeed = _windowStartSpeed;
    _brakeWindowStart = null;
    _brakeWindowLastSample = null;
    _brakeWindowSum = Vector3.zero();
    _brakeWindowSamples = 0;
    _brakePeak = 0;
    _windowStartSpeed = null;

    if (!reachedMinDuration) return null;
    if (samples == 0) return null;

    // 方向判别：优先 GPS 速度趋势
    final speedNow = _lastSpeed;
    if (startSpeed != null && speedNow != null) {
      final net = speedNow - startSpeed;
      if (net > speedNetChangeThreshold) return null; // 起步加速
      if (net < -speedNetChangeThreshold) {
        return _emit(DriveEventType.braking, -peak, windowStart);
      }
      // 速度变化不明显：继续用前行轴判别
    }

    final axis = _forwardAxis;
    if (axis == null) return null; // 无法判别方向，宁缺毋滥
    final mean = sum / samples.toDouble();
    final projection = mean.dot(axis);
    if (projection < axisProjectionMargin) {
      return _emit(DriveEventType.braking, -peak, windowStart);
    }
    return null;
  }

  void _updateEma(Vector3 accel, DateTime at) {
    // 50Hz 采样下的 EMA 系数（按半衰期换算）
    final periodMs = 20;
    final lambda = math.ln2 / (emaHalfLife.inMilliseconds / periodMs);
    final alpha = 1 - math.exp(-lambda);
    _ema = _ema * (1 - alpha) + accel.scaled(alpha);
    if (_ema.length > axisMinMagnitude) {
      _forwardAxis = _ema.normalized();
    }
  }

  DetectedEvent? _emit(DriveEventType type, double peak, DateTime at) {
    // 碰撞窗口复位
    if (type == DriveEventType.collision) {
      _collisionWindowStart = null;
      _collisionPeak = 0;
    }

    final last = _lastEmittedAt[type];
    final merged =
        last != null && at.difference(last) < debounceWindow;
    if (!merged) {
      _lastEmittedAt[type] = at;
    }
    return DetectedEvent(
      type: type,
      peakIntensity: peak,
      timestamp: at,
      mergedIntoPrevious: merged,
    );
  }
}
