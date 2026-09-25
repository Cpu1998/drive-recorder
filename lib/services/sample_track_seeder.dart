import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/drive_event.dart';
import '../models/track.dart';
import '../models/track_point.dart';
import '../utils/geo_utils.dart';
import 'database/app_database.dart';

/// 首次启动时种入一条示例轨迹（仅一次，可删除）。
///
/// 目的：无高德 Key 时定位不可用，新装用户录不出有效轨迹；
/// 提供一条带定位点 + 事件 + 照片的完整示例，让详情页/GPX 导出
/// 等能力可以直接体验验证。
///
/// - 仅当本地没有任何轨迹且未种过（[prefKey] 标记）时种入；
/// - 用户删除示例后不会再次种入。
class SampleTrackSeeder {
  static const String prefKey = 'sample_track_seeded';
  static const String assetKey = 'assets/sample_photo.jpg';

  final AppDatabase db;
  final SharedPreferences prefs;

  /// 资产加载器（单测注入桩）。
  final Future<Uint8List> Function(String) assetLoader;

  /// 照片落盘目录（单测注入临时目录）。
  final Future<Directory> Function() docsDirResolver;

  SampleTrackSeeder(
    this.db,
    this.prefs, {
    Future<Uint8List> Function(String)? assetLoader,
    Future<Directory> Function()? docsDirResolver,
  })  : assetLoader = assetLoader ?? ((k) => rootBundle.load(k).then((b) => b.buffer.asUint8List())),
        docsDirResolver = docsDirResolver ?? getApplicationDocumentsDirectory;

  /// 种入示例轨迹；返回是否实际种入（调用方据此决定是否刷新列表）。
  Future<bool> seedIfNeeded() async {
    if (prefs.getBool(prefKey) == true) return false;
    // 无论是否种入都打标：只在“第一次”尝试种
    await prefs.setBool(prefKey, true);
    if (await db.listTracks().then((l) => l.isNotEmpty)) return false;

    final start = DateTime.now()
        .subtract(const Duration(hours: 3))
        .add(Duration(minutes: -DateTime.now().minute % 5)); // 对齐到 5 分钟
    var track = await db.insertTrack(Track(
      startTime: start,
      name: '示例轨迹（可删除）',
      source: 'manual',
    ));
    final points = _buildRoute(track.id!, start);
    final distance = _routeDistance(points);
    await db.insertPoints(points, distance);
    await db.insertEvent(DriveEvent(
      trackId: track.id!,
      timestamp: points[12].timestamp,
      type: DriveEventType.manual,
      latitude: points[12].latitude,
      longitude: points[12].longitude,
      note: '经过路口，手动打点',
    ));
    await db.insertEvent(DriveEvent(
      trackId: track.id!,
      timestamp: points[24].timestamp,
      type: DriveEventType.braking,
      latitude: points[24].latitude,
      longitude: points[24].longitude,
      peakIntensity: -4.6,
    ));
    final photoPath = await _persistPhoto(track.id!, points[31]);
    await db.insertEvent(DriveEvent(
      trackId: track.id!,
      timestamp: points[31].timestamp,
      type: DriveEventType.photo,
      latitude: points[31].latitude,
      longitude: points[31].longitude,
      photoPath: photoPath,
    ));
    // insertPoints/insertEvent 会在库内自动累计统计；重取最新行后再回填
    // endTime，避免用旧内存对象把统计整行覆盖回 0（updateTrack 是全量写）。
    final fresh = (await db.getTrack(track.id!))!;
    await db.updateTrack(
        fresh.copyWith(endTime: points.last.timestamp));
    return true;
  }

  /// 望京一带环线：手工路点 → 每段插值并带轻微抖动与合理速度。
  List<TrackPoint> _buildRoute(int trackId, DateTime start) {
    const waypoints = [
      (39.99612, 116.46206), // 望京西
      (39.99520, 116.46880),
      (39.99310, 116.47420), // 阜通东大街
      (39.99020, 116.47510),
      (39.98805, 116.47120), // 望京南
      (39.98760, 116.46550),
      (39.98860, 116.46010),
      (39.99130, 116.45860), // 广顺北大街
      (39.99410, 116.45940),
      (39.99590, 116.46080), // 回到起点附近
    ];
    final rnd = math.Random(7);
    final pts = <TrackPoint>[];
    var seq = 0;
    DateTime t = start;
    for (var s = 0; s < waypoints.length - 1; s++) {
      final (aLat, aLon) = waypoints[s];
      final (bLat, bLon) = waypoints[s + 1];
      final v = 6.5 + rnd.nextDouble() * 6; // 6.5~12.5 m/s ≈ 23~45 km/h
      final steps = 4;
      for (var i = (s == 0 ? 0 : 1); i <= steps; i++) {
        final f = i / steps;
        final jitter = (rnd.nextDouble() - 0.5) * 0.00008;
        t = start.add(Duration(seconds: seq * 9));
        // 全局第 23~25 点附近模拟急刹减速（对应 braking 事件点 24）
        final nearBrake = seq >= 23 && seq <= 25;
        pts.add(TrackPoint(
          trackId: trackId,
          timestamp: t,
          latitude: aLat + (bLat - aLat) * f + jitter,
          longitude: aLon + (bLon - aLon) * f + jitter * 0.6,
          altitude: 38 + rnd.nextDouble() * 6,
          speed: nearBrake ? 2.1 : v + rnd.nextDouble() * 1.5,
          accuracy: 4 + rnd.nextDouble() * 4,
          bearing: _bearing(aLat, aLon, bLat, bLon),
        ));
        seq++;
      }
    }
    return pts;
  }

  double _routeDistance(List<TrackPoint> pts) {
    var d = 0.0;
    for (var i = 1; i < pts.length; i++) {
      d += GeoUtils.distance(pts[i - 1].latitude!, pts[i - 1].longitude!,
          pts[i].latitude!, pts[i].longitude!);
    }
    return d;
  }

  double _bearing(double aLat, double aLon, double bLat, double bLon) {
    const rad = math.pi / 180;
    final dy = (bLat - aLat) * rad;
    final dx = (bLon - aLon) * rad * math.cos(aLat * rad);
    return (math.atan2(dx, dy) / rad + 360) % 360;
  }

  Future<String> _persistPhoto(int trackId, TrackPoint at) async {
    final bytes = await assetLoader(assetKey);
    final docs = await docsDirResolver();
    final dir = Directory(p.join(docs.path, 'photos', '$trackId'));
    await dir.create(recursive: true);
    final dest = p.join(
        dir.path, '${at.timestamp.millisecondsSinceEpoch}.jpg');
    await File(dest).writeAsBytes(bytes, flush: true);
    return dest;
  }
}
