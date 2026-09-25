/// 展示格式化工具。
library;

/// 时长 → "1:23:45" / "12:34" / "45s"。
String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  if (h > 0) {
    return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  if (m > 0) {
    return '$m:${s.toString().padLeft(2, '0')}';
  }
  return '${s}s';
}

/// 米 → "12.3 km" / "856 m"。
String formatDistance(double meters) {
  if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(1)} km';
  return '${meters.round()} m';
}

/// m/s → "58 km/h"。
String formatSpeed(double? mps) {
  if (mps == null) return '-- km/h';
  return '${(mps * 3.6).round()} km/h';
}

/// m/s² 强度 → "-4.2 m/s²"。
String formatIntensity(double? value) =>
    value == null ? '' : '${value.toStringAsFixed(1)} m/s²';

/// 默认轨迹名："9月25日 10:41"。
String defaultTrackName(DateTime start) {
  final m = start.month, d = start.day;
  final hh = start.hour.toString().padLeft(2, '0');
  final mm = start.minute.toString().padLeft(2, '0');
  return '$m月$d日 $hh:$mm';
}

/// 时刻 → "14:05:32"（照片/事件卡片用）。
String formatClock(DateTime t) {
  final hh = t.hour.toString().padLeft(2, '0');
  final mm = t.minute.toString().padLeft(2, '0');
  final ss = t.second.toString().padLeft(2, '0');
  return '$hh:$mm:$ss';
}
