import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../utils/constants.dart';

/// 应用设置（SharedPreferences 持久化）。
class SettingsService {
  final SharedPreferences prefs;

  SettingsService(this.prefs);

  // —— 阈值 ——
  double get brakingThreshold =>
      prefs.getDouble(PrefKeys.brakingThreshold) ??
      3.0;
  Future<void> setBrakingThreshold(double v) =>
      prefs.setDouble(PrefKeys.brakingThreshold, v);

  double get collisionThreshold =>
      prefs.getDouble(PrefKeys.collisionThreshold) ??
      60.0;
  Future<void> setCollisionThreshold(double v) =>
      prefs.setDouble(PrefKeys.collisionThreshold, v);

  // —— 蓝牙车机 ——
  bool get btAutoEnabled => prefs.getBool(PrefKeys.btAutoEnabled) ?? false;
  Future<void> setBtAutoEnabled(bool v) =>
      prefs.setBool(PrefKeys.btAutoEnabled, v);

  String? get btDeviceName => prefs.getString(PrefKeys.btDeviceName);
  String? get btDeviceAddress => prefs.getString(PrefKeys.btDeviceAddress);

  Future<void> bindBtDevice(String name, String address) async {
    await prefs.setString(PrefKeys.btDeviceName, name);
    await prefs.setString(PrefKeys.btDeviceAddress, address);
  }

  Future<void> unbindBtDevice() async {
    await prefs.remove(PrefKeys.btDeviceName);
    await prefs.remove(PrefKeys.btDeviceAddress);
  }

  // —— 云同步 ——
  bool get syncEnabled => prefs.getBool(PrefKeys.syncEnabled) ?? false;
  Future<void> setSyncEnabled(bool v) =>
      prefs.setBool(PrefKeys.syncEnabled, v);

  // —— 高德隐私 ——
  bool get amapPrivacyAgreed =>
      prefs.getBool(PrefKeys.amapPrivacyAgreed) ?? false;
  Future<void> setAmapPrivacyAgreed(bool v) =>
      prefs.setBool(PrefKeys.amapPrivacyAgreed, v);
}
