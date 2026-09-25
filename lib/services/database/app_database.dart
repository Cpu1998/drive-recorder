import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../models/drive_event.dart';
import '../../models/track.dart';
import '../../models/track_point.dart';

/// SQLite 数据库：tracks / track_points / events 三张表 + DAO。
///
/// 迁移骨架：升版时在 [onUpgrade] 的 switch 中追加分支，
/// 并保持每个迁移只做增量 DDL（已发布的版本不可修改历史分支）。
class AppDatabase {
  static const String dbName = 'drive_recorder.db';

  /// 数据库结构版本号。改动表结构时 +1，并在 [onUpgrade] 增加迁移分支。
  static const int dbVersion = 1;

  final Database db;

  AppDatabase._(this.db);

  /// 打开（或创建）数据库。
  ///
  /// [factoryOverride] 供桌面端单测注入 sqflite_common_ffi。
  static Future<AppDatabase> open({
    String? path,
    DatabaseFactory? factoryOverride,
  }) async {
    final databasePath = path ??
        p.join(await (factoryOverride ?? databaseFactory).getDatabasesPath(),
            dbName);
    final db = await (factoryOverride ?? databaseFactory).openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: dbVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
    return AppDatabase._(db);
  }

  static Future<void> _onCreate(Database db, int version) async {
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
      CREATE TABLE track_points (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
        timestamp INTEGER NOT NULL,
        latitude REAL,
        longitude REAL,
        altitude REAL,
        speed REAL,
        accuracy REAL,
        bearing REAL,
        degraded INTEGER NOT NULL DEFAULT 0
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
    await db
        .execute('CREATE INDEX idx_points_track ON track_points(track_id)');
    await db.execute(
        'CREATE INDEX idx_events_track ON events(track_id, timestamp)');
  }

  /// 迁移骨架：
  /// ```dart
  /// switch (oldVersion) {
  ///   case 1:
  ///     // v2 迁移：await db.execute('ALTER TABLE ...');
  ///   case 2:
  ///     // v3 迁移：...
  /// }
  /// ```
  static Future<void> _onUpgrade(
      Database db, int oldVersion, int newVersion) async {
    switch (oldVersion) {
      // case 1: v2 迁移写这里
      // case 2: v3 迁移写这里
    }
  }

  Future<void> close() => db.close();

  // ---------------------------------------------------------------------------
  // tracks
  // ---------------------------------------------------------------------------

  Future<Track> insertTrack(Track track) async {
    final id = await db.insert('tracks', track.toRow());
    return track.copyWith(id: id);
  }

  Future<Track?> getTrack(int id) async {
    final rows = await db.query('tracks', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Track.fromRow(rows.first);
  }

  Future<List<Track>> listTracks({int? limit}) async =>
      [for (final r in await db.query('tracks', orderBy: 'start_time DESC', limit: limit)) Track.fromRow(r)];

  Future<void> updateTrack(Track track) async {
    await db.update('tracks', track.toRow(),
        where: 'id = ?', whereArgs: [track.id]);
  }

  Future<void> deleteTrack(int id) async {
    await db.transaction((txn) async {
      await txn
          .delete('track_points', where: 'track_id = ?', whereArgs: [id]);
      await txn.delete('events', where: 'track_id = ?', whereArgs: [id]);
      await txn.delete('tracks', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<Track?> latestTrack() async {
    final rows = await db.query('tracks',
        orderBy: 'start_time DESC', limit: 1);
    return rows.isEmpty ? null : Track.fromRow(rows.first);
  }

  // ---------------------------------------------------------------------------
  // track_points
  // ---------------------------------------------------------------------------

  /// 批量事务写入轨迹点；同时把点数/里程累计到所属轨迹。
  /// [extraDistanceMeters] 为这批点新产生的里程。
  Future<List<TrackPoint>> insertPoints(
      List<TrackPoint> points, double extraDistanceMeters) async {
    if (points.isEmpty && extraDistanceMeters <= 0) return const [];
    final results = <TrackPoint>[];
    await db.transaction((txn) async {
      if (points.isNotEmpty) {
        final batch = txn.batch();
        for (final point in points) {
          batch.insert('track_points', point.toRow());
        }
        final ids = await batch.commit(noResult: false);
        for (var i = 0; i < ids.length && i < points.length; i++) {
          final id = ids[i];
          results.add(id is int ? points[i].copyWith(id: id) : points[i]);
        }
      }
      if (points.isNotEmpty || extraDistanceMeters > 0) {
        await txn.rawUpdate('''
          UPDATE tracks SET
            point_count = point_count + ?,
            distance_meters = distance_meters + ?
          WHERE id = ?
        ''', [points.length, extraDistanceMeters, points.first.trackId]);
      }
    });
    return results;
  }

  Future<List<TrackPoint>> pointsForTrack(int trackId) async => [
        for (final r in await db.query('track_points',
            where: 'track_id = ?',
            whereArgs: [trackId],
            orderBy: 'timestamp ASC'))
          TrackPoint.fromRow(r)
      ];

  Future<TrackPoint?> lastPointOfTrack(int trackId) async {
    final rows = await db.query('track_points',
        where: 'track_id = ?',
        whereArgs: [trackId],
        orderBy: 'timestamp DESC',
        limit: 1);
    return rows.isEmpty ? null : TrackPoint.fromRow(rows.first);
  }

  // ---------------------------------------------------------------------------
  // events
  // ---------------------------------------------------------------------------

  Future<DriveEvent> insertEvent(DriveEvent event) async {
    final id = await db.transaction<int>((txn) async {
      final id = await txn.insert('events', event.toRow());
      await txn.rawUpdate(
          'UPDATE tracks SET event_count = event_count + 1 WHERE id = ?',
          [event.trackId]);
      return id;
    });
    return event.copyWith(id: id);
  }

  /// 去抖合并：把 10s 窗口内的同类事件合并到已有记录（更新峰值，保留首次时间戳）。
  Future<DriveEvent> mergeEventPeak(DriveEvent existing, double newPeak) async {
    final merged = existing.copyWith(
        peakIntensity:
            (existing.peakIntensity?.abs() ?? 0) > newPeak.abs() ? existing.peakIntensity : (existing.type == DriveEventType.braking ? -newPeak : newPeak));
    await db.update('events', merged.toRow(),
        where: 'id = ?', whereArgs: [merged.id]);
    return merged;
  }

  Future<List<DriveEvent>> eventsForTrack(int trackId) async => [
        for (final r in await db.query('events',
            where: 'track_id = ?',
            whereArgs: [trackId],
            orderBy: 'timestamp ASC'))
          DriveEvent.fromRow(r)
      ];

  Future<DriveEvent?> lastEventOfTrack(
      int trackId, DriveEventType type) async {
    final rows = await db.query('events',
        where: 'track_id = ? AND type = ?',
        whereArgs: [trackId, type.name],
        orderBy: 'timestamp DESC',
        limit: 1);
    return rows.isEmpty ? null : DriveEvent.fromRow(rows.first);
  }
}
