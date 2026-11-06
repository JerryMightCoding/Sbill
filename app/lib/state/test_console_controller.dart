import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../build_config.dart';
import '../models/ledger_models.dart';
import 'ledger_controller.dart';

class TestIdentity {
  const TestIdentity(this.id, this.label);
  final String id;
  final String label;
  static const all = [
    TestIdentity('primary', '身份 A'),
    TestIdentity('peer_b', '身份 B'),
    TestIdentity('peer_c', '身份 C'),
    TestIdentity('viewer', '身份 D'),
  ];
}

class TestConsoleController extends ChangeNotifier {
  TestConsoleController(this.ledger, {this.closeRoutes});
  static const _channel = MethodChannel('com.sbill.app/fileshare');
  final LedgerController ledger;
  final Future<void> Function()? closeRoutes;
  bool _disposed = false;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  bool ready = false;
  bool busy = false;
  String activeProfile = 'primary';
  String status = '正在检查测试构建…';

  void _requireEnabled() {
    if (!testToolsEnabled) throw StateError('普通版不开放开发者控制台');
  }

  Future<void> initialize() async {
    _requireEnabled();
    try {
      final config = await _channel
          .invokeMapMethod<String, dynamic>('getTestConsoleConfig');
      if (config?['enabled'] != true) throw StateError('原生构建未启用测试工具，操作已禁用');
      final profile = config!['active_profile'] as String;
      if (!TestIdentity.all.any((p) => p.id == profile)) {
        throw StateError('未知测试身份');
      }
      activeProfile = profile;
      ready = true;
      status = '独立测试身份；不会读取普通版的数据。';
    } catch (e) {
      status = e.toString();
    }
    _changed();
  }

  Future<void> _open(String profile, {bool persist = true}) async {
    final path = await _channel.invokeMethod<String>(
        'getTestProfileDatabasePath', {'profile': profile});
    if (path == null || path.isEmpty) throw StateError('无法获取测试身份目录');
    if (!await ledger.openTestWorkspace(path)) {
      throw StateError(ledger.lastError ?? '打开测试身份失败');
    }
    activeProfile = profile;
    if (persist &&
        await _channel.invokeMethod<bool>(
                'persistTestProfile', {'profile': profile}) !=
            true) {
      throw StateError('无法保存测试身份选择');
    }
    _changed();
  }

  Future<void> _run(Future<void> Function() operation) async {
    _requireEnabled();
    if (!ready || busy || ledger.isLoading) return;
    busy = true;
    ledger.setTestSessionBusy(true);
    _changed();
    try {
      await closeRoutes?.call();
      await operation();
    } catch (e) {
      status = e.toString();
    } finally {
      ledger.setTestSessionBusy(false);
      busy = false;
      _changed();
    }
  }

  Future<void> switchProfile(String profile) => _run(() async {
        if (!TestIdentity.all.any((p) => p.id == profile)) {
          throw StateError('未知测试身份');
        }
        final previous = activeProfile;
        try {
          await _open(profile);
          status =
              '已切换${TestIdentity.all.firstWhere((p) => p.id == profile).label}，使用该身份自己的私钥和账本目录。';
        } catch (e) {
          try {
            await _open(previous);
          } catch (restoreError) {
            throw StateError('切换失败：$e；恢复原身份也失败：$restoreError');
          }
          rethrow;
        }
      });

  Future<void> refresh() => _run(() async {
        if (!await ledger.refreshTestState()) {
          throw StateError(ledger.lastError ?? '刷新失败');
        }
        status = '已从 Rust 核心重新读取状态。';
      });

  Future<void> prepareSharedLedger() => _run(() async {
        final previous = activeProfile;
        try {
          await _open('primary', persist: false);
          if (!await ledger.createLedger(
              groupName: '四身份联调账本',
              displayName: '测试 A',
              companions: ['测试 B', '测试 C', '测试 D'])) {
            throw StateError(ledger.lastError ?? '创建联调账本失败');
          }
          final snapshot = ledger.snapshot!;
          final groupId = snapshot.groupId;
          final peers = <String, ParticipantModel>{
            for (final p
                in snapshot.participants.where((p) => p.boundPublicKey == null))
              p.displayName: p,
          };
          final roles = [
            MemberRole.financeEditor,
            MemberRole.member,
            MemberRole.viewer
          ];
          for (var i = 1; i < TestIdentity.all.length; i++) {
            final profile = TestIdentity.all[i];
            final peer = peers['测试 ${String.fromCharCode(65 + i)}']!;
            if (!await ledger.updateCompanion(
                id: peer.participantId,
                displayName: peer.displayName,
                role: roles[i - 1],
                active: true)) {
              throw StateError(ledger.lastError ?? '配置伙伴失败');
            }
            await _open(profile.id, persist: false);
            if (!await ledger.createClaim(
                groupId: groupId,
                participantId: peer.participantId,
                displayName: peer.displayName)) {
              throw StateError(ledger.lastError ?? '生成申请失败');
            }
            final request = ledger.transferCode!;
            await _open('primary', persist: false);
            if (!await ledger.approveClaim(request, peer.participantId)) {
              throw StateError(ledger.lastError ?? '认领失败');
            }
            final welcome = ledger.transferCode!;
            final key = ledger.accessKey!;
            await _open(profile.id, persist: false);
            if (!await ledger.joinLedger(welcome, key)) {
              throw StateError(ledger.lastError ?? '加入失败');
            }
            await _open('primary', persist: false);
          }
          // Earlier peers need the later owner-signed role/claim policies as well.
          if (!await ledger.exportTripDelta()) {
            throw StateError(ledger.lastError ?? '导出政策失败');
          }
          final update = ledger.snapshot!.lastSyncReport!.exportedCompactCode!;
          for (final profile in TestIdentity.all.skip(1)) {
            await _open(profile.id, persist: false);
            if (!await ledger.importTripDelta(update)) {
              throw StateError(ledger.lastError ?? '同步政策失败');
            }
          }
          await _open('primary');
          status = '联调账本已准备：A 主人、B 财务、C 成员、D 只读。四个独立身份已认领同一本空账本，没有示例账目。';
        } catch (e) {
          try {
            await _open(previous);
          } catch (restoreError) {
            throw StateError('准备失败：$e；恢复原身份失败：$restoreError');
          }
          rethrow;
        }
      });

  Future<void> syncSharedLedger() => _run(() async {
        final previous = activeProfile;
        final groupId = ledger.snapshot?.groupId;
        if (groupId == null) throw StateError('请先进入要联调的账本');
        try {
          final codes = <String>[];
          for (final profile in TestIdentity.all) {
            await _open(profile.id, persist: false);
            if (!ledger.ledgers.any((entry) => entry.groupId == groupId)) {
              throw StateError('${profile.label}尚未加入当前账本，请先完成认领');
            }
            if (!await ledger.selectLedger(groupId) ||
                !await ledger.exportTripDelta()) {
              throw StateError(ledger.lastError ?? '导出失败');
            }
            codes.add(ledger.snapshot!.lastSyncReport!.exportedCompactCode!);
          }
          for (final profile in TestIdentity.all) {
            await _open(profile.id, persist: false);
            for (final code in codes) {
              if (!await ledger.importTripDelta(code)) {
                throw StateError(ledger.lastError ?? '导入失败');
              }
            }
          }
          await _open(previous);
          status = '四个身份的当前账本已通过真实加密事件包交换完成同步（同机测试，不是网络直连）。';
        } catch (e) {
          try {
            await _open(previous);
          } catch (restoreError) {
            throw StateError('同步失败：$e；恢复原身份失败：$restoreError');
          }
          rethrow;
        }
      });
}
