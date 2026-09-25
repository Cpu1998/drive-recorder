import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../services/app_logger.dart';

/// 运行日志查看页：彩色分级展示 + 分享导出 + 清空。
class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _jumpToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _share() async {
    final text = AppLogger.export();
    final tmp = await getTemporaryDirectory();
    final file = File(
        '${tmp.path}/drive_recorder_log_${DateTime.now().millisecondsSinceEpoch}.txt');
    await file.writeAsString(text, flush: true);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        text: '行车记录 运行日志',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = AppLogger.entries;
    _jumpToEnd();

    return Scaffold(
      appBar: AppBar(
        title: Text('运行日志（${entries.length}）'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清空',
            onPressed: () => setState(AppLogger.reset),
          ),
          IconButton(
            icon: const Icon(Icons.share_outlined),
            tooltip: '分享',
            onPressed: _share,
          ),
        ],
      ),
      body: entries.isEmpty
          ? Center(
              child: Text('暂无日志',
                  style: TextStyle(color: Theme.of(context).disabledColor)),
            )
          : ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(8),
              itemCount: entries.length,
              itemBuilder: (context, i) {
                final e = entries[i];
                final color = switch (e.level) {
                  'E' => Colors.red.shade700,
                  'W' => Colors.orange.shade800,
                  _ => Theme.of(context).textTheme.bodySmall!.color!,
                };
                final hh = e.time.hour.toString().padLeft(2, '0');
                final mm = e.time.minute.toString().padLeft(2, '0');
                final ss = e.time.second.toString().padLeft(2, '0');
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Text(
                    '$hh:$mm:$ss ${e.level} ${e.tag}: ${e.message}',
                    style: TextStyle(
                        fontSize: 11, fontFamily: 'monospace', color: color),
                  ),
                );
              },
            ),
    );
  }
}
