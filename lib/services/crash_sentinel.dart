import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

import 'app_logger.dart';

/// 静默死亡哨兵：把「正在做什么」写进磁盘文件。
///
/// 背景：native 层崩溃（SIGSEGV/abort）或系统 LMK 杀进程时，Dart 层
/// 任何异常处理器都不会执行，运行日志里表现为「无异常但进程消失」。
/// 哨兵文件在每次启动时检查：若残留，说明上次运行死在标记的阶段，
/// 立即写入运行日志，从而把「无日志的静默死亡」变成有据可查。
class CrashSentinel {
  static File? _file;

  static Future<File> _sentinelFile() async {
    final cached = _file;
    if (cached != null) return cached;
    final dir = await getTemporaryDirectory();
    return _file = File('${dir.path}/crash_sentinel');
  }

  /// 标记进入某阶段（覆盖写入，fire-and-forget，不阻塞 UI）。
  static void mark(String phase) => unawaited(_write(phase));

  static Future<void> _write(String phase) async {
    try {
      final f = await _sentinelFile();
      await f.writeAsString(phase, flush: true);
    } catch (_) {}
  }

  /// 阶段全部完成（存活下来），清除哨兵。
  static void clear() => unawaited(_clear());

  static Future<void> _clear() async {
    try {
      final f = await _sentinelFile();
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// 启动时检查上次是否静默死亡；返回死亡阶段（无残留则返回 null）。
  static Future<String?> checkLastRun() async {
    try {
      final f = await _sentinelFile();
      if (!f.existsSync()) return null;
      final phase = f.readAsStringSync().trim();
      if (phase.isEmpty) {
        f.deleteSync();
        return null;
      }
      f.deleteSync();
      AppLogger.e('crash', '检测到上次运行在「$phase」阶段被系统级杀死'
          '（native 崩溃或被系统回收，Dart 层无异常）');
      return phase;
    } catch (_) {
      return null;
    }
  }
}
