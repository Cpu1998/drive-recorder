import 'dart:async';

import 'package:flutter/material.dart';

import '../services/bluetooth_car_service.dart';

/// 车机蓝牙连接状态（供 UI 展示）。
class BluetoothStateProvider extends ChangeNotifier {
  final BluetoothCarService service;

  BluetoothStateProvider(this.service) {
    _sub = service.stateStream.listen((s) {
      state = s;
      notifyListeners();
    });
    state = service.state;
  }

  StreamSubscription? _sub;

  CarConnectionState state = CarConnectionState.unbound;

  String get label => switch (state) {
        CarConnectionState.unbound => '未绑车机',
        CarConnectionState.unavailable => '蓝牙未开',
        CarConnectionState.disconnected => '车机未连',
        CarConnectionState.connected => '车机已连',
      };

  IconData get icon => switch (state) {
        CarConnectionState.unbound => Icons.bluetooth_disabled,
        CarConnectionState.unavailable => Icons.bluetooth_disabled,
        CarConnectionState.disconnected => Icons.bluetooth,
        CarConnectionState.connected => Icons.bluetooth_audio,
      };

  Color get color => switch (state) {
        CarConnectionState.connected => Colors.green,
        CarConnectionState.disconnected => Colors.grey,
        CarConnectionState.unavailable => Colors.orange,
        CarConnectionState.unbound => Colors.grey,
      };

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
