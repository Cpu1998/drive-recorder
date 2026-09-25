import 'package:flutter_test/flutter_test.dart';

import 'package:drive_recorder/models/drive_event.dart';
import 'package:drive_recorder/models/track.dart';
import 'package:drive_recorder/models/track_point.dart';
import 'package:drive_recorder/services/gpx_service.dart';

Track _track() => Track(
      id: 7,
      startTime: DateTime(2026, 9, 25, 10, 41, 30),
      endTime: DateTime(2026, 9, 25, 11, 5, 0),
      pointCount: 3,
      eventCount: 2,
      distanceMeters: 1234.5,
      name: '9月25日 10:41',
    );

List<TrackPoint> _points() => [
      TrackPoint(
        trackId: 7,
        timestamp: DateTime(2026, 9, 25, 10, 41, 30),
        latitude: 39.90923,
        longitude: 116.397428,
        altitude: 43.2,
        speed: 12.5,
      ),
      TrackPoint(
        trackId: 7,
        timestamp: DateTime(2026, 9, 25, 10, 41, 32),
        latitude: 39.91000,
        longitude: 116.39800,
        altitude: 44.0,
        speed: 13.1,
      ),
      // 无定位的降级点：不应出现在 trkpt 中
      TrackPoint(
        trackId: 7,
        timestamp: DateTime(2026, 9, 25, 10, 41, 34),
        degraded: true,
      ),
    ];

List<DriveEvent> _events() => [
      DriveEvent(
        id: 1,
        trackId: 7,
        timestamp: DateTime(2026, 9, 25, 10, 45, 0),
        type: DriveEventType.braking,
        peakIntensity: -4.2,
        latitude: 39.911,
        longitude: 116.399,
      ),
      DriveEvent(
        id: 2,
        trackId: 7,
        timestamp: DateTime(2026, 9, 25, 10, 50, 0),
        type: DriveEventType.manual,
        // 无坐标：不应输出 wpt，但应计入 trk desc 统计
        degraded: true,
        note: '无定位信号',
      ),
    ];

void main() {
  final gpx = GpxService().build(
    track: _track(),
    points: _points(),
    events: _events(),
  );

  test('GPX 1.1 头部与命名空间', () {
    expect(gpx, startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
    expect(gpx, contains('version="1.1"'));
    expect(gpx, contains('xmlns="http://www.topografix.com/GPX/1/1"'));
    expect(gpx, contains('xsi:schemaLocation="http://www.topografix.com/GPX/1/1'));
    expect(gpx.trim().endsWith('</gpx>'), isTrue);
  });

  test('trk/trkseg/trkpt 结构与字段', () {
    expect(gpx, contains('<trk>'));
    expect(gpx, contains('<trkseg>'));
    expect(gpx, contains('<name>9月25日 10:41</name>'));
    // 两个有定位的点
    expect(RegExp('<trkpt ').allMatches(gpx).length, 2);
    expect(gpx, contains('lat="39.909230"'));
    expect(gpx, contains('lon="116.397428"'));
    expect(gpx, contains('<ele>43.2</ele>'));
    expect(gpx, contains('<time>2026-09-25T02:41:30.000Z</time>'),
        reason: '时间应为 ISO8601 UTC（Z 后缀）');
  });

  test('事件输出为 wpt + name/desc（仅有坐标的事件）', () {
    expect(RegExp('<wpt ').allMatches(gpx).length, 1,
        reason: '无坐标的手动事件不输出 wpt');
    expect(gpx, contains('<wpt lat="39.911000" lon="116.399000">'));
    expect(gpx, contains('<name>急刹</name>'));
    expect(gpx, contains('峰值 -4.2 m/s²'));
    expect(gpx, contains('<time>2026-09-25T02:45:00.000Z</time>'));
  });

  test('无坐标事件计入 trk desc 统计', () {
    expect(gpx, contains('手动打点 1 次'));
    expect(gpx, contains('无定位轨迹点 1 个'));
    expect(gpx, contains('急刹 1 次'));
  });

  test('XML 转义', () {
    final nasty = GpxService().build(
      track: _track().copyWith(name: 'a<b>&"c"'),
      points: _points(),
      events: const [],
    );
    expect(nasty, contains('a&lt;b&gt;&amp;&quot;c&quot;'));
    expect(nasty, isNot(contains('a<b>')));
  });

  test('里程写入 desc', () {
    expect(gpx, contains('1.2 km'));
  });

  test('photo 事件输出为 wpt：name=📷 拍照点、desc 含照片文件名、不含二进制', () {
    final out = GpxService().build(
      track: _track(),
      points: _points(),
      events: [
        DriveEvent(
          id: 9,
          trackId: 7,
          timestamp: DateTime(2026, 9, 25, 10, 47, 0),
          type: DriveEventType.photo,
          latitude: 39.912,
          longitude: 116.401,
          photoPath: '/docs/photos/7/1758779220000.jpg',
        ),
        // 无坐标的 photo 事件：不输出 wpt，但计入统计
        DriveEvent(
          id: 10,
          trackId: 7,
          timestamp: DateTime(2026, 9, 25, 10, 48, 0),
          type: DriveEventType.photo,
          degraded: true,
          note: '无定位信号',
          photoPath: '/docs/photos/7/1758779280000.jpg',
        ),
      ],
    );

    // 有坐标的 photo → wpt
    expect(out, contains('<wpt lat="39.912000" lon="116.401000">'));
    expect(out, contains('<name>📷 拍照点</name>'));
    expect(out, contains('照片 1758779220000.jpg'));
    expect(out, contains('<time>2026-09-25T02:47:00.000Z</time>'));

    // 仅 1 个 wpt（无坐标的不输出）
    expect(RegExp('<wpt ').allMatches(out).length, 1);

    // 不内嵌图片二进制：输出长度远小于典型照片体积
    expect(out.length, lessThan(2000));

    // 统计计入拍照次数（含无坐标的）
    expect(out, contains('拍照 2 次'));
  });
}
