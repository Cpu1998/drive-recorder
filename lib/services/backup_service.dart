import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:media_store_plus/media_store_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/drive_event.dart';
import '../models/track.dart';
import '../models/track_point.dart';
import '../utils/constants.dart';
import 'app_logger.dart';
import 'database/app_database.dart';

/// 备份异常（导入格式不符/损坏等，面向用户展示 message）。
class BackupException implements Exception {
  final String message;
  const BackupException(this.message);
  @override
  String toString() => message;
}

/// 导出结果。
class BackupExportResult {
  /// 导出的 zip 文件（调用方决定落公共目录或分享）。
  final File file;

  /// 轨迹/点/事件/照片数量。
  final int tracks;
  final int points;
  final int events;
  final int photos;

  const BackupExportResult({
    required this.file,
    required this.tracks,
    required this.points,
    required this.events,
    required this.photos,
  });
}

/// 导入前预览（确认对话框用）。
class BackupPreview {
  final int tracks;
  final int points;
  final int events;
  final int photos;
  const BackupPreview(
      this.tracks, this.points, this.events, this.photos);
}

/// 导入结果。
class BackupImportResult {
  final int imported;
  final int skippedDuplicates;
  final int photosRestored;
  const BackupImportResult(
      this.imported, this.skippedDuplicates, this.photosRestored);
}

/// 全量数据导入/导出（标准 ZIP + JSON，跨版本/跨平台兼容）。
///
/// 压缩包结构（全部 ASCII 路径 + UTF-8 JSON，任何解压工具可读）：
/// ```
/// DriveRecorder-backup-20260929-2330.zip
/// ├── manifest.json                       # 格式标识/版本/统计
/// └── tracks/<原始轨迹id>/
///     ├── track.json                      # 轨迹元数据
///     ├── points.json                     # 轨迹点数组
///     ├── events.json                     # 事件数组
///     └── photos/<文件名>                  # 事件照片
/// ```
///
/// 兼容性策略：
/// - 标准 ZIP（deflate），Windows/macOS/安卓文件管理器直接解压；
/// - 数据为带版本号的 JSON（非 SQLite 二进制），未来版本可按
///   manifest.version 兼容解析，升级 App 不丢备份；
/// - 导入时重新分配本地 id，照片按新 id 落 `photos/<新id>/`，
///   同一备份重复导入自动跳过（按 开始时间+名称+点数 判重）。
class BackupService {
  /// 文档目录解析（单测注入临时目录）。
  final Future<Directory> Function() docsDirResolver;

  /// 系统临时目录解析（单测注入）。
  final Future<Directory> Function() tmpDirResolver;

  BackupService(
      {Future<Directory> Function()? docsDirResolver,
      Future<Directory> Function()? tmpDirResolver})
      : docsDirResolver = docsDirResolver ?? getApplicationDocumentsDirectory,
        tmpDirResolver = tmpDirResolver ?? getTemporaryDirectory;

  static const String formatId = 'driverecorder-backup';

  /// 当前备份格式版本。
  static const int formatVersion = 1;

  // ---------------------------------------------------------------------------
  // 导出
  // ---------------------------------------------------------------------------

  /// 导出全部数据为 zip（写入系统临时目录，文件名 ASCII）。
  Future<BackupExportResult> exportAll(AppDatabase database) async {
    final tracks = await database.listTracks();
    final archive = Archive();
    var pointTotal = 0;
    var eventTotal = 0;
    var photoTotal = 0;

    for (final track in tracks) {
      final id = track.id!;
      final dirName = 'tracks/${id.toString().padLeft(6, '0')}';
      final points = await database.pointsForTrack(id);
      final events = await database.eventsForTrack(id);
      pointTotal += points.length;
      eventTotal += events.length;

      archive.add(ArchiveFile.string(
          '$dirName/track.json',
          const JsonEncoder.withIndent('  ')
              .convert(_trackJson(track))));

      archive.add(ArchiveFile.string(
          '$dirName/points.json',
          const JsonEncoder.withIndent('  ')
              .convert([for (final pt in points) _pointJson(pt)])));

      // 照片只存文件名（跨设备路径无意义），二进制放 photos/ 下
      final eventsJson = <Map<String, Object?>>[];
      for (final e in events) {
        final json = _eventJson(e);
        if (e.photoPath?.isNotEmpty == true) {
          final base = p.basename(e.photoPath!);
          json['photo_path'] = base;
          final src = await _photoFileOf(id, base);
          if (src != null) {
            final bytes = await src.readAsBytes();
            archive.add(ArchiveFile.bytes('$dirName/photos/$base', bytes));
            photoTotal++;
          } else {
            AppLogger.w('backup', '照片缺失，跳过：track=$id $base');
          }
        }
        eventsJson.add(json);
      }
      archive.add(ArchiveFile.string('$dirName/events.json',
          const JsonEncoder.withIndent('  ').convert(eventsJson)));
    }

    archive.add(ArchiveFile.string(
        'manifest.json',
        const JsonEncoder.withIndent('  ').convert({
          'format': formatId,
          'version': formatVersion,
          'app_version': AppInfo.version,
          'exported_at': DateTime.now().millisecondsSinceEpoch,
          'tracks': tracks.length,
          'points': pointTotal,
          'events': eventTotal,
          'photos': photoTotal,
        })));

    final zipBytes = ZipEncoder().encodeBytes(archive);
    final tmp = await tmpDirResolver();
    final file = File(p.join(tmp.path, exportFileName()));
    await file.writeAsBytes(zipBytes, flush: true);
    AppLogger.i('backup',
        '导出完成：${tracks.length} 轨迹 / $pointTotal 点 / $eventTotal 事件 / $photoTotal 照片 → ${p.basename(file.path)}');
    return BackupExportResult(
      file: file,
      tracks: tracks.length,
      points: pointTotal,
      events: eventTotal,
      photos: photoTotal,
    );
  }

  /// 备份文件名（ASCII，含秒级时间戳防重名）。
  static String exportFileName([DateTime? now]) {
    final t = now ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'DriveRecorder-backup-'
        '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}.zip';
  }

  /// 把 zip 落到公共下载目录 Download/DriveRecorder/。
  ///
  /// 返回展示路径；失败（机型兼容问题）返回 null，
  /// 调用方回落「应用目录 + 分享面板」策略。
  Future<String?> saveToDownloads(File zipFile) async {
    if (!Platform.isAndroid) return null;
    try {
      await MediaStore.ensureInitialized();
      MediaStore.appFolder = 'DriveRecorder';
      final info = await MediaStore().saveFile(
        tempFilePath: zipFile.path,
        dirType: DirType.download,
        dirName: DirName.download,
      );
      if (info == null) return null;
      return 'Download/DriveRecorder/${info.name}';
    } catch (e) {
      AppLogger.w('backup', '公共下载目录写入失败：$e');
      return null;
    }
  }

  Future<File?> _photoFileOf(int trackId, String basename) async {
    final docs = await docsDirResolver();
    final f = File(p.join(docs.path, 'photos', '$trackId', basename));
    return f.existsSync() ? f : null;
  }

  // ---------------------------------------------------------------------------
  // 导入
  // ---------------------------------------------------------------------------

  /// 预览备份内容（不动数据库）。
  Future<BackupPreview> inspect(String zipPath) async {
    final (_, tracks, _) = await _decode(zipPath);
    var points = 0, events = 0, photos = 0;
    for (final t in tracks) {
      final l = _readJsonList(t, 'points.json');
      points += l.length;
      events += _readJsonList(t, 'events.json').length;
      photos += t.files.entries
          .where((e) => e.key.startsWith('photos/') && e.value.isFile)
          .length;
    }
    return BackupPreview(tracks.length, points, events, photos);
  }

  /// 导入备份：重建轨迹/点/事件/照片，重复导入自动跳过。
  Future<BackupImportResult> importZip(
      String zipPath, AppDatabase database) async {
    final (archive, tracks, manifest) = await _decode(zipPath);
    final existing = await database.listTracks();
    final dupKeys = <String>{
      for (final t in existing) '${t.startTime.millisecondsSinceEpoch}|${t.name ?? ''}|${t.pointCount}'
    };

    var imported = 0, skipped = 0, photosRestored = 0;
    for (final tdir in tracks) {
      final trackJson = _readJsonMap(tdir, 'track.json');
      final track = Track.fromRow(trackJson);
      final key =
          '${track.startTime.millisecondsSinceEpoch}|${track.name ?? ''}|${trackJson['point_count'] ?? 0}';
      if (dupKeys.contains(key)) {
        skipped++;
        continue;
      }
      final points = [
        for (final row in _readJsonList(tdir, 'points.json'))
          TrackPoint.fromRow(row)
      ];
      final eventRows = _readJsonList(tdir, 'events.json');

      // 照片先解到内存（数量小：拍照事件级别）
      final photoBytes = <String, Uint8List>{};
      for (final e in tdir.files.entries) {
        if (e.value.isFile && e.key.startsWith('photos/')) {
          photoBytes[p.basename(e.key)] = e.value.content;
        }
      }

      final events = [for (final row in eventRows) DriveEvent.fromRow(row)];

      final newTrack = await database.importTrack(track, points, events);
      final newId = newTrack.id!;

      // 照片落盘 + 修正事件 photo_path
      final docs = await docsDirResolver();
      final photoDir = Directory(p.join(docs.path, 'photos', '$newId'));
      await photoDir.create(recursive: true);
      for (final e in events) {
        final base = e.photoPath;
        if (base == null || base.isEmpty) continue;
        final bytes = photoBytes[base];
        if (bytes == null) continue;
        final dest = File(p.join(photoDir.path, base));
        await dest.writeAsBytes(bytes, flush: true);
        photosRestored++;
        await database.db.update(
          'events',
          {'photo_path': dest.path},
          where: 'track_id = ? AND photo_path = ?',
          whereArgs: [newId, base],
        );
      }
      dupKeys.add(key);
      imported++;
    }
    AppLogger.i('backup',
        '导入完成：新 $imported 条，跳过重复 $skipped 条，照片 $photosRestored 张');
    await archive.clear();
    return BackupImportResult(imported, skipped, photosRestored);
  }

  // ---------------------------------------------------------------------------
  // 解码与判型
  // ---------------------------------------------------------------------------

  Future<(Archive, List<_TrackDir>, Map<String, Object?>)> _decode(
      String zipPath) async {
    final Uint8List bytes;
    try {
      bytes = await File(zipPath).readAsBytes();
    } catch (e) {
      throw BackupException('无法读取文件：$e');
    }
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw BackupException('不是有效的 ZIP 备份文件');
    }
    Map<String, Object?> manifest;
    try {
      final mf = archive.find('manifest.json');
      if (mf == null || !mf.isFile) {
        throw BackupException('缺少 manifest.json（非本应用备份）');
      }
      manifest =
          (jsonDecode(utf8.decode(mf.content)) as Map).cast<String, Object?>();
    } on BackupException {
      rethrow;
    } catch (_) {
      throw BackupException('manifest.json 解析失败（文件可能损坏）');
    }
    if (manifest['format'] != formatId) {
      throw BackupException('备份格式不符：${manifest['format']}');
    }
    final version = (manifest['version'] as num?)?.toInt() ?? 0;
    if (version > formatVersion) {
      throw BackupException('备份版本 $version 高于当前支持（$formatVersion），请先升级 App');
    }

    // 按目录归组 tracks/<id>/*
    final dirs = <String, _TrackDir>{};
    for (final f in archive) {
      if (!f.isFile) continue;
      if (!f.name.startsWith('tracks/')) continue;
      final parts = f.name.split('/');
      if (parts.length < 3) continue;
      final dirKey = 'tracks/${parts[1]}';
      final rel = parts.sublist(2).join('/');
      dirs.putIfAbsent(dirKey, () => _TrackDir(dirKey)).files[rel] = f;
    }
    final tracks = dirs.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    if (tracks.isEmpty) {
      throw BackupException('备份里没有轨迹数据');
    }
    return (archive, tracks, manifest);
  }

  List<Map<String, Object?>> _readJsonList(_TrackDir dir, String rel) {
    final f = dir.files[rel];
    if (f == null) return const [];
    final decoded = jsonDecode(utf8.decode(f.content));
    return (decoded as List).cast<Map>().map((m) => m.cast<String, Object?>()).toList();
  }

  Map<String, Object?> _readJsonMap(_TrackDir dir, String rel) {
    final f = dir.files[rel];
    if (f == null) throw BackupException('备份缺少 $rel');
    return (jsonDecode(utf8.decode(f.content)) as Map).cast<String, Object?>();
  }

  // —— 行 → JSON（与 toRow 对齐，id 仅轨迹保留用于目录名）——
  Map<String, Object?> _trackJson(Track t) =>
      {...t.toRow(), 'id': t.id};

  Map<String, Object?> _pointJson(TrackPoint p) => p.toRow();

  Map<String, Object?> _eventJson(DriveEvent e) => e.toRow();
}

/// 备份内一个轨迹目录（文件按相对路径索引）。
class _TrackDir {
  final String name;
  final Map<String, ArchiveFile> files = {};
  _TrackDir(this.name);
}
