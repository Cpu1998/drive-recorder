# 本地补丁说明

## amap_map-1.0.15 Hybrid Composition 补丁（2026-09-25）

**问题**：AndroidView（纹理/TLHC 模式）在部分设备上创建地图视图时抛
`PlatformException NullPointerException`（TextureAndroidViewController._sendCreateMessage
→ 引擎 PlatformViewsController NPE），地图不显示。Flutter 3.35 + 关闭
Impeller（EnableImpeller=false）均无效。

**补丁**：`lib/src/core/method_channel_amap_map.dart` 的 `buildViewWithCreationParams`
由 `AndroidView` 改为 `PlatformViewLink` + `initSurfaceAndroidView`（Hybrid
Composition），绕开纹理平台视图路径。

**应用方式**（`flutter pub cache repair` 后需重打）：

```bash
cp tools/patches/amap_map-1.0.15_method_channel_amap_map.dart.txt \
   ~/.pub-cache/hosted/pub.flutter-io.cn/amap_map-1.0.15/lib/src/core/method_channel_amap_map.dart
```

**注意**：amap_flutter_location-3.0.0 也有本地补丁（隐私合规），位置
`~/.pub-cache/hosted/pub.flutter-io.cn/amap_flutter_location-3.0.0/`，
详见仓库早期提交记录。
