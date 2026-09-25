import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

import 'package:drive_recorder/models/drive_event.dart';
import 'package:drive_recorder/models/track.dart';
import 'package:drive_recorder/services/database/app_database.dart';
import 'package:drive_recorder/services/sample_track_seeder.dart';

/// 示例轨迹种入：一次性、可删除、统计正确、照片落盘。
void main() {
  sqfliteFfiInit();
  if (Platform.isLinux) {
    open.overrideFor(
        OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  }
  late Directory tmp;
  late Directory docs;
  late AppDatabase db;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('seed_test');
    docs = Directory('${tmp.path}/docs');
    await docs.create();
    db = await AppDatabase.open(
        path: '${tmp.path}/test.db', factoryOverride: databaseFactoryFfiNoIsolate);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<SampleTrackSeeder> mkSeeder() async => SampleTrackSeeder(
        db,
        await SharedPreferences.getInstance(),
        assetLoader: (_) async =>
            Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]),
        docsDirResolver: () async => docs,
      );

  test('空库首次种入：轨迹 + 37 点 + 3 事件 + 照片落盘 + 统计正确', () async {
    final seeded = await (await mkSeeder()).seedIfNeeded();
    expect(seeded, isTrue);

    final tracks = await db.listTracks();
    expect(tracks.length, 1);
    final t = tracks.first;
    expect(t.name, '示例轨迹（可删除）');
    expect(t.endTime, isNotNull, reason: '应回填结束时间');
    expect(t.pointCount, greaterThanOrEqualTo(30));
    expect(t.eventCount, 3);
    expect(t.distanceMeters, greaterThan(3000), reason: '望京环线约 3-5 km');
    expect(t.distanceMeters, lessThan(8000));

    final points = await db.pointsForTrack(t.id!);
    expect(points.length, t.pointCount);
    expect(points.every((p) => p.latitude != null && p.longitude != null),
        isTrue, reason: '示例点全部有定位');

    final events = await db.eventsForTrack(t.id!);
    expect(events.where((e) => e.type == DriveEventType.photo), isNotEmpty);
    final photo = events.firstWhere((e) => e.type == DriveEventType.photo);
    expect(File(photo.photoPath!).existsSync(), isTrue,
        reason: '示例照片应复制到文档目录');
    final braking = events.firstWhere((e) => e.type == DriveEventType.braking);
    expect(braking.peakIntensity, lessThan(0));
  });

  test('第二次调用不再种入（一次性标记）', () async {
    final s = await mkSeeder();
    await s.seedIfNeeded();
    // 删掉轨迹模拟用户删除示例
    final tracks = await db.listTracks();
    await db.deleteTrack(tracks.first.id!);
    expect(await s.seedIfNeeded(), isFalse, reason: '删除后也不 resurrect');
    expect(await db.listTracks(), isEmpty);
  });

  test('已有轨迹时不种入（不打扰老用户）', () async {
    await db.insertTrack(Track(
        startTime: DateTime(2026, 9, 20, 8, 0),
        name: '用户自己的轨迹',
        source: 'manual'));
    expect(await (await mkSeeder()).seedIfNeeded(), isFalse);
    expect((await db.listTracks()).length, 1);
  });

  test('标记已存在时直接跳过（不查库）', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(SampleTrackSeeder.prefKey, true);
    expect(await (await mkSeeder()).seedIfNeeded(), isFalse);
    expect(await db.listTracks(), isEmpty);
  });
}
