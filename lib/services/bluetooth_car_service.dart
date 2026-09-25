import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../utils/constants.dart';

/// 已连接经典蓝牙设备（名称 + MAC）。
@immutable
class ClassicBtDevice {
  final String name;
  final String address;
  const ClassicBtDevice({required this.name, required this.address});

  @override
  bool operator ==(Object other) =>
      other is ClassicBtDevice && other.address == address;

  @override
  int get hashCode => address.hashCode;
}

/// 蓝牙车机状态。
enum CarConnectionState {
  /// 未绑定车机
  unbound,

  /// 蓝牙关闭/无权限，无法监测
  unavailable,

  /// 已绑定、当前未连接
  disconnected,

  /// 已连接（记录中自动启停生效）
  connected,
}

/// 车机蓝牙自动启停服务。
///
/// - 经典蓝牙（A2DP/HFP）连接查询走原生通道 `drive_recorder/bluetooth`
///   （flutter_blue_plus 只覆盖 BLE，车机多媒体多为经典蓝牙）；
/// - flutter_blue_plus 负责：蓝牙开关状态监听、能力探测；
/// - 轮询周期 5s；断开后启动 30s 宽限计时，期间重连则取消；
/// - 匹配规则：优先 MAC 精确匹配，其次名称匹配（换新车机不换名字也能认）。
class BluetoothCarService {
  static const _btChannel = MethodChannel('drive_recorder/bluetooth');

  /// 绑定的车机（null = 未绑定）。
  ClassicBtDevice? boundDevice;

  /// 自动启停是否启用。
  bool autoEnabled = false;

  CarConnectionState _state = CarConnectionState.unbound;
  CarConnectionState get state => _state;

  final _stateController = StreamController<CarConnectionState>.broadcast();
  Stream<CarConnectionState> get stateStream => _stateController.stream;

  /// 车机连接事件（true=连上，false=宽限期后确认断开）。
  final _connectionEvents = StreamController<bool>.broadcast();
  Stream<bool> get connectionEvents => _connectionEvents.stream;

  Timer? _pollTimer;
  Timer? _graceTimer;
  bool _wasConnected = false;

  /// 启动监测（应用启动后调用；无论是否开启自动启停都保持监测，
  /// 以便设置页展示连接状态）。
  Future<void> start() async {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(BluetoothTuning.pollInterval, (_) => _poll());
    await _poll();

    // 蓝牙开关变化立即触发一次轮询（FBP 事件在 Android 上可靠）
    FlutterBluePlus.adapterState.listen((s) {
      if (s == BluetoothAdapterState.on ||
          s == BluetoothAdapterState.turningOn) {
        _poll();
      }
    });
  }

  void stop() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _graceTimer?.cancel();
    _graceTimer = null;
  }

  /// 查询当前已连接的经典蓝牙设备（含权限错误时返回空列表）。
  Future<List<ClassicBtDevice>> connectedDevices() async {
    try {
      final raw = await _btChannel
          .invokeListMethod<Object>('getConnectedClassicDevices');
      if (raw == null) return const [];
      return [
        for (final e in raw.cast<Map>())
          ClassicBtDevice(
            name: '${e['name']}',
            address: '${e['address']}',
          )
      ];
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  Future<bool> isBluetoothEnabled() async {
    try {
      return await _btChannel.invokeMethod<bool>('isBluetoothEnabled') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> _poll() async {
    if (boundDevice == null) {
      _setState(CarConnectionState.unbound);
      return;
    }
    final enabled = await isBluetoothEnabled();
    if (!enabled) {
      _setState(CarConnectionState.unavailable);
      return;
    }
    final devices = await connectedDevices();
    final target = boundDevice!;
    final matched = devices.any((d) =>
        d.address == target.address ||
        (target.name.isNotEmpty && d.name == target.name));

    if (matched) {
      _cancelGrace();
      if (!_wasConnected) {
        _wasConnected = true;
        _connectionEvents.add(true);
      }
      _setState(CarConnectionState.connected);
    } else {
      if (_wasConnected) {
        // 疑似瞬断：进入宽限期等待重连
        _setState(CarConnectionState.disconnected);
        _graceTimer ??= Timer(BluetoothTuning.disconnectGrace, () {
          if (_wasConnected) {
            _wasConnected = false;
            _connectionEvents.add(false);
          }
        });
      } else {
        _setState(CarConnectionState.disconnected);
      }
    }
  }

  void _cancelGrace() {
    _graceTimer?.cancel();
    _graceTimer = null;
  }

  void _setState(CarConnectionState s) {
    if (_state == s) return;
    _state = s;
    _stateController.add(s);
  }

  void dispose() {
    stop();
    _stateController.close();
    _connectionEvents.close();
  }
}
