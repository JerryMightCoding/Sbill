import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/ledger_models.dart';
import '../../state/ledger_controller.dart';
import '../theme/app_theme.dart';
import 'optical_qr_sync_screen.dart';

/// Clean, User-Centric Sync & Companions Tab (M6 & M7):
/// - Nearby LAN direct sync + Face-to-Face Animated QR entry at top
/// - 1-tap `.tripdelta` file sharing (Xiaomi Share / Quick Share / AirDrop) & code import
/// - WebDAV cloud store-and-forward status & 1-tap sync
/// - Companion list & role management
/// - Collapsible "Offline & Fault-Injection Drill Drawer" at the bottom so QA/demo controls
///   stay accessible without cluttering the everyday travel UI.
class SyncCenterScreen extends StatefulWidget {
  const SyncCenterScreen({
    super.key,
    required this.controller,
  });

  final LedgerController controller;

  @override
  State<SyncCenterScreen> createState() => _SyncCenterScreenState();
}

class _SyncCenterScreenState extends State<SyncCenterScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.checkIncomingSystemFileIntent();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final snap = widget.controller.snapshot;
        if (snap == null) {
          return const Center(child: CircularProgressIndicator());
        }

        final dav = snap.webDavStatus;
        final report = snap.lastSyncReport;
        final actor = snap.activeActor;

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            // 1. 最近一次同步结果温和反馈条
            AnimatedSize(
              duration: AppTheme.fastAnim,
              curve: AppTheme.smoothCurve,
              child: report != null
                  ? Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: report.failedUploads > 0
                              ? AppTheme.conflictAmber.withValues(alpha: 0.12)
                              : AppTheme.primaryTeal.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              report.failedUploads > 0
                                  ? Icons.cloud_off_rounded
                                  : Icons.check_circle_outline_rounded,
                              size: 20,
                              color: report.failedUploads > 0
                                  ? AppTheme.conflictAmber
                                  : AppTheme.primaryTeal,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                report.summaryTitle,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),

            // 2. 面对面与局域网直连（无需公网）
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.wifi_tethering_rounded,
                          size: 20,
                          color: AppTheme.primaryTeal,
                        ),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            '附近同伴直连 (无需公网)',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: () {
                            HapticFeedback.selectionClick();
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => OpticalQrSyncScreen(
                                  controller: widget.controller,
                                ),
                              ),
                            );
                          },
                          icon: const Icon(Icons.qr_code_2_rounded, size: 17),
                          label: const Text('面对面扫码传账'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (snap.lanStatus.apIsolationDetected)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppTheme.conflictAmber.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Text(
                          '当前酒店 Wi-Fi 开启了客户端隔离，设备间无法直接互通。请开启手机热点或使用右上角「面对面扫码传账」。',
                          style: TextStyle(fontSize: 12),
                        ),
                      )
                    else ...[
                      ...snap.lanStatus.discoveredPeers.map((peer) {
                        return Container(
                          margin: const EdgeInsets.only(top: 8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.surfaceBg,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.smartphone_rounded,
                                size: 18,
                                color: AppTheme.primaryTeal,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      peer.displayName,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 14,
                                      ),
                                    ),
                                    Text(
                                      '同一局域网在线 · 已同步至 #${peer.contiguousSeq}',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: AppTheme.mutedSlate,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              FilledButton.tonal(
                                onPressed: () {
                                  HapticFeedback.lightImpact();
                                  widget.controller.syncLanWithPeer(
                                    peerMemberId: peer.memberId,
                                    simulateGapFill: true,
                                  );
                                },
                                child: const Text('立即同步'),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),

            // 3. 系统文件互传（小米互传 / Quick Share / 隔空投送）与 WebDAV 异步留存
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '文件互传与云端留存',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      '支持通过小米互传 / Quick Share / 微信发送加密账本包 (.tripdelta)，或通过个人 WebDAV 错峰同步。',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.mutedSlate,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () {
                              HapticFeedback.lightImpact();
                              widget.controller.shareTripDeltaViaSystemSheet();
                            },
                            icon: const Icon(Icons.ios_share_rounded, size: 17),
                            label: const Text('发送加密同步包'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _showImportTripDeltaDialog(context),
                            icon: const Icon(
                              Icons.download_done_rounded,
                              size: 17,
                            ),
                            label: const Text('导入同步包/口令'),
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'WebDAV 加密异步留存',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                ),
                              ),
                              Text(
                                dav.pendingUploadCount > 0
                                    ? '有 ${dav.pendingUploadCount} 条加密变更待上传 · 远端已存 ${dav.remoteObjectCount} 条'
                                    : '已全部上传 · 远端密文对象 ${dav.remoteObjectCount} 个',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.mutedSlate,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () =>
                              _showConfigureWebDavDialog(context, dav),
                          icon: const Icon(Icons.settings_outlined, size: 20),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: () {
                            HapticFeedback.lightImpact();
                            widget.controller.syncWebDavNow();
                          },
                          icon: const Icon(Icons.sync_rounded, size: 16),
                          label: const Text('同步'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),

            // 4. 同行伙伴与权限管理
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          '同行伙伴 (${snap.participants.length})',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                        ),
                        const Spacer(),
                        if (actor.role.canManageMembers)
                          TextButton.icon(
                            onPressed: () =>
                                _showAddParticipantDialog(context, snap),
                            icon: const Icon(Icons.person_add_alt_1, size: 16),
                            label: const Text('添加伙伴'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ...snap.participants.map((p) {
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          radius: 17,
                          backgroundColor:
                              AppTheme.primaryTeal.withValues(alpha: 0.12),
                          child: Text(
                            p.participantId,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 13,
                              color: AppTheme.primaryTeal,
                            ),
                          ),
                        ),
                        title: Text(
                          p.displayName,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          p.hasBoundDevice ? '已绑定设备公钥' : '仅记账参与人 (未安装 App)',
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.surfaceBg,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            p.role.label,
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),

            // 5. 折叠式「离线与异常场景演练台」（不干扰日常洁净 UI，点开即可一键验收边缘用例）
            Card(
              child: ExpansionTile(
                shape: const Border(),
                leading: const Icon(
                  Icons.science_outlined,
                  size: 20,
                  color: AppTheme.mutedSlate,
                ),
                title: const Text(
                  '离线与异常场景演练台 (验收测试工具)',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.mutedSlate,
                  ),
                ),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      '模拟酒店 Wi-Fi 开启 AP 隔离 (AC-L02)',
                      style: TextStyle(fontSize: 12),
                    ),
                    value: snap.lanStatus.apIsolationDetected,
                    onChanged: (v) {
                      widget.controller.configureLanDiscovery(
                        apIsolationDetected: v,
                      );
                    },
                  ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      '模拟无公网 / WebDAV 暂不可达 (AC-D02)',
                      style: TextStyle(fontSize: 12),
                    ),
                    value: dav.simulateUnreachable,
                    onChanged: (v) {
                      widget.controller.configureWebDav(
                        endpointUrl: dav.endpointUrl,
                        username: dav.username,
                        simulateUnreachable: v,
                      );
                    },
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: () {
                          widget.controller.simulatePeerTripDelta(
                            autoImport: true,
                          );
                        },
                        child: const Text(
                          '模拟收到同伴 .tripdelta 互传包',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                      OutlinedButton(
                        onPressed: () async {
                          await widget.controller.simulateRemoteWebDavIncoming(
                            injectTampered: true,
                          );
                          await widget.controller.syncWebDavNow();
                        },
                        child: const Text(
                          '模拟错峰上传 + 服务端篡改拦截 (AC-D05)',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showImportTripDeltaDialog(BuildContext context) async {
    await widget.controller.exportTripDelta();
    final textCtrl = TextEditingController(
      text: widget.controller.snapshot?.lastSyncReport?.exportedCompactCode ??
          '',
    );
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('复制或导入加密同步码'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '下方已生成本机最新 SBILL1: 紧凑加密同步码，可复制发给同伴，或粘贴同伴发来的同步码导入。',
                style: TextStyle(fontSize: 12, color: AppTheme.mutedSlate),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: textCtrl,
                maxLines: 4,
                decoration: const InputDecoration(
                  hintText: '粘贴 SBILL1:... 同步码',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: textCtrl.text));
                if (ctx.mounted) Navigator.of(ctx).pop();
              },
              child: const Text('复制本机同步码'),
            ),
            FilledButton(
              onPressed: () async {
                final ok = await widget.controller.importTripDelta(
                  textCtrl.text,
                );
                if (ok && ctx.mounted) {
                  Navigator.of(ctx).pop();
                }
              },
              child: const Text('验签并导入'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showConfigureWebDavDialog(
    BuildContext context,
    WebDavStatusModel current,
  ) async {
    final urlCtrl = TextEditingController(text: current.endpointUrl);
    final userCtrl = TextEditingController(text: current.username);

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('配置 WebDAV 留存节点'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: urlCtrl,
                decoration: const InputDecoration(
                  labelText: 'WebDAV HTTPS 地址',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: userCtrl,
                decoration: const InputDecoration(
                  labelText: '应用专用账号 (勿填 NAS 主账号)',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                final ok = await widget.controller.configureWebDav(
                  endpointUrl: urlCtrl.text,
                  username: userCtrl.text,
                  simulateUnreachable: current.simulateUnreachable,
                );
                if (ok && ctx.mounted) Navigator.of(ctx).pop();
              },
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showAddParticipantDialog(
    BuildContext context,
    UiWorkspaceSnapshotModel snap,
  ) async {
    final idCtrl =
        TextEditingController(text: 'M${snap.participants.length + 1}');
    final nameCtrl = TextEditingController();
    MemberRole role = MemberRole.member;
    bool bindKey = true;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Text('添加同行伙伴'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: '伙伴昵称'),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<MemberRole>(
                    value: role,
                    decoration: const InputDecoration(labelText: '角色权限'),
                    items: const [
                      DropdownMenuItem(
                        value: MemberRole.financeEditor,
                        child: Text('财务管理员 (可协助改账/合并冲突)'),
                      ),
                      DropdownMenuItem(
                        value: MemberRole.member,
                        child: Text('普通成员'),
                      ),
                    ],
                    onChanged: (v) {
                      if (v != null) setDialogState(() => role = v);
                    },
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      '本人使用 App 参与对账',
                      style: TextStyle(fontSize: 13),
                    ),
                    subtitle: const Text(
                      '关闭则作为未装 App 的同行亲友代记账 (AC-G02)',
                      style: TextStyle(fontSize: 11),
                    ),
                    value: bindKey,
                    onChanged: (v) => setDialogState(() => bindKey = v),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () async {
                    if (nameCtrl.text.trim().isNotEmpty) {
                      await widget.controller.addParticipant(
                        participantId: idCtrl.text.trim(),
                        displayName: nameCtrl.text.trim(),
                        role: role,
                        bindDeviceKey: bindKey,
                      );
                      if (ctx.mounted) Navigator.of(ctx).pop();
                    }
                  },
                  child: const Text('添加'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
