import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 拍照事件服务：调起相机 + 照片落盘到应用文档目录。
///
/// - 拍照时即由 image_picker 原生侧压缩：长边 ≤1920、JPEG quality 85；
/// - 照片复制到 `photos/<trackId>/<timestamp>.jpg`（应用文档目录下），
///   与缓存目录隔离，避免系统清理误删；
/// - 相机取消 / 拍照失败返回 null，不产生事件。
class PhotoService {
  final ImagePicker picker;

  /// 文档目录解析（单测可注入临时目录）。
  final Future<Directory> Function() docsDirResolver;

  PhotoService({
    ImagePicker? picker,
    Future<Directory> Function()? docsDirResolver,
  })  : picker = picker ?? ImagePicker(),
        docsDirResolver = docsDirResolver ?? getApplicationDocumentsDirectory;

  /// 拍照长边上限（px）。
  static const int maxDimension = 1920;

  /// JPEG 压缩质量。
  static const int jpegQuality = 85;

  /// 调起系统相机拍照，返回临时文件路径；取消/失败返回 null。
  ///
  /// 压缩参数（maxWidth/maxHeight/imageQuality）由原生侧执行，
  /// 无需额外 Dart 依赖。
  Future<String?> takePhoto() async {
    try {
      final xfile = await picker.pickImage(
        source: ImageSource.camera,
        maxWidth: maxDimension.toDouble(),
        maxHeight: maxDimension.toDouble(),
        imageQuality: jpegQuality,
      );
      return xfile?.path;
    } catch (e) {
      debugPrint('拍照失败：$e');
      return null;
    }
  }

  /// 删除某轨迹的全部照片文件（`photos/<trackId>/` 整目录）。
  /// 最佳努力：目录不存在或删除失败静默容错（DB 行已删，孤儿文件无害）。
  Future<void> deleteTrackPhotos(int trackId) async {
    try {
      final docs = await docsDirResolver();
      final dir = Directory(p.join(docs.path, 'photos', '$trackId'));
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
    } catch (e) {
      debugPrint('清理轨迹照片失败（trackId=$trackId）：$e');
    }
  }

  /// 把拍照产物复制到 `photos/<trackId>/<timestamp>.jpg`，返回新路径。
  ///
  /// [timestamp] 为事件时间戳（毫秒），同时用作文件名，保证同轨迹内唯一。
  Future<String> persist(String sourcePath, int trackId, DateTime timestamp) async {
    final docs = await docsDirResolver();
    final dir = Directory(p.join(docs.path, 'photos', '$trackId'));
    await dir.create(recursive: true);
    final dest = p.join(dir.path, '${timestamp.millisecondsSinceEpoch}.jpg');
    await File(sourcePath).copy(dest);
    return dest;
  }
}
