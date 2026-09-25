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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [
          RecordScreen(),
          HistoryScreen(),
          DetailScreen(), // 详情页（Tab 模式显示最近一条轨迹）
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
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
