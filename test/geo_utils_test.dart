import 'package:flutter_test/flutter_test.dart';
import 'package:drive_recorder/utils/geo_utils.dart';

void main() {
  test('境内 WGS-84 → GCJ-02 偏移约 300-600 米（北京）', () {
    // 天安门 WGS-84 ≈ (39.90734, 116.39134)
    const lat = 39.90734, lng = 116.39134;
    final (gLat, gLng) = GeoUtils.wgs84ToGcj02(lat, lng);

    expect(gLat, closeTo(lat, 0.01), reason: '纬度偏移应在合理范围内');
    expect(gLng, closeTo(lng, 0.01), reason: '经度偏移应在合理范围内');

    // 典型偏移量：几百米（0.001-0.006 度）
    final dLatMeters = GeoUtils.distance(lat, lng, gLat, lng);
    final dLngMeters = GeoUtils.distance(lat, lng, lat, gLng);
    expect(dLatMeters + dLngMeters, greaterThan(200),
        reason: '北京区域 WGS/GCJ 偏移应大于 200 米');
    expect(dLatMeters + dLngMeters, lessThan(1200),
        reason: '偏移不应异常巨大');
  });

  test('上海：转换稳定（往返一致性参考值）', () {
    // 上海人民广场 WGS-84 ≈ (31.22935, 121.46227)
    final (gLat, gLng) = GeoUtils.wgs84ToGcj02(31.22935, 121.46227);
    // 已知 GCJ-02 参考值（业界通用实现输出 ≈ 31.22732, 121.46746）
    expect(gLat, closeTo(31.22732, 0.001));
    expect(gLng, closeTo(121.46746, 0.001));
  });

  test('境外坐标原样返回（纽约）', () {
    const lat = 40.7128, lng = -74.0060;
    final (gLat, gLng) = GeoUtils.wgs84ToGcj02(lat, lng);
    expect(gLat, lat);
    expect(gLng, lng);
  });

  test('outOfChina 边界判断', () {
    expect(GeoUtils.outOfChina(39.9, 116.4), isFalse, reason: '北京在境内');
    expect(GeoUtils.outOfChina(31.2, 121.5), isFalse, reason: '上海在境内');
    expect(GeoUtils.outOfChina(35.6, 139.7), isTrue, reason: '东京在境外');
  });
}
