import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:drive_recorder/providers/bluetooth_state_provider.dart';
import 'package:drive_recorder/providers/settings_provider.dart';
import 'package:drive_recorder/screens/settings_screen.dart';
import 'package:drive_recorder/services/bluetooth_car_service.dart';
import 'package:drive_recorder/services/settings_service.dart';
import 'package:drive_recorder/services/sync/sync_service.dart';
import 'package:drive_recorder/utils/formatters.dart';

/// 无配置同步 stub：isConfigured 恒 false（覆盖"默认关闭/未接入不崩"路径）。
class _UnconfiguredSync extends SyncService {
  @override
  Future<void> deleteTrack(int trackId) async {}

  @override
  Future<void> initialize() async {
    throw SyncNotConfiguredException();
  }

  @override
  Future<bool> isConfigured() async => false;

  @override
  Future<void> uploadTrack(track, points, events) async {}

  @override
  String? lastError;
}

Widget _wrap(Widget child, SettingsProvider settings) => MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ChangeNotifierProvider<BluetoothStateProvider>(
          create: (_) => BluetoothStateProvider(BluetoothCarService()),
        ),
      ],
      child: MaterialApp(home: child),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('formatters', () {
    expect(formatDuration(const Duration(seconds: 45)), '45s');
    expect(formatDuration(const Duration(minutes: 12, seconds: 3)), '12:03');
    expect(formatDuration(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '1:02:03');
    expect(formatDistance(856.4), '856 m');
    expect(formatDistance(1234.5), '1.2 km');
    expect(formatSpeed(null), '-- km/h');
    expect(formatSpeed(16.6667), '60 km/h');
    expect(formatIntensity(-4.24), '-4.2 m/s²');
    expect(defaultTrackName(DateTime(2026, 9, 25, 9, 5)), '9月25日 09:05');
  });

  testWidgets('设置页渲染 + 未配置时开同步被拒绝并回弹',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final settings = SettingsProvider(
      SettingsService(prefs),
      _UnconfiguredSync(),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(_wrap(const SettingsScreen(), settings));
    await tester.pumpAndSettle();

    expect(find.text('急刹减速度阈值'), findsOneWidget);
    expect(find.text('碰撞加速度阈值'), findsOneWidget);
    // 车机开关被顶出首屏（v1.3.0 设置页顶部新增 Key/日志入口），先滚到可见
    await tester.scrollUntilVisible(find.text('连上车机自动开始记录'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('连上车机自动开始记录'), findsOneWidget);

    // 滑块默认值展示（未滚动时可见，先断言）
    expect(find.text('3.0 m/s²（持续 ≥500ms 触发；越大越不敏感）'),
        findsOneWidget);

    // 同步开关在屏幕外，先滚动到可见
    await tester.scrollUntilVisible(
        find.text('同步轨迹到 Firestore'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('同步轨迹到 Firestore'), findsOneWidget);

    // 未配置 Firebase：打开开关 → 回弹 + SnackBar 报错
    final syncSwitch = find.descendant(
      of: find.ancestor(
        of: find.text('同步轨迹到 Firestore'),
        matching: find.byType(SwitchListTile),
      ),
      matching: find.byType(Switch),
    );
    await tester.ensureVisible(syncSwitch);
    await tester.tap(syncSwitch);
    await tester.pump(); // snackbar 出现
    expect(find.byType(SnackBar), findsOneWidget);
    expect(settings.syncEnabled, isFalse, reason: '未配置时开关应回弹');
    await tester.pumpAndSettle(const Duration(seconds: 4));
  });

  testWidgets('阈值滑块拖动更新设置值', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final settings = SettingsProvider(SettingsService(prefs), _UnconfiguredSync());
    await tester.pumpAndSettle();

    await tester.pumpWidget(_wrap(const SettingsScreen(), settings));
    await tester.pumpAndSettle();

    final slider = find.byType(Slider).first;
    await tester.drag(slider, const Offset(120, 0));
    await tester.pumpAndSettle();
    expect(settings.brakingThreshold, greaterThan(3.0));
    expect(prefs.getDouble('braking_threshold'), greaterThan(3.0),
        reason: '阈值应已持久化到 SharedPreferences');
  });
}
