import 'package:flutter/foundation.dart';

/// 运行日志条目。
@immutable
class LogEntry {
  final DateTime time;
  final String level; // I / W / E
  final String tag;
  final String message;

  const LogEntry(this.time, this.level, this.tag, this.message);
}

/// 应用内运行日志（环形缓冲，最多 [maxEntries] 条）。
///
/// 目的：普通用户没有 adb/logcat，定位、地图、Key 校验等关键动作
/// 与错误必须能直接在 App 里看到并分享出来排查。
class AppLogger {
  static const int maxEntries = 1000;

  static final List<LogEntry> _entries = [];
  static List<LogEntry> get entries => List.unmodifiable(_entries);

  /// 清空日志（日志页「清空」按钮/测试共用）。
  static void reset() => _entries.clear();

  static void i(String tag, String message) => _add('I', tag, message);
  static void w(String tag, String message) => _add('W', tag, message);
  static void e(String tag, String message) => _add('E', tag, message);

  static void _add(String level, String tag, String message) {
    _entries.add(LogEntry(DateTime.now(), level, tag, message));
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
    // 同步镜像到控制台，开发调试时 adb 也能看到
    debugPrint('[$level][$tag] $message');
  }

  /// 捕获全局未处理异常（Dart 层），native 崩溃不在此列。
  static void attachGlobalHandlers() {
    FlutterError.onError = (details) {
      e('flutter', '框架异常：${details.exception}\n'
          '${details.stack?.toString().split('\n').take(6).join('\n')}');
      FlutterError.presentError(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      e('flutter', '未捕获异常：$error\n'
          '${stack.toString().split('\n').take(6).join('\n')}');
      return true;
    };
  }

  /// 导出纯文本（分享用）。
  static String export() {
    final buf = StringBuffer('行车记录 运行日志（最近 ${_entries.length} 条）\n'
        '导出时间：${DateTime.now()}\n\n');
    for (final e in _entries) {
      final hh = e.time.hour.toString().padLeft(2, '0');
      final mm = e.time.minute.toString().padLeft(2, '0');
      final ss = e.time.second.toString().padLeft(2, '0');
      final ms = e.time.millisecond.toString().padLeft(3, '0');
      buf.write('$hh:$mm:$ss.$ms ${e.level} ${e.tag.padRight(9)} ${e.message}\n');
    }
    return buf.toString();
  }

  /// Key 打码展示（避免完整 Key 泄漏到日志/分享）。
  static String maskKey(String key) {
    if (key.length <= 8) return '${key.length} 位';
    return '${key.substring(0, 4)}…${key.substring(key.length - 4)}'
        '（${key.length} 位）';
  }
}
