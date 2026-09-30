import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../providers/bluetooth_state_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/tracks_provider.dart';
import '../services/app_logger.dart';
import '../services/backup_service.dart';
import '../services/bluetooth_car_service.dart';
import '../services/database/app_database.dart';
import '../services/permission_service.dart';
import 'log_screen.dart';

/// 设置页：急刹/碰撞阈值滑块、车机绑定、Firebase 同步开关。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with WidgetsBindingObserver {
  final _permissions = PermissionService();
  final _amapKeyController = TextEditingController();
  bool _amapKeyEdited = false;
  bool _amapKeySynced = false;
  bool _backupBusy = false;

  /// 「忽略电池优化」当前状态：null = 检查中，false = 未豁免（后台风险）。
  bool? _batteryIgnored;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _amapKeyController.addListener(() => _amapKeyEdited = true);
    _refreshBatteryOptimization();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统设置（如电池/自启动页）返回 App 时重查电池优化状态
    if (state == AppLifecycleState.resumed) {
      _refreshBatteryOptimization();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _amapKeyController.dispose();
    super.dispose();
  }

  Future<void> _saveAmapKey() async {
    final key = _amapKeyController.text.trim();
    await context.read<SettingsProvider>().setAmapKey(key);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(key.isEmpty ? '已清除高德 Key，重启 App 后生效' : '已保存，重启 App 后生效'),
      duration: const Duration(seconds: 3),
    ));
  }

  // —— 息屏保活：忽略电池优化 ——

  Future<void> _refreshBatteryOptimization() async {
    final granted = await _permissions.isIgnoringBatteryOptimizations();
    if (mounted) setState(() => _batteryIgnored = granted);
  }

  Future<void> _handleBatteryTap() async {
    if (_batteryIgnored == true) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已允许忽略电池优化，无需操作')));
      return;
    }
    final granted = await _permissions.requestIgnoreBatteryOptimizations();
    await _refreshBatteryOptimization();
    if (!mounted) return;
    if (granted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              '已允许：息屏后定位更稳定。vivo 手机建议再按引导检查自启动/后台高耗电'),
          duration: Duration(seconds: 4)));
    } else {
      _showVivoPowerDialog(context);
    }
  }

  /// 未授予电池优化豁免时：vivo（及通用 Android）后台限制的手动设置引导。
  /// 这些是厂商自家省电策略，App 无法代开，只能引导用户去系统设置放行。
  void _showVivoPowerDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('息屏后定位不稳？'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('「忽略电池优化」尚未授予（未弹窗、被拒绝或被系统拦截）。'
                '除重试该开关外，vivo 手机的自家省电策略必须在系统设置手动放行：'),
            SizedBox(height: 10),
            Text('1. 自启动：设置 → 应用 → 应用管理 → 行车记录 → 自启动\n'
                '   （部分机型：i管家 → 应用管理 → 自启动管理）'),
            SizedBox(height: 6),
            Text('2. 后台高耗电：设置 → 电池 → 后台耗电管理 → 行车记录 → '
                '允许后台高耗电'),
            SizedBox(height: 6),
            Text('3. 可选：最近任务里下拉「行车记录」卡片，点锁图标锁定后台'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  // —— 数据备份：导出 / 导入 ——

  Future<void> _exportBackup() async {
    if (_backupBusy) return;
    setState(() => _backupBusy = true);
    final backup = BackupService();
    final db = context.read<AppDatabase>();
    try {
      final result = await backup.exportAll(db);
      if (!mounted) return;
      final saved = await backup.saveToDownloads(result.file);
      if (!mounted) return;
      if (saved != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('已导出 $saved（${result.tracks} 条轨迹，'
              '${result.points} 点，${result.photos} 张照片）'),
          duration: const Duration(seconds: 4),
        ));
      } else {
        // 公共目录写入失败的兼容回落：存应用目录 + 分享面板另存
        final docs = await getApplicationDocumentsDirectory();
        final dest =
            File(p.join(docs.path, p.basename(result.file.path)));
        await result.file.copy(dest.path);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('公共下载目录写入失败，已调起分享面板，可另存到任意位置'),
          duration: const Duration(seconds: 4),
        ));
        await SharePlus.instance.share(ShareParams(
          files: [XFile(dest.path)],
          text: '行车记录全量备份（${result.tracks} 条轨迹）',
        ));
      }
    } catch (e) {
      AppLogger.e('backup', '导出失败：$e');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导出失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<void> _importBackup() async {
    if (_backupBusy) return;
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
        dialogTitle: '选择 DriveRecorder 备份 zip',
      );
      final path = picked?.files.single.path;
      if (path == null) return;

      final backup = BackupService();
      final preview = await backup.inspect(path);
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('导入备份？'),
          content: Text(
              '备份包含 ${preview.tracks} 条轨迹 / ${preview.points} 个轨迹点 /\n'
              '${preview.events} 个事件 / ${preview.photos} 张照片。\n'
              '重复的轨迹会自动跳过，已有数据不受影响。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('导入')),
          ],
        ),
      );
      if (confirmed != true) return;

      if (!mounted) return;
      final db = context.read<AppDatabase>();
      final tracksProvider = context.read<TracksProvider>();
      setState(() => _backupBusy = true);
      final result = await backup.importZip(path, db);
      await tracksProvider.refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('已导入 ${result.imported} 条轨迹'
            '（跳过重复 ${result.skippedDuplicates} 条，'
            '照片 ${result.photosRestored} 张）'),
        duration: const Duration(seconds: 4),
      ));
    } on BackupException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      AppLogger.e('backup', '导入失败：$e');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsProvider>();
    final btState = context.watch<BluetoothStateProvider>().state;
    // 首次加载后同步已存的 Key 到输入框（用户未手动编辑时）
    if (!_amapKeyEdited && !_amapKeySynced && s.amapKey.isNotEmpty) {
      _amapKeyController.text = s.amapKey;
      _amapKeySynced = true;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          // —— 高德 Key ——
          _sectionHeader(context, '高德地图 Key'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _amapKeyController,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.vpn_key_outlined),
                          border: OutlineInputBorder(),
                          isDense: true,
                          labelText: 'Android Key',
                          hintText: '32 位，在高德开放平台创建',
                        ),
                        onSubmitted: (_) => _saveAmapKey(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _saveAmapKey,
                      child: const Text('保存'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '仅影响地图底图（定位已改用手机系统 GPS，不依赖 Key）。'
                  '不填则用打包内置的占位 Key（地图可能不可用）。'
                  '申请：console.amap.com → 创建应用 → 添加 Android Key，'
                  '包名 com.zhangkeyou.drive_recorder，SHA1 与包名见 README。'
                  '保存后需重启 App 生效。',
                  style: TextStyle(
                      fontSize: 12, color: Theme.of(context).disabledColor),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.receipt_long_outlined),
            title: const Text('运行日志'),
            subtitle: const Text('查看定位/地图/记录的运行过程与错误，可分享'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const LogScreen())),
          ),
          const Divider(),

          // —— 息屏保活 ——
          _sectionHeader(context, '息屏保活（后台定位）'),
          ListTile(
            leading: const Icon(Icons.battery_saver_outlined),
            title: const Text('忽略电池优化'),
            subtitle: Text(
              switch (_batteryIgnored) {
                null => '正在检查…',
                true => '已允许：记录中息屏时，系统 Doze 省电机制不会冻结定位回调',
                false => '未允许：息屏后系统省电策略可能延迟/掐断定位（息屏丢轨迹常见原因）\n'
                    '点击申请系统豁免；vivo 手机另需手动放行自启动/后台高耗电',
              },
              style: const TextStyle(fontSize: 12),
            ),
            isThreeLine: true,
            trailing: _batteryIgnored == null
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(
                    _batteryIgnored!
                        ? Icons.check_circle
                        : Icons.error_outline,
                    color: _batteryIgnored!
                        ? Colors.green
                        : Theme.of(context).colorScheme.error,
                  ),
            onTap: _handleBatteryTap,
          ),
          const Divider(),

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
          // —— 数据备份 ——
          _sectionHeader(context, '数据备份'),
          ListTile(
            leading: const Icon(Icons.upload_file_outlined),
            title: const Text('导出全部数据'),
            subtitle: const Text(
                '全部轨迹/轨迹点/事件/照片打包为标准 ZIP（下载目录 DriveRecorder/），\n'
                '可在任何设备解压查看，也可用于迁移',
                style: TextStyle(fontSize: 12)),
            enabled: !_backupBusy,
            trailing: _backupBusy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.chevron_right),
            onTap: _exportBackup,
          ),
          ListTile(
            leading: const Icon(Icons.restore_outlined),
            title: const Text('导入备份'),
            subtitle: const Text('从备份 ZIP 恢复轨迹与照片，重复轨迹自动跳过',
                style: TextStyle(fontSize: 12)),
            enabled: !_backupBusy,
            trailing: const Icon(Icons.chevron_right),
            onTap: _importBackup,
          ),
          const Divider(),

          // —— 事件检测阈值 ——
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
