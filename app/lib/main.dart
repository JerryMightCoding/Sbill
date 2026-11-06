import 'package:flutter/material.dart';

import 'build_config.dart';
import 'state/ledger_controller.dart';
import 'ui/widgets/test_console_overlay.dart';
import 'ui/screens/workspace_home_screen.dart';
import 'ui/theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = LedgerController()..initializeApp();
  runApp(SbillApp(controller: controller));
}

class SbillApp extends StatefulWidget {
  const SbillApp({
    super.key,
    required this.controller,
  });

  final LedgerController controller;
  @override
  State<SbillApp> createState() => _SbillAppState();
}

class _SbillAppState extends State<SbillApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _testNavigation = testToolsEnabled ? TestNavigationObserver() : null;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '同行账本',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme(),
      navigatorKey: _navigatorKey,
      navigatorObservers:
          _testNavigation == null ? const [] : [_testNavigation],
      builder: testToolsEnabled
          ? (context, child) => Overlay.wrap(
                  child: TestConsoleOverlay(
                controller: widget.controller,
                navigation: _testNavigation!,
                child: child ?? const SizedBox.shrink(),
              ))
          : null,
      home: WorkspaceHomeScreen(controller: widget.controller),
    );
  }
}
