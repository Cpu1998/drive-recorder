import 'package:flutter/foundation.dart';

import '../services/bluetooth_car_service.dart';
import '../services/settings_service.dart';
import '../services/sync/firestore_sync_service_impl.dart';
import '../services/sync/sync_service.dart';
import '../utils/constants.dart';

/// 设置状态：阈值 / 车机绑定 / 云同步开关。
class SettingsProvider extends ChangeNotifier {
  final SettingsService _settings;
  final SyncService _sync;

  SettingsProvider(this._settings, [SyncService? sync])
      : _sync = sync ?? FirestoreSyncServiceImpl() {
    _load();
  }

  // —— 阈值 ——
  double _brakingThreshold = DetectionDefaults.brakingThreshold;
  double get brakingThreshold => _brakingThreshold;

  double _collisionThreshold = DetectionDefaults.collisionThreshold;
  double get collisionThreshold => _collisionThreshold;

  // —— 蓝牙 ——
  bool _btAutoEnabled = false;
  bool get btAutoEnabled => _btAutoEnabled;
  String? _btDeviceName;
  String? get btDeviceName => _btDeviceName;
  String? _btDeviceAddress;
  String? get btDeviceAddress => _btDeviceAddress;

  // —— 高德 Key ——
  String _amapKey = '';
  String get amapKey => _amapKey;

  // —— 同步 ——
  bool _syncEnabled = false;
  bool get syncEnabled => _syncEnabled;
  String? _syncError;
  String? get syncError => _syncError;
  SyncService get syncService => _sync;

  Future<void> _load() async {
    _brakingThreshold = _settings.brakingThreshold;
    _collisionThreshold = _settings.collisionThreshold;
    _btAutoEnabled = _settings.btAutoEnabled;
    _btDeviceName = _settings.btDeviceName;
    _btDeviceAddress = _settings.btDeviceAddress;
    _syncEnabled = _settings.syncEnabled;
    _amapKey = _settings.amapKey;
    notifyListeners();
  }

  Future<void> setBrakingThreshold(double v) async {
    _brakingThreshold = v;
    notifyListeners();
    await _settings.setBrakingThreshold(v);
  }

  Future<void> setCollisionThreshold(double v) async {
    _collisionThreshold = v;
    notifyListeners();
    await _settings.setCollisionThreshold(v);
  }

  Future<void> setAmapKey(String v) async {
    _amapKey = v;
    notifyListeners();
    await _settings.setAmapKey(v);
  }

  Future<void> setBtAutoEnabled(bool v) async {
    _btAutoEnabled = v;
    notifyListeners();
    await _settings.setBtAutoEnabled(v);
  }

  Future<void> bindBtDevice(ClassicBtDevice device) async {
    _btDeviceName = device.name;
    _btDeviceAddress = device.address;
    notifyListeners();
    await _settings.bindBtDevice(device.name, device.address);
  }

  Future<void> unbindBtDevice() async {
    _btDeviceName = null;
    _btDeviceAddress = null;
    notifyListeners();
    await _settings.unbindBtDevice();
  }

  /// 同步开关：开启时尝试初始化 Firebase，失败则回弹并给出原因。
  Future<bool> setSyncEnabled(bool v) async {
    if (v) {
      if (!await _sync.isConfigured()) {
        _syncError = 'Firebase 未配置：请按 README 完成 flutterfire configure 与 '
            'google-services.json 接入后重试';
        notifyListeners();
        return false;
      }
      try {
        await _sync.initialize();
      } on SyncNotConfiguredException {
        _syncError = _sync.lastError ?? 'Firebase 初始化失败';
        notifyListeners();
        return false;
      }
    }
    _syncEnabled = v;
    _syncError = null;
    notifyListeners();
    await _settings.setSyncEnabled(v);
    return true;
  }
}
