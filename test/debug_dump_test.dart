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

class _DbgSync extends SyncService {
  @override
  Future<void> deleteTrack(int trackId) async {}
  @override
  Future<void> initialize() async { throw SyncNotConfiguredException(); }
  @override
  Future<bool> isConfigured() async => false;
  @override
  Future<void> uploadTrack(track, points, events) async {}
  @override
  String? lastError;
}

void main() {
  testWidgets('dump texts', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final settings = SettingsProvider(SettingsService(prefs), _DbgSync());
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ChangeNotifierProvider<BluetoothStateProvider>(
          create: (_) => BluetoothStateProvider(BluetoothCarService()),
        ),
      ],
      child: MaterialApp(home: const SettingsScreen()),
    ));
    await tester.pumpAndSettle();
    final texts = find
        .descendant(of: find.byType(MaterialApp), matching: find.byType(Text))
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .toList();
    // ignore: avoid_print
    texts.forEach((t) => print('TEXT>> $t'));
  });
}
