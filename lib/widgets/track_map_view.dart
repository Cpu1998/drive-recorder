import 'dart:async';

import 'package:amap_map/amap_map.dart' as amap;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:x_amap_base/x_amap_base.dart';

import '../models/drive_event.dart';
import '../models/track.dart';
import '../models/track_point.dart';
import '../services/app_logger.dart';
import '../services/crash_sentinel.dart';
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

  /// 高德 Android Key（设置页配置，运行时注入）；空则走 manifest 内置。
  final String? amapKey;

  const TrackMapView({
    super.key,
    required this.track,
    required this.points,
    required this.events,
    this.amapKey,
  });

  @override
  State<TrackMapView> createState() => _TrackMapViewState();
}

class _TrackMapViewState extends State<TrackMapView> {
  bool _privacyAgreed = false;
  bool _mapReady = false;
  bool _privacyChecked = false;
  Timer? _overlaysSettledTimer;

  @override
  void initState() {
    super.initState();
    _checkPrivacy();
  }

  @override
  void dispose() {
    _overlaysSettledTimer?.cancel();
    // 用户主动离开地图页：清除哨兵，避免下次启动误报
    CrashSentinel.clear();
    super.dispose();
  }

  Future<void> _checkPrivacy() async {
    final prefs = await SharedPreferences.getInstance();
    final agreed = prefs.getBool(PrefKeys.amapPrivacyAgreed) == true;
    AppLogger.i('map', agreed ? '高德隐私：已同意' : '高德隐私：待用户确认');
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
    // 关键防御：没有任何定位点的轨迹不创建地图（空点集 polyline 会导致
    // 高德原生层崩溃，即“点开轨迹闪退”的根因），直接给用户可读的提示。
    final located = widget.points.where((p) => p.hasFix).toList();
    if (located.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.location_searching_outlined,
                  size: 40, color: Theme.of(context).disabledColor),
              const SizedBox(height: 8),
              const Text('该轨迹没有定位点'),
              const SizedBox(height: 4),
              Text(
                '可能原因：未配置高德 Android Key（定位服务不可用），'
                '或全程无 GPS 信号。\n配置方法见 README「高德 Key 配置」。',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12, color: Theme.of(context).disabledColor),
              ),
            ],
          ),
        ),
      );
    }
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
    // 优先用设置页配置的 Key（运行时注入），否则走 manifest meta-data
    final key = widget.amapKey ?? '';
    AppLogger.i('map', '创建地图：${key.isEmpty ? '内置 Key（manifest）' : '设置页 Key ${AppLogger.maskKey(key)}'}，'
        '定位点 ${widget.points.where((p) => p.hasFix).length} 个，事件 ${widget.events.length} 个');
    amap.AMapInitializer.init(
      context,
      apiKey: key.isEmpty
          ? null
          : AMapApiKey(androidKey: key, iosKey: ''),
    );
    amap.AMapInitializer.updatePrivacyAgree(
      const AMapPrivacyStatement(hasContains: true, hasShow: true, hasAgree: true),
    );

    // 修复：标记与轨迹线在地图原生引擎就绪前创建会触发
    // native 崩溃/NPE（amap_map 经 creationParams 在 factory.create
    // 阶段（引擎构造后毫秒级）同步处理 markersToAdd/polylinesToAdd，
    // 此时引擎未就绪）。改为 onMapCreated 之后再挂载
    // （分别走 markers#update / polylines#update 通道）。
    final markers = _mapReady ? _markers.toSet() : const <amap.Marker>{};
    final polylines = _mapReady
        ? {_polyline}
        : const <amap.Polyline>{};
    CrashSentinel.mark('map_build（创建地图原生视图）');
    return amap.AMapWidget(
      initialCameraPosition: _initialCamera,
      markers: markers,
      polylines: polylines,
      onMapCreated: (_) {
        AppLogger.i('map', '地图原生视图已创建（onMapCreated 回调到达）');
        CrashSentinel.mark('map_overlays（挂载轨迹线与事件标记）');
        setState(() => _mapReady = true);
        AppLogger.i('map', '地图就绪，挂载轨迹线与 ${_markers.length} 个事件标记'
            '（走 update 通道，避开引擎未就绪窗口）');
        // 覆盖物挂载后存活 2 秒即视为安全过关，清除哨兵
        _overlaysSettledTimer?.cancel();
        _overlaysSettledTimer = Timer(const Duration(seconds: 2), () {
          CrashSentinel.clear();
          AppLogger.i('map', '轨迹线与标记挂载完成，地图阶段结束');
        });
      },
    );
  }
}
