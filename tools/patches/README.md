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

## amap_map-1.0.15 Android 诊断补丁（2026-09-25，v1.3.4）

**问题**：地图不显示，日志只有无信息量的 NPE。反混淆（mapping.txt）定位：
`o0.d.j()` = `AMapPlatformView.getView()`，异常源头在插件原生侧被两层 try-catch
吞掉（`LogUtil.e` 仅 debugMode 输出；`AMapOptionsBuilder.build` 失败时
`return null`），真凶不可见。

**补丁**：
- `AMapPlatformView.java` 构造失败改为 rethrow RuntimeException；getView() 加
  null 检查抛 IllegalStateException
- `AMapOptionsBuilder.java` build 失败 rethrow 而非 return null
- 效果：原始异常会作为 PlatformException（含完整 Java 堆栈与 cause 链）到达
  Dart 侧，被 AppLogger 全局处理器记录进运行日志

**应用方式**：
```bash
cp tools/patches/AMapPlatformView.java.txt ~/.pub-cache/hosted/pub.flutter-io.cn/amap_map-1.0.15/android/src/main/java/com/amap/flutter/map/AMapPlatformView.java
cp tools/patches/AMapOptionsBuilder.java.txt ~/.pub-cache/hosted/pub.flutter-io.cn/amap_map-1.0.15/android/src/main/java/com/amap/flutter/map/AMapOptionsBuilder.java
```
