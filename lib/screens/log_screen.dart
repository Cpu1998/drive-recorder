import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../services/app_logger.dart';

/// 运行日志查看页：彩色分级展示 + 复制（全部/多选）+ 分享导出 + 清空。
///
/// 多选：长按任意条目进入选择模式，点选多条后「复制所选」。
class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  final _scroll = ScrollController();
  final _selected = <int>{}; // 选中条目下标；非空即处于选择模式

  bool get _selecting => _selected.isNotEmpty;

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

  void _toggleSelect(int i) {
    setState(() {
      _selected.contains(i) ? _selected.remove(i) : _selected.add(i);
    });
  }

  void _exitSelection() => setState(_selected.clear);

  /// 单条日志的纯文本（与导出格式一致，含毫秒）。
  String _entryText(LogEntry e) {
    final hh = e.time.hour.toString().padLeft(2, '0');
    final mm = e.time.minute.toString().padLeft(2, '0');
    final ss = e.time.second.toString().padLeft(2, '0');
    final ms = e.time.millisecond.toString().padLeft(3, '0');
    return '$hh:$mm:$ss.$ms ${e.level} ${e.tag} ${e.message}';
  }

  Future<void> _copy(String text, int count) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已复制 $count 条日志')));
  }

  Future<void> _copySelected() async {
    final indices = _selected.toList()..sort();
    final text =
        indices.map((i) => _entryText(AppLogger.entries[i])).join('\n');
    await _copy(text, indices.length);
    _exitSelection();
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
    if (!_selecting) _jumpToEnd();

    return PopScope(
      // 选择模式下先退出选择，而不是直接退出页面
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exitSelection();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: _selecting
              ? IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: '取消选择',
                  onPressed: _exitSelection,
                )
              : null,
          title: Text(_selecting
              ? '已选 ${_selected.length} 条'
              : '运行日志（${entries.length}）'),
          actions: [
            if (_selecting)
              IconButton(
                icon: const Icon(Icons.copy),
                tooltip: '复制所选',
                onPressed: _copySelected,
              )
            else ...[
              IconButton(
                icon: const Icon(Icons.copy_all_outlined),
                tooltip: '复制全部',
                onPressed: entries.isEmpty
                    ? null
                    : () => _copy(AppLogger.export(), entries.length),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: '清空',
                onPressed: () {
                  _selected.clear();
                  setState(AppLogger.reset);
                },
              ),
              IconButton(
                icon: const Icon(Icons.share_outlined),
                tooltip: '分享',
                onPressed: _share,
              ),
            ],
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
                  final selected = _selected.contains(i);
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: InkWell(
                      onTap: _selecting ? () => _toggleSelect(i) : null,
                      onLongPress: () => _toggleSelect(i),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 2),
                        color: selected
                            ? Theme.of(context).colorScheme.primaryContainer
                            : null,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_selecting)
                              Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: Icon(
                                  selected
                                      ? Icons.check_box
                                      : Icons.check_box_outline_blank,
                                  size: 14,
                                  color:
                                      Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            Expanded(
                              child: Text(
                                _entryText(e),
                                style: TextStyle(
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                    color: color),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
