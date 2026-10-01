import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/recording_provider.dart';
import '../services/screen_policy_controller.dart';
import '../utils/formatters.dart';

/// 挂在 MaterialApp.builder 上的全局宿主：[ScreenPolicyController]
/// 的 fakeOffActive 为 true 时，在整个 Navigator 之上盖一层全屏黑（假熄屏）。
///
/// 用手动监听而非 context.watch：RecordingProvider 每个定位点都会
/// notifyListeners，watch 会让整个 App 以定位频率重 build。
class ScreenPolicyHost extends StatefulWidget {
  final Widget child;

  const ScreenPolicyHost({super.key, required this.child});

  @override
  State<ScreenPolicyHost> createState() => _ScreenPolicyHostState();
}

class _ScreenPolicyHostState extends State<ScreenPolicyHost> {
  ScreenPolicyController? _ctl;

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ctl = context.read<RecordingProvider>().screen;
    if (!identical(ctl, _ctl)) {
      _ctl?.removeListener(_onControllerChanged);
      _ctl = ctl;
      ctl.addListener(_onControllerChanged);
    }
  }

  @override
  void dispose() {
    _ctl?.removeListener(_onControllerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctl = _ctl;
    return Stack(
      children: [
        widget.child,
        if (ctl != null && ctl.fakeOffActive)
          FakeOffOverlay(
            startTime: context
                .read<RecordingProvider>()
                .currentTrack
                ?.startTime,
            onExit: ctl.exitFakeOff,
          ),
      ],
    );
  }
}

/// 假熄屏覆盖层：全屏纯黑（AMOLED 真省电）+ 沉浸式隐藏系统栏，
/// 屏幕仍保持唤醒（wakelock 在记录结束前不释放）。
/// 点按任意处临时退出黑屏（记录不中断）；记录页可再进入。
class FakeOffOverlay extends StatefulWidget {
  final DateTime? startTime;

  /// 点按退出回调（临时退出，wakelock 保持）。
  final VoidCallback onExit;

  const FakeOffOverlay({
    super.key,
    required this.startTime,
    required this.onExit,
  });

  @override
  State<FakeOffOverlay> createState() => _FakeOffOverlayState();
}

class _FakeOffOverlayState extends State<FakeOffOverlay> {
  Timer? _ticker;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    final start = widget.startTime;
    if (start != null) {
      _elapsed = DateTime.now().difference(start);
    }
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final start = widget.startTime;
      if (mounted && start != null) {
        setState(() => _elapsed = DateTime.now().difference(start));
      }
    });
    _setImmersive(true);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _setImmersive(false);
    super.dispose();
  }

  /// 沉浸式隐藏状态/导航栏保证纯黑；退出时恢复系统栏。
  /// 测试环境无平台通道，异常静默忽略。
  void _setImmersive(bool on) {
    () async {
      try {
        if (on) {
          await SystemChrome.setEnabledSystemUIMode(
            SystemUiMode.immersiveSticky,
          );
        } else {
          await SystemChrome.setEnabledSystemUIMode(
            SystemUiMode.manual,
            overlays: SystemUiOverlay.values,
          );
        }
      } catch (_) {
        // 无通道环境忽略
      }
    }();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: GestureDetector(
        // opaque：黑屏本身吃掉所有点按，只响应「点按退出」
        behavior: HitTestBehavior.opaque,
        onTap: widget.onExit,
        child: Container(
          color: Colors.black,
          alignment: Alignment.bottomCenter,
          padding: const EdgeInsets.only(bottom: 32),
          child: DefaultTextStyle(
            style: const TextStyle(
              color: Colors.white38,
              fontSize: 11,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
            textAlign: TextAlign.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('记录中 · ${formatDuration(_elapsed)}'),
                const SizedBox(height: 4),
                const Text(
                  '点按屏幕临时退出黑屏',
                  style: TextStyle(color: Colors.white24, fontSize: 10),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
