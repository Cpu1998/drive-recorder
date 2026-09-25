// Firebase 配置占位文件。
//
// ⚠️ 这是占位 stub：读取 DefaultFirebaseOptions.currentPlatform 会抛
// UnsupportedError，由 FirestoreSyncServiceImpl 捕获并提示
// "Firebase 未配置"，App 可正常编译运行、其他功能不受影响。
//
// 真实接入（覆盖本文件）：
//   1. dart pub global activate flutterfire_cli
//   2. flutterfire configure   （选择 Firebase 项目 + android/ios 平台）
//   3. 生成的 lib/firebase_options.dart 会覆盖本文件，无需改任何业务代码
//
// 详见 README.md「Firebase 接入步骤」。

library;

import 'package:firebase_core/firebase_core.dart';

/// flutterfire configure 生成后这里会返回各平台真实配置；
/// stub 状态下读取即抛错，上层据此优雅降级。
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform => throw UnsupportedError(
      'Firebase 未配置：请运行 flutterfire configure 生成 lib/firebase_options.dart');
}
