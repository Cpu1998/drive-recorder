import 'dart:io';

import 'package:flutter/services.dart';

import 'app_logger.dart';

/// 公共下载目录写入（Android）。
///
/// 原生通道 `drive_recorder/downloads` → MainActivity.saveFileToDownloads：
/// Android 10+ 经 MediaStore.Downloads 免权限插入（RELATIVE_PATH=
/// Download/[subDir]）；Android 9- 遗留公共目录直写。
/// （替代已停更的 media_store_plus 插件——其在 Android 16 上 saveFile
/// 恒返回 null，即「保存失败」的根因。）
class DownloadsSaver {
  static const MethodChannel _channel = MethodChannel('drive_recorder/downloads');

  DownloadsSaver._();

  /// 把本地文件 [filePath] 复制到 `Download/[subDir]/`。
  ///
  /// 成功返回展示路径（`Download/子目录/实际文件名`，重名自动加 (1)
  /// 时返回真实名）；失败抛异常（调用方自行回落应用目录）。
  static Future<String> saveFileToDownloads({
    required String filePath,
    required String mime,
    String subDir = 'DriveRecorder',
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('仅 Android 支持公共下载目录');
    }
    final actualName = await _channel.invokeMethod<String>(
      'saveFileToDownloads',
      {'filePath': filePath, 'subDir': subDir, 'mime': mime},
    );
    if (actualName == null || actualName.isEmpty) {
      throw Exception('保存到下载目录失败（原生返回空）');
    }
    AppLogger.i('download', '已写入公共下载目录：Download/$subDir/$actualName');
    return 'Download/$subDir/$actualName';
  }
}
