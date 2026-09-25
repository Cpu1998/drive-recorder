import 'dart:math' as math;

/// 地理计算工具。
class GeoUtils {
  /// 地球半径（米）。
  static const double earthRadius = 6371000;

  /// 两点大圆距离（米），Haversine 公式。
  static double distance(double lat1, double lon1, double lat2, double lon2) {
    final phi1 = _rad(lat1), phi2 = _rad(lat2);
    final dPhi = _rad(lat2 - lat1), dLambda = _rad(lon2 - lon1);
    final a = math.sin(dPhi / 2) * math.sin(dPhi / 2) +
        math.cos(phi1) * math.cos(phi2) *
            math.sin(dLambda / 2) * math.sin(dLambda / 2);
    return 2 * earthRadius * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  static double _rad(double deg) => deg * math.pi / 180;
}
