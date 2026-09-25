import 'package:flutter/foundation.dart';

/// 轨迹点：一次定位结果。
@immutable
class TrackPoint {
  final int? id;
  final int trackId;
  final DateTime timestamp;

  /// 纬度；无定位结果时为 null（degraded=true）。
  final double? latitude;

  /// 经度；无定位结果时为 null。
  final double? longitude;

  /// 海拔（米）。
  final double? altitude;

  /// 速度（m/s）。
  final double? speed;

  /// 定位精度（米）。
  final double? accuracy;

  /// 方向角（度）。
  final double? bearing;

  /// 降级标记：定位失败/精度过差时为 true。
  final bool degraded;

  const TrackPoint({
    this.id,
    required this.trackId,
    required this.timestamp,
    this.latitude,
    this.longitude,
    this.altitude,
    this.speed,
    this.accuracy,
    this.bearing,
    this.degraded = false,
  });

  bool get hasFix => latitude != null && longitude != null;

  TrackPoint copyWith({int? id}) => TrackPoint(
        id: id ?? this.id,
        trackId: trackId,
        timestamp: timestamp,
        latitude: latitude,
        longitude: longitude,
        altitude: altitude,
        speed: speed,
        accuracy: accuracy,
        bearing: bearing,
        degraded: degraded,
      );

  Map<String, Object?> toRow() => {
        'track_id': trackId,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'latitude': latitude,
        'longitude': longitude,
        'altitude': altitude,
        'speed': speed,
        'accuracy': accuracy,
        'bearing': bearing,
        'degraded': degraded ? 1 : 0,
      };

  static TrackPoint fromRow(Map<String, Object?> row) => TrackPoint(
        id: row['id'] as int?,
        trackId: row['track_id'] as int,
        timestamp: DateTime.fromMillisecondsSinceEpoch(row['timestamp'] as int),
        latitude: row['latitude'] as double?,
        longitude: row['longitude'] as double?,
        altitude: row['altitude'] as double?,
        speed: row['speed'] as double?,
        accuracy: row['accuracy'] as double?,
        bearing: row['bearing'] as double?,
        degraded: (row['degraded'] as int?) == 1,
      );
}
