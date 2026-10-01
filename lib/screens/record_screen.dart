import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/bluetooth_state_provider.dart';
import '../providers/recording_provider.dart';
import '../providers/settings_provider.dart';
import '../services/location_service.dart';
import '../utils/constants.dart';
import '../utils/formatters.dart';
import 'settings_screen.dart';

/// 记录页：当前状态、大号手动事件按钮、开始/停止、实时速度/点数。
class RecordScreen extends StatefulWidget {
  const RecordScreen({super.key});

  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends State<RecordScreen> {
  @override
  Widget build(BuildContext context) {
    final rec = context.watch<RecordingProvider>();
    final bt = context.watch<BluetoothStateProvider>();
    final s = context.watch<SettingsProvider>();
    final track = rec.currentTrack;
    final recording = rec.isRecording;

    // 额外监听屏幕策略控制器：点按退出/再进入黑屏时刷新「熄屏保活」按钮
    return ListenableBuilder(
      listenable: rec.screen,
      builder: (context, _) {
        // 假熄屏策略 + 记录中 + 当前不在黑屏 → 显示再进入按钮
        final fakeOffIdle =
            recording &&
            s.screenPolicy == ScreenPolicy.fakeOff &&
            !rec.screen.fakeOffActive;
        return Scaffold(
          appBar: AppBar(
            title: const Text('行车记录'),
            actions: [
              // 车机蓝牙状态角标
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Chip(
                  avatar: Icon(bt.icon, size: 18, color: bt.color),
                  label: Text(bt.label),
                  visualDensity: VisualDensity.compact,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: '设置',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const SettingsScreen(),
                  ),
                ),
              ),
            ],
          ),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _StatusCard(
                    recording: recording,
                    paused: rec.isPaused,
                    trackName: track?.name,
                    startTime: track?.startTime,
                    speed: rec.currentSpeed,
                    distance: track?.distanceMeters ?? 0,
                    gpsDegraded: rec.gpsDegraded,
                    locationRuntime: rec.locationRuntime,
                    sourceLabel: recording
                        ? ' · ${_sourceLabel(track?.source)}'
                        : '',
                  ),
                  const SizedBox(height: 12),
                  if (rec.statusMessage != null)
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Icon(
                              Icons.warning_amber_rounded,
                              color: Theme.of(context).colorScheme.error,
                            ),
                            const SizedBox(width: 8),
                            Expanded(child: Text(rec.statusMessage!)),
                          ],
                        ),
                      ),
                    ),

                  // 大按钮：手动打点 + 拍照
                  Expanded(
                    child: Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _BigEventButton(
                            enabled: recording,
                            onTap: () async {
                              final hasFix = rec.hasGpsFix;
                              final ok = await rec.manualEvent();
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    ok
                                        ? (hasFix
                                              ? '已打点 ✓（含当前坐标）'
                                              : '已打点 ✓（无定位信号，标记降级）')
                                        : '尚未开始记录，先点「开始记录」',
                                  ),
                                  duration: const Duration(seconds: 2),
                                ),
                              );
                            },
                          ),
                          const SizedBox(width: 20),
                          _CameraEventButton(
                            enabled: recording,
                            onTap: () => _takePhoto(rec),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // 假熄屏：手动再进入黑屏（仅在 fakeOff 策略且记录中显示）
                  if (fakeOffIdle) ...[
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        foregroundColor: Colors.blueGrey,
                        side: BorderSide(
                          color: Colors.blueGrey.shade300,
                          width: 1.2,
                        ),
                      ),
                      onPressed: rec.screen.enterFakeOff,
                      icon: const Icon(Icons.nights_stay_outlined),
                      label: const Text('熄屏保活'),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // 开始/暂停/继续/停止
                  if (rec.isActive)
                    Row(
                      children: [
                        Expanded(
                          child: rec.isPaused
                              ? FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 16,
                                    ),
                                  ),
                                  onPressed: rec.resume,
                                  icon: const Icon(Icons.play_arrow),
                                  label: const Text('继续记录'),
                                )
                              : OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 16,
                                    ),
                                    foregroundColor: Colors.orange.shade800,
                                    side: BorderSide(
                                      color: Colors.orange.shade300,
                                      width: 1.4,
                                    ),
                                  ),
                                  onPressed: rec.pause,
                                  icon: const Icon(Icons.pause),
                                  label: const Text('暂停'),
                                ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              backgroundColor: Colors.red,
                            ),
                            onPressed: rec.stop,
                            icon: const Icon(Icons.stop),
                            label: const Text('停止记录'),
                          ),
                        ),
                      ],
                    )
                  else
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      onPressed: () => rec.start(),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('开始记录'),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _sourceLabel(String? source) => source == 'bluetooth' ? '车机自动' : '手动';

  /// 拍照流程：权限检查 → 调起相机 → 照片落盘 + 写入 photo 事件。
  /// 取消拍照静默返回，不打扰用户。
  Future<void> _takePhoto(RecordingProvider rec) async {
    final perm = await rec.permissions.ensureCameraPermission();
    if (!perm.ok) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('缺少权限：${perm.missing.join('、')}，无法拍照'),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    final path = await rec.photos.takePhoto();
    if (path == null) return; // 用户取消

    final hasFix = rec.hasGpsFix;
    final ok = await rec.photoEvent(path);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? (hasFix ? '已保存照片 ✓（含当前坐标）' : '已保存照片 ✓（无定位信号，标记降级）')
              : '尚未开始记录，无法保存照片',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final bool recording;
  final bool paused;
  final String? trackName;
  final DateTime? startTime;
  final double? speed;
  final double distance;
  final bool gpsDegraded;
  final LocationRuntime locationRuntime;
  final String sourceLabel;

  const _StatusCard({
    required this.recording,
    this.paused = false,
    this.trackName,
    this.startTime,
    this.speed,
    required this.distance,
    required this.gpsDegraded,
    required this.locationRuntime,
    required this.sourceLabel,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  recording ? Icons.circle : Icons.circle_outlined,
                  size: 14,
                  color: recording
                      ? Colors.red
                      : paused
                      ? Colors.orange
                      : cs.outline,
                ),
                const SizedBox(width: 6),
                Text(
                  recording
                      ? '记录中$sourceLabel'
                      : paused
                      ? '已暂停$sourceLabel'
                      : '未在记录',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: recording
                        ? Colors.red
                        : paused
                        ? Colors.orange.shade800
                        : null,
                  ),
                ),
                const Spacer(),
                if (recording && startTime != null)
                  _ElapsedTicker(
                    start: startTime!,
                    style: Theme.of(context).textTheme.titleMedium!.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
            if (trackName != null) ...[
              const SizedBox(height: 4),
              Text(trackName!, style: Theme.of(context).textTheme.bodyMedium),
            ],
            const Divider(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _Metric(label: '速度', value: formatSpeed(speed)),
                _Metric(label: '里程', value: formatDistance(distance)),
                _Metric(
                  label: 'GPS',
                  value: paused
                      ? '已暂停'
                      : gpsDegraded
                      ? '无信号'
                      : '正常',
                  valueColor: paused || gpsDegraded ? Colors.orange : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _Metric({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(color: valueColor),
        ),
        const SizedBox(height: 2),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

/// 拍照事件按钮：紧邻手动打点大按钮，仅记录中可用。
class _CameraEventButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;

  const _CameraEventButton({required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: '拍照',
      enabled: enabled,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            shape: const CircleBorder(),
            elevation: enabled ? 4 : 0,
            color: enabled ? cs.secondaryContainer : cs.surfaceContainerHighest,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: enabled ? onTap : null,
              child: SizedBox(
                width: 72,
                height: 72,
                child: Icon(
                  Icons.photo_camera,
                  size: 32,
                  color: enabled ? cs.onSecondaryContainer : cs.outlineVariant,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '拍照',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: enabled ? null : cs.outline,
            ),
          ),
        ],
      ),
    );
  }
}

/// 每秒刷新的记录时长。
/// 拍照事件按钮：紧邻手动打点大按钮，仅记录中可用。
class _ElapsedTicker extends StatefulWidget {
  final DateTime start;
  final TextStyle style;

  const _ElapsedTicker({required this.start, required this.style});

  @override
  State<_ElapsedTicker> createState() => _ElapsedTickerState();
}

class _ElapsedTickerState extends State<_ElapsedTicker> {
  Timer? _timer;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _elapsed = DateTime.now().difference(widget.start);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _elapsed = DateTime.now().difference(widget.start));
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Text(formatDuration(_elapsed), style: widget.style);
}

/// 大号手动事件按钮。
class _BigEventButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;

  const _BigEventButton({required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: '手动事件打点',
      child: Material(
        shape: const CircleBorder(),
        elevation: enabled ? 4 : 0,
        color: enabled ? cs.primaryContainer : cs.surfaceContainerHighest,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onTap : null,
          child: SizedBox(
            width: 190,
            height: 190,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.touch_app,
                  size: 56,
                  color: enabled ? cs.primary : cs.outlineVariant,
                ),
                const SizedBox(height: 8),
                Text(
                  '手动打点',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: enabled ? cs.onPrimaryContainer : cs.outline,
                  ),
                ),
                Text(
                  '点击记录当前时刻事件',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: enabled ? cs.onPrimaryContainer : cs.outline,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
