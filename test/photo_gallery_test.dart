import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:drive_recorder/models/drive_event.dart';
import 'package:drive_recorder/widgets/photo_gallery.dart';

/// 有效 1x1 红色 PNG（69 字节）。本文件刻意不等待真实图片解码：
/// FakeAsync 测试环境下 FileImage 的解码 Future 不会完成，
/// precacheImage + pumpAndSettle 会永久挂起——一律用显式 pump。
const List<int> _pngBytes = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, //
  0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, //
  0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0x00, 0x00, //
  0x03, 0x01, 0x01, 0x00, 0xC9, 0xFE, 0x92, 0xEF, //
  0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, //
  0xAE, 0x42, 0x60, 0x82,
];

DriveEvent _photoEvent(String path, {bool degraded = false}) => DriveEvent(
      id: 1,
      trackId: 7,
      timestamp: DateTime(2026, 9, 25, 10, 45, 12),
      type: DriveEventType.photo,
      latitude: degraded ? null : 39.91,
      longitude: degraded ? null : 116.4,
      degraded: degraded,
      photoPath: path,
    );

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: SizedBox(height: 150, child: child)));

/// 在 runAsync 里建临时文件，返回路径（真实 IO 必须包 runAsync）。
Future<String> _writeTempPng(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  final f = await File('${dir.path}/1000.jpg')
      .writeAsBytes(Uint8List.fromList(_pngBytes));
  return f.path;
}

void main() {
  testWidgets('缩略图列表渲染本地照片文件 + 标题计数', (tester) async {
    final path = await tester.runAsync(() => _writeTempPng('pg_t1'));

    await tester.pumpWidget(
        _wrap(PhotoStrip(photoEvents: [_photoEvent(path!)])));
    // 显式 pump 两次（build + layout），不等图片解码
    await tester.pump();
    await tester.pump();

    expect(find.text('现场照片（1）'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('10:45:12'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('照片文件缺失时显示占位图 + 降级角标，不崩溃', (tester) async {
    await tester.pumpWidget(_wrap(PhotoStrip(
      photoEvents: [_photoEvent('/nonexistent/pg_t2/deleted.jpg',
          degraded: true)],
    )));
    await tester.pump();
    await tester.pump();

    expect(find.text('现场照片（1）'), findsOneWidget);
    expect(find.text('照片缺失'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.location_off), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击缩略图进入全屏查看（InteractiveViewer）再点击退出',
      (tester) async {
    final path = await tester.runAsync(() => _writeTempPng('pg_t3'));

    await tester.pumpWidget(
        _wrap(PhotoStrip(photoEvents: [_photoEvent(path!)])));
    await tester.pump();
    await tester.pump();

    // 点击卡片中心（Image 已布局，无需解码完成）
    await tester.tap(find.byType(Card));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('📷 10:45:12'), findsOneWidget);

    // 点击退出
    await tester.tap(find.byType(InteractiveViewer),
        warnIfMissed: false);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byType(InteractiveViewer), findsNothing);
  });

  testWidgets('缺失照片的全屏查看显示错误占位不崩溃', (tester) async {
    await tester.pumpWidget(
        MaterialApp(home: PhotoViewer(event: _photoEvent('nope.jpg'))));
    await tester.pump();

    expect(find.text('照片文件不存在（可能已被清理）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
