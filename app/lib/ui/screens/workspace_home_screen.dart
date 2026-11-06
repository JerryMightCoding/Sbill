import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/ledger_controller.dart';
import '../theme/app_theme.dart';
import 'group_home_screen.dart';

class WorkspaceHomeScreen extends StatefulWidget {
  const WorkspaceHomeScreen({super.key, required this.controller});
  final LedgerController controller;
  @override
  State<WorkspaceHomeScreen> createState() => _WorkspaceHomeScreenState();
}

class _WorkspaceHomeScreenState extends State<WorkspaceHomeScreen>
    with WidgetsBindingObserver {
  LedgerController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        controller.isAppReady &&
        !controller.isTestSessionBusy &&
        controller.snapshot != null) {
      controller.checkIncomingSystemFileIntent();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          if (!controller.isAppReady) {
            return Scaffold(
                body: Center(
                    child: controller.lastError == null
                        ? const CircularProgressIndicator()
                        : Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.lock_outline, size: 48),
                                  const SizedBox(height: 16),
                                  const Text('无法安全打开本机账本'),
                                  const SizedBox(height: 8),
                                  Text(controller.lastError!),
                                  TextButton(
                                      onPressed: controller.initializeApp,
                                      child: const Text('重试')),
                                ]))));
          }
          final snap = controller.snapshot;
          if (snap != null) {
            return GroupHomeScreen(
                key: ValueKey(snap.groupId), controller: controller);
          }
          final first = controller.ledgers.isEmpty;
          return Scaffold(
            appBar: AppBar(title: Text(first ? '同行账本' : '我的出行账本')),
            body: SafeArea(
                child: ListView(padding: const EdgeInsets.all(24), children: [
              if (first) ...[
                const SizedBox(height: 36),
                const Icon(Icons.travel_explore_rounded,
                    size: 72, color: AppTheme.primaryTeal),
                const SizedBox(height: 24),
                const Text('每次出行，一本清楚的账',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(fontSize: 25, fontWeight: FontWeight.w800)),
                const SizedBox(height: 12),
                const Text('创建账本，添加同行伙伴，记下第一笔。\n离线也能使用；伙伴可以稍后认领本人身份。',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.mutedSlate, height: 1.7)),
                const SizedBox(height: 32),
              ],
              for (final ledger in controller.ledgers)
                Card(
                    child: ListTile(
                  leading: const Icon(Icons.menu_book_rounded,
                      color: AppTheme.primaryTeal),
                  title: Text(ledger.groupName),
                  subtitle: Text(
                      ledger.legacy ? '原账本已保留 · 旧版身份，暂不可邀请认领' : '成员、分类与结算独立'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: controller.isLoading
                      ? null
                      : () => controller.selectLedger(ledger.groupId),
                )),
              const SizedBox(height: 16),
              FilledButton.icon(
                  onPressed: controller.isLoading
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                              builder: (_) =>
                                  CreateLedgerScreen(controller: controller))),
                  icon: const Icon(Icons.add),
                  label: const Text('创建出行账本')),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                  onPressed: controller.isLoading
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                              builder: (_) =>
                                  JoinLedgerScreen(controller: controller))),
                  icon: const Icon(Icons.group_add_outlined),
                  label: const Text('加入同行账本')),
              if (controller.lastError != null)
                Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(controller.lastError!,
                        style: const TextStyle(color: AppTheme.debtRose))),
              const SizedBox(height: 20),
              const Text('无需注册或公网。不同账本不会混合账目、伙伴或自定义分类。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: AppTheme.mutedSlate)),
            ])),
          );
        },
      );
}

class CreateLedgerScreen extends StatefulWidget {
  const CreateLedgerScreen({super.key, required this.controller});
  final LedgerController controller;
  @override
  State<CreateLedgerScreen> createState() => _CreateLedgerScreenState();
}

class _CreateLedgerScreenState extends State<CreateLedgerScreen> {
  final _form = GlobalKey<FormState>();
  final _trip = TextEditingController();
  final _self = TextEditingController();
  final _companions = TextEditingController();
  bool _saving = false;
  @override
  void dispose() {
    _trip.dispose();
    _self.dispose();
    _companions.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('开始一次出行')),
        body: Form(
            key: _form,
            child: ListView(padding: const EdgeInsets.all(24), children: [
              const Text('先填两项，就能开始记账',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              const SizedBox(height: 20),
              TextFormField(
                  controller: _trip,
                  maxLength: 80,
                  decoration: const InputDecoration(
                      labelText: '出行账本名称', hintText: '例如：周末杭州游'),
                  validator: _required),
              const SizedBox(height: 12),
              TextFormField(
                  controller: _self,
                  maxLength: 80,
                  decoration: const InputDecoration(
                      labelText: '大家怎么称呼你', hintText: '你的昵称'),
                  validator: _required),
              const SizedBox(height: 12),
              TextFormField(
                  controller: _companions,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(
                      labelText: '同行伙伴（选填，每行一位）', hintText: '也可以创建后再添加')),
              const SizedBox(height: 16),
              const Text('你是账本主人。伙伴暂时不需要安装 App，也能参与分摊；之后可认领本人身份。不会创建示例账目。',
                  style: TextStyle(color: AppTheme.mutedSlate, height: 1.6)),
              const SizedBox(height: 24),
              FilledButton(
                  onPressed: _saving
                      ? null
                      : () async {
                          if (!_form.currentState!.validate()) return;
                          setState(() => _saving = true);
                          final ok = await widget.controller.createLedger(
                              groupName: _trip.text,
                              displayName: _self.text,
                              companions: _companions.text
                                  .split('\n')
                                  .map((v) => v.trim())
                                  .where((v) => v.isNotEmpty)
                                  .toList());
                          if (!context.mounted) return;
                          setState(() => _saving = false);
                          if (ok) {
                            Navigator.of(context).pop();
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                content: Text(
                                    widget.controller.lastError ?? '创建失败')));
                          }
                        },
                  child: Text(_saving ? '正在创建…' : '创建并开始记账')),
            ])),
      );
  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? '请填写这一项' : null;
}

class JoinLedgerScreen extends StatefulWidget {
  const JoinLedgerScreen({super.key, required this.controller});
  final LedgerController controller;
  @override
  State<JoinLedgerScreen> createState() => _JoinLedgerScreenState();
}

class _JoinLedgerScreenState extends State<JoinLedgerScreen> {
  final _trip = TextEditingController();
  final _participant = TextEditingController();
  final _name = TextEditingController();
  final _welcome = TextEditingController();
  final _key = TextEditingController();
  String? _request;
  bool _busy = false;
  @override
  void dispose() {
    for (final c in [_trip, _participant, _name, _welcome, _key]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<bool> Function() action, {bool join = false}) async {
    setState(() => _busy = true);
    final ok = await action();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok && !join) _request = widget.controller.transferCode;
    });
    if (ok && join) {
      Navigator.of(context).pop();
    } else if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.controller.lastError ?? '操作失败')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('加入同行账本')),
        body: ListView(padding: const EdgeInsets.all(24), children: [
          const Text('1. 向账本主人申请认领',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          const Text('请主人从“同步与伙伴”复制账本编号和你的伙伴编号。你生成的申请只包含公钥，不包含私钥。',
              style: TextStyle(color: AppTheme.mutedSlate, height: 1.6)),
          const SizedBox(height: 12),
          TextField(
              controller: _trip,
              decoration: const InputDecoration(labelText: '账本编号')),
          TextField(
              controller: _participant,
              decoration: const InputDecoration(labelText: '要认领的伙伴编号')),
          TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: '你的昵称')),
          const SizedBox(height: 12),
          OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => _run(() => widget.controller.createClaim(
                      groupId: _trip.text,
                      participantId: _participant.text,
                      displayName: _name.text)),
              child: const Text('生成本人认领申请')),
          if (_request != null) ...[
            const SizedBox(height: 8),
            Text('本机身份指纹：${widget.controller.identityFingerprint}',
                style: const TextStyle(fontSize: 12)),
            TextButton.icon(
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: _request!)),
                icon: const Icon(Icons.copy),
                label: const Text('复制申请，交给账本主人')),
            const Text('请当面或通过可信渠道核对身份指纹。主人批准前，你还不能以该伙伴身份记账。',
                style: TextStyle(fontSize: 12, color: AppTheme.mutedSlate)),
          ],
          const SizedBox(height: 28),
          const Text('2. 导入主人批准的加入包',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          const Text('主人批准后会给你加密加入包和访问密钥。请分别通过可信渠道接收，勿公开分享。',
              style: TextStyle(color: AppTheme.mutedSlate, height: 1.6)),
          const SizedBox(height: 12),
          TextField(
              controller: _welcome,
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(
                  labelText: '加密加入包', hintText: 'SBILL-JOIN1:…')),
          TextField(
              controller: _key,
              obscureText: true,
              decoration: const InputDecoration(labelText: '访问密钥')),
          const SizedBox(height: 20),
          FilledButton(
              onPressed: _busy
                  ? null
                  : () => _run(
                      () => widget.controller
                          .joinLedger(_welcome.text, _key.text),
                      join: true),
              child: const Text('验签并加入账本')),
        ]),
      );
}
