import 'package:flutter/foundation.dart';

/// 驾驶事件类型。
enum DriveEventType {
  /// 手动打点
  manual,

  /// 急刹
  braking,

  /// 碰撞（尖峰）
  collision;

  static DriveEventType fromName(String name) => values.firstWhere(
        (e) => e.name == name,
        orElse: () => DriveEventType.manual,
      );

  String get label => switch (this) {
        manual => '手动打点',
        braking => '急刹',
        collision => '碰撞',
      };
}

/// 驾驶事件：手动打点 / 急刹 / 碰撞。
@immutable
class DriveEvent {
  final int? id;

  /// 关联轨迹的 rowId。
  final int trackId;
  final DateTime timestamp;
  final DriveEventType type;

  /// 事件强度：急刹=负向减速度峰值（m/s²），碰撞=合成加速度峰值（m/s²），手动=null。
  final double? peakIntensity;

  final double? latitude;
  final double? longitude;

  /// 降级标记：手动打点时无定位结果为 true；传感器事件无就近轨迹点坐标时亦为 true。
  final bool degraded;

  /// 关联的最近轨迹点（用于地图上精确定位事件位置），可为 null。
  final int? trackPointId;

  final String? note;

  const DriveEvent({
    this.id,
    required this.trackId,
    required this.timestamp,
    required this.type,
    this.peakIntensity,
    this.latitude,
    this.longitude,
    this.degraded = false,
    this.trackPointId,
    this.note,
  });

  DriveEvent copyWith({
    int? id,
    int? trackId,
    DateTime? timestamp,
    DriveEventType? type,
    double? peakIntensity,
    double? latitude,
    double? longitude,
    bool? degraded,
    int? trackPointId,
    String? note,
  }) =>
      DriveEvent(
        id: id ?? this.id,
        trackId: trackId ?? this.trackId,
        timestamp: timestamp ?? this.timestamp,
        type: type ?? this.type,
        peakIntensity: peakIntensity ?? this.peakIntensity,
        latitude: latitude ?? this.latitude,
        longitude: longitude ?? this.longitude,
        degraded: degraded ?? this.degraded,
        trackPointId: trackPointId ?? this.trackPointId,
        note: note ?? this.note,
      );

  Map<String, Object?> toRow() => {
        'track_id': trackId,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'type': type.name,
        'peak_intensity': peakIntensity,
        'latitude': latitude,
        'longitude': longitude,
        'degraded': degraded ? 1 : 0,
        'track_point_id': trackPointId,
        'note': note,
      };

  static DriveEvent fromRow(Map<String, Object?> row) => DriveEvent(
        id: row['id'] as int?,
        trackId: row['track_id'] as int,
        timestamp: DateTime.fromMillisecondsSinceEpoch(row['timestamp'] as int),
        type: DriveEventType.fromName(row['type'] as String? ?? 'manual'),
        peakIntensity: row['peak_intensity'] as double?,
        latitude: row['latitude'] as double?,
        longitude: row['longitude'] as double?,
        degraded: (row['degraded'] as int?) == 1,
        trackPointId: row['track_point_id'] as int?,
        note: row['note'] as String?,
      );
}
