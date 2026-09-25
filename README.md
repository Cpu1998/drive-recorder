# drive_recorder 行车轨迹记录

Flutter 行车轨迹记录 App（Android 为主线，iOS 已留好配置与说明）。

- 高德地图 SDK 渲染（`amap_map`）+ 高德定位 SDK 后台连续定位
- 手动事件打点 / 拍照事件（📷 原生侧压缩长边≤1920·q85）/ 急刹·碰撞自动识别（加速度传感器 50Hz）
- 蓝牙车机自动开始/停止记录（经典蓝牙，30s 断开宽限）
- SQLite 本地存储（tracks / track_points / events），本地优先
- GPX 1.1 导出与分享
- Firebase/Firestore 云同步（默认关闭，可开关的抽象层）

---

## 1. 项目结构

```
lib/
├── main.dart                     # 入口：初始化设置/数据库/权限引导，装配 Provider
├── app.dart                      # MaterialApp + 底部导航（记录/历史/详情）
├── firebase_options.dart         # flutterfire configure 生成的占位（未配置时同步开关被拒绝）
├── models/
│   ├── track.dart                # 轨迹（会话）
│   ├── track_point.dart          # 轨迹点
│   └── drive_event.dart          # 事件（manual / braking / collision）
├── services/
│   ├── database/app_database.dart# sqflite DAO + 建表 + 迁移骨架（dbVersion=1）
│   ├── location_service.dart     # amap_flutter_location 自适应频率（行驶 2s / 静止 30s）
│   ├── sensor_service.dart       # sensors_plus 50Hz，仅记录中采集
│   ├── driving_event_detector.dart # 急刹/碰撞算法 + 10s 去抖合并
│   ├── bluetooth_car_service.dart  # 车机检测（平台通道列经典蓝牙 + FBP 兜底）
│   ├── foreground_service.dart   # Android 前台服务 method channel
│   ├── gpx_service.dart          # GPX 1.1 生成（trkpt + 事件 wpt）
│   ├── permission_service.dart   # 定位/后台定位/蓝牙/通知权限
│   ├── settings_service.dart     # SharedPreferences 持久化
│   └── sync/
│       ├── sync_service.dart     # 抽象接口（可换实现）
│       └── firestore_sync_service_impl.dart
├── providers/                    # provider 状态管理
│   ├── recording_provider.dart   # 记录状态机（核心）
│   ├── tracks_provider.dart
│   ├── settings_provider.dart
│   └── bluetooth_state_provider.dart
├── screens/
│   ├── record_screen.dart        # 状态卡 + 大号手动事件按钮 + 开始/停止
│   ├── history_screen.dart       # 轨迹列表
│   ├── detail_screen.dart        # 地图轨迹 + 事件 marker + 导出/分享
│   └── settings_screen.dart      # 阈值滑块 / 车机绑定 / 同步开关
├── widgets/track_map_view.dart   # 高德地图封装（隐私同意后渲染）
└── utils/                        # 常量 / 格式化 / 地理计算

android/app/src/main/kotlin/com/zhangkeyou/drive_recorder/
├── MainActivity.kt              # drive_recorder/foreground + drive_recorder/bluetooth 通道
└── ForegroundService.kt         # location 类型前台服务 + WakeLock
```

## 2. 高德 Key 配置（必做）

Android 包名：`com.zhangkeyou.drive_recorder`。

1. 到 [高德开放平台](https://console.amap.com/dev/key/app) 创建应用，添加 **Android** Key：
   - 发布版 SHA1：`keytool -list -v -keystore <你的签名文件>` 取
   - 调试版 SHA1：`keytool -list -v -keystore ~/.android/debug.keystore`（口令 android）
2. 把 Key 填入 `android/app/src/main/AndroidManifest.xml`：

```xml
<meta-data
    android:name="com.amap.api.v2.androidkey"
    android:value="YOUR_AMAP_ANDROID_KEY" />   <!-- 替换为你的 Key -->
```

3. iOS：在 [高德控制台](https://console.amap.com) 添加 **iOS** Key（Bundle ID 对应），填入
   `ios/Runner/Info.plist` 的 `com.amap.api.ioskey`。

> 不配置 Key 也能编译运行，但地图与定位不工作（SDK 会报 INVALID_USER_KEY）。
> 首次启动需要同意高德隐私政策（App 内弹窗，同意后才会初始化 SDK）。

## 3. Firebase 接入步骤（可选，默认关闭）

项目在**不接入 Firebase** 时也能编译运行——`lib/firebase_options.dart` 是占位实现，
同步开关打开时会提示「未配置 Firebase」并回弹。

1. 安装 FlutterFire CLI：`dart pub global activate flutterfire_cli`
2. `flutterfire configure`（选择 Firebase 项目与 Android/iOS 平台），
   会自动生成真实的 `lib/firebase_options.dart`
3. Android 需要 `google-services.json` 放入 `android/app/`，并在
   `android/build.gradle.kts` / `android/app/build.gradle.kts` 应用 google-services 插件
   （本项目默认未应用，不影响无 Firebase 构建）
4. Firestore 规则：App 读写 `users/{uid}/tracks/{trackId}` 及其子集合
   `points`、`events`（见 `firestore_sync_service_impl.dart`）
5. App 设置页打开「同步轨迹到 Firestore」→ 首次会请求初始化，
   之后每条轨迹在停止记录后自动上传

## 4. 阈值调参指引（设置页滑块，即时生效）

| 参数 | 默认 | 说明 |
|------|------|------|
| 急刹减速度阈值 | -3 m/s² | GPS 速度差分为主判据（更准），无速度时回退到 EMA 前行轴投影。持续 ≥500ms 才触发 |
| 碰撞加速度阈值 | 60 m/s² | user_accelerometer 合成加速度尖峰，80ms 窗口内取峰值 |

- **误报多（颠簸路被记为急刹）**：把急刹阈值调到 -3.5 ~ -4
- **漏报（轻刹没记录）**：调到 -2.5（注意红灯缓刹也会触发）
- **碰撞**：日常急刹约 8~15 m/s²、过减速带可到 20~30 m/s²，
  真实碰撞 >60 m/s²；若常走烂路误报，调到 80
- 同类事件 10s 内只记一条（去抖合并），峰值取绝对值更大者
- 阈值存于 SharedPreferences，记录开始时重建检测器立即生效

## 5. 权限与后台限制说明

### Android
- 定位：前台 / 后台 (ACCESS_BACKGROUND_LOCATION) / 前台服务 (FOREGROUND_SERVICE_LOCATION)
- 蓝牙：API 31+ 需要 BLUETOOTH_CONNECT/BLUETOOTH_SCAN（运行时请求）
- 通知：POST_NOTIFICATIONS（API 33+，前台服务常驻通知）
- 部分国产 ROM（小米/华为等）需手动允许「后台弹出/自启动/无限制省电」，
  否则息屏后定位可能被杀

### iOS 蓝牙检测限制（重要）
- iOS 13+ **不再允许查询已连接的配件列表**（`retrieveConnectedPeripherals`
  只返回通过本 App 蓚求连接过的设备）。因此车机检测在 iOS 上只能：
  1. 把车机当 **BLE 外设**（车机广播 BLE）用 flutter_blue_plus 扫描，或
  2. 通过 `CBCentralManager` 的状态恢复/系统弹出监听（本项目未实现）
- 本项目 Android 走平台通道（A2DP/HEADSET 已连接列表），iOS 侧通道为空实现，
  蓝牙自动启停功能默认视为 Android-only
- iOS 后台定位：Info.plist 已配 `UIBackgroundModes=location, bluetooth`，
  需勾选 Xcode Signing & Capabilities 的 Background Modes；系统会显示蓝色胶囊，
  长时间后台定位可能被系统降频

### 已知限制
- 进程被系统杀死后不会自动续录（前台服务已尽量降低概率）
- 「静态漂移」用自适应频率抑制：速度 <1 m/s 连续 3 次切入 30s 静止间隔，静止点仍会记录
- 高德定位 SDK 在国内坐标系（GCJ-02），GPX 导出的经纬度即 GCJ-02，
  在国际地图（OSM/Google）上会偏移数百米——属预期行为

### v1.2.0 稳定性修复
- **修复「点开历史轨迹闪退 / 之后无法启动」**：根因是没有定位点的轨迹会让高德
  原生地图用空点集初始化 polyline 而崩溃；且首页三个 Tab 是急切构建，崩溃后每次
  启动都会复现。现在：
  - 无定位点的轨迹在详情页直接显示可读占位提示，不再创建地图；
  - Tab 改为懒加载，只有访问过的页面才构建；
  - 数据库文件损坏时自动备份（`*.corrupt-<时间戳>`）并重建，不再卡死启动。
- **新增示例轨迹**：首次启动且本地无任何轨迹时，自动种入一条带定位点、手动
  打点、急刹、照片事件的完整示例（名为「示例轨迹（可删除）」），方便未配置
  高德 Key 时也能体验详情页/GPX 导出。删除后不会再次生成。

## 6. 开发与验证

```bash
export PATH="$HOME/flutter/bin:$PATH"
flutter pub get
flutter analyze        # 0 issues
flutter test           # 46 个用例：急刹/碰撞算法、GPX 生成、DAO 读写、设置页、DB 损坏自恢复、示例种入、地图空点守卫
flutter build apk --debug
```

测试运行于 `sqflite_common_ffi`，Linux 宿主若无 `libsqlite3.so` 符号链接，
测试内已 override 到 `libsqlite3.so.0`。

### ⚠️ 构建注意事项：amap_flutter_location pub cache 补丁

`amap_flutter_location 3.0.0` 的 android/build.gradle 太老（无 namespace、
compileSdk 29、jcenter），在 AGP 8 下无法配置。本机构建前已打补丁
（同目录留有 `.orig` 备份）：

- `namespace 'com.amap.flutter.location'`、`compileSdkVersion 34`
- 仓库换成 mavenCentral + 阿里云镜像

若 `flutter pub cache repair` 后重新构建，需要重打（两端 cache 目录均需，
以 `flutter build` 报错里的路径为准）。

依赖版本说明：`permission_handler` 固定 `^12.0.1`，因为 14.x 的
`permission_handler_android` 需要 AGP 9 工具链，与 Flutter 3.35 不兼容。

## 7. 数据与导出
- SQLite 三张表：`tracks`（会话）/ `track_points`（点）/ `events`（事件，v2 起 photo 事件带 `photo_path`），
  批量事务写入，迁移走 `AppDatabase._onUpgrade`（当前 v2）
- 拍照事件：照片存应用文档目录 `photos/<trackId>/<timestamp>.jpg`（与缓存隔离，避免系统清理误删）；
  详情页缩略图列表 + 全屏查看（InteractiveViewer 缩放）；删除轨迹时随级联清理（文件同步删除）
- GPX 1.1：`trk/trkseg/trkpt(lat,lon,ele,time)`；有坐标的事件输出为
  `wpt`（name=类型，desc=峰值/说明，photo 事件 name=📷 拍照点、desc 含照片文件名）；无坐标事件计入 `trk>desc` 统计
- 分享用 share_plus（系统分享面板），同时可保存到应用文档目录
