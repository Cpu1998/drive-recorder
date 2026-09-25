import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'providers/bluetooth_state_provider.dart';
import 'providers/recording_provider.dart';
import 'providers/settings_provider.dart';
import 'providers/tracks_provider.dart';
import 'services/bluetooth_car_service.dart';
import 'package:amap_flutter_location/amap_flutter_location.dart';

import 'services/app_logger.dart';
import 'utils/constants.dart';
import 'services/database/app_database.dart';
import 'services/sample_track_seeder.dart';
import 'services/settings_service.dart';
import 'services/sync/firestore_sync_service_impl.dart';

Future<void> main() async {
  AppLogger.attachGlobalHandlers();
  AppLogger.i('app', '进程启动 v${AppInfo.version}');
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
  // 高德定位 Key：设置页配置的 Key 在启动时注入定位 SDK（SDK 限制：
  // 只能在创建定位客户端前设置，故放启动路径；地图 Key 则在地图组件内注入）
  final amapKey = settings.amapKey;
  if (amapKey.isNotEmpty) {
    AMapFlutterLocation.setApiKey(amapKey, '');
    AppLogger.i('key', '定位 Key 已注入：${AppLogger.maskKey(amapKey)}');
  } else {
    AppLogger.w('key', '未配置高德 Key（设置页可填），使用打包内置 Key');
  }

  bluetooth.autoEnabled = settings.btAutoEnabled;
  try {
    await bluetooth.start();
    AppLogger.i('bluetooth', '车机蓝牙监测已启动');
  } catch (e) {
    // 蓝牙启动失败不阻塞 App（部分设备无蓝牙/权限拒绝时也能正常用）
    AppLogger.w('bluetooth', '蓝牙监测启动失败（忽略）：$e');
  }
  recording.attachBluetoothEvents(bluetooth.connectionEvents);

  // 首次启动种入示例轨迹（无高德 Key 时定位不可用，示例保证详情页可体验）
  final seeded = await SampleTrackSeeder(db, prefs).seedIfNeeded();
  AppLogger.i('sample', seeded ? '已种入示例轨迹（可删除）' : '未种入示例轨迹（已种过或已有轨迹）');

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
