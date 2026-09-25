import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/track.dart';
import '../providers/tracks_provider.dart';
import '../utils/formatters.dart';
import 'detail_screen.dart';

/// 历史页：轨迹列表，点击进详情。
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  @override
  void initState() {
    super.initState();
    context.read<TracksProvider>().refresh();
  }

  @override
  Widget build(BuildContext context) {
    final tracks = context.watch<TracksProvider>().tracks;
    return Scaffold(
      appBar: AppBar(title: const Text('历史轨迹')),
      body: tracks.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.route_outlined,
                      size: 48, color: Theme.of(context).disabledColor),
                  const SizedBox(height: 8),
                  Text('还没有轨迹记录',
                      style: TextStyle(
                          color: Theme.of(context).disabledColor)),
                  const SizedBox(height: 4),
                  const Text('去「记录」页点开始记录吧',
                      style: TextStyle(fontSize: 12)),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: () => context.read<TracksProvider>().refresh(),
              child: ListView.separated(
                itemCount: tracks.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final t = tracks[i];
                  return ListTile(
                    leading: CircleAvatar(
                      child: Icon(
                        t.source == 'bluetooth'
                            ? Icons.bluetooth_audio
                            : Icons.directions_car,
                        size: 20,
                      ),
                    ),
                    title: Text(t.name ?? '轨迹 #${t.id}'),
                    subtitle: Text(
                      '${_dateRange(t)} · ${formatDistance(t.distanceMeters)}'
                      ' · ${t.pointCount} 点 · ${t.eventCount} 事件',
                    ),
                    trailing: t.endTime == null
                        ? const Chip(label: Text('进行中'))
                        : Text(formatDuration(t.duration ?? Duration.zero)),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => DetailScreen(trackId: t.id!),
                      ),
                    ),
                    onLongPress: () => _confirmDelete(context, t),
                  );
                },
              ),
            ),
    );
  }

  String _dateRange(Track t) {
    final s = '${t.startTime.month}/${t.startTime.day} '
        '${t.startTime.hour.toString().padLeft(2, '0')}:'
        '${t.startTime.minute.toString().padLeft(2, '0')}';
    final e = t.endTime;
    if (e == null) return s;
    return '$s - '
        '${e.hour.toString().padLeft(2, '0')}:'
        '${e.minute.toString().padLeft(2, '0')}';
  }

  void _confirmDelete(BuildContext context, Track t) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除轨迹？'),
        content: Text('「${t.name ?? '轨迹 #${t.id}'}」及其全部轨迹点、事件'
            '（含云端副本，若已开启同步）将被删除，不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              Navigator.pop(ctx);
              await context.read<TracksProvider>().delete(t);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}
