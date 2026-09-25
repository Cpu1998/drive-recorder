import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';

import '../../firebase_options.dart';
import '../../models/drive_event.dart';
import '../../models/track.dart';
import '../../models/track_point.dart';
import 'sync_service.dart';

/// Firestore 实现的云同步。
///
/// 数据布局：
/// - `tracks/{trackId}`：轨迹元数据（含 pointCount/eventCount/distance…）
/// - `tracks/{trackId}/points/{i}`：轨迹点（分 500 点一批写入子集合）
/// - `tracks/{trackId}/events/{eventId}`：事件
///
/// 设计要点：
/// - **本地优先**：所有读写先进 SQLite，云端失败只记录 lastError，不阻塞本地；
/// - **延迟初始化**：Firebase.initializeApp 只在用户开启同步且配置存在时执行，
///   未配置（使用占位 firebase_options.dart 或未放 google-services.json）时
///   App 其他功能完全不受影响。
class FirestoreSyncServiceImpl implements SyncService {
  FirebaseFirestore? _firestore;

  String? _lastError;

  @override
  String? get lastError => _lastError;

  @override
  Future<bool> isConfigured() async {
    try {
      // 占位 stub 读取即抛 UnsupportedError；真实配置则正常返回
      final options = DefaultFirebaseOptions.currentPlatform;
      return options.apiKey.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> initialize() async {
    if (_firestore != null) return;
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        );
      }
      _firestore = FirebaseFirestore.instance;
      _lastError = null;
    } catch (e) {
      _lastError = 'Firebase 初始化失败：$e';
      throw SyncNotConfiguredException();
    }
  }

  @override
  Future<void> uploadTrack(
      Track track, List<TrackPoint> points, List<DriveEvent> events) async {
    await _runGuarded(() async {
      final fs = _requireFirestore();
      final ref = fs.collection('tracks').doc('${track.id}');
      await ref.set({
        'start_time': track.startTime.millisecondsSinceEpoch,
        'end_time': track.endTime?.millisecondsSinceEpoch,
        'point_count': points.length,
        'event_count': events.length,
        'distance_meters': track.distanceMeters,
        'source': track.source,
        'name': track.name,
        'uploaded_at': FieldValue.serverTimestamp(),
      });

      // 轨迹点分批（每批 500，Firestore 单批上限）
      const batch = 500;
      for (var i = 0; i < points.length; i += batch) {
        final chunk = points.skip(i).take(batch);
        final writer = fs.batch();
        for (final p in chunk) {
          writer.set(
            ref.collection('points').doc('${p.id ?? i}'),
            {
              'timestamp': p.timestamp.millisecondsSinceEpoch,
              'lat': p.latitude,
              'lon': p.longitude,
              'alt': p.altitude,
              'speed': p.speed,
              'bearing': p.bearing,
              'degraded': p.degraded,
            },
          );
        }
        await writer.commit();
      }

      if (events.isNotEmpty) {
        final writer = fs.batch();
        for (final e in events) {
          writer.set(
            ref.collection('events').doc('${e.id}'),
            {
              'timestamp': e.timestamp.millisecondsSinceEpoch,
              'type': e.type.name,
              'peak_intensity': e.peakIntensity,
              'lat': e.latitude,
              'lon': e.longitude,
              'degraded': e.degraded,
              'note': e.note,
            },
          );
        }
        await writer.commit();
      }
    });
  }

  @override
  Future<void> deleteTrack(int trackId) async {
    await _runGuarded(() async {
      final fs = _requireFirestore();
      final ref = fs.collection('tracks').doc('$trackId');
      final subs = [
        await ref.collection('points').get(),
        await ref.collection('events').get(),
      ];
      final writer = fs.batch();
      for (final snap in subs) {
        for (final doc in snap.docs) {
          writer.delete(doc.reference);
        }
      }
      writer.delete(ref);
      await writer.commit();
    });
  }

  // ---------------------------------------------------------------------------

  FirebaseFirestore _requireFirestore() {
    final fs = _firestore;
    if (fs == null) {
      throw StateError('SyncService 未初始化：请先调用 initialize()');
    }
    return fs;
  }

  Future<void> _runGuarded(Future<void> Function() action) async {
    try {
      await action();
      _lastError = null;
    } catch (e) {
      _lastError = '云端同步失败：$e';
      // 本地优先：不上抛，不打断本地功能
    }
  }
}
