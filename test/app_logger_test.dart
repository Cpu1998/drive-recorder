import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:drive_recorder/screens/log_screen.dart';
import 'package:drive_recorder/services/app_logger.dart';

/// 运行日志：环形缓冲、导出格式、打码、日志页渲染与清空。
void main() {
  setUp(() => AppLogger.reset());

  test('i/w/e 分级写入与顺序', () {
    AppLogger.i('app', '启动');
    AppLogger.w('key', '未配置');
    AppLogger.e('loc', '失败');
    final es = AppLogger.entries;
    expect(es.length, 3);
    expect(es.map((e) => e.level).toList(), ['I', 'W', 'E']);
    expect(es[0].tag, 'app');
  });

  test('环形缓冲封顶 1000 条', () {
    for (var i = 0; i < 1200; i++) {
      AppLogger.i('t', 'msg$i');
    }
    expect(AppLogger.entries.length, 1000);
    expect(AppLogger.entries.first.message, 'msg200');
    expect(AppLogger.entries.last.message, 'msg1199');
  });

  test('导出含条数与全部内容', () {
    AppLogger.i('app', '进程启动');
    AppLogger.w('db', '打开失败，进入损坏自恢复');
    final out = AppLogger.export();
    expect(out, contains('运行日志（最近 2 条）'));
    expect(out, contains('进程启动'));
    expect(out, contains('损坏自恢复'));
    expect(out, contains(' I '));
    expect(out, contains(' W '));
  });

  test('Key 打码：保留首尾 4 位与长度', () {
    expect(AppLogger.maskKey('abcdefgh12345678'),
        'abcd…5678（16 位）');
    expect(AppLogger.maskKey('short'), '5 位');
  });

  testWidgets('日志页渲染条目 + 清空', (tester) async {
    AppLogger.i('app', '进程启动 v1.3.0');
    AppLogger.e('loc', '定位失败 errorCode=7 INVALID_USER_KEY');
    await tester.pumpWidget(const MaterialApp(home: LogScreen()));
    await tester.pump();

    expect(find.textContaining('进程启动 v1.3.0'), findsOneWidget);
    expect(find.textContaining('INVALID_USER_KEY'), findsOneWidget);

    await tester.tap(find.byTooltip('清空'));
    await tester.pump();
    expect(find.text('暂无日志'), findsOneWidget);
  });
}
