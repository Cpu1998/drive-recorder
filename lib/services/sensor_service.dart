import 'dart:async';

import 'package:sensors_plus/sensors_plus.dart';
import 'package:vector_math/vector_math.dart';

import 'driving_event_detector.dart';

/// 传感器采集 + 驾驶事件检测服务。
///
/// 仅在记录进行中订阅传感器流（50Hz，省电）；
/// 急刹走 user_accelerometer（已去重力），碰撞走 accelerometer（含重力）。
class SensorService {
  final DrivingEventDetector detector;

  SensorService({DrivingEventDetector? detector})
      : detector = detector ?? DrivingEventDetector();

  StreamSubscription<UserAccelerometerEvent>? _userAccelSub;
  StreamSubscription<AccelerometerEvent>? _accelSub;

  /// 检测到的事件（去抖合并逻辑见 DrivingEventDetector）。
  final _events = StreamController<DetectedEvent>.broadcast();
  Stream<DetectedEvent> get events => _events.stream;

  /// GPS 速度上下文（用于急刹方向判别），由 RecordingProvider 喂入。
  void feedSpeed(double mps) => detector.onSpeed(mps, DateTime.now());

  /// 开始采集（记录开始时调用）。
  void start() {
    stop();
    const period = Duration(milliseconds: 20); // 50Hz
    _userAccelSub = userAccelerometerEventStream(samplingPeriod: period)
        .listen((e) {
      final event = detector.onUserAccel(
        Vector3(e.x, e.y, e.z),
        e.timestamp,
      );
      if (event != null) _events.add(event);
    });
    _accelSub = accelerometerEventStream(samplingPeriod: period).listen((e) {
      final event = detector.onAccel(Vector3(e.x, e.y, e.z), e.timestamp);
      if (event != null) _events.add(event);
    });
  }

  /// 停止采集（记录结束/暂停时调用，释放传感器省电）。
  void stop() {
    _userAccelSub?.cancel();
    _userAccelSub = null;
    _accelSub?.cancel();
    _accelSub = null;
  }

  void dispose() {
    stop();
    _events.close();
  }
}
