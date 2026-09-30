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

  // ---------------------------------------------------------------------------
  // WGS-84 → GCJ-02（火星坐标）转换
  // 系统定位（GPS/FusedLocationProvider）输出 WGS-84，高德底图是 GCJ-02，
  // 不转换会整体偏移约 300-600 米。算法为业界通用近似，误差 < 1m。
  // ---------------------------------------------------------------------------

  static const double _a = 6378245.0;
  static const double _ee = 0.00669342162296594323;

  /// 是否在中国版图外（境外不做偏移，直接原样返回）。
  static bool outOfChina(double lat, double lng) =>
      lng < 72.004 || lng > 137.8347 || lat < 0.8293 || lat > 55.8271;

  static double _transformLat(double x, double y) {
    var ret = -100.0 +
        2.0 * x +
        3.0 * y +
        0.2 * y * y +
        0.1 * x * y +
        0.2 * math.sqrt(x.abs()) +
        (20.0 * math.sin(6.0 * x * math.pi) +
                20.0 * math.sin(2.0 * x * math.pi)) *
            2.0 /
            3.0 +
        (20.0 * math.sin(y * math.pi) + 40.0 * math.sin(y / 3.0 * math.pi)) *
            2.0 /
            3.0 +
        (160.0 * math.sin(y / 12.0 * math.pi) +
                320 * math.sin(y * math.pi / 30.0)) *
            2.0 /
            3.0;
    return ret;
  }

  static double _transformLng(double x, double y) {
    var ret = 300.0 +
        x +
        2.0 * y +
        0.1 * x * x +
        0.1 * x * y +
        0.1 * math.sqrt(x.abs()) +
        (20.0 * math.sin(6.0 * x * math.pi) +
                20.0 * math.sin(2.0 * x * math.pi)) *
            2.0 /
            3.0 +
        (20.0 * math.sin(x * math.pi) + 40.0 * math.sin(x / 3.0 * math.pi)) *
            2.0 /
            3.0 +
        (150.0 * math.sin(x / 12.0 * math.pi) +
                300.0 * math.sin(x / 30.0 * math.pi)) *
            2.0 /
            3.0;
    return ret;
  }

  /// WGS-84 → GCJ-02。境外坐标原样返回。
  static (double, double) wgs84ToGcj02(double wgsLat, double wgsLng) {
    if (outOfChina(wgsLat, wgsLng)) return (wgsLat, wgsLng);
    var dLat = _transformLat(wgsLng - 105.0, wgsLat - 35.0);
    var dLng = _transformLng(wgsLng - 105.0, wgsLat - 35.0);
    final radLat = wgsLat / 180.0 * math.pi;
    var magic = math.sin(radLat);
    magic = 1 - _ee * magic * magic;
    final sqrtMagic = math.sqrt(magic);
    dLat = (dLat * 180.0) / ((_a * (1 - _ee)) / (magic * sqrtMagic) * math.pi);
    dLng = (dLng * 180.0) / (_a / sqrtMagic * math.cos(radLat) * math.pi);
    return (wgsLat + dLat, wgsLng + dLng);
  }
}
