import 'dart:io';
import 'package:path/path.dart' as p;

import '../models/drive_event.dart';
import '../models/track.dart';
import '../models/track_point.dart';

/// GPX 1.1 生成与导出。
///
/// - 轨迹 → `<trk><trkseg><trkpt lat/lon><ele><time>`；
/// - 事件 → `<wpt>` + `<name>`（类型）+ `<desc>`（强度/备注）；
/// - 无坐标的事件无法落成 wpt，统计进 `<trk><desc>` 文本；
/// - time 统一 ISO8601 UTC（Z 后缀）。
class GpxService {
  /// 生成 GPX 字符串（纯函数，可单测）。
  String build({
    required Track track,
    required List<TrackPoint> points,
    required List<DriveEvent> events,
  }) {
    final b = StringBuffer();
    b.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    b.writeln(
        '<gpx version="1.1" creator="DriveRecorder" '
        'xmlns="http://www.topografix.com/GPX/1/1" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
        'xsi:schemaLocation="http://www.topografix.com/GPX/1/1 '
        'http://www.topografix.com/GPX/1/1/gpx.xsd">');

    b.writeln('  <metadata>');
    b.writeln('    <name>${_esc(_nameOf(track))}</name>');
    b.writeln('    <time>${_iso8601(track.startTime)}</time>');
    b.writeln('  </metadata>');

    // 事件航点（有坐标的）
    for (final e in events) {
      if (e.latitude == null || e.longitude == null) continue;
      b.writeln('  <wpt lat="${_fmt(e.latitude!)}" lon="${_fmt(e.longitude!)}">');
      b.writeln('    <name>${_esc(_wptName(e))}</name>');
      b.writeln(
          '    <desc>${_esc(_eventDesc(e))}</desc>');
      b.writeln('    <time>${_iso8601(e.timestamp)}</time>');
      b.writeln('  </wpt>');
    }

    // 轨迹
    final located = points.where((p) => p.hasFix).toList();
    final degradedCount = points.length - located.length;
    b.writeln('  <trk>');
    b.writeln('    <name>${_esc(_nameOf(track))}</name>');
    b.writeln('    <desc>${_trkDesc(events, degradedCount, track)}</desc>');
    b.writeln('    <trkseg>');
    for (final p in located) {
      b.write('      <trkpt lat="${_fmt(p.latitude!)}" lon="${_fmt(p.longitude!)}">');
      if (p.altitude != null) {
        b.write('<ele>${p.altitude!.toStringAsFixed(1)}</ele>');
      }
      b.write('<time>${_iso8601(p.timestamp)}</time>');
      b.writeln('</trkpt>');
    }
    b.writeln('    </trkseg>');
    b.writeln('  </trk>');
    b.writeln('</gpx>');
    return b.toString();
  }

  /// 保存到文件，返回文件对象。
  Future<File> save(String gpx, Directory docsDir, Track track) async {
    final fileName =
        'drive_${track.id}_${track.startTime.toIso8601String().split('T').first}.gpx';
    final file = File('${docsDir.path}/$fileName');
    await file.writeAsString(gpx, flush: true);
    return file;
  }

  // ---------------------------------------------------------------------------

  String _nameOf(Track track) => track.name ?? 'Track ${track.id}';

  /// wpt 名称：photo 事件固定为「📷 拍照点」，其余用类型标签。
  String _wptName(DriveEvent e) =>
      e.type == DriveEventType.photo ? '📷 拍照点' : e.type.label;

  String _eventDesc(DriveEvent e) {
    final parts = <String>[e.type.label];
    if (e.peakIntensity != null) {
      parts.add('峰值 ${e.peakIntensity!.toStringAsFixed(1)} m/s²');
    }
    // photo 事件附带照片文件名（不含二进制，便于对照本地照片）
    if (e.type == DriveEventType.photo &&
        e.photoPath?.isNotEmpty == true) {
      parts.add('照片 ${p.basename(e.photoPath!)}');
    }
    if (e.note?.isNotEmpty == true) parts.add(e.note!);
    if (e.degraded) parts.add('定位降级');
    return parts.join(' | ');
  }

  String _trkDesc(List<DriveEvent> events, int degradedPoints, Track track) {
    final braking =
        events.where((e) => e.type == DriveEventType.braking).length;
    final collision =
        events.where((e) => e.type == DriveEventType.collision).length;
    final manual = events.where((e) => e.type == DriveEventType.manual).length;
    final photo = events.where((e) => e.type == DriveEventType.photo).length;
    final parts = <String>[
      '事件：急刹 $braking 次，碰撞 $collision 次，手动打点 $manual 次，拍照 $photo 次',
      if (degradedPoints > 0) '无定位轨迹点 $degradedPoints 个（未含在轨迹中）',
      '里程 ${(track.distanceMeters / 1000).toStringAsFixed(1)} km',
    ];
    return parts.join('；');
  }

  String _iso8601(DateTime t) => t.toUtc().toIso8601String();

  /// 6 位小数（约 0.1 m 精度）。
  String _fmt(double v) => v.toStringAsFixed(6);

  String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}
