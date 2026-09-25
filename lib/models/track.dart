import 'package:flutter/foundation.dart';

/// 轨迹（一次行车记录会话）。
@immutable
class Track {
  final int? id;
  final DateTime startTime;
  final DateTime? endTime;

  /// 轨迹点数（冗余字段，随写入更新）。
  final int pointCount;

  /// 事件数（冗余字段，随写入更新）。
  final int eventCount;

  /// 总里程（米，按相邻点大圆距离累加）。
  final double distanceMeters;

  /// 记录来源：manual=手动开始，bluetooth=车机蓝牙自动开始。
  final String source;

  /// 展示名（默认按开始时间生成，如「9月25日 10:41」）。
  final String? name;

  const Track({
    this.id,
    required this.startTime,
    this.endTime,
    this.pointCount = 0,
    this.eventCount = 0,
    this.distanceMeters = 0,
    this.source = 'manual',
    this.name,
  });

  Track copyWith({
    int? id,
    DateTime? startTime,
    DateTime? endTime,
    bool clearEndTime = false,
    int? pointCount,
    int? eventCount,
    double? distanceMeters,
    String? source,
    String? name,
  }) =>
      Track(
        id: id ?? this.id,
        startTime: startTime ?? this.startTime,
        endTime: clearEndTime ? null : (endTime ?? this.endTime),
        pointCount: pointCount ?? this.pointCount,
        eventCount: eventCount ?? this.eventCount,
        distanceMeters: distanceMeters ?? this.distanceMeters,
        source: source ?? this.source,
        name: name ?? this.name,
      );

  Duration? get duration => endTime?.difference(startTime);

  /// 均速（m/s），无有效数据时为 null。
  double? get averageSpeed {
    final d = duration;
    if (d == null || d.inMilliseconds <= 0 || distanceMeters <= 0) return null;
    return distanceMeters / d.inSeconds;
  }

  Map<String, Object?> toRow() => {
        'start_time': startTime.millisecondsSinceEpoch,
        'end_time': endTime?.millisecondsSinceEpoch,
        'point_count': pointCount,
        'event_count': eventCount,
        'distance_meters': distanceMeters,
        'source': source,
        'name': name,
      };

  static Track fromRow(Map<String, Object?> row) => Track(
        id: row['id'] as int?,
        startTime:
            DateTime.fromMillisecondsSinceEpoch(row['start_time'] as int),
        endTime: row['end_time'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row['end_time'] as int),
        pointCount: (row['point_count'] as int?) ?? 0,
        eventCount: (row['event_count'] as int?) ?? 0,
        distanceMeters: (row['distance_meters'] as double?) ?? 0,
        source: (row['source'] as String?) ?? 'manual',
        name: row['name'] as String?,
      );
}
