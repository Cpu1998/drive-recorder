import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:drive_recorder/models/track.dart';
import 'package:drive_recorder/models/track_point.dart';
import 'package:drive_recorder/widgets/track_map_view.dart';

/// 空点集轨迹不创建高德地图（闪退根因的回归测试）：
/// 直接显示可读占位提示，不弹隐私框、不初始化地图 SDK。
void main() {
  testWidgets('无定位点轨迹 → 占位提示，不弹隐私框不建地图', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final track = Track(
      startTime: DateTime(2026, 9, 25, 9, 0),
      name: '空轨迹',
      source: 'manual',
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TrackMapView(track: track, points: const [], events: const []),
      ),
    ));
    await tester.pump();

    expect(find.text('该轨迹没有定位点'), findsOneWidget);
    expect(find.textContaining('高德 Android Key'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing,
        reason: '无地图可初始化，不应弹隐私弹窗');
    expect(tester.takeException(), isNull);
  });

  testWidgets('仅降级点（无坐标）同样走占位提示', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final track = Track(
      startTime: DateTime(2026, 9, 25, 9, 0),
      name: '全程无 GPS',
      source: 'manual',
    );
    final degraded = List.generate(
      3,
      (i) => TrackPoint(
        trackId: 1,
        timestamp: track.startTime.add(Duration(seconds: i * 10)),
        degraded: true, // latitude/longitude 均为 null
      ),
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TrackMapView(track: track, points: degraded, events: const []),
      ),
    ));
    await tester.pump();

    expect(find.text('该轨迹没有定位点'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
