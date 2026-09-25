import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'providers/bluetooth_state_provider.dart';
import 'providers/recording_provider.dart';
import 'providers/settings_provider.dart';
import 'providers/tracks_provider.dart';
import 'services/bluetooth_car_service.dart';
import 'services/database/app_database.dart';
import 'services/settings_service.dart';
import 'services/sync/firestore_sync_service_impl.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final db = await AppDatabase.open();
  final prefs = await SharedPreferences.getInstance();
  final settings = SettingsService(prefs);
  final bluetooth = BluetoothCarService();

  final settingsProvider = SettingsProvider(settings, FirestoreSyncServiceImpl());
  final tracksProvider = TracksProvider(db, sync: settingsProvider.syncService);

  final recording = RecordingProvider(
    db: db,
    settings: settings,
    settingsProvider: settingsProvider,
    tracks: tracksProvider,
  );

  // 车机蓝牙：恢复绑定并启动监测，连/断事件接入记录编排
  if (settings.btDeviceName != null && settings.btDeviceAddress != null) {
    bluetooth.boundDevice = ClassicBtDevice(
      name: settings.btDeviceName!,
      address: settings.btDeviceAddress!,
    );
  }
  bluetooth.autoEnabled = settings.btAutoEnabled;
  await bluetooth.start();
  recording.attachBluetoothEvents(bluetooth.connectionEvents);

  await tracksProvider.refresh();

  runApp(DriveRecorderApp(
    db: db,
    bluetooth: bluetooth,
    settingsProvider: settingsProvider,
    tracksProvider: tracksProvider,
    recordingProvider: recording,
    bluetoothStateProvider: BluetoothStateProvider(bluetooth),
  ));
}

/// 根组件：装配 MultiProvider。
class DriveRecorderApp extends StatelessWidget {
  final AppDatabase db;
  final BluetoothCarService bluetooth;
  final SettingsProvider settingsProvider;
  final TracksProvider tracksProvider;
  final RecordingProvider recordingProvider;
  final BluetoothStateProvider bluetoothStateProvider;

  const DriveRecorderApp({
    super.key,
    required this.db,
    required this.bluetooth,
    required this.settingsProvider,
    required this.tracksProvider,
    required this.recordingProvider,
    required this.bluetoothStateProvider,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AppDatabase>.value(value: db),
        Provider<BluetoothCarService>.value(value: bluetooth),
        ChangeNotifierProvider<SettingsProvider>.value(value: settingsProvider),
        ChangeNotifierProvider<TracksProvider>.value(value: tracksProvider),
        ChangeNotifierProvider<RecordingProvider>.value(
            value: recordingProvider),
        ChangeNotifierProvider<BluetoothStateProvider>.value(
            value: bluetoothStateProvider),
      ],
      child: const DriveRecorderAppView(),
    );
  }
}
