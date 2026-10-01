import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../utils/constants.dart';

/// 屏幕策略执行器：把「记录是否进行中 + 当前策略」翻译成两个动作——
/// 1. 屏幕 WakeLock（wakelock_plus，等价 Android FLAG_KEEP_SCREEN_ON，
///    无需任何权限）；
/// 2. 假熄屏覆盖层开关（[fakeOffActive]，UI 侧监听后盖全屏黑层）。
///
/// 职责边界：本类只管状态与 wakelock，不碰 Widget 树；覆盖层由
/// `widgets/fake_off_overlay.dart` 监听绘制。
class ScreenPolicyController extends ChangeNotifier {
  /// 屏亮锁开关后端；注入以便单测（默认走 wakelock_plus）。
  final Future<void> Function(bool enabled) _wakelockToggle;

  ScreenPolicyController({Future<void> Function(bool enabled)? wakelockToggle})
    : _wakelockToggle = wakelockToggle ?? _toggleViaWakelockPlus;

  static Future<void> _toggleViaWakelockPlus(bool enabled) async {
    try {
      if (enabled) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (_) {
      // 插件异常（无平台通道的测试/桌面环境等）不阻塞记录主流程
    }
  }

  bool _wakelockHeld = false;

  /// 当前是否持有屏幕 WakeLock。
  bool get wakelockHeld => _wakelockHeld;

  bool _fakeOffActive = false;

  /// 假熄屏覆盖层是否应显示（仅记录进行中且策略为 fakeOff 时为 true）。
  bool get fakeOffActive => _fakeOffActive;

  /// 记录状态变化时应用/释放策略（start、resume 传 true；pause、stop 传 false）。
  ///
  /// - system：不持有 wakelock，无覆盖层；
  /// - keepOn：持有 wakelock；
  /// - fakeOff：持有 wakelock + 自动进入黑屏（继续/重新开始时同样自动进入）。
  Future<void> applyRecordingState(bool recording, ScreenPolicy policy) async {
    if (!recording || policy == ScreenPolicy.system) {
      var changed = await _setWakelock(false);
      if (_fakeOffActive) {
        _fakeOffActive = false;
        changed = true;
      }
      if (changed) notifyListeners();
      return;
    }
    var changed = await _setWakelock(true);
    if (policy == ScreenPolicy.fakeOff && !_fakeOffActive) {
      _fakeOffActive = true;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// 手动进入黑屏（记录页「熄屏保活」按钮；仅记录中且 fakeOff 策略有意义）。
  void enterFakeOff() {
    if (_fakeOffActive) return;
    _fakeOffActive = true;
    notifyListeners();
  }

  /// 临时退出黑屏（覆盖层点按）：仅收起覆盖层，wakelock 保持到记录结束。
  void exitFakeOff() {
    if (!_fakeOffActive) return;
    _fakeOffActive = false;
    notifyListeners();
  }

  /// 兜底全释放（provider dispose / widget 销毁时调用，防泄漏）。
  Future<void> releaseAll() => applyRecordingState(false, ScreenPolicy.system);

  Future<bool> _setWakelock(bool on) async {
    if (_wakelockHeld == on) return false;
    await _wakelockToggle(on);
    _wakelockHeld = on;
    return true;
  }
}
