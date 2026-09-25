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
import 'package:drive_recorder/utils/constants.dart';

/// 设置页「高德 Key」输入框：保存持久化 + 已存值回显。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(Widget child, SettingsProvider settings) => MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<BluetoothStateProvider>(
            create: (_) => BluetoothStateProvider(BluetoothCarService()),
          ),
        ],
        child: MaterialApp(home: child),
      );

  testWidgets('输入 Key 保存 → 持久化到 SharedPreferences + 提示重启',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final settings =
        SettingsProvider(SettingsService(prefs), _NoopSync());
    await tester.pumpAndSettle();

    await tester.pumpWidget(wrap(const SettingsScreen(), settings));
    await tester.pumpAndSettle();

    expect(find.text('高德地图 Key'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'abc123key456def');
    await tester.tap(find.text('保存'));
    await tester.pump();

    expect(prefs.getString(PrefKeys.amapKey), 'abc123key456def');
    expect(find.textContaining('重启 App 后生效'), findsOneWidget);
    expect(settings.amapKey, 'abc123key456def');
  });

  testWidgets('已保存的 Key 在重新打开设置页时回显', (tester) async {
    SharedPreferences.setMockInitialValues({PrefKeys.amapKey: 'existing999'});
    final prefs = await SharedPreferences.getInstance();
    final settings =
        SettingsProvider(SettingsService(prefs), _NoopSync());
    await tester.pumpAndSettle();

    await tester.pumpWidget(wrap(const SettingsScreen(), settings));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.controller?.text, 'existing999');
  });
}

class _NoopSync implements SyncService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
