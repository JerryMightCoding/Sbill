import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../build_config.dart';
import '../../state/ledger_controller.dart';
import '../../state/test_console_controller.dart';

class TestNavigationObserver extends NavigatorObserver {
  final List<Route<dynamic>> _routes = [];
  final Set<TransitionRoute<dynamic>> _closing = {};
  void _trackExit(Route<dynamic> route) {
    if (route is TransitionRoute<dynamic>) {
      _closing.add(route);
      route.completed.whenComplete(() => _closing.remove(route));
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _trackExit(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute != null) {
        _routes[index] = newRoute;
      } else {
        _routes.removeAt(index);
      }
    }
  }

  Future<void> closeTransientRoutes() async {
    final closing = {
      ..._routes.skip(1).whereType<TransitionRoute<dynamic>>(),
      ..._closing
    };
    navigator?.popUntil((route) => route.isFirst);
    // Old editors must be disposed before the signing identity or ledger changes.
    await Future.wait(closing.map((route) => route.completed));
  }
}

class TestConsoleOverlay extends StatefulWidget {
  const TestConsoleOverlay(
      {super.key,
      required this.controller,
      required this.navigation,
      required this.child});
  final LedgerController controller;
  final TestNavigationObserver navigation;
  final Widget child;
  @override
  State<TestConsoleOverlay> createState() => _TestConsoleOverlayState();
}

class _TestConsoleOverlayState extends State<TestConsoleOverlay> {
  late final TestConsoleController _console;
  bool _expanded = false;
  bool _dialogOpen = false;
  Offset? _position;
  @override
  void initState() {
    super.initState();
    _console = TestConsoleController(widget.controller,
        closeRoutes: widget.navigation.closeTransientRoutes);
    if (testToolsEnabled) _console.initialize();
  }

  @override
  void dispose() {
    _console.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => !testToolsEnabled
      ? widget.child
      : ListenableBuilder(
          listenable: Listenable.merge([_console, widget.controller]),
          builder: (context, _) => Stack(children: [
            AbsorbPointer(absorbing: _console.busy, child: widget.child),
            if (!_dialogOpen)
              Positioned.fill(
                  child: SafeArea(
                      child: Padding(
                padding: EdgeInsets.only(
                    bottom: MediaQuery.viewInsetsOf(context).bottom),
                child: LayoutBuilder(builder: (context, bounds) {
                  final bubbleWidth = math.min(136.0, bounds.maxWidth);
                  final position = _position ??
                      Offset(
                          math.max(0, bounds.maxWidth - bubbleWidth - 8), 88);
                  final x = position.dx
                      .clamp(0.0, math.max(0.0, bounds.maxWidth - bubbleWidth))
                      .toDouble();
                  final y = position.dy
                      .clamp(0.0, math.max(0.0, bounds.maxHeight - 48))
                      .toDouble();
                  return Stack(children: [
                    if (!_expanded)
                      Positioned(
                          left: x,
                          top: y,
                          child: GestureDetector(
                              onPanUpdate: (details) => setState(() =>
                                  _position = Offset(x, y) + details.delta),
                              child: Material(
                                  elevation: 6,
                                  color: const Color(0xFF1E293B),
                                  borderRadius: BorderRadius.circular(24),
                                  child: InkWell(
                                      key: const ValueKey(
                                          'developer_console_bubble'),
                                      borderRadius: BorderRadius.circular(24),
                                      onTap: () =>
                                          setState(() => _expanded = true),
                                      child: SizedBox(
                                          width: bubbleWidth,
                                          height: 48,
                                          child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 12,
                                                      vertical: 10),
                                              child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    const Icon(
                                                        Icons
                                                            .bug_report_outlined,
                                                        color: Colors.amber,
                                                        size: 19),
                                                    const SizedBox(width: 5),
                                                    Text(
                                                        '调试 · ${_console.activeProfile == 'primary' ? 'A' : _console.activeProfile == 'peer_b' ? 'B' : _console.activeProfile == 'peer_c' ? 'C' : 'D'}',
                                                        style: const TextStyle(
                                                            color: Colors.white,
                                                            fontSize: 12)),
                                                  ])))))))
                    else
                      Align(
                          alignment: Alignment.topRight,
                          child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: SizedBox(
                                width: math.min(380, bounds.maxWidth - 20),
                                height: math.min(
                                    620, math.max(0, bounds.maxHeight - 20)),
                                child: Material(
                                    key: const ValueKey(
                                        'developer_console_panel'),
                                    elevation: 12,
                                    borderRadius: BorderRadius.circular(18),
                                    clipBehavior: Clip.antiAlias,
                                    child: _panel(context)),
                              ))),
                  ]);
                }),
              ))),
          ]),
        );

  Widget _panel(BuildContext context) {
    final ledger = widget.controller;
    final snapshot = ledger.snapshot;
    final disabled = !_console.ready || _console.busy || ledger.isLoading;
    return Column(children: [
      Container(
          color: const Color(0xFF1E293B),
          padding: const EdgeInsets.only(left: 14),
          child: Row(children: [
            const Icon(Icons.bug_report, color: Colors.amber, size: 20),
            const SizedBox(width: 8),
            const Expanded(
                child: Text('开发者控制台 · 仅测试版',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w700))),
            IconButton(
                tooltip: '收起控制台',
                onPressed: () => setState(() => _expanded = false),
                icon: const Icon(Icons.close, color: Colors.white)),
          ])),
      if (_console.busy) const LinearProgressIndicator(),
      Expanded(
          child: ListView(padding: const EdgeInsets.all(14), children: [
        const Text('测试身份', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final identity in TestIdentity.all)
            ChoiceChip(
                label: Text(identity.label),
                selected: _console.activeProfile == identity.id,
                onSelected: disabled
                    ? null
                    : (_) => _console.switchProfile(identity.id)),
        ]),
        const SizedBox(height: 10),
        Text(_console.status,
            style: const TextStyle(fontSize: 12, height: 1.5)),
        const SizedBox(height: 14),
        const Text('当前状态', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        SelectableText(
            snapshot == null
                ? '未进入账本'
                : '${snapshot.groupName}\n本人：${snapshot.activeActor.displayName} · ${snapshot.activeActor.role.label}\n'
                    '成员 ${snapshot.participants.length} · 账目 ${snapshot.expenses.length} · 分类 ${snapshot.customCategories.length}\n'
                    '事件 ${snapshot.totalEventCount} · 冲突 ${snapshot.conflictCount} · 待重授权 ${snapshot.pendingReauthCount}',
            style: const TextStyle(fontSize: 12, height: 1.6)),
        const SizedBox(height: 6),
        SelectableText('身份指纹：${ledger.identityFingerprint}',
            style: const TextStyle(fontSize: 11)),
        if (ledger.lastError != null)
          Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('最近错误：${ledger.lastError}',
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.red))),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 6, children: [
          OutlinedButton(
              onPressed: disabled ? null : _console.refresh,
              child: const Text('刷新状态')),
          OutlinedButton(
              onPressed: disabled ? null : () => _confirmScene(context),
              child: const Text('准备四身份联调账本')),
          OutlinedButton(
              onPressed: disabled || snapshot == null
                  ? null
                  : _console.syncSharedLedger,
              child: const Text('同步四个测试身份')),
        ]),
        const SizedBox(height: 6),
        const Text(
            '切换会关闭当前编辑页；未保存的输入会丢弃。各身份使用自己的私钥，不绕过角色权限。同步按钮只做同机加密包交换，不模拟网络成功。',
            style: TextStyle(fontSize: 11, color: Colors.black54, height: 1.6)),
        const Divider(height: 28),
        Row(children: [
          const Expanded(
              child: Text('最近调用（最多 100 条）',
                  style: TextStyle(fontWeight: FontWeight.w700))),
          IconButton(
              tooltip: '清空调用记录',
              onPressed: disabled ? null : ledger.clearTestTraces,
              icon: const Icon(Icons.delete_outline, size: 18)),
          IconButton(
              tooltip: '复制调用记录',
              onPressed: disabled
                  ? null
                  : () => Clipboard.setData(ClipboardData(
                      text: ledger.testTraces
                          .map((t) =>
                              '${t.ok ? 'OK' : 'FAIL'} ${t.operation} ${t.elapsedMs}ms')
                          .join('\n'))),
              icon: const Icon(Icons.copy, size: 18)),
        ]),
        const Text('仅记录操作名、结果与耗时，不记录私钥、加入包、访问密钥或命令参数。',
            style: TextStyle(fontSize: 11, color: Colors.black54, height: 1.5)),
        for (final trace in ledger.testTraces.reversed.take(20))
          Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                  '${trace.ok ? 'OK' : 'FAIL'} · ${trace.operation} · ${trace.elapsedMs} ms',
                  style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: trace.ok ? Colors.teal : Colors.red))),
      ])),
    ]);
  }

  Future<void> _confirmScene(BuildContext context) async {
    final navigator = widget.navigation.navigator;
    if (navigator == null) return;
    setState(() => _dialogOpen = true);
    final confirmed = await showDialog<bool>(
        context: navigator.context,
        builder: (ctx) => AlertDialog(
              title: const Text('准备四身份联调账本？'),
              content: const Text(
                  '在测试版中新增一本空账本，让 A/B/C/D 使用各自私钥完成认领。\n不会清空现有测试账本，也不添加示例账目。准备后返回身份 A。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: const Text('创建联调场景'))
              ],
            ));
    if (!mounted) return;
    setState(() => _dialogOpen = false);
    if (confirmed == true) await _console.prepareSharedLedger();
  }
}
