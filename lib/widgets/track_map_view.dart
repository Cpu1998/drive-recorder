import 'package:amap_map/amap_map.dart' as amap;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x_amap_base/x_amap_base.dart';

import '../models/drive_event.dart';
import '../models/track.dart';
import '../models/track_point.dart';
import '../utils/constants.dart';

/// 高德隐私合规门：未同意前不初始化地图 SDK（同 flutter_mapapp 做法）。
Future<bool> _ensurePrivacyAgreed(BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(PrefKeys.amapPrivacyAgreed) == true) return true;
  if (!context.mounted) return false;
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('高德地图服务提示'),
      content: const Text(
        '地图功能由高德开放平台提供。为了正常使用地图服务，'
        '我们需要在您使用地图时处理设备信息与位置相关信息。'
        '详细内容请查阅《高德地图服务协议》与《高德开放平台隐私权政策》。\n\n'
        '是否同意并继续使用地图功能？',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('不同意'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('同意'),
        ),
      ],
    ),
  );
  if (result == true) {
    await prefs.setBool(PrefKeys.amapPrivacyAgreed, true);
  }
  return result == true;
}

/// 轨迹地图：polyline 画轨迹 + 事件 marker。
class TrackMapView extends StatefulWidget {
  final Track track;
  final List<TrackPoint> points;
  final List<DriveEvent> events;

  const TrackMapView({
    super.key,
    required this.track,
    required this.points,
    required this.events,
  });

  @override
  State<TrackMapView> createState() => _TrackMapViewState();
}

class _TrackMapViewState extends State<TrackMapView> {
  bool _privacyAgreed = false;
  bool _privacyChecked = false;

  @override
  void initState() {
    super.initState();
    _checkPrivacy();
  }

  Future<void> _checkPrivacy() async {
    final prefs = await SharedPreferences.getInstance();
    final agreed = prefs.getBool(PrefKeys.amapPrivacyAgreed) == true;
    if (!mounted) return;
    if (agreed) {
      setState(() {
        _privacyAgreed = true;
        _privacyChecked = true;
      });
    } else {
      // 等首帧后弹窗
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final ok = await _ensurePrivacyAgreed(context);
        if (!mounted) return;
        setState(() {
          _privacyAgreed = ok;
          _privacyChecked = true;
        });
      });
    }
  }

  List<amap.Marker> get _markers {
    final markers = <amap.Marker>[];
    for (final e in widget.events) {
      if (e.latitude == null || e.longitude == null) continue;
      final (hue, label) = switch (e.type) {
        DriveEventType.manual =>
          (amap.BitmapDescriptor.hueAzure, '手动打点'),
        DriveEventType.braking =>
          (amap.BitmapDescriptor.hueOrange, '急刹'),
        DriveEventType.collision =>
          (amap.BitmapDescriptor.hueRed, '碰撞'),
        DriveEventType.photo =>
          (amap.BitmapDescriptor.hueRose, '📷 拍照点'),
      };
      final marker = amap.Marker(
        position: LatLng(e.latitude!, e.longitude!),
        icon: amap.BitmapDescriptor.defaultMarkerWithHue(hue),
        infoWindow: amap.InfoWindow(
          title: label,
          snippet: e.peakIntensity != null
              ? '峰值 ${e.peakIntensity!.toStringAsFixed(1)} m/s²'
              : null,
        ),
      );
      marker.setIdForCopy('event_${e.id}');
      markers.add(marker);
    }
    return markers;
  }

  amap.Polyline get _polyline {
    final located = widget.points.where((p) => p.hasFix).toList();
    final p = amap.Polyline(
      points: [
        for (final pt in located) LatLng(pt.latitude!, pt.longitude!)
      ],
      width: 6,
      color: const Color(0xFF1A73E9),
    );
    p.setIdForCopy('track_${widget.track.id}');
    return p;
  }

  amap.CameraPosition get _initialCamera {
    final located = widget.points.where((p) => p.hasFix).toList();
    if (located.isEmpty) {
      return const amap.CameraPosition(
          target: LatLng(39.90923, 116.397428), zoom: 12);
    }
    var minLat = located.first.latitude!, maxLat = minLat;
    var minLon = located.first.longitude!, maxLon = minLon;
    for (final p in located) {
      minLat = p.latitude! < minLat ? p.latitude! : minLat;
      maxLat = p.latitude! > maxLat ? p.latitude! : maxLat;
      minLon = p.longitude! < minLon ? p.longitude! : minLon;
      maxLon = p.longitude! > maxLon ? p.longitude! : maxLon;
    }
    return amap.CameraPosition(
      target: LatLng((minLat + maxLat) / 2, (minLon + maxLon) / 2),
      zoom: 13,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_privacyChecked) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_privacyAgreed) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.map_outlined,
                size: 40, color: Theme.of(context).disabledColor),
            const SizedBox(height: 8),
            const Text('未同意高德地图服务条款，地图功能不可用'),
            TextButton(
              onPressed: () async {
                final ok = await _ensurePrivacyAgreed(context);
                if (!mounted || !ok) return;
                setState(() => _privacyAgreed = true);
              },
              child: const Text('重新查看'),
            ),
          ],
        ),
      );
    }

    // 按官方示例要求：在 AMapWidget 创建前完成初始化与合规声明
    // （Android Key 走 AndroidManifest meta-data，这里不传 apiKey）
    amap.AMapInitializer.init(context);
    amap.AMapInitializer.updatePrivacyAgree(
      const AMapPrivacyStatement(hasContains: true, hasShow: true, hasAgree: true),
    );

    return amap.AMapWidget(
      initialCameraPosition: _initialCamera,
      markers: _markers.toSet(),
      polylines: {_polyline},
    );
  }
}
