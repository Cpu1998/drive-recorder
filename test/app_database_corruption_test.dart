import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

import 'package:drive_recorder/models/track.dart';
import 'package:drive_recorder/services/database/app_database.dart';

/// 数据库损坏自恢复：垃圾文件 / 半截文件都能兜底重建，绝不让启动路径崩死。
void main() {
  sqfliteFfiInit();
  if (Platform.isLinux) {
    open.overrideFor(
        OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  }
  late final Directory tmp;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('db_corrupt_test');
  });

  tearDownAll(() async {
    await tmp.delete(recursive: true);
  });

  test('垃圾字节文件 → 备份改名并重建空库', () async {
    final path = '${tmp.path}/garbage.db';
    File(path).writeAsBytesSync(
        List<int>.generate(4096, (i) => i % 251)); // 非 SQLite 格式
    final db = await AppDatabase.open(
        path: path, factoryOverride: databaseFactoryFfiNoIsolate);
    expect(await db.listTracks(), isEmpty, reason: '应重建为空库');
    // 老文件应被备份保留
    final backups =
        Directory(tmp.path).listSync().where((f) => f.path.contains('corrupt-'));
    expect(backups, isNotEmpty);
    await db.close();
  });

  test('空文件（0 字节）→ 重建', () async {
    final path = '${tmp.path}/empty.db';
    File(path).writeAsBytesSync([]);
    final db = await AppDatabase.open(
        path: path, factoryOverride: databaseFactoryFfiNoIsolate);
    expect(await db.listTracks(), isEmpty);
    await db.close();
  });

  test('正常库不受影响，可重复打开', () async {
    final path = '${tmp.path}/normal.db';
    final db = await AppDatabase.open(
        path: path, factoryOverride: databaseFactoryFfiNoIsolate);
    await db.insertTrack(Track(
        startTime: DateTime(2026, 9, 25, 9, 0), name: '正常', source: 'manual'));
    expect((await db.listTracks()).length, 1);
    await db.close();

    final db2 = await AppDatabase.open(
        path: path, factoryOverride: databaseFactoryFfiNoIsolate);
    expect((await db2.listTracks()).length, 1, reason: '正常库不能被误判损坏');
    await db2.close();
  });
}
