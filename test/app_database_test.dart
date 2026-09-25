import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

import 'package:drive_recorder/models/drive_event.dart';
import 'package:drive_recorder/models/track.dart';
import 'package:drive_recorder/models/track_point.dart';
import 'package:drive_recorder/services/database/app_database.dart';

void main() {
  // Linux 宿主机通常只有 libsqlite3.so.0（无 -dev 的 .so 链接），显式指向；
  // 用 NoIsolate 工厂：override 只在本 isolate 生效，ffi 默认的 worker
  // isolate 看不到 open.overrideFor 的映射
  sqfliteFfiInit();
  if (Platform.isLinux) {
    open.overrideFor(
        OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  }
  final factory = databaseFactoryFfiNoIsolate;

  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.open(
      path: inMemoryDatabasePath,
      factoryOverride: factory,
    );
  });

  tearDown(() async {
    await db.close();
  });

  Track mkTrack(DateTime start) => Track(
        startTime: start,
        source: 'manual',
        name: '测试轨迹',
      );

  group('tracks DAO', () {
    test('插入回填 id，读取往返一致', () async {
      final t = await db.insertTrack(mkTrack(DateTime(2026, 9, 25, 10)));
      expect(t.id, isNotNull);

      final loaded = await db.getTrack(t.id!);
      expect(loaded!.name, '测试轨迹');
      expect(loaded.source, 'manual');
      expect(loaded.startTime, DateTime(2026, 9, 25, 10));
      expect(loaded.pointCount, 0);
      expect(loaded.distanceMeters, 0);
    });

    test('listTracks 按开始时间倒序', () async {
      await db.insertTrack(mkTrack(DateTime(2026, 9, 24)));
      final newer = await db.insertTrack(mkTrack(DateTime(2026, 9, 25)));
      final list = await db.listTracks();
      expect(list.first.id, newer.id);
      expect(list.length, 2);
      expect((await db.latestTrack())!.id, newer.id);
    });

    test('updateTrack 持久化结束时间与统计', () async {
      var t = await db.insertTrack(mkTrack(DateTime(2026, 9, 25, 10)));
      final finished = t.copyWith(
        endTime: DateTime(2026, 9, 25, 11),
        pointCount: 42,
        eventCount: 3,
        distanceMeters: 5600,
      );
      await db.updateTrack(finished);

      final loaded = await db.getTrack(t.id!);
      expect(loaded!.endTime, DateTime(2026, 9, 25, 11));
      expect(loaded.pointCount, 42);
      expect(loaded.eventCount, 3);
      expect(loaded.distanceMeters, 5600);
      expect(loaded.duration, const Duration(hours: 1));
    });

    test('deleteTrack 级联删除点与事件', () async {
      final t = await db.insertTrack(mkTrack(DateTime(2026, 9, 25)));
      await db.insertPoints(
        [TrackPoint(trackId: t.id!, timestamp: DateTime.now())],
        100,
      );
      await db.insertEvent(DriveEvent(
        trackId: t.id!,
        timestamp: DateTime.now(),
        type: DriveEventType.braking,
        peakIntensity: -4,
      ));
      expect((await db.pointsForTrack(t.id!)).length, 1);
      expect((await db.eventsForTrack(t.id!)).length, 1);

      await db.deleteTrack(t.id!);
      expect(await db.getTrack(t.id!), isNull);
      expect((await db.pointsForTrack(t.id!)).isEmpty, isTrue);
      expect((await db.eventsForTrack(t.id!)).isEmpty, isTrue);
    });
  });

  group('track_points DAO', () {
    test('批量事务写入回填 id + 轨迹统计自动累计', () async {
      final t = await db.insertTrack(mkTrack(DateTime(2026, 9, 25, 10)));
      final now = DateTime.now();
      final points = [
        for (var i = 0; i < 25; i++)
          TrackPoint(
            trackId: t.id!,
            timestamp: now.add(Duration(seconds: i)),
            latitude: 39.9 + i * 0.0001,
            longitude: 116.4,
            speed: 10.0,
          ),
      ];
      final stored = await db.insertPoints(points, 1234.5);
      expect(stored.length, 25);
      expect(stored.every((p) => p.id != null), isTrue,
          reason: '批量写入应回填自增 id');
      expect(stored.map((p) => p.timestamp.millisecondsSinceEpoch).toList(),
          points.map((p) => p.timestamp.millisecondsSinceEpoch).toList());

      final track = await db.getTrack(t.id!);
      expect(track!.pointCount, 25);
      expect(track.distanceMeters, closeTo(1234.5, 0.001));

      final read = await db.pointsForTrack(t.id!);
      expect(read.length, 25);
      expect(read.first.latitude, closeTo(39.9, 1e-9));
      expect(read.first.id, stored.first.id);

      expect((await db.lastPointOfTrack(t.id!))!.timestamp.millisecondsSinceEpoch,
          points.last.timestamp.millisecondsSinceEpoch);
    });

    test('降级点（null 坐标 + degraded 标记）往返', () async {
      final t = await db.insertTrack(mkTrack(DateTime(2026, 9, 25)));
      await db.insertPoints([
        TrackPoint(
          trackId: t.id!,
          timestamp: DateTime(2026, 9, 25, 10, 0),
          degraded: true,
        ),
      ], 0);

      final pts = await db.pointsForTrack(t.id!);
      expect(pts.single.degraded, isTrue);
      expect(pts.single.latitude, isNull);
      expect(pts.single.longitude, isNull);
    });
  });

  group('events DAO', () {
    test('插入 + event_count 自动累计 + 按类型查询最近', () async {
      final t = await db.insertTrack(mkTrack(DateTime(2026, 9, 25)));
      final base = DateTime(2026, 9, 25, 10);

      await db.insertEvent(DriveEvent(
          trackId: t.id!,
          timestamp: base,
          type: DriveEventType.manual,
          degraded: true,
          note: '无定位信号'));
      await db.insertEvent(DriveEvent(
          trackId: t.id!,
          timestamp: base.add(const Duration(minutes: 5)),
          type: DriveEventType.braking,
          peakIntensity: -4.5,
          latitude: 39.9,
          longitude: 116.4));
      await db.insertEvent(DriveEvent(
          trackId: t.id!,
          timestamp: base.add(const Duration(minutes: 10)),
          type: DriveEventType.collision,
          peakIntensity: 88,
          latitude: 39.91,
          longitude: 116.41));

      expect((await db.getTrack(t.id!))!.eventCount, 3);

      final events = await db.eventsForTrack(t.id!);
      expect(events.length, 3);
      expect(events.map((e) => e.type.name).toSet(),
          {'manual', 'braking', 'collision'});

      final lastBraking =
          await db.lastEventOfTrack(t.id!, DriveEventType.braking);
      expect(lastBraking!.peakIntensity, -4.5);
      expect(lastBraking.timestamp, base.add(const Duration(minutes: 5)));
    });

    test('mergeEventPeak：峰值取绝对值更大者、时间戳保留', () async {
      final t = await db.insertTrack(mkTrack(DateTime(2026, 9, 25)));
      final base = DateTime(2026, 9, 25, 10);
      final e1 = await db.insertEvent(DriveEvent(
          trackId: t.id!,
          timestamp: base,
          type: DriveEventType.braking,
          peakIntensity: -4.0));

      // 更强的一次 → 更新峰值
      final merged = await db.mergeEventPeak(e1, 5.5);
      expect(merged.peakIntensity, closeTo(-5.5, 0.001));

      // 更弱的一次 → 保持不变
      final merged2 = await db.mergeEventPeak(merged, 3.0);
      expect(merged2.peakIntensity, closeTo(-5.5, 0.001));

      // 时间戳不更新
      final reloaded =
          await db.lastEventOfTrack(t.id!, DriveEventType.braking);
      expect(reloaded!.timestamp, base);
      expect(reloaded.peakIntensity, closeTo(-5.5, 0.001));

      // 事件数不增加（合并非新增）
      expect((await db.eventsForTrack(t.id!)).length, 1);
      expect((await db.getTrack(t.id!))!.eventCount, 1);
    });
  });

  group('迁移版本骨架', () {
    test('dbVersion 为 2（升级时在 onUpgrade 增加分支）', () {
      expect(AppDatabase.dbVersion, 2);
    });
  });

  group('photo 事件 DAO', () {
    test('photo 事件读写往返（photoPath 持久化 + event_count 累计）', () async {
      final t = await db.insertTrack(mkTrack(DateTime(2026, 9, 25, 10)));
      final base = DateTime(2026, 9, 25, 10, 30);

      final e = await db.insertEvent(DriveEvent(
        trackId: t.id!,
        timestamp: base,
        type: DriveEventType.photo,
        latitude: 39.92,
        longitude: 116.41,
        photoPath:
            '/data/user/0/app/documents/photos/${t.id}/${base.millisecondsSinceEpoch}.jpg',
      ));
      expect(e.id, isNotNull);

      final events = await db.eventsForTrack(t.id!);
      expect(events.single.type, DriveEventType.photo);
      expect(events.single.photoPath,
          '/data/user/0/app/documents/photos/${t.id}/${base.millisecondsSinceEpoch}.jpg');
      expect(events.single.latitude, 39.92);
      expect(events.single.degraded, isFalse);
      // photo 也计入事件数
      expect((await db.getTrack(t.id!))!.eventCount, 1);
    });

    test('photo 事件无 GPS 时坐标 null + degraded 往返', () async {
      final t = await db.insertTrack(mkTrack(DateTime(2026, 9, 25)));
      await db.insertEvent(DriveEvent(
        trackId: t.id!,
        timestamp: DateTime(2026, 9, 25, 10, 30),
        type: DriveEventType.photo,
        degraded: true,
        note: '无定位信号',
        photoPath: '/tmp/x/123.jpg',
      ));

      final e = (await db.eventsForTrack(t.id!)).single;
      expect(e.latitude, isNull);
      expect(e.longitude, isNull);
      expect(e.degraded, isTrue);
      expect(e.note, '无定位信号');
      expect(e.photoPath, '/tmp/x/123.jpg');
    });
  });

  group('v1→v2 迁移', () {
    test('先建 v1 库插老数据再迁移：photo_path 列新增、老数据零丢失', () async {
      final path =
          '${Directory.systemTemp.path}/drive_recorder_migration_${DateTime.now().millisecondsSinceEpoch}.db';
      addTearDown(() async {
        final f = File(File(path).resolveSymbolicLinksSync());
        if (await f.exists()) await f.delete();
      });

      // 1. 手工建 v1 库（结构 = 迁移前的 events 表，无 photo_path）
      final v1 = await factory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            await db.execute('''
              CREATE TABLE tracks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                start_time INTEGER NOT NULL,
                end_time INTEGER,
                point_count INTEGER NOT NULL DEFAULT 0,
                event_count INTEGER NOT NULL DEFAULT 0,
                distance_meters REAL NOT NULL DEFAULT 0,
                source TEXT NOT NULL DEFAULT 'manual',
                name TEXT
              )
            ''');
            await db.execute('''
              CREATE TABLE events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
                timestamp INTEGER NOT NULL,
                type TEXT NOT NULL,
                peak_intensity REAL,
                latitude REAL,
                longitude REAL,
                degraded INTEGER NOT NULL DEFAULT 0,
                track_point_id INTEGER,
                note TEXT
              )
            ''');
          },
        ),
      );
      final ts = DateTime(2026, 9, 24, 9).millisecondsSinceEpoch;
      final trackId = await v1.insert('tracks', {
        'start_time': ts,
        'point_count': 10,
        'event_count': 2,
        'distance_meters': 1200.5,
        'source': 'manual',
        'name': 'v1 老轨迹',
      });
      await v1.insert('events', {
        'track_id': trackId,
        'timestamp': ts + 60000,
        'type': 'braking',
        'peak_intensity': -4.2,
        'latitude': 39.9,
        'longitude': 116.4,
        'degraded': 0,
      });
      await v1.insert('events', {
        'track_id': trackId,
        'timestamp': ts + 120000,
        'type': 'manual',
        'degraded': 1,
        'note': '无定位信号',
      });
      await v1.close();

      // 2. 用 AppDatabase 重开：应触发 onUpgrade 1→2
      final db2 = await AppDatabase.open(path: path, factoryOverride: factory);

      // 老轨迹零丢失
      final track = await db2.getTrack(trackId);
      expect(track!.name, 'v1 老轨迹');
      expect(track.pointCount, 10);
      expect(track.eventCount, 2);

      // 老事件零丢失（photoPath 为 null）
      final oldEvents = await db2.eventsForTrack(trackId);
      expect(oldEvents.length, 2);
      expect(oldEvents.first.type, DriveEventType.braking);
      expect(oldEvents.first.peakIntensity, -4.2);
      expect(oldEvents.every((e) => e.photoPath == null), isTrue);

      // 3. 新增 photo_path 列可写
      await db2.insertEvent(DriveEvent(
        trackId: trackId,
        timestamp: DateTime(2026, 9, 24, 9, 5),
        type: DriveEventType.photo,
        latitude: 39.91,
        longitude: 116.41,
        photoPath: '/docs/photos/$trackId/123.jpg',
      ));
      final events = await db2.eventsForTrack(trackId);
      expect(events.length, 3);
      expect(
          events.last.photoPath, '/docs/photos/$trackId/123.jpg');
      expect((await db2.getTrack(trackId))!.eventCount, 3);

      await db2.close();
    });
  });
}
