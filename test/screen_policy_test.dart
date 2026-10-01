import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

import 'package:drive_recorder/providers/bluetooth_state_provider.dart';
import 'package:drive_recorder/providers/recording_provider.dart';
import 'package:drive_recorder/providers/settings_provider.dart';
import 'package:drive_recorder/providers/tracks_provider.dart';
import 'package:drive_recorder/screens/record_screen.dart';
import 'package:drive_recorder/services/bluetooth_car_service.dart';
import 'package:drive_recorder/services/database/app_database.dart';
import 'package:drive_recorder/services/foreground_service.dart';
import 'package:drive_recorder/services/location_service.dart';
import 'package:drive_recorder/services/permission_service.dart';
import 'package:drive_recorder/services/screen_policy_controller.dart';
import 'package:drive_recorder/services/sensor_service.dart';
import 'package:drive_recorder/services/settings_service.dart';
import 'package:drive_recorder/services/sync/sync_service.dart';
import 'package:drive_recorder/utils/constants.dart';
import 'package:drive_recorder/widgets/fake_off_overlay.dart';

/// 「定位时屏幕」策略（v1.9.0）：设置持久化 + 记录状态 → wakelock/覆盖层。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('设置持久化：ScreenPolicy 存取、默认值、未知值回落、重启后恢复', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final svc = SettingsService(prefs);

    // 默认 system
    expect(svc.screenPolicy, ScreenPolicy.system);
    expect(prefs.getString(PrefKeys.screenPolicy), isNull);

    // SettingsProvider 层保存 → SharedPreferences 持久化
    final provider = SettingsProvider(svc, _NoopSync());
    await provider.setScreenPolicy(ScreenPolicy.keepOn);
    expect(prefs.getString(PrefKeys.screenPolicy), 'keepOn');
    expect(provider.screenPolicy, ScreenPolicy.keepOn);

    // 模拟重启：新实例从持久化恢复
    expect(SettingsService(prefs).screenPolicy, ScreenPolicy.keepOn);

    // 未知/损坏值回落 system
    await prefs.setString(PrefKeys.screenPolicy, 'garbage');
    expect(svc.screenPolicy, ScreenPolicy.system);
  });

  test('ScreenPolicyController：记录状态 → wakelock/覆盖层应用与释放', () async {
    final toggles = <bool>[];
    final ctl = ScreenPolicyController(
      wakelockToggle: (on) async => toggles.add(on),
    );

    // system 策略：记录中也不持有 wakelock
    await ctl.applyRecordingState(true, ScreenPolicy.system);
    expect(ctl.wakelockHeld, isFalse);
    expect(ctl.fakeOffActive, isFalse);
    expect(toggles, isEmpty);

    // keepOn：记录中持有 wakelock，无覆盖层
    await ctl.applyRecordingState(true, ScreenPolicy.keepOn);
    expect(ctl.wakelockHeld, isTrue);
    expect(ctl.fakeOffActive, isFalse);
    expect(toggles, [true]);

    // 停止（或暂停）：释放
    await ctl.applyRecordingState(false, ScreenPolicy.keepOn);
    expect(ctl.wakelockHeld, isFalse);
    expect(toggles, [true, false]);

    // fakeOff：记录中 wakelock + 自动进入黑屏
    await ctl.applyRecordingState(true, ScreenPolicy.fakeOff);
    expect(ctl.wakelockHeld, isTrue);
    expect(ctl.fakeOffActive, isTrue);
    expect(toggles, [true, false, true]);

    // 点按临时退出黑屏：覆盖层收起，wakelock 保持
    ctl.exitFakeOff();
    expect(ctl.fakeOffActive, isFalse);
    expect(ctl.wakelockHeld, isTrue);
    expect(toggles.length, 3, reason: '退出黑屏不应触碰 wakelock');

    // 记录页按钮再进入
    ctl.enterFakeOff();
    expect(ctl.fakeOffActive, isTrue);

    // 停止：全释放
    await ctl.releaseAll();
    expect(ctl.wakelockHeld, isFalse);
    expect(ctl.fakeOffActive, isFalse);
    expect(toggles, [true, false, true, false]);
  });

  test('RecordingProvider：开始/暂停/继续/停止驱动屏幕策略', () async {
    final harness = await _RecordingHarness.create(ScreenPolicy.fakeOff);
    final rec = harness.rec;
    final screen = harness.screen;

    // 开始记录（fakeOff）：自动 wakelock + 自动黑屏
    expect(await rec.start(), isTrue);
    expect(screen.wakelockHeld, isTrue);
    expect(screen.fakeOffActive, isTrue);

    // 暂停：释放 wakelock、收起覆盖层（定位/传感器也停了，恢复系统行为）
    await rec.pause();
    expect(screen.wakelockHeld, isFalse);
    expect(screen.fakeOffActive, isFalse);

    // 继续：重新应用（含自动回到黑屏）
    await rec.resume();
    expect(screen.wakelockHeld, isTrue);
    expect(screen.fakeOffActive, isTrue);

    // 点按退出黑屏后停止：wakelock 也释放
    screen.exitFakeOff();
    await rec.stop();
    expect(screen.wakelockHeld, isFalse);
    expect(screen.fakeOffActive, isFalse);

    // 记录中切策略立即生效：keepOn 下重新开始 → 只常亮、不黑屏
    await harness.settingsProvider.setScreenPolicy(ScreenPolicy.keepOn);
    expect(await rec.start(), isTrue);
    expect(screen.wakelockHeld, isTrue);
    expect(screen.fakeOffActive, isFalse);
    await rec.stop();
    expect(screen.wakelockHeld, isFalse);

    await harness.dispose();
  });

  testWidgets('假熄屏覆盖层：记录开始自动黑屏，点按退出，按钮可再进入', (tester) async {
    late final _RecordingHarness harness;
    var started = false;
    await tester.runAsync(() async {
      harness = await _RecordingHarness.create(ScreenPolicy.fakeOff);
      started = await harness.rec.start();
    });
    expect(started, isTrue);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>.value(
            value: harness.settingsProvider,
          ),
          ChangeNotifierProvider<TracksProvider>.value(value: harness.tracks),
          ChangeNotifierProvider<RecordingProvider>.value(value: harness.rec),
          ChangeNotifierProvider<BluetoothStateProvider>(
            create: (_) => BluetoothStateProvider(BluetoothCarService()),
          ),
        ],
        child: MaterialApp(
          home: const RecordScreen(),
          builder: (context, child) =>
              ScreenPolicyHost(child: child ?? const SizedBox.shrink()),
        ),
      ),
    );
    // 记录页与覆盖层都有 1s 周期 ticker，禁用 pumpAndSettle（永不满帧），
    // 只 pump 固定帧数验证状态机
    await tester.pump();
    await tester.pump();

    // 记录一开始：全屏黑覆盖层已盖上（记录页内容仍在其下）
    expect(find.byType(FakeOffOverlay), findsOneWidget);
    expect(find.text('点按屏幕临时退出黑屏'), findsOneWidget);
    expect(find.text('熄屏保活'), findsNothing, reason: '黑屏中不需要显示再进入按钮');

    // 点按任意处：临时退出黑屏，记录页可见 + 「熄屏保活」按钮出现
    await tester.tap(find.byType(FakeOffOverlay));
    await tester.pump();
    expect(find.byType(FakeOffOverlay), findsNothing);
    expect(
      harness.screen.wakelockHeld,
      isTrue,
      reason: '退出黑屏后 wakelock 保持到记录结束',
    );
    expect(find.text('熄屏保活'), findsOneWidget);

    // 点按钮：重新进入黑屏
    await tester.tap(find.text('熄屏保活'));
    await tester.pump();
    expect(find.byType(FakeOffOverlay), findsOneWidget);

    // 停止记录：覆盖层收起
    await tester.runAsync(() async {
      await harness.rec.stop();
    });
    await tester.pump();
    expect(
      find.byType(FakeOffOverlay),
      findsNothing,
      reason: '停止记录后覆盖层收起、wakelock 释放',
    );
    expect(harness.screen.wakelockHeld, isFalse);

    // 收尾：卸载页面（取消周期 ticker）+ 释放 db，避免遗留定时器/资源
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await harness.dispose();
    });
  });
}

/// 桌面端 RecordingProvider 测试装配：内存库 + 各服务空转桩。
class _RecordingHarness {
  final AppDatabase db;
  final SettingsProvider settingsProvider;
  final TracksProvider tracks;
  final RecordingProvider rec;
  final ScreenPolicyController screen;

  const _RecordingHarness(
    this.db,
    this.settingsProvider,
    this.tracks,
    this.rec,
    this.screen,
  );

  static Future<_RecordingHarness> create(ScreenPolicy policy) async {
    sqfliteFfiInit();
    // Linux 宿主机通常只有 libsqlite3.so.0（无 -dev 的 .so 链接），显式指向
    if (Platform.isLinux) {
      open.overrideFor(
          OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
    }
    final db = await AppDatabase.open(
      path: inMemoryDatabasePath,
      factoryOverride: databaseFactoryFfiNoIsolate,
    );

    SharedPreferences.setMockInitialValues({
      PrefKeys.screenPolicy: policy.name,
    });
    final prefs = await SharedPreferences.getInstance();
    final settings = SettingsService(prefs);
    final settingsProvider = SettingsProvider(settings, _NoopSync());
    await settingsProvider.setScreenPolicy(policy);

    final tracks = TracksProvider(db);
    final screen = ScreenPolicyController(wakelockToggle: (on) async {});
    final rec = RecordingProvider(
      db: db,
      settings: settings,
      settingsProvider: settingsProvider,
      tracks: tracks,
      locationService: _NoopLocation(),
      sensorService: _NoopSensors(),
      foregroundService: _NoopForeground(),
      permissionService: _OkPermissions(),
      screenPolicyController: screen,
    );
    return _RecordingHarness(db, settingsProvider, tracks, rec, screen);
  }

  Future<void> dispose() async {
    rec.dispose();
    await db.close();
  }
}

class _NoopSync implements SyncService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoopLocation extends LocationService {
  @override
  void start({LocationMode initial = LocationMode.moving}) {}

  @override
  void stop() {}
}

class _NoopSensors extends SensorService {
  @override
  void start() {}

  @override
  void stop() {}
}

class _NoopForeground extends ForegroundServiceController {
  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

class _OkPermissions extends PermissionService {
  @override
  Future<PermissionResult> ensureRecordingPermissions() async =>
      const PermissionResult(ok: true, missing: []);
}
