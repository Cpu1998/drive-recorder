import 'dart:io';
import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'downloads_saver.dart';
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

  /// 保存 GPX，返回保存结果。
  ///
  /// - Android：经原生通道写入公共下载目录 `Download/DriveRecorder/`
  ///   （Android 10+ MediaStore 免权限；Android 9- 遗留直写），
  ///   失败（机型兼容问题）时回落到应用文档目录，结果带
  ///   [GpxSaveResult.fallback]=true，调用方可再调起分享面板另存；
  /// - 其余平台：写入 [fallbackDir]（调用方给的应用文档目录）。
  Future<GpxSaveResult> save(String gpx, Directory fallbackDir, Track track) async {
    if (Platform.isAndroid) {
      try {
        final temp = await writeLocal(gpx, fallbackDir, track);
        final display = await DownloadsSaver.saveFileToDownloads(
          filePath: temp.path,
          mime: 'application/gpx+xml',
          subDir: _downloadSubdir,
        );
        // 已复制到公共目录，临时文件不再需要
        await temp.delete();
        return GpxSaveResult(displayPath: display);
      } catch (e) {
        AppLogger.w('gpx', '公共下载目录保存失败，回落应用目录：$e');
        final file = await writeLocal(gpx, fallbackDir, track);
        return GpxSaveResult(
            file: file, displayPath: file.path, fallback: true);
      }
    }
    final file = await writeLocal(gpx, fallbackDir, track);
    return GpxSaveResult(file: file, displayPath: file.path);
  }

  /// 直接写入 [dir] 并返回文件对象（分享面板需要真实文件路径，走这里）。
  Future<File> writeLocal(String gpx, Directory dir, Track track) async {
    final file = File('${dir.path}/${_fileNameOf(track)}');
    await file.writeAsString(gpx, flush: true);
    return file;
  }

  // ---------------------------------------------------------------------------

  /// 公共下载目录下的导出子文件夹（与 DownloadsSaver 默认一致）。
  static const String _downloadSubdir = 'DriveRecorder';

  String _fileNameOf(Track track) =>
      'drive_${track.id}_${track.startTime.toIso8601String().split('T').first}.gpx';

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

/// GPX 保存结果。
///
/// - 经 MediaStore 保存时（Android 10+）[file] 为空，文件在公共下载目录，
///   只能通过 [displayPath]（如 `Download/DriveRecorder/xxx.gpx`）定位；
/// - 其余情况 [file] 为实际落盘文件；
/// - [fallback]=true 表示公共目录写入失败、已回落应用文档目录，
///   调用方可调起分享面板让用户自行另存。
class GpxSaveResult {
  final File? file;
  final String displayPath;
  final bool fallback;

  const GpxSaveResult({this.file, required this.displayPath, this.fallback = false});
}
