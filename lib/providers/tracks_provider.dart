import 'package:flutter/foundation.dart';

import '../models/drive_event.dart';
import '../models/track.dart';
import '../models/track_point.dart';
import '../services/database/app_database.dart';
import '../services/photo_service.dart';
import '../services/sync/sync_service.dart';

/// 历史轨迹列表 + 详情数据（含云同步钩子）。
class TracksProvider extends ChangeNotifier {
  final AppDatabase db;
  final SyncService? sync;
  final PhotoService photos;

  TracksProvider(this.db, {this.sync, PhotoService? photoService})
      : photos = photoService ?? PhotoService();

  List<Track> _tracks = [];
  List<Track> get tracks => _tracks;

  Future<void> refresh() async {
    _tracks = await db.listTracks();
    notifyListeners();
  }

  Future<Track?> track(int id) => db.getTrack(id);

  Future<List<TrackPoint>> points(int trackId) =>
      db.pointsForTrack(trackId);

  Future<List<DriveEvent>> events(int trackId) => db.eventsForTrack(trackId);

  Future<void> delete(Track track) async {
    await db.deleteTrack(track.id!);
    await photos.deleteTrackPhotos(track.id!);
    try {
      await sync?.deleteTrack(track.id!);
    } on SyncNotConfiguredException {
      // 同步未配置时静默跳过
    }
    await refresh();
  }

  /// 轨迹结束后触发上传（同步开启时）。
  Future<void> maybeUpload(Track track) async {
    if (sync == null) return;
    try {
      await sync!.uploadTrack(
        track,
        await db.pointsForTrack(track.id!),
        await db.eventsForTrack(track.id!),
      );
    } on SyncNotConfiguredException {
      // 忽略
    }
  }
}
