import 'dart:io';

import 'package:flutter/material.dart';

import '../models/drive_event.dart';
import '../utils/formatters.dart';

/// 照片横向缩略图列表：详情页展示 photo 事件的现场照片。
///
/// - 缩略图用 [Image.file] 本地读取，圆角卡片；
/// - 照片文件缺失（被清理/删除）时显示占位图，不崩溃；
/// - 点击进入全屏查看（[InteractiveViewer] 支持缩放平移）。
class PhotoStrip extends StatelessWidget {
  final List<DriveEvent> photoEvents;

  const PhotoStrip({super.key, required this.photoEvents});

  @override
  Widget build(BuildContext context) {
    final sorted = [...photoEvents]
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text('现场照片（${sorted.length}）',
              style: Theme.of(context).textTheme.titleSmall),
        ),
        Expanded(
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(8),
            itemCount: sorted.length,
            itemBuilder: (context, i) {
              final e = sorted[i];
              return _PhotoThumb(
                event: e,
                onTap: () => _openViewer(context, e),
              );
            },
          ),
        ),
      ],
    );
  }

  void _openViewer(BuildContext context, DriveEvent e) {
    Navigator.of(context).push(PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black87,
      pageBuilder: (context, _, __) => PhotoViewer(event: e),
    ));
  }
}

/// 单张缩略图：96 高、宽按 4:3。
class _PhotoThumb extends StatelessWidget {
  final DriveEvent event;
  final VoidCallback onTap;

  const _PhotoThumb({required this.event, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final path = event.photoPath;
    final exists = path != null && File(path).existsSync();
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 128,
            height: 96,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (exists)
                  Image.file(
                    File(path),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _placeholder(context),
                  )
                else
                  _placeholder(context),
                // 底部时间戳渐变条
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    color: Colors.black54,
                    child: Text(
                      formatClock(event.timestamp),
                      style: const TextStyle(color: Colors.white, fontSize: 10),
                    ),
                  ),
                ),
                if (event.degraded)
                  const Positioned(
                    top: 4,
                    right: 4,
                    child: Tooltip(
                      message: '拍照时无定位信号',
                      child: Icon(Icons.location_off, size: 14,
                          color: Colors.orangeAccent),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _placeholder(BuildContext context) => ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.broken_image_outlined,
                size: 28, color: Theme.of(context).disabledColor),
            const SizedBox(height: 4),
            Text('照片缺失',
                style: TextStyle(
                    fontSize: 10, color: Theme.of(context).disabledColor)),
          ],
        ),
      );
}

/// 全屏照片查看：InteractiveViewer 支持双指缩放/平移，点击退出。
class PhotoViewer extends StatelessWidget {
  final DriveEvent event;

  const PhotoViewer({super.key, required this.event});

  @override
  Widget build(BuildContext context) {
    final path = event.photoPath;
    final exists = path != null && File(path).existsSync();
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        // opaque：图片未解码完成（尺寸 0）时也保证全屏可点退出
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).pop(),
        child: Stack(
          children: [
            Center(
              child: exists
                  ? InteractiveViewer(
                      maxScale: 8,
                      child: Image.file(
                        File(path),
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) =>
                            _errorView(context, '照片加载失败'),
                      ),
                    )
                  : _errorView(context, '照片文件不存在（可能已被清理）'),
            ),
            // 顶部信息条
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Text(
                        '📷 ${formatClock(event.timestamp)}'
                        '${event.degraded ? ' · 定位降级' : ''}',
                        style: const TextStyle(color: Colors.white70),
                      ),
                      const Spacer(),
                      const Icon(Icons.close, color: Colors.white70),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorView(BuildContext context, String message) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.broken_image_outlined,
              size: 56, color: Colors.white38),
          const SizedBox(height: 8),
          Text(message, style: const TextStyle(color: Colors.white54)),
        ],
      );
}
