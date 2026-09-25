import '../../models/drive_event.dart';
import '../../models/track.dart';
import '../../models/track_point.dart';

/// 云端同步抽象接口（本地优先：SQLite 永远是 source of truth，云端为副本）。
abstract class SyncService {
  /// Firebase 是否已配置（google-services.json / firebase_options.dart 是否就绪）。
  Future<bool> isConfigured();

  /// 延迟初始化（用户首次开启同步时才调用）。
  /// 未配置时抛 [SyncNotConfiguredException]。
  Future<void> initialize();

  /// 上传一条轨迹（含轨迹点与事件）。
  Future<void> uploadTrack(
      Track track, List<TrackPoint> points, List<DriveEvent> events);

  /// 删除远端轨迹。
  Future<void> deleteTrack(int trackId);

  /// 最近一次错误信息（用于设置页展示），null 表示正常。
  String? get lastError;
}

class SyncNotConfiguredException implements Exception {
  @override
  String toString() => 'Firebase 未配置：请先完成 README 中的接入步骤';
}
