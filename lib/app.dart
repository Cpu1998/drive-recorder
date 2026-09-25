import 'package:flutter/material.dart';

import 'screens/detail_screen.dart';
import 'screens/history_screen.dart';
import 'screens/record_screen.dart';

/// App 外壳：MaterialApp + 底部导航（记录 / 历史 / 详情）。
class DriveRecorderAppView extends StatelessWidget {
  const DriveRecorderAppView({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '行车记录',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF1A73E9),
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF1A73E9),
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  /// 懒加载：只构建访问过的 tab。
  /// 全量急切构建会让详情页（含高德地图）在启动时就初始化，
  /// 一旦地图数据异常（如空点集轨迹）会变成“一启动就闪退”。
  final Set<int> _visited = {0};

  static const List<Widget> _tabs = [
    RecordScreen(),
    HistoryScreen(),
    DetailScreen(), // 详情页（Tab 模式显示最近一条轨迹）
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          for (var i = 0; i < _tabs.length; i++)
            (i == 0 || _visited.contains(i)) ? _tabs[i] : const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() {
          _visited.add(i);
          _index = i;
        }),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.radio_button_checked_outlined),
            selectedIcon: Icon(Icons.radio_button_checked),
            label: '记录',
          ),
          NavigationDestination(
            icon: Icon(Icons.route_outlined),
            selectedIcon: Icon(Icons.route),
            label: '历史',
          ),
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: '详情',
          ),
        ],
      ),
    );
  }
}
