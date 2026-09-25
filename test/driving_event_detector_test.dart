import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

import 'package:drive_recorder/models/drive_event.dart';
import 'package:drive_recorder/services/driving_event_detector.dart';

/// 50Hz 采样周期。
const period = Duration(milliseconds: 20);

/// 生成 [seconds] 秒的采样时间戳序列（从 t0 开始，50Hz）。
List<DateTime> times(DateTime t0, int count) =>
    [for (var i = 0; i < count; i++) t0.add(period * i)];

void main() {
  group('DrivingEventDetector - 急刹（速度上下文判别）', () {
    test('持续超阈值 600ms + 速度下降 → 触发急刹，峰值为负', () {
      final d = DrivingEventDetector(brakingThreshold: 3.0);
      final t0 = DateTime(2026, 9, 25, 10, 0);
      DetectedEvent? hit;

      // 匀速 60km/h ≈ 16.7 m/s，0.5s 静止噪声
      var speed = 16.7;
      for (final t in times(t0, 25)) {
        d.onUserAccel(Vector3(0.1, 0.0, 0.0), t);
      }
      // 600ms 匀减速 -4 m/s²，速度同步下降
      var i = 0;
      for (final t in times(t0.add(period * 25), 31)) {
        speed = 16.7 - 4.0 * (i++ * 0.02);
        d.onSpeed(speed, t);
        final e = d.onUserAccel(Vector3(0, -4, 0), t);
        if (e != null) hit = e;
      }

      expect(hit, isNotNull, reason: '600ms @ -4m/s² 应触发急刹');
      expect(hit!.type, DriveEventType.braking);
      expect(hit.peakIntensity, closeTo(-4.0, 0.5));
      expect(hit.mergedIntoPrevious, isFalse);
    });

    test('起步加速（速度上升）→ 不触发', () {
      final d = DrivingEventDetector(brakingThreshold: 3.0);
      final t0 = DateTime(2026, 9, 25, 10, 0);
      var speed = 0.0;
      var anyEvent = false;
      for (final t in times(t0, 31)) {
        d.onSpeed(speed, t);
        if (d.onUserAccel(Vector3(0, 4, 0), t) != null) anyEvent = true;
      }
      expect(anyEvent, isFalse, reason: '速度净上升应判为加速而非急刹');
    });

    test('仅 300ms（< 500ms 最短持续）→ 不触发', () {
      final d = DrivingEventDetector(brakingThreshold: 3.0);
      final t0 = DateTime(2026, 9, 25, 10, 0);
      var speed = 16.7;
      var anyEvent = false;
      // 300ms @ -4m/s²
      var i = 0;
      for (final t in times(t0, 15)) {
        speed = 16.7 - 4.0 * (i++ * 0.02);
        d.onSpeed(speed, t);
        if (d.onUserAccel(Vector3(0, -4, 0), t) != null) anyEvent = true;
      }
      // 随后恢复静止
      for (final t in times(t0.add(period * 20), 10)) {
        if (d.onUserAccel(Vector3(0, 0, 0), t) != null) anyEvent = true;
      }
      expect(anyEvent, isFalse, reason: '300ms 不满足 ≥500ms 最短持续时间');
    });

    test('无速度数据时回退前行轴判别：先加速建立前行轴，再反向减速 → 触发', () {
      final d = DrivingEventDetector(brakingThreshold: 3.0);
      final t0 = DateTime(2026, 9, 25, 10, 0);

      // 6s 向 +Y 加速（0→50km/h 量级；EMA 半衰期 3s，充分建立前行轴 +Y）
      for (final t in times(t0, 300)) {
        d.onUserAccel(Vector3(0, 1.2, 0), t);
      }
      // 700ms 向 -Y 减速（无速度数据）
      DetectedEvent? hit;
      for (final t in times(t0.add(period * 150), 36)) {
        final e = d.onUserAccel(Vector3(0, -4, 0), t);
        if (e != null) hit = e;
      }
      expect(hit, isNotNull, reason: '前行轴投影为负应判为急刹');
      expect(hit!.type, DriveEventType.braking);
      expect(hit.peakIntensity, lessThan(0));
    });

    test('阈值以下的小幅减速 → 不触发', () {
      final d = DrivingEventDetector(brakingThreshold: 3.0);
      final t0 = DateTime(2026, 9, 25, 10, 0);
      var speed = 16.7;
      var anyEvent = false;
      var i = 0;
      for (final t in times(t0, 51)) {
        speed = 16.7 - 2.0 * (i++ * 0.02);
        d.onSpeed(speed, t);
        if (d.onUserAccel(Vector3(0, -2, 0), t) != null) anyEvent = true;
      }
      expect(anyEvent, isFalse, reason: '-2 m/s² 低于默认阈值 3');
    });
  });

  group('DrivingEventDetector - 碰撞', () {
    test('60ms 处出现 80m/s² 尖峰 → 触发碰撞，峰值取窗口最大', () {
      final d = DrivingEventDetector(collisionThreshold: 60.0);
      final t0 = DateTime(2026, 9, 25, 10, 0);
      DetectedEvent? hit;
      var i = 0;
      for (final t in times(t0, 20)) {
        // 静止重力 + 第 3 个样本出现尖峰 80，随后 90（更新峰值）
        final mag = i == 3
            ? 80.0
            : (i == 4 ? 90.0 : 9.8);
        final e = d.onAccel(Vector3(0, 0, mag), t);
        if (e != null) hit = e;
        i++;
      }
      expect(hit, isNotNull);
      expect(hit!.type, DriveEventType.collision);
      expect(hit.peakIntensity, closeTo(90.0, 1.0),
          reason: '80ms 窗口内峰值应取最大值');
    });

    test('日常颠簸（20 m/s²）→ 不触发', () {
      final d = DrivingEventDetector(collisionThreshold: 60.0);
      final t0 = DateTime(2026, 9, 25, 10, 0);
      var anyEvent = false;
      for (final t in times(t0, 50)) {
        if (d.onAccel(Vector3(0, 15, 9.8), t) != null) anyEvent = true;
      }
      expect(anyEvent, isFalse);
    });
  });

  group('DrivingEventDetector - 10s 去抖合并', () {
    test('急刹 10s 内再次触发 → mergedIntoPrevious=true，且不更新发射时间', () {
      final d = DrivingEventDetector(brakingThreshold: 3.0);
      final t0 = DateTime(2026, 9, 25, 10, 0);
      DetectedEvent? first, second;

      // 第一次：600ms -4m/s²，速度下降
      var speed = 16.7;
      var i = 0;
      for (final t in times(t0, 31)) {
        speed = 16.7 - 4.0 * (i++ * 0.02);
        d.onSpeed(speed, t);
        final e = d.onUserAccel(Vector3(0, -4, 0), t);
        if (e != null) first = e;
      }
      expect(first, isNotNull);
      expect(first!.mergedIntoPrevious, isFalse);

      // 3 秒后第二次急刹（去抖窗口内）
      final t1 = t0.add(const Duration(seconds: 3));
      speed = 14.5;
      i = 0;
      for (final t in times(t1, 31)) {
        speed = 14.5 - 4.0 * (i++ * 0.02);
        d.onSpeed(speed, t);
        final e = d.onUserAccel(Vector3(0, -4, 0), t);
        if (e != null) second = e;
      }
      expect(second, isNotNull);
      expect(second!.mergedIntoPrevious, isTrue,
          reason: '3s < 10s 去抖窗口，应合并');

      // 12 秒后第三次 → 新事件
      final t2 = t0.add(const Duration(seconds: 13));
      DetectedEvent? third;
      speed = 12.0;
      i = 0;
      for (final t in times(t2, 31)) {
        speed = 12.0 - 4.0 * (i++ * 0.02);
        d.onSpeed(speed, t);
        final e = d.onUserAccel(Vector3(0, -4, 0), t);
        if (e != null) third = e;
      }
      expect(third, isNotNull);
      expect(third!.mergedIntoPrevious, isFalse,
          reason: '13s > 10s 去抖窗口，应为新事件');
    });

    test('碰撞去抖：同类合并，跨类型不合并', () {
      final d = DrivingEventDetector(collisionThreshold: 60.0);
      final t0 = DateTime(2026, 9, 25, 10, 0);
      // 第一次碰撞
      var e1 = d.onAccel(Vector3(0, 0, 70), t0);
      e1 = e1 ?? d.onAccel(Vector3(0, 0, 70), t0.add(period * 5));
      expect(e1, isNotNull);
      expect(e1!.mergedIntoPrevious, isFalse);

      // 2s 后第二次碰撞（需再喂一帧让 80ms 窗口结算）→ 合并
      final t2 = t0.add(const Duration(seconds: 2));
      final e2 = d.onAccel(Vector3(0, 0, 80), t2) ??
          d.onAccel(Vector3(0, 0, 80), t2.add(period * 5));
      expect(e2, isNotNull);
      expect(e2!.mergedIntoPrevious, isTrue);
    });
  });

  group('DrivingEventDetector - 参数可调', () {
    test('阈值 5 时 -4m/s² 不触发急刹', () {
      final d = DrivingEventDetector(brakingThreshold: 5.0);
      final t0 = DateTime(2026, 9, 25, 10, 0);
      var speed = 16.7;
      var anyEvent = false;
      var i = 0;
      for (final t in times(t0, 31)) {
        speed = 16.7 - 4.0 * (i++ * 0.02);
        d.onSpeed(speed, t);
        if (d.onUserAccel(Vector3(0, -4, 0), t) != null) anyEvent = true;
      }
      expect(anyEvent, isFalse);
    });

    test('运行时更新阈值立即生效（记录开始时重建参数场景）', () {
      final d = DrivingEventDetector(brakingThreshold: 3.0)
        ..brakingThreshold = 2.0;
      final t0 = DateTime(2026, 9, 25, 10, 0);
      var speed = 16.7;
      var anyEvent = false;
      var i = 0;
      for (final t in times(t0, 31)) {
        speed = 16.7 - 2.5 * (i++ * 0.02);
        d.onSpeed(speed, t);
        if (d.onUserAccel(Vector3(0, -2.5, 0), t) != null) anyEvent = true;
      }
      expect(anyEvent, isTrue, reason: '阈值降为 2 后 -2.5 应触发');
    });
  });
}
