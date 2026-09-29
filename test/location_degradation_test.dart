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

  LocationFix okFix({
    double lat = 30.0,
    double lon = 120.0,
    double? speed,
    LocationSource source = LocationSource.amap,
  }) =>
      LocationFix(
        latitude: lat,
        longitude: lon,
        speed: speed,
        locationTime: DateTime.now(),
        source: source,
      );

  LocationFix errFix({int code = 13, LocationSource source = LocationSource.amap}) =>
      LocationFix(
        locationTime: DateTime.now(),
        errorCode: code,
        errorInfo: 'fake error',
        source: source,
      );
}

/// 可拨动时钟。
class FakeClock {
  DateTime _now = DateTime(2026, 9, 29, 12, 0, 0);
  DateTime now() => _now;
  void advanceMs(int ms) => _now = _now.add(Duration(milliseconds: ms));
}

void main() {
  late FakeClock clock;
  late List<FakeLocator> amaps;
  late List<FakeLocator> systems;

  LocationService build() {
    amaps = [];
    systems = [];
    return LocationService(
      amapFactory: () {
        final l = FakeLocator('amap-${amaps.length}');
        amaps.add(l);
        return l;
      },
      systemFactory: () {
        final l = FakeLocator('system-${systems.length}');
        systems.add(l);
        return l;
      },
      enableWatchdog: false,
      clock: clock.now,
    );
  }

  setUp(() {
    clock = FakeClock();
  });

  test('正常链路：高德供点直达 fixes/lastFix，无需系统兜底', () async {
    final svc = build();
    final received = <LocationFix>[];
    final sub = svc.fixes.listen(received.add);

    svc.start();
    await Future<void>.delayed(Duration.zero);
    amaps.single.emit(amaps.single.okFix(speed: 5));
    await Future<void>.delayed(Duration.zero);

    expect(received, hasLength(1));
    expect(svc.lastFix, isNotNull);
    expect(svc.lastFix!.source, LocationSource.amap);
    expect(svc.runtime, LocationRuntime.amap);
    expect(systems, isEmpty);

    await sub.cancel();
    svc.dispose();
  });

  test('停滞自愈→重启耗尽→降级系统兜底，系统点继续入库', () async {
    final svc = build();
    final received = <LocationFix>[];
    final sub = svc.fixes.listen(received.add);

    svc.start();
    await Future<void>.delayed(Duration.zero);
    expect(amaps, hasLength(1));

    // 停滞 1：间隔 2000 + 宽限 20000 = 22s 后触发重建
    clock.advanceMs(22001);
    svc.checkHealth();
    await Future<void>.delayed(Duration.zero);
    expect(amaps, hasLength(2), reason: '第一次停滞应重建高德客户端');

    // 停滞 2：再次触发重建
    clock.advanceMs(22001);
    svc.checkHealth();
    await Future<void>.delayed(Duration.zero);
    expect(amaps, hasLength(3), reason: '第二次停滞应再次重建');

    // 停滞 3：重建额度耗尽 → 降级系统定位
    clock.advanceMs(22001);
    svc.checkHealth();
    await Future<void>.delayed(Duration.zero);
    expect(systems, hasLength(1), reason: '重启耗尽后应降级到系统定位');
    expect(svc.runtime, LocationRuntime.system);
    expect(amaps.last.disposeCount, 1);

    // 系统点应照常流出且 source=system
    systems.single.emit(systems.single.okFix(source: LocationSource.system));
    await Future<void>.delayed(Duration.zero);
    expect(received.last.source, LocationSource.system);
    expect(svc.lastFix!.source, LocationSource.system);

    await sub.cancel();
    svc.dispose();
  });

  test('降级后回升：高德探测出点即切回并停掉系统流', () async {
    final svc = build();
    final received = <LocationFix>[];
    final sub = svc.fixes.listen(received.add);

    svc.start();
    await Future<void>.delayed(Duration.zero);

    // 连续 9 次错误（3 次→重建1，3 次→重建2，3 次→降级）
    for (var i = 0; i < 3; i++) {
      amaps[0].emit(amaps[0].errFix());
      await Future<void>.delayed(Duration.zero);
    }
    expect(amaps, hasLength(2));
    for (var i = 0; i < 3; i++) {
      amaps[1].emit(amaps[1].errFix());
      await Future<void>.delayed(Duration.zero);
    }
    expect(amaps, hasLength(3));
    for (var i = 0; i < 3; i++) {
      amaps[2].emit(amaps[2].errFix());
      await Future<void>.delayed(Duration.zero);
    }
    expect(svc.runtime, LocationRuntime.system);
    expect(systems, hasLength(1));

    // 回升探测：新高德实例启动，系统仍供点
    await svc.escalateNow();
    expect(amaps, hasLength(4));
    expect(svc.runtime, LocationRuntime.amapRecovering);
    systems.single.emit(systems.single.okFix(source: LocationSource.system));
    await Future<void>.delayed(Duration.zero);
    expect(svc.lastFix!.source, LocationSource.system);

    // 高德出点 → 切回
    amaps.last.emit(amaps.last.okFix(speed: 8));
    await Future<void>.delayed(Duration.zero);
    expect(svc.runtime, LocationRuntime.amap);
    expect(svc.lastFix!.source, LocationSource.amap);
    expect(systems.single.stopCount, greaterThanOrEqualTo(1),
        reason: '切回高德后系统兜底应停止');

    await sub.cancel();
    svc.dispose();
  });

  test('系统兜底下模式自适应仍生效（静止切 30s 间隔）', () async {
    final svc = build();
    final sub = svc.fixes.listen((_) {});

    svc.start();
    await Future<void>.delayed(Duration.zero);

    // 快速降级：3 轮各 3 次错误
    for (var round = 0; round < 3; round++) {
      for (var i = 0; i < 3; i++) {
        amaps[round].emit(amaps[round].errFix());
        await Future<void>.delayed(Duration.zero);
      }
    }
    expect(svc.runtime, LocationRuntime.system);

    // 系统低速 ×3 → 切静止模式，系统定位应收到 30s 间隔
    for (var i = 0; i < 3; i++) {
      systems.single
          .emit(systems.single.okFix(speed: 0.2, source: LocationSource.system));
      await Future<void>.delayed(Duration.zero);
    }
    expect(svc.mode, LocationMode.stationary);
    expect(systems.single.intervals, contains(LocationTuning.stationaryIntervalMs));

    await sub.cancel();
    svc.dispose();
  });

  test('stop 后看门狗不再动作，重启计数重置', () async {
    final svc = build();
    svc.start();
    await Future<void>.delayed(Duration.zero);

    clock.advanceMs(22001);
    svc.checkHealth();
    expect(amaps, hasLength(2));

    svc.stop();
    clock.advanceMs(60000);
    svc.checkHealth(); // 已停止，不应有任何动作
    expect(amaps, hasLength(2));
    expect(systems, isEmpty);

    svc.start();
    expect(svc.amapRestartCount, 0, reason: '新记录会话重启额度应重置');
    svc.dispose();
  });
}
