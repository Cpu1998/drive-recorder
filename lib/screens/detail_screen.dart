import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/drive_event.dart';
import '../models/track.dart';
import '../models/track_point.dart';
import '../providers/tracks_provider.dart';
import '../services/gpx_service.dart';
import '../utils/formatters.dart';
import '../widgets/photo_gallery.dart';
import '../widgets/track_map_view.dart';

/// 详情页：
/// - Tab 模式（底部导航）：显示最近一条轨迹；
/// - 路由模式（从历史页进入）：显示指定轨迹；
/// - 高德地图画轨迹 polyline + 事件 marker，导出/分享 GPX。
class DetailScreen extends StatefulWidget {
  final int? trackId;
  const DetailScreen({super.key, this.trackId});

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  Track? _track;
  List<TrackPoint>? _points;
  List<DriveEvent>? _events;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final provider = context.read<TracksProvider>();
      final list = provider.tracks;
      final id = widget.trackId ?? (list.isEmpty ? null : list.first.id);
      if (id == null) {
        setState(() {
          _track = null;
          _error = null;
        });
        return;
      }
      final track = await provider.track(id);
      final points = await provider.points(id);
      final events = await provider.events(id);
      if (!mounted) return;
      setState(() {
        _track = track;
        _points = points;
        _events = events;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '加载失败：$e');
    }
  }

  Future<void> _export({required bool share}) async {
    final track = _track;
    if (track?.id == null || _points == null || _events == null) return;
    try {
      final gpx = GpxService().build(
        track: track!,
        points: _points!,
        events: _events!,
      );
      final docs = await getApplicationDocumentsDirectory();
      final file =
          await GpxService().save(gpx, docs, track);
      if (!mounted) return;
      if (share) {
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path)],
            text: '行车轨迹 GPX（${track.name ?? '轨迹 #${track.id}'}）',
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('已保存：${file.path}'),
          duration: const Duration(seconds: 4),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导出失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final photoEvents = (_events ?? const <DriveEvent>[])
        .where((e) => e.type == DriveEventType.photo)
        .toList(growable: false);
    return Scaffold(
      appBar: AppBar(
        title: Text(_track?.name ?? '轨迹详情'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save_outlined),
            tooltip: '保存 GPX',
            onPressed: _track == null ? null : () => _export(share: false),
          ),
          IconButton(
            icon: const Icon(Icons.share_outlined),
            tooltip: '分享 GPX',
            onPressed: _track == null ? null : () => _export(share: true),
          ),
        ],
      ),
      body: _error != null
          ? Center(child: Text(_error!))
          : _track == null
              ? const _EmptyDetail()
              : Column(
                  children: [
                    _summaryBar(context, _track!),
                    Expanded(
                      child: TrackMapView(
                        track: _track!,
                        points: _points ?? const [],
                        events: _events ?? const [],
                      ),
                    ),
                    if ((_events ?? []).isNotEmpty)
                      SizedBox(
                        height: 128,
                        child: _EventList(events: _events!),
                      ),
                    // 照片横向缩略图列表（仅有 photo 事件时出现）
                    if (photoEvents.isNotEmpty)
                      SizedBox(
                        height: 150,
                        child: PhotoStrip(photoEvents: photoEvents),
                      ),
                  ],
                ),
    );
  }

  Widget _summaryBar(BuildContext context, Track t) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _item('里程', formatDistance(t.distanceMeters)),
          _item('时长', formatDuration(t.duration ?? Duration.zero)),
          _item('轨迹点', '${t.pointCount}'),
          _item('事件', '${t.eventCount}'),
        ],
      ),
    );
  }

  Widget _item(String label, String value) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value, style: Theme.of(context).textTheme.titleMedium),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      );
}

class _EmptyDetail extends StatelessWidget {
  const _EmptyDetail();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.map_outlined, size: 48,
              color: Theme.of(context).disabledColor),
          const SizedBox(height: 8),
          Text('暂无轨迹详情',
              style: TextStyle(color: Theme.of(context).disabledColor)),
          const SizedBox(height: 4),
          const Text('完成一次记录后，这里展示最近轨迹', style: TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

class _EventList extends StatelessWidget {
  final List<DriveEvent> events;
  const _EventList({required this.events});

  @override
  Widget build(BuildContext context) {
    final sorted = [...events]..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text('事件（${events.length}）',
              style: Theme.of(context).textTheme.titleSmall),
        ),
        Expanded(
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(8),
            itemCount: math.min(sorted.length, 50),
            itemBuilder: (context, i) {
              final e = sorted[i];
              final (icon, color) = switch (e.type) {
                DriveEventType.manual => (Icons.touch_app, Colors.blue),
                DriveEventType.braking => (Icons.south_east, Colors.orange),
                DriveEventType.collision => (Icons.warning, Colors.red),
                DriveEventType.photo => (Icons.photo_camera, Colors.teal),
              };
              return Card(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      Icon(icon, color: color, size: 20),
                      const SizedBox(width: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(e.type.label +
                              (e.peakIntensity != null
                                  ? ' ${formatIntensity(e.peakIntensity)}'
                                  : '')),
                          Text(
                            '${e.timestamp.hour.toString().padLeft(2, '0')}:'
                            '${e.timestamp.minute.toString().padLeft(2, '0')}:'
                            '${e.timestamp.second.toString().padLeft(2, '0')}'
                            '${e.degraded ? ' · 定位降级' : ''}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
