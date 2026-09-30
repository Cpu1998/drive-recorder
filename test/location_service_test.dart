import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:drive_recorder/services/locators.dart';
import 'package:drive_recorder/services/location_service.dart';
import 'package:drive_recorder/utils/constants.dart';

/// 可控假定位器：手动灌入定位事件，记录 start/stop/applyInterval 调用。
class FakeLocator implements ContinuousLocator {
  FakeLocator(this.name);

  @override
  final String name;

  final _fixes = StreamController<LocationFix>.broadcast();
  int startCount = 0;
  int stopCount = 0;
  int disposeCount = 0;
  final List<int> intervals = [];

  @override
  Stream<LocationFix> get fixes => _fixes.stream;

  @override
  Future<void> start({required int intervalMs}) async {
    startCount++;
    intervals.add(intervalMs);
  }

  @override
  Future<void> applyInterval(int intervalMs) async {
    intervals.add(intervalMs);
  }

  @override
  Future<void> stop() async => stopCount++;

  @override
  Future<void> dispose() async {
    disposeCount++;
    stopCount++;
    await _fixes.close();
  }

  void emit(LocationFix fix) => _fixes.add(fix);

  LocationFix okFix({double lat = 30.0, double lon = 120.0, double? speed}) =>
      LocationFix(
        latitude: lat,
        longitude: lon,
        speed: speed,
        locationTime: DateTime.now(),
      );

  LocationFix errFix({int code = 1000}) => LocationFix(
        locationTime: DateTime.now(),
        errorCode: code,
        errorInfo: 'fake error',
      );
}

/// 可拨动时钟。
class FakeClock {
  DateTime _now = DateTime(2026, 9, 30, 12, 0, 0);
  DateTime now() => _now;
  void advanceMs(int ms) => _now = _now.add(Duration(milliseconds: ms));
}

void main() {
  late FakeClock clock;
  late FakeLocator system;

  LocationService build() {
    system = FakeLocator('system');
    return LocationService(
      systemFactory: () => system,
      enableWatchdog: false,
      clock: clock.now,
    );
  }

  setUp(() {
    clock = FakeClock();
  });

  test('系统定位供点直达 fixes/lastFix，runtime=running', () async {
    final svc = build();
    final received = <LocationFix>[];
    final sub = svc.fixes.listen(received.add);

    svc.start();
    await Future<void>.delayed(Duration.zero);
    expect(system.startCount, 1);
    expect(system.intervals.single, LocationTuning.movingIntervalMs);
    expect(svc.runtime, LocationRuntime.running);

    system.emit(system.okFix(speed: 5));
    await Future<void>.delayed(Duration.zero);

    expect(received, hasLength(1));
    expect(svc.lastFix, isNotNull);
    expect(svc.lastFix!.isOk, isTrue);

    await sub.cancel();
    svc.dispose();
  });

  test('行驶/静止自适应：低速×3 切 30s，再高速切回 2s', () async {
    final svc = build();
    final sub = svc.fixes.listen((_) {});

    svc.start();
    await Future<void>.delayed(Duration.zero);

    for (var i = 0; i < 3; i++) {
      system.emit(system.okFix(speed: 0.2));
      await Future<void>.delayed(Duration.zero);
    }
    expect(svc.mode, LocationMode.stationary);
    expect(system.intervals, contains(LocationTuning.stationaryIntervalMs));

    system.emit(system.okFix(speed: 5));
    await Future<void>.delayed(Duration.zero);
    expect(svc.mode, LocationMode.moving);
    expect(system.intervals.last, LocationTuning.movingIntervalMs);

    await sub.cancel();
    svc.dispose();
  });

  test('停滞看门狗：超过 间隔+宽限 无回调 → 重建定位流', () async {
    final svc = build();
    svc.start();
    await Future<void>.delayed(Duration.zero);

    // moving 间隔 2000 + stallGrace 20000 + extraGrace 20000 = 42000ms
    clock.advanceMs(42001);
    svc.checkHealth();
    await Future<void>.delayed(Duration.zero);
    expect(system.startCount, 2, reason: '停滞应重启系统定位流');

    // 供点后窗口重置，短期不再触发
    system.emit(system.okFix(speed: 5));
    await Future<void>.delayed(Duration.zero);
    clock.advanceMs(1000);
    svc.checkHealth();
    expect(system.startCount, 2);

    svc.dispose();
  });

  test('失败事件透传且不更新 lastFix', () async {
    final svc = build();
    final received = <LocationFix>[];
    final sub = svc.fixes.listen(received.add);

    svc.start();
    await Future<void>.delayed(Duration.zero);
    system.emit(system.okFix());
    await Future<void>.delayed(Duration.zero);

    system.emit(system.errFix());
    await Future<void>.delayed(Duration.zero);

    expect(received, hasLength(2));
    expect(received.last.isOk, isFalse);
    expect(svc.lastFix!.isOk, isTrue, reason: '失败点不应覆盖 lastFix');

    await sub.cancel();
    svc.dispose();
  });

  test('stop 停流；再次 start 恢复且间隔重置为 moving', () async {
    final svc = build();
    svc.start();
    await Future<void>.delayed(Duration.zero);

    // 切到静止再停
    for (var i = 0; i < 3; i++) {
      system.emit(system.okFix(speed: 0.2));
      await Future<void>.delayed(Duration.zero);
    }
    expect(svc.mode, LocationMode.stationary);

    svc.stop();
    expect(svc.runtime, LocationRuntime.stopped);
    expect(system.stopCount, greaterThanOrEqualTo(1));

    svc.start();
    await Future<void>.delayed(Duration.zero);
    expect(svc.mode, LocationMode.moving, reason: '新会话应从 moving 模式开始');
    expect(system.intervals.last, LocationTuning.movingIntervalMs);

    svc.dispose();
  });
}
