import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

import 'package:drive_recorder/models/drive_event.dart';
import 'package:drive_recorder/models/track.dart';
import 'package:drive_recorder/models/track_point.dart';
import 'package:drive_recorder/services/backup_service.dart';
import 'package:drive_recorder/services/database/app_database.dart';
import 'package:drive_recorder/utils/geo_utils.dart';

void main() {
  sqfliteFfiInit();
  if (Platform.isLinux) {
    open.overrideFor(
        OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  }
  final factory = databaseFactoryFfiNoIsolate;

  late Directory tmp;
  late AppDatabase db;
  late Directory docs; // 模拟应用文档目录（照片所在）

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dr_bk');
    docs = Directory('${tmp.path}/docs');
    await docs.create();
    db = await AppDatabase.open(
      path: '${tmp.path}/test.db',
      factoryOverride: factory,
    );
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  BackupService mkService({Directory? docsOverride}) => BackupService(
        docsDirResolver: () async => docsOverride ?? docs,
        tmpDirResolver: () async => tmp,
      );

  /// 造一条完整轨迹：2 点 + 1 事件 + 1 照片（文件已落 docs/photos/<id>/）。
  Future<Track> seedTrack(
      String name, DateTime start, {String photo = '1730000000000.jpg'}) async {
    final t = await db.insertTrack(Track(
      startTime: start,
      source: 'manual',
      name: name,
    ));
    await db.insertPoints([
      TrackPoint(
          trackId: t.id!,
          timestamp: start,
          latitude: 31.2304,
          longitude: 121.4737,
          speed: 8.5),
      TrackPoint(
          trackId: t.id!,
          timestamp: start.add(const Duration(seconds: 10)),
          latitude: 31.2310,
          longitude: 121.4740,
          speed: 9.0),
    ], 0);
    final photoDir = Directory('${docs.path}/photos/${t.id}');
    await photoDir.create(recursive: true);
    final pf = File('${photoDir.path}/$photo');
    await pf.writeAsBytes([1, 2, 3, 4, 5]);
    await db.insertEvent(DriveEvent(
      trackId: t.id!,
      timestamp: start.add(const Duration(seconds: 5)),
      type: DriveEventType.braking,
      peakIntensity: 4.2,
      latitude: 31.2305,
      longitude: 121.4738,
      photoPath: pf.path,
    ));
    return (await db.getTrack(t.id!))!;
  }

  test('导出→导入 完整往返（数据/照片/路径均还原）', () async {
    await seedTrack('周末自驾', DateTime(2026, 9, 26, 9));
    final svc = mkService();
    final result = await svc.exportAll(db);
    expect(result.tracks, 1);
    expect(result.points, 2);
    expect(result.events, 1);
    expect(result.photos, 1);
    expect(result.file.existsSync(), isTrue);
    expect(result.file.path, endsWith('.zip'));
    // 文件名 ASCII（跨平台兼容）
    expect(BackupService.exportFileName(), matches(RegExp(
        r'^DriveRecorder-backup-\d{8}-\d{6}\.zip$')));

    // 全新数据库导入
    final db2 = await AppDatabase.open(
      path: '${tmp.path}/import.db',
      factoryOverride: factory,
    );
    final docs2 = Directory('${tmp.path}/docs2');
    await docs2.create();
    final svc2 = mkService(docsOverride: docs2);

    final preview = await svc2.inspect(result.file.path);
    expect(preview.tracks, 1);
    expect(preview.points, 2);
    expect(preview.events, 1);
    expect(preview.photos, 1);

    final imported = await svc2.importZip(result.file.path, db2);
    expect(imported.imported, 1);
    expect(imported.photosRestored, 1);
    expect(imported.skippedDuplicates, 0);

    final tracks = await db2.listTracks();
    expect(tracks.length, 1);
    final t = tracks.first;
    expect(t.name, '周末自驾');
    expect(t.pointCount, 2); // 计数器随导入重建
    expect(t.eventCount, 1);
    expect(t.distanceMeters, greaterThan(0)); // 距离随导入重算
    // 里程应等于点间实际距离
    final pts = await db2.pointsForTrack(t.id!);
    final expectDist = GeoUtils.distance(
        pts[0].latitude!, pts[0].longitude!, pts[1].latitude!, pts[1].longitude!);
    expect(t.distanceMeters, closeTo(expectDist, 0.5));

    final events = await db2.eventsForTrack(t.id!);
    expect(events.length, 1);
    expect(events[0].type, DriveEventType.braking);
    // photo_path 已重写为新轨迹 id 下的绝对路径，且文件存在
    expect(events[0].photoPath,
        '${docs2.path}/photos/${t.id}/1730000000000.jpg');
    expect(File(events[0].photoPath!).existsSync(), isTrue);
    expect(File(events[0].photoPath!).readAsBytesSync(), [1, 2, 3, 4, 5]);

    await db2.close();
  });

  test('同一备份重复导入自动跳过', () async {
    await seedTrack('通勤', DateTime(2026, 9, 27, 8));
    final svc = mkService();
    final result = await svc.exportAll(db);

    final db2 = await AppDatabase.open(
      path: '${tmp.path}/import.db',
      factoryOverride: factory,
    );
    addTearDown(db2.close);
    final svc2 = mkService(); // 共用 docs：照片判重不影响轨迹判重
    final first = await svc2.importZip(result.file.path, db2);
    expect(first.imported, 1);
    final second = await svc2.importZip(result.file.path, db2);
    expect(second.imported, 0);
    expect(second.skippedDuplicates, 1);
    expect((await db2.listTracks()).length, 1);
  });

  test('损坏/非备份 zip 报友好错误', () async {
    final svc = mkService();
    final junk = File('${tmp.path}/junk.zip');
    await junk.writeAsBytes([1, 2, 3, 4]);
    await expectLater(svc.inspect(junk.path), throwsA(isA<BackupException>()));

    final notZip = File('${tmp.path}/plain.zip');
    await notZip.writeAsString('hello, i am not a zip');
    await expectLater(svc.inspect(notZip.path), throwsA(isA<BackupException>()));

    final missing = File('${tmp.path}/nope.zip');
    await expectLater(
        svc.inspect(missing.path), throwsA(isA<BackupException>()));
  });

  test('导出 zip 可被标准解压器读取（unzip 兼容性）', () async {
    await seedTrack('兼容性', DateTime(2026, 9, 28, 7));
    final svc = mkService();
    final result = await svc.exportAll(db);
    final out = Directory('${tmp.path}/unzipped');
    final pr = await Process.run('unzip', ['-o', result.file.path, '-d', out.path]);
    expect(pr.exitCode, 0, reason: pr.stderr.toString());
    expect(File('${out.path}/manifest.json').existsSync(), isTrue);
    final mf = File('${out.path}/manifest.json').readAsStringSync();
    expect(mf, contains('"driverecorder-backup"'));
    expect(mf, contains('"version": 1'));
    expect(
        File('${out.path}/tracks/000001/points.json').existsSync(), isTrue);
  });
}
