import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/ledger_models.dart';
import '../../state/ledger_controller.dart';
import '../theme/app_theme.dart';
import 'optical_qr_sync_screen.dart';

class CompanionCenterScreen extends StatelessWidget {
  const CompanionCenterScreen({super.key, required this.controller});
  final LedgerController controller;

  void _error(BuildContext context) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(controller.lastError ?? '操作失败')));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final snap = controller.snapshot!;
          final legacy = controller.ledgers
              .any((e) => e.groupId == snap.groupId && e.legacy);
          final manage = snap.activeActor.active &&
              snap.activeActor.role.canManageMembers &&
              !legacy;
          return ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('只同步当前出行',
                                  style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w800)),
                              const SizedBox(height: 8),
                              const Text(
                                  '分享加密文件或复制同步码给已经认领的伙伴。导入时会核对账本、签名与权限，不会把其他出行混进来。',
                                  style: TextStyle(
                                      color: AppTheme.mutedSlate, height: 1.6)),
                              const SizedBox(height: 12),
                              Wrap(spacing: 8, runSpacing: 8, children: [
                                FilledButton.tonalIcon(
                                    onPressed: controller.isLoading
                                        ? null
                                        : () async {
                                            final ok = await controller
                                                .shareTripDeltaViaSystemSheet();
                                            if (!ok && context.mounted) {
                                              _error(context);
                                            }
                                          },
                                    icon: const Icon(Icons.ios_share),
                                    label: const Text('分享同步文件')),
                                OutlinedButton(
                                    onPressed: controller.isLoading
                                        ? null
                                        : () async {
                                            if (await controller
                                                .exportTripDelta()) {
                                              final code = controller
                                                  .snapshot
                                                  ?.lastSyncReport
                                                  ?.exportedCompactCode;
                                              if (code != null) {
                                                await Clipboard.setData(
                                                    ClipboardData(text: code));
                                              }
                                              if (context.mounted) {
                                                ScaffoldMessenger.of(context)
                                                    .showSnackBar(
                                                        const SnackBar(
                                                            content: Text(
                                                                '当前账本同步码已复制')));
                                              }
                                            } else if (context.mounted) {
                                              _error(context);
                                            }
                                          },
                                    child: const Text('复制同步码')),
                                OutlinedButton(
                                    onPressed: controller.isLoading
                                        ? null
                                        : () async {
                                            final ok = await controller
                                                .importTripDeltaFromPicker();
                                            if (!ok && context.mounted) {
                                              _error(context);
                                            }
                                          },
                                    child: const Text('选择同步文件')),
                                OutlinedButton(
                                    onPressed: controller.isLoading
                                        ? null
                                        : () => _import(context),
                                    child: const Text('导入伙伴同步码')),
                                FilledButton.tonalIcon(
                                    key: const ValueKey('open_optical_qr_sync'),
                                    onPressed: controller.isLoading
                                        ? null
                                        : () {
                                            Navigator.of(context).push(
                                              MaterialPageRoute(
                                                builder: (_) =>
                                                    OpticalQrSyncScreen(
                                                  controller: controller,
                                                ),
                                              ),
                                            );
                                          },
                                    icon: const Icon(Icons.qr_code_2_rounded,
                                        size: 18),
                                    label: const Text('面对面瀑布二维码')),
                              ]),
                              if (snap.lastSyncReport != null)
                                Padding(
                                    padding: const EdgeInsets.only(top: 12),
                                    child: Text(
                                        snap.lastSyncReport!.summaryTitle,
                                        style: const TextStyle(fontSize: 12))),
                            ]))),
                const SizedBox(height: 14),
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('局域网直连与 WebDAV 异步留存',
                                  style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w800)),
                              const SizedBox(height: 8),
                              Text(
                                  controller.isLanServerRunning
                                      ? '本机局域网节点已开启：${controller.lanServerUrl}（同伴在同一 Wi-Fi/热点下可直接连接同步）'
                                      : '支持同一 Wi-Fi/手机热点下无公网 HTTP 直连互传，或配置个人 WebDAV 留存密文对象。',
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.mutedSlate,
                                      height: 1.5)),
                              const SizedBox(height: 10),
                              Wrap(spacing: 8, runSpacing: 8, children: [
                                OutlinedButton.icon(
                                    key: const ValueKey('toggle_lan_server'),
                                    onPressed: controller.isLoading
                                        ? null
                                        : () async {
                                            if (controller.isLanServerRunning) {
                                              await controller
                                                  .stopLanSyncServer();
                                            } else {
                                              final url = await controller
                                                  .startLanSyncServer();
                                              if (url != null) {
                                                await Clipboard.setData(
                                                    ClipboardData(text: url));
                                                if (context.mounted) {
                                                  ScaffoldMessenger.of(context)
                                                      .showSnackBar(SnackBar(
                                                          content: Text(
                                                              '本机局域网节点已启动并复制：$url')));
                                                }
                                              }
                                            }
                                          },
                                    icon: Icon(
                                        controller.isLanServerRunning
                                            ? Icons.stop_circle_outlined
                                            : Icons.wifi_tethering_rounded,
                                        size: 17),
                                    label: Text(controller.isLanServerRunning
                                        ? '关闭本机局域网节点'
                                        : '开启本机局域网节点')),
                                OutlinedButton.icon(
                                    key: const ValueKey('connect_lan_peer_button'),
                                    onPressed: controller.isLoading
                                        ? null
                                        : () => _connectLanPeer(context),
                                    icon: const Icon(Icons.lan_outlined,
                                        size: 17),
                                    label: const Text('连接伙伴局域网')),
                              ]),
                              const Divider(height: 24),
                              Row(children: [
                                Expanded(
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                      const Text('WebDAV 加密异步留存',
                                          style: TextStyle(
                                              fontWeight: FontWeight.w700,
                                              fontSize: 14)),
                                      const SizedBox(height: 2),
                                      Text(
                                          snap.webDavStatus.endpointUrl.isEmpty
                                              ? '未配置 WebDAV 地址 · 待上传密文 ${snap.webDavStatus.pendingUploadCount} 条'
                                              : '${snap.webDavStatus.endpointUrl} · 待上传 ${snap.webDavStatus.pendingUploadCount} 条 · 远端 ${snap.webDavStatus.remoteObjectCount} 条',
                                          style: const TextStyle(
                                              fontSize: 12,
                                              color: AppTheme.mutedSlate)),
                                    ])),
                                TextButton.icon(
                                    key: const ValueKey(
                                        'configure_webdav_button'),
                                    onPressed: controller.isLoading
                                        ? null
                                        : () => _configureWebDav(
                                            context, snap.webDavStatus),
                                    icon: const Icon(Icons.settings_outlined,
                                        size: 17),
                                    label: const Text('配置')),
                                FilledButton.tonalIcon(
                                    key: const ValueKey('sync_webdav_now_button'),
                                    onPressed: controller.isLoading
                                        ? null
                                        : () async {
                                            final ok = await controller
                                                .syncWebDavNow();
                                            if (!ok && context.mounted) {
                                              _error(context);
                                            }
                                          },
                                    icon: const Icon(Icons.sync_rounded,
                                        size: 17),
                                    label: const Text('同步')),
                              ]),
                            ]))),
                const SizedBox(height: 14),
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                const Expanded(
                                    child: Text('同行伙伴',
                                        style: TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w800))),
                                if (manage)
                                  TextButton.icon(
                                      onPressed: controller.isLoading
                                          ? null
                                          : () => _edit(context),
                                      icon: const Icon(Icons.person_add_alt),
                                      label: const Text('添加')),
                              ]),
                              const Text('未认领伙伴也能参与付款与分摊，但不能代替本人签名确认结算。',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.mutedSlate,
                                      height: 1.6)),
                              if (legacy)
                                const Padding(
                                    padding: EdgeInsets.only(top: 10),
                                    child: Text(
                                        '旧账本和账目已保留。旧版曾在本机代造多人的身份，不能据此安全邀请他人；请新建出行账本使用认领流程。',
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: AppTheme.conflictAmber))),
                              const SizedBox(height: 12),
                              for (final p in snap.participants)
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: CircleAvatar(
                                      child:
                                          Text(p.displayName.characters.first)),
                                  title: Text(
                                      '${p.displayName}${p.participantId == snap.activeActorId ? '（我）' : ''}'),
                                  subtitle: Text(
                                      '${p.role.label} · ${!p.active ? '已移出，历史保留' : p.boundPublicKey == null ? '待本人认领' : '已绑定本人身份'}'),
                                  trailing: manage && p.role != MemberRole.owner
                                      ? PopupMenuButton<String>(
                                          onSelected: (action) {
                                            if (action == 'claim') {
                                              _claim(context, p);
                                            } else {
                                              _edit(context, p);
                                            }
                                          },
                                          itemBuilder: (_) => [
                                            const PopupMenuItem(
                                                value: 'edit',
                                                child: Text('编辑权限 / 移出伙伴')),
                                            if (p.active)
                                              const PopupMenuItem(
                                                  value: 'claim',
                                                  child: Text('邀请或批准本人认领')),
                                          ],
                                        )
                                      : null,
                                ),
                              const Divider(),
                              const Text('权限说明',
                                  style:
                                      TextStyle(fontWeight: FontWeight.w700)),
                              const SizedBox(height: 8),
                              const Text(
                                  '账本主人：管理伙伴、审批认领、改账与发布结算。\n财务管理员：改账、解决冲突、发布结算，不能管理成员。\n普通成员：新增账目、修订自己创建的账目。\n只读成员：不可改账或发布结算，但可确认本人方案、声明本人还款和确认本人收款。\n本人收付必须本人签名，不得代签。',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.mutedSlate,
                                      height: 1.8)),
                            ]))),
                const SizedBox(height: 14),
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('安全备份与恢复 (Argon2id)',
                                  style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w800)),
                              const SizedBox(height: 6),
                              const Text(
                                  '使用 32 字节随机盐与 Argon2id (64 MiB / 3 次迭代) 派生密钥加密本机 Ed25519 签名身份，与账本群密钥隔离。',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.mutedSlate,
                                      height: 1.5)),
                              const SizedBox(height: 12),
                              Wrap(spacing: 8, runSpacing: 8, children: [
                                OutlinedButton.icon(
                                    key: const ValueKey(
                                        'export_identity_backup_button'),
                                    onPressed: controller.isLoading
                                        ? null
                                        : () => _exportBackup(context),
                                    icon: const Icon(Icons.key_outlined,
                                        size: 17),
                                    label: const Text('导出加密身份备份')),
                                OutlinedButton.icon(
                                    key: const ValueKey(
                                        'restore_identity_backup_button'),
                                    onPressed: controller.isLoading
                                        ? null
                                        : () => _restoreBackup(context),
                                    icon: const Icon(Icons.restore_rounded,
                                        size: 17),
                                    label: const Text('恢复身份备份')),
                              ]),
                            ]))),
              ]);
        },
      );

  Future<void> _connectLanPeer(BuildContext context) async {
    final addrCtrl = TextEditingController();
    await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('连接伙伴局域网节点'),
              content: TextField(
                  key: const ValueKey('lan_peer_endpoint_input'),
                  controller: addrCtrl,
                  decoration: const InputDecoration(
                      labelText: '伙伴局域网地址',
                      hintText: 'http://192.168.43.101:9443')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('取消')),
                FilledButton(
                    key: const ValueKey('confirm_lan_peer_sync'),
                    onPressed: () async {
                      final ok =
                          await controller.syncWithLanPeerHttp(addrCtrl.text);
                      if (!ctx.mounted) return;
                      if (ok) {
                        Navigator.of(ctx).pop();
                      } else {
                        _error(ctx);
                      }
                    },
                    child: const Text('直连同步'))
              ],
            ));
    addrCtrl.dispose();
  }

  Future<void> _configureWebDav(
      BuildContext context, WebDavStatusModel current) async {
    final urlCtrl = TextEditingController(text: current.endpointUrl);
    final userCtrl = TextEditingController(text: current.username);
    final passCtrl = TextEditingController();
    var simUnreachable = current.simulateUnreachable;
    await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setStateDialog) => AlertDialog(
                  title: const Text('配置 WebDAV 留存节点'),
                  content: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        key: const ValueKey('webdav_endpoint_input'),
                        controller: urlCtrl,
                        decoration: const InputDecoration(
                            labelText: 'WebDAV 地址 (HTTPS/HTTP)',
                            hintText: 'https://dav.example.com/sbill')),
                    const SizedBox(height: 10),
                    TextField(
                        key: const ValueKey('webdav_username_input'),
                        controller: userCtrl,
                        decoration: const InputDecoration(
                            labelText: '应用专用账号 (勿填 NAS 主账号)')),
                    const SizedBox(height: 10),
                    TextField(
                        key: const ValueKey('webdav_password_input'),
                        controller: passCtrl,
                        obscureText: true,
                        decoration: const InputDecoration(
                            labelText: '应用专用密码 (仅存本机会话内存)')),
                    const SizedBox(height: 8),
                    SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text('离线演练：模拟远端暂不可达',
                            style: TextStyle(fontSize: 12)),
                        value: simUnreachable,
                        onChanged: (v) =>
                            setStateDialog(() => simUnreachable = v)),
                  ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('取消')),
                    FilledButton(
                        key: const ValueKey('save_webdav_config_button'),
                        onPressed: () async {
                          final ok = await controller.configureWebDav(
                            endpointUrl: urlCtrl.text,
                            username: userCtrl.text,
                            password: passCtrl.text,
                            simulateUnreachable: simUnreachable,
                          );
                          if (!ctx.mounted) return;
                          if (ok) {
                            Navigator.of(ctx).pop();
                          } else {
                            _error(ctx);
                          }
                        },
                        child: const Text('保存'))
                  ],
                )));
    urlCtrl.dispose();
    userCtrl.dispose();
    passCtrl.dispose();
  }

  Future<void> _exportBackup(BuildContext context) async {
    final passCtrl = TextEditingController();
    await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('导出 Argon2id 加密身份备份'),
              content: TextField(
                  key: const ValueKey('backup_passphrase_input'),
                  controller: passCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                      labelText: '备份口令 (至少 12 个字符)',
                      helperText: '口令独立于账本群密钥，请妥善保管')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('取消')),
                FilledButton(
                    key: const ValueKey('confirm_export_backup_button'),
                    onPressed: () async {
                      final ok =
                          await controller.exportIdentityBackup(passCtrl.text);
                      if (!ctx.mounted) return;
                      if (ok) {
                        final code = controller
                            .snapshot?.lastSyncReport?.exportedCompactCode;
                        if (code != null) {
                          await Clipboard.setData(ClipboardData(text: code));
                        }
                        if (ctx.mounted) {
                          Navigator.of(ctx).pop();
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('加密身份备份已生成并复制到剪贴板')));
                        }
                      } else {
                        _error(ctx);
                      }
                    },
                    child: const Text('加密并复制'))
              ],
            ));
    passCtrl.dispose();
  }

  Future<void> _restoreBackup(BuildContext context) async {
    final jsonCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('恢复加密身份备份'),
              content: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                    key: const ValueKey('restore_backup_json_input'),
                    controller: jsonCtrl,
                    minLines: 3,
                    maxLines: 5,
                    decoration: const InputDecoration(
                        labelText: '粘贴备份 JSON (format_version: 2)')),
                const SizedBox(height: 10),
                TextField(
                    key: const ValueKey('restore_backup_passphrase_input'),
                    controller: passCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: '备份口令')),
              ])),
              actions: [
                TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('取消')),
                FilledButton(
                    key: const ValueKey('confirm_restore_backup_button'),
                    onPressed: () async {
                      final ok = await controller.restoreIdentityBackup(
                        backupJson: jsonCtrl.text,
                        passphrase: passCtrl.text,
                      );
                      if (!ctx.mounted) return;
                      if (ok) {
                        Navigator.of(ctx).pop();
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('签名身份恢复并校验通过')));
                      } else {
                        _error(ctx);
                      }
                    },
                    child: const Text('解密并恢复'))
              ],
            ));
    jsonCtrl.dispose();
    passCtrl.dispose();
  }

  Future<void> _import(BuildContext context) async {
    final input = TextEditingController();
    await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('导入当前账本更新'),
              content: TextField(
                  controller: input,
                  minLines: 3,
                  maxLines: 6,
                  decoration:
                      const InputDecoration(hintText: '粘贴伙伴的 SBILL1: 同步码')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () async {
                      if (await controller.importTripDelta(input.text)) {
                        if (ctx.mounted) Navigator.of(ctx).pop();
                      } else if (ctx.mounted) {
                        _error(ctx);
                      }
                    },
                    child: const Text('验签并导入'))
              ],
            ));
    input.dispose();
  }

  Future<void> _edit(BuildContext context,
      [ParticipantModel? participant]) async {
    final input = TextEditingController(text: participant?.displayName ?? '');
    var role = participant?.role ?? MemberRole.member;
    var active = participant?.active ?? true;
    var busy = false;
    await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, update) => AlertDialog(
                  title: Text(participant == null ? '添加同行伙伴' : '管理同行伙伴'),
                  content: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: input,
                        maxLength: 80,
                        decoration: const InputDecoration(labelText: '伙伴昵称')),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<MemberRole>(
                        initialValue: role,
                        decoration: const InputDecoration(labelText: '角色权限'),
                        items: [
                          for (final r in [
                            MemberRole.member,
                            MemberRole.financeEditor,
                            MemberRole.viewer
                          ])
                            DropdownMenuItem(value: r, child: Text(r.label))
                        ],
                        onChanged: busy
                            ? null
                            : (v) => update(() => role = v ?? role)),
                    if (participant != null)
                      SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('参与本次出行'),
                          subtitle: const Text('关闭即移出伙伴，历史账目和欠款仍保留'),
                          value: active,
                          onChanged:
                              busy ? null : (v) => update(() => active = v)),
                    const SizedBox(height: 8),
                    const Text(
                        '新伙伴先作为待认领参与人，不会在本机创建对方的私钥。移出或降权后，未同步的离线操作需要重新核对；对方已持有的历史数据无法远程收回。',
                        style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.mutedSlate,
                            height: 1.6)),
                  ])),
                  actions: [
                    TextButton(
                        onPressed: busy ? null : () => Navigator.of(ctx).pop(),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: busy
                            ? null
                            : () async {
                                update(() => busy = true);
                                final ok = participant == null
                                    ? await controller.addCompanion(
                                        input.text, role)
                                    : await controller.updateCompanion(
                                        id: participant.participantId,
                                        displayName: input.text,
                                        role: role,
                                        active: active);
                                if (!ctx.mounted) return;
                                update(() => busy = false);
                                if (ok) {
                                  Navigator.of(ctx).pop();
                                } else {
                                  _error(ctx);
                                }
                              },
                        child: const Text('保存'))
                  ],
                )));
    input.dispose();
  }

  Future<void> _claim(
      BuildContext context, ParticipantModel participant) async {
    final groupId = controller.snapshot!.groupId;
    final request = TextEditingController();
    Map<String, dynamic>? preview;
    String? welcome;
    String? key;
    var busy = false;
    await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, update) => AlertDialog(
                  title: Text('认领：${participant.displayName}'),
                  content: SizedBox(
                      width: 440,
                      child: SingleChildScrollView(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                            const Text('将下面两个编号给伙伴，让对方在自己的 App 点击“加入同行账本”生成申请。',
                                style: TextStyle(
                                    fontSize: 12, color: AppTheme.mutedSlate)),
                            const SizedBox(height: 8),
                            SelectableText(
                                '账本编号：$groupId\n伙伴编号：${participant.participantId}',
                                style: const TextStyle(fontSize: 12)),
                            TextButton(
                                onPressed: () => Clipboard.setData(ClipboardData(
                                    text:
                                        '$groupId\n${participant.participantId}')),
                                child: const Text('复制两个编号')),
                            if (welcome == null) ...[
                              TextField(
                                  controller: request,
                                  minLines: 3,
                                  maxLines: 5,
                                  onChanged: (_) =>
                                      update(() => preview = null),
                                  decoration: const InputDecoration(
                                      labelText: '粘贴对方认领申请',
                                      hintText: 'SBILL-CLAIM1:…')),
                              if (preview != null)
                                Padding(
                                    padding: const EdgeInsets.only(top: 12),
                                    child: Text(
                                        '申请人：${preview!['display_name']}\n身份指纹：${preview!['fingerprint']}\n请当面或通过可信渠道核对与对方 App 显示的指纹一致，再批准。',
                                        style: const TextStyle(
                                            fontSize: 12, height: 1.6))),
                            ] else ...[
                              const Text(
                                  '已绑定对方公钥。把加密加入包交给对方，并通过另一可信渠道传递访问密钥。两者合用能读取此账本，切勿公开。',
                                  style: TextStyle(fontSize: 12, height: 1.6)),
                              TextButton.icon(
                                  onPressed: () => Clipboard.setData(
                                      ClipboardData(text: welcome!)),
                                  icon: const Icon(Icons.copy),
                                  label: const Text('复制加密加入包')),
                              SelectableText('访问密钥：$key',
                                  style: const TextStyle(fontSize: 12)),
                              TextButton(
                                  onPressed: () => Clipboard.setData(
                                      ClipboardData(text: key!)),
                                  child: const Text('单独复制访问密钥')),
                            ],
                          ]))),
                  actions: [
                    TextButton(
                        onPressed: busy ? null : () => Navigator.of(ctx).pop(),
                        child: Text(welcome == null ? '取消' : '完成')),
                    if (welcome == null)
                      FilledButton(
                          onPressed: busy
                              ? null
                              : () async {
                                  update(() => busy = true);
                                  final ok = preview == null
                                      ? await controller
                                          .inspectClaim(request.text)
                                      : await controller.approveClaim(
                                          request.text,
                                          participant.participantId);
                                  if (!ctx.mounted) return;
                                  update(() {
                                    busy = false;
                                    if (ok) {
                                      if (preview == null) {
                                        preview = controller.claimPreview;
                                      } else {
                                        welcome = controller.transferCode;
                                        key = controller.accessKey;
                                      }
                                    }
                                  });
                                  if (!ok) _error(ctx);
                                },
                          child:
                              Text(preview == null ? '验签并查看申请' : '已核对指纹，批准认领'))
                  ],
                )));
    request.dispose();
  }
}
