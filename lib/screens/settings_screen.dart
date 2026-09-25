import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/bluetooth_state_provider.dart';
import '../providers/settings_provider.dart';
import '../services/bluetooth_car_service.dart';
import '../services/permission_service.dart';

/// 设置页：急刹/碰撞阈值滑块、车机绑定、Firebase 同步开关。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _permissions = PermissionService();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsProvider>();
    final btState = context.watch<BluetoothStateProvider>().state;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          // —— 事件检测阈值 ——
          _sectionHeader(context, '事件检测阈值'),
          ListTile(
            leading: const Icon(Icons.south_east),
            title: Text('急刹减速度阈值'),
            subtitle: Text(
                '${s.brakingThreshold.toStringAsFixed(1)} m/s²（持续 ≥500ms 触发；'
                '越大越不敏感）',
                style: const TextStyle(fontSize: 12)),
          ),
          Slider(
            value: s.brakingThreshold,
            min: 1.0,
            max: 8.0,
            divisions: 14,
            label: '${s.brakingThreshold.toStringAsFixed(1)} m/s²',
            onChanged: (v) => context
                .read<SettingsProvider>()
                .setBrakingThreshold(double.parse(v.toStringAsFixed(1))),
          ),
          ListTile(
            leading: const Icon(Icons.warning_amber_rounded),
            title: Text('碰撞加速度阈值'),
            subtitle: Text(
                '${s.collisionThreshold.round()} m/s²（80ms 窗口尖峰触发；'
                '日常颠簸约 10-20，急刹约 4-6）',
                style: const TextStyle(fontSize: 12)),
          ),
          Slider(
            value: s.collisionThreshold,
            min: 20,
            max: 120,
            divisions: 20,
            label: '${s.collisionThreshold.round()} m/s²',
            onChanged: (v) => context
                .read<SettingsProvider>()
                .setCollisionThreshold(v.roundToDouble()),
          ),
          const Divider(),

          // —— 车机蓝牙 ——
          _sectionHeader(context, '车机蓝牙自动启停'),
          SwitchListTile(
            secondary: const Icon(Icons.bluetooth_audio),
            title: const Text('连上车机自动开始记录'),
            subtitle: const Text('断开 30 秒后未重连则自动停止\n（仅对车机自动开启的记录生效）',
                style: TextStyle(fontSize: 12)),
            value: s.btAutoEnabled,
            onChanged: (v) async {
              if (v) {
                final perm = await _permissions.ensureBluetoothPermissions();
                if (!context.mounted) return;
                if (!perm.ok) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('缺少权限：${perm.missing.join('、')}')));
                  return;
                }
              }
              // 同步到蓝牙服务
              context.read<BluetoothStateProvider>().service.autoEnabled = v;
              await context.read<SettingsProvider>().setBtAutoEnabled(v);
            },
          ),
          ListTile(
            leading: const Icon(Icons.car_crash_outlined),
            title: const Text('绑定车机'),
            subtitle: Text(
              s.btDeviceName == null
                  ? '未绑定（点击选择当前已连接的蓝牙设备）'
                  : '已绑定：${s.btDeviceName}\n'
                      '状态：${_carStateLabel(btState)}',
              style: const TextStyle(fontSize: 12),
            ),
            isThreeLine: true,
            trailing: s.btDeviceName == null
                ? const Icon(Icons.chevron_right)
                : IconButton(
                    icon: const Icon(Icons.link_off),
                    tooltip: '解除绑定',
                    onPressed: () async {
                      final service =
                          context.read<BluetoothStateProvider>().service;
                      service.boundDevice = null;
                      await context.read<SettingsProvider>().unbindBtDevice();
                    },
                  ),
            onTap: () => _showDevicePicker(context),
          ),
          const Divider(),

          // —— 云同步 ——
          _sectionHeader(context, '云端同步（Firebase）'),
          SwitchListTile(
            secondary: const Icon(Icons.cloud_sync_outlined),
            title: const Text('同步轨迹到 Firestore'),
            subtitle: Text(
              s.syncError ??
                  (s.syncEnabled
                      ? '已开启：记录结束时上传轨迹与事件'
                      : '默认关闭。本地优先：所有数据先存手机 SQLite，'
                          '开启后记录结束时上传副本'),
              style: const TextStyle(fontSize: 12),
            ),
            value: s.syncEnabled,
            onChanged: (v) async {
              final ok =
                  await context.read<SettingsProvider>().setSyncEnabled(v);
              if (!ok && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(context
                      .read<SettingsProvider>()
                      .syncError ?? '开启失败')),
                );
              }
            },
          ),
          if (s.syncEnabled)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                '数据布局：tracks/{id}/points、tracks/{id}/events；'
                '删除本地轨迹会同步删除云端副本。',
                style: TextStyle(fontSize: 11),
              ),
            ),
          const Divider(),

          // —— 关于 ——
          _sectionHeader(context, '关于'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('行车记录 DriveRecorder'),
            subtitle: Text('v1.0.0 · 轨迹 · 事件 · GPX · Firebase 可选同步',
                style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  String _carStateLabel(dynamic state) => switch ('$state') {
        'CarConnectionState.connected' => '已连接，自动启停生效中',
        'CarConnectionState.disconnected' => '未连接',
        'CarConnectionState.unavailable' => '蓝牙未开启/无权限',
        _ => '未绑定',
      };

  Widget _sectionHeader(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          text,
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(color: Theme.of(context).colorScheme.primary),
        ),
      );

  /// 设备选择器：列出当前已连接的经典蓝牙设备（5s 轮询数据）。
  Future<void> _showDevicePicker(BuildContext context) async {
    final service = context.read<BluetoothStateProvider>().service;
    final perm = await _permissions.ensureBluetoothPermissions();
    if (!perm.ok) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('缺少权限：${perm.missing.join('、')}')));
      }
      return;
    }
    final devices = await service.connectedDevices();
    if (!context.mounted) return;
    if (devices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('未发现已连接的蓝牙设备。请先在系统设置中连接车机蓝牙，'
              '或确认 App 拥有蓝牙权限。')));
      return;
    }
    final selected = await showModalBottomSheet<ClassicBtDevice>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('选择车机（当前已连接）',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            for (final d in devices)
              ListTile(
                leading: const Icon(Icons.bluetooth),
                title: Text(d.name),
                subtitle: Text(d.address,
                    style: const TextStyle(fontSize: 11)),
                onTap: () => Navigator.pop(context, d),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (selected == null || !context.mounted) return;
    service.boundDevice = selected;
    await context.read<SettingsProvider>().bindBtDevice(selected);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已绑定车机：${selected.name}')));
    }
  }
}
