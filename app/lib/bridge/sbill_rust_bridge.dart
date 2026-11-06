import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import '../models/ledger_models.dart';

typedef _InvokeJsonNative = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>);
typedef _InvokeJsonDart = ffi.Pointer<Utf8> Function(ffi.Pointer<Utf8>);

typedef _FreeStringNative = ffi.Void Function(ffi.Pointer<Utf8>);
typedef _FreeStringDart = void Function(ffi.Pointer<Utf8>);

/// Asynchronous bridge to `rust_core` (`libsbill_core.so` on Android, `libsbill_core.dylib` on macOS).
/// All calls execute inside a background Dart `Isolate.run` so the Flutter UI thread is never blocked.
class SbillRustBridge {
  SbillRustBridge._();
  static final SbillRustBridge instance = SbillRustBridge._();

  bool _nativeLoaded = false;
  bool get isNativeRustLoaded => _nativeLoaded;

  static String? _resolveDynamicLibraryPath() {
    if (Platform.isAndroid) {
      return 'libsbill_core.so';
    }
    if (Platform.isMacOS) {
      final candidates = [
        '/Users/Jerry/Documents/Sbill/rust_core/target/release/libsbill_core.dylib',
        '/Users/Jerry/Documents/Sbill/rust_core/target/debug/libsbill_core.dylib',
        'libsbill_core.dylib',
      ];
      for (final p in candidates) {
        if (File(p).existsSync()) return p;
      }
    }
    return null;
  }

  Future<UiWorkspaceSnapshotModel> invokeCommand(
    Map<String, dynamic> command,
  ) async {
    final requestJson = jsonEncode(command);
    final libPath = _resolveDynamicLibraryPath();

    if (libPath != null || Platform.isIOS) {
      try {
        final responseJson = await Isolate.run(
          () => _invokeNativeInBackgroundIsolate(requestJson, libPath),
        );
        _nativeLoaded = true;
        final decoded =
            Map<String, dynamic>.from(jsonDecode(responseJson) as Map);
        if (decoded['ok'] != true) {
          throw StateError(decoded['error'] as String? ?? 'Rust 核心校验未通过');
        }
        return UiWorkspaceSnapshotModel.fromJson(
          Map<String, dynamic>.from(decoded['snapshot'] as Map),
        );
      } on ArgumentError catch (e) {
        // Native library missing or not loadable on this ABI; fall back to the
        // deterministic engine, but keep the reason visible instead of hiding it.
        debugPrint(
            'sbill_core native load failed (${libPath ?? 'process'}): $e');
      }
    }

    _nativeLoaded = false;
    return _FallbackDeterministicEngine.instance.execute(command);
  }

  Future<Map<String, dynamic>> invokeAppCommand(
      Map<String, dynamic> command) async {
    final libPath = _resolveDynamicLibraryPath();
    if (libPath == null && !Platform.isIOS) {
      throw StateError('本机 Rust 存储核心不可用，已停止启动以避免丢失账目');
    }
    final request = jsonEncode(command);
    final response = await Isolate.run(
      () => _invokeNativeInBackgroundIsolate(request, libPath),
    );
    _nativeLoaded = true;
    final decoded = Map<String, dynamic>.from(jsonDecode(response) as Map);
    if (decoded['ok'] != true) {
      throw StateError(decoded['error'] as String? ?? '账本操作失败');
    }
    return Map<String, dynamic>.from(decoded['workspace'] as Map);
  }

  static String _invokeNativeInBackgroundIsolate(
    String requestJson,
    String? libPath,
  ) {
    final dylib = Platform.isIOS
        ? ffi.DynamicLibrary.process()
        : ffi.DynamicLibrary.open(libPath!);

    final invoke = dylib.lookupFunction<_InvokeJsonNative, _InvokeJsonDart>(
      'sbill_core_invoke_json',
    );
    final freeStr = dylib.lookupFunction<_FreeStringNative, _FreeStringDart>(
      'sbill_core_free_string',
    );

    final reqPtr = requestJson.toNativeUtf8();
    ffi.Pointer<Utf8> respPtr = ffi.nullptr;
    try {
      respPtr = invoke(reqPtr);
      if (respPtr == ffi.nullptr) {
        return '{"ok":false,"error":"null response pointer from rust_core"}';
      }
      return respPtr.toDartString();
    } finally {
      calloc.free(reqPtr);
      if (respPtr != ffi.nullptr) {
        freeStr(respPtr);
      }
    }
  }
}

/// Deterministic fallback engine matching `rust_core` rules (M4 & M5) so UI tests and previews
/// work even before `cargo ndk` builds `libsbill_core.so`.
class _FallbackDeterministicEngine {
  _FallbackDeterministicEngine._();
  static final _FallbackDeterministicEngine instance =
      _FallbackDeterministicEngine._();

  String _activeActorId = 'A';
  int _seqCounter = 3;

  final List<ParticipantModel> _participants = [];
  final List<FxRateSpecModel> _fxRates = [];
  final List<ExpenseCategoryModel> _customCategories = [];
  final List<UiExpenseViewModel> _expenses = [];
  final List<RepaymentItemModel> _repayments = [];
  final List<SettlementObligationModel> _activeObligations = [];
  final List<SnapshotProjectionModel> _snapshots = [];
  final Map<String, String> _settledExpenseRevisions = {};
  WebDavStatusModel _webDavStatus = const WebDavStatusModel(
    enabled: true,
    endpointUrl: 'https://nas.local:5006/webdav/sbill_app',
    username: 'sbill_trip_member',
    opaqueGroupDir: 'opaque_trip_autumn_2026',
    simulateUnreachable: false,
    pendingUploadCount: 3,
    remoteObjectCount: 0,
  );
  SyncActivityReportModel? _lastSyncReport;
  bool _apIsolation = false;
  bool _opticalSlowMode = false;
  bool _opticalComplete = false;
  int _opticalSolved = 0;
  int _opticalTotal = 6;
  int _peerSimCounter = 100;
  int _pendingPulledEvents = 0;
  int _pendingRejectedObjects = 0;

  void _ensureInitialized() {
    if (_participants.isNotEmpty) return;
    _resetState();
  }

  void _resetState() {
    _activeActorId = 'A';
    _seqCounter = 3;
    _participants
      ..clear()
      ..addAll(const [
        ParticipantModel(
          participantId: 'A',
          displayName: '阿杰 (群主)',
          boundPublicKey: 'ed25519_pk_A',
          role: MemberRole.owner,
          active: true,
        ),
        ParticipantModel(
          participantId: 'B',
          displayName: '白露 (财务管理员)',
          boundPublicKey: 'ed25519_pk_B',
          role: MemberRole.financeEditor,
          active: true,
        ),
        ParticipantModel(
          participantId: 'C',
          displayName: '程远 (成员)',
          boundPublicKey: 'ed25519_pk_C',
          role: MemberRole.member,
          active: true,
        ),
        ParticipantModel(
          participantId: 'D',
          displayName: '丁宁 (成员)',
          boundPublicKey: 'ed25519_pk_D',
          role: MemberRole.member,
          active: true,
        ),
      ]);
    _fxRates
      ..clear()
      ..addAll(const [
        FxRateSpecModel(
          baseCurrency: 'USD',
          quoteCurrency: 'CNY',
          numerator: 7,
          denominator: 1,
        ),
        FxRateSpecModel(
          baseCurrency: 'JPY',
          quoteCurrency: 'CNY',
          numerator: 1,
          denominator: 20,
        ),
      ]);
    _expenses.clear();
    _customCategories.clear();
    _repayments.clear();
    _activeObligations.clear();
    _snapshots.clear();
    _settledExpenseRevisions.clear();
    _pendingPulledEvents = 0;
    _pendingRejectedObjects = 0;
    _seedInitialExpenses();
  }

  Future<UiWorkspaceSnapshotModel> execute(Map<String, dynamic> cmd) async {
    _ensureInitialized();
    final op = cmd['op'] as String;
    final args = cmd['args'] != null
        ? Map<String, dynamic>.from(cmd['args'] as Map)
        : <String, dynamic>{};

    switch (op) {
      case 'InitOrGetSnapshot':
      case 'OpenPersistentWorkspace':
        break;
      case 'ResetDemoWorkspace':
        _resetState();
        break;
      case 'SwitchActor':
        _activeActorId = args['actor_id'] as String;
        break;
      case 'SetFxRate':
        final base = args['base_currency'] as String;
        final quote = args['quote_currency'] as String;
        final numVal = (args['numerator'] as num).toInt();
        final denVal = (args['denominator'] as num).toInt();
        if (numVal <= 0 || denVal <= 0) {
          throw StateError('汇率分子和分母必须为正整数');
        }
        final idx = _fxRates.indexWhere(
          (r) => r.baseCurrency == base && r.quoteCurrency == quote,
        );
        final updated = FxRateSpecModel(
          baseCurrency: base,
          quoteCurrency: quote,
          numerator: numVal,
          denominator: denVal,
        );
        if (idx >= 0) {
          _fxRates[idx] = updated;
        } else {
          _fxRates.add(updated);
        }
        break;
      case 'AddParticipant':
        final actor = _participants.firstWhere(
          (p) => p.participantId == (args['actor_id'] as String),
        );
        if (!actor.role.canManageMembers) {
          throw StateError('权限拒绝：仅群主可添加或管理成员角色');
        }
        _participants.add(
          ParticipantModel(
            participantId: args['participant_id'] as String,
            displayName: args['display_name'] as String,
            boundPublicKey: (args['bind_device_key'] as bool? ?? true)
                ? 'ed25519_bound'
                : null,
            role: MemberRole.fromWire(args['role'] as String),
            active: true,
          ),
        );
        _seqCounter++;
        break;
      case 'UpsertExpense':
        _handleUpsertExpense(args);
        break;
      case 'SimulateConcurrentConflict':
        _handleSimulateConflict(args['expense_id'] as String);
        break;
      case 'DeclareRepayment':
        _repayments.add(
          RepaymentItemModel(
            paymentId: args['payment_id'] as String,
            declareEventId: 'ev_pay_${++_seqCounter}',
            confirmEventId: null,
            payerId: args['payer_id'] as String,
            payeeId: args['payee_id'] as String,
            currency: args['currency'] as String,
            amountMinor: (args['amount_minor'] as num).toInt(),
            targetObligationId: args['target_obligation_id'] as String?,
            note: args['note'] as String? ?? '',
            statusLabel: '付款方已声明 (待收款方确认)',
            isConfirmed: false,
            overpaymentMinor: 0,
          ),
        );
        break;
      case 'ConfirmRepayment':
        _handleConfirmRepayment(args);
        break;
      case 'ProposeSettlement':
        _handleProposeSettlement(args);
        break;
      case 'ApproveSettlement':
        _handleApproveSettlement(args);
        break;
      case 'CommitSettlement':
        _handleCommitSettlement(args);
        break;
      case 'ExportTripDelta':
        final payloadJson = jsonEncode({
          'magic': 'SBILL_TRIPDELTA_V1',
          'group_id': 'trip_autumn_2026',
          'event_count': _seqCounter,
        });
        final compact =
            'SBILL1:${base64Url.encode(utf8.encode(payloadJson)).replaceAll("=", "")}';
        _lastSyncReport = SyncActivityReportModel(
          channel: '文件互传 (.tripdelta)',
          summaryTitle: '已打包 $_seqCounter 条签名事件 (${payloadJson.length} 字节)',
          addedEvents: 0,
          duplicateEvents: _seqCounter,
          rejectedOrTampered: 0,
          uploadedObjects: 0,
          failedUploads: 0,
          packageByteLen: payloadJson.length,
          packageDigest: 'blake3_pack_v1',
          exportedTripdeltaJson: payloadJson,
          exportedCompactCode: compact,
        );
        break;
      case 'ImportTripDelta':
        final raw = (args['payload'] as String? ?? '').trim();
        if (raw.isEmpty ||
            (!raw.startsWith('SBILL1:') && !raw.startsWith('{'))) {
          throw StateError('无效或截断的 .tripdelta 同步包');
        }
        _lastSyncReport = SyncActivityReportModel(
          channel: '导入 .tripdelta 同步包',
          summaryTitle: '导入完成：新增 0 条，重复跳过 $_seqCounter 条，拒绝 0 条',
          addedEvents: 0,
          duplicateEvents: _seqCounter,
          rejectedOrTampered: 0,
          uploadedObjects: 0,
          failedUploads: 0,
          packageByteLen: raw.length,
          packageDigest: 'blake3_pack_v1',
        );
        break;
      case 'SimulatePeerTripDelta':
        final autoImport = args['auto_import'] as bool? ?? true;
        final idx = ++_peerSimCounter;
        if (autoImport) {
          _handleUpsertExpense({
            'actor_id': 'D',
            'expense_id': 'exp_peer_delta_$idx',
            'parent_revision_event_ids': const <String>[],
            'currency': 'CNY',
            'total_minor': 32000,
            'payers': const [
              {'participant_id': 'D', 'amount_minor': 32000},
            ],
            'split_rule': const {
              'Equal': {
                'participants': ['A', 'B', 'C', 'D'],
              },
            },
            'title': '同伴互传账单 #$idx (景区观光车)',
            'note': '由丁宁手机离线生成并通过 .tripdelta 互传导入',
            'revision_reason': '同伴离线创建',
            'voided': false,
          });
        }
        const sampleCode = 'SBILL1:eyJtYWdpYyI6IlNCSIxMX1RSSVBERUxUQV9WMSJ9';
        _lastSyncReport = SyncActivityReportModel(
          channel: '导入 .tripdelta 同步包',
          summaryTitle: autoImport
              ? '导入完成：新增 1 条，重复跳过 0 条，拒绝 0 条'
              : '已生成外部同伴 .tripdelta 包',
          addedEvents: autoImport ? 1 : 0,
          duplicateEvents: 0,
          rejectedOrTampered: 0,
          uploadedObjects: 0,
          failedUploads: 0,
          packageByteLen: 512,
          packageDigest: 'blake3_peer_$idx',
          exportedTripdeltaJson: '{"magic":"SBILL_TRIPDELTA_V1"}',
          exportedCompactCode: sampleCode,
        );
        break;
      case 'ConfigureWebDav':
        _webDavStatus = WebDavStatusModel(
          enabled: true,
          endpointUrl: args['endpoint_url'] as String,
          username: args['username'] as String,
          opaqueGroupDir: _webDavStatus.opaqueGroupDir,
          simulateUnreachable: args['simulate_unreachable'] as bool? ?? false,
          pendingUploadCount: _webDavStatus.pendingUploadCount,
          remoteObjectCount: _webDavStatus.remoteObjectCount,
        );
        break;
      case 'SyncWebDavNow':
        if (_webDavStatus.simulateUnreachable) {
          _lastSyncReport = SyncActivityReportModel(
            channel: 'WebDAV 异步留存通道',
            summaryTitle:
                'WebDAV 暂不可达：${_webDavStatus.pendingUploadCount} 个密文对象保留在待传队列',
            addedEvents: 0,
            duplicateEvents: 0,
            rejectedOrTampered: 0,
            uploadedObjects: 0,
            failedUploads: _webDavStatus.pendingUploadCount,
            packageByteLen: 0,
          );
        } else {
          final uploaded = _webDavStatus.pendingUploadCount;
          _webDavStatus = WebDavStatusModel(
            enabled: true,
            endpointUrl: _webDavStatus.endpointUrl,
            username: _webDavStatus.username,
            opaqueGroupDir: _webDavStatus.opaqueGroupDir,
            simulateUnreachable: false,
            pendingUploadCount: 0,
            remoteObjectCount: _webDavStatus.remoteObjectCount + uploaded,
          );
          final pulled = _pendingPulledEvents;
          final rejected = _pendingRejectedObjects;
          _pendingPulledEvents = 0;
          _pendingRejectedObjects = 0;
          _lastSyncReport = SyncActivityReportModel(
            channel: 'WebDAV 异步留存通道',
            summaryTitle:
                'WebDAV 同步完成：上传 $uploaded 个对象，拉取新增 $pulled 条事件，拦截篡改 $rejected 个',
            addedEvents: pulled,
            duplicateEvents: _seqCounter,
            rejectedOrTampered: rejected,
            uploadedObjects: uploaded,
            failedUploads: 0,
            packageByteLen: 0,
          );
        }
        break;
      case 'SimulateRemoteWebDavIncoming':
        final injectTampered = args['inject_tampered'] as bool? ?? false;
        final idx = ++_peerSimCounter;
        _handleUpsertExpense({
          'actor_id': 'C',
          'expense_id': 'exp_webdav_async_$idx',
          'parent_revision_event_ids': const <String>[],
          'currency': 'CNY',
          'total_minor': 24000,
          'payers': const [
            {'participant_id': 'C', 'amount_minor': 24000},
          ],
          'split_rule': const {
            'Equal': {
              'participants': ['A', 'B', 'C', 'D'],
            },
          },
          'title': '错峰留存账单 #$idx (夜间便利店补给)',
          'note': '程远夜间上传至 WebDAV 留存节点',
          'revision_reason': '错峰异步上传',
          'voided': false,
        });
        _webDavStatus = WebDavStatusModel(
          enabled: true,
          endpointUrl: _webDavStatus.endpointUrl,
          username: _webDavStatus.username,
          opaqueGroupDir: _webDavStatus.opaqueGroupDir,
          simulateUnreachable: _webDavStatus.simulateUnreachable,
          pendingUploadCount: _webDavStatus.pendingUploadCount,
          remoteObjectCount: _webDavStatus.remoteObjectCount + 1,
        );
        _pendingPulledEvents += 1;
        if (injectTampered) {
          _pendingRejectedObjects += 1;
        }
        _lastSyncReport = SyncActivityReportModel(
          channel: 'WebDAV 异步留存通道',
          summaryTitle:
              'WebDAV 同步完成：拉取新增 1 条事件，拦截篡改 ${injectTampered ? 1 : 0} 个',
          addedEvents: 1,
          duplicateEvents: 0,
          rejectedOrTampered: injectTampered ? 1 : 0,
          uploadedObjects: 0,
          failedUploads: 0,
          packageByteLen: 0,
        );
        break;
      case 'ConfigureLanDiscovery':
        _apIsolation = args['ap_isolation_detected'] as bool? ?? false;
        if (_apIsolation) {
          _lastSyncReport = const SyncActivityReportModel(
            channel: '局域网直连 (LAN)',
            summaryTitle: '检测到当前 Wi-Fi 开启了 AP 客户端隔离，建议切换手机热点或动态二维码通道 (AC-L02)',
            addedEvents: 0,
            duplicateEvents: 0,
            rejectedOrTampered: 0,
            uploadedObjects: 0,
            failedUploads: 0,
            packageByteLen: 0,
          );
        }
        break;
      case 'SyncLanWithPeer':
        if (_apIsolation) {
          throw StateError('当前路由器启用了 AP 客户端隔离，局域网设备无法直接互通 (AC-L02)');
        }
        final peerId = args['peer_member_id'] as String;
        final gapFill = args['simulate_gap_fill'] as bool? ?? false;
        final idx = ++_peerSimCounter;
        _handleUpsertExpense({
          'actor_id': peerId,
          'expense_id': 'exp_lan_${idx}_1',
          'parent_revision_event_ids': const <String>[],
          'currency': 'CNY',
          'total_minor': 16000,
          'payers': [
            {'participant_id': peerId, 'amount_minor': 16000},
          ],
          'split_rule': const {
            'Equal': {
              'participants': ['A', 'B', 'C', 'D'],
            },
          },
          'title': '局域网同步账单 #$idx-1 (山地缆车)',
          'note': '无公网环境下通过局域网直连同步',
          'revision_reason': '同伴创建',
          'voided': false,
        });
        if (gapFill) {
          _handleUpsertExpense({
            'actor_id': peerId,
            'expense_id': 'exp_lan_${idx}_2',
            'parent_revision_event_ids': const <String>[],
            'currency': 'CNY',
            'total_minor': 8000,
            'payers': [
              {'participant_id': peerId, 'amount_minor': 8000},
            ],
            'split_rule': const {
              'Equal': {
                'participants': ['A', 'B', 'C', 'D'],
              },
            },
            'title': '局域网同步账单 #$idx-2 (山顶热饮)',
            'note': '补齐序号缺口后激活入账',
            'revision_reason': '同伴创建',
            'voided': false,
          });
        }
        _lastSyncReport = SyncActivityReportModel(
          channel: gapFill ? '局域网无公网直连 (LAN + 缺口补齐)' : '局域网无公网直连 (LAN)',
          summaryTitle: gapFill
              ? '已与成员 $peerId 完成无公网直连同步，精准补齐序号缺口并激活 2 条账单 (AC-L04)'
              : '已与成员 $peerId 完成局域网直连增量同步 (AC-L01)',
          addedEvents: gapFill ? 2 : 1,
          duplicateEvents: 0,
          rejectedOrTampered: 0,
          uploadedObjects: 0,
          failedUploads: 0,
          packageByteLen: 0,
        );
        break;
      case 'GenerateOpticalFrames':
        _opticalSlowMode = args['slow_mode'] as bool? ?? false;
        break;
      case 'IngestOpticalFrame':
        _opticalSolved = (_opticalSolved + 1).clamp(0, _opticalTotal);
        _opticalComplete = _opticalSolved == _opticalTotal;
        break;
      case 'SimulateOpticalAirgapTransfer':
        final idx = ++_peerSimCounter;
        _handleUpsertExpense({
          'actor_id': 'B',
          'expense_id': 'exp_optical_qr_$idx',
          'parent_revision_event_ids': const <String>[],
          'currency': 'CNY',
          'total_minor': 28000,
          'payers': const [
            {'participant_id': 'B', 'amount_minor': 28000},
          ],
          'split_rule': const {
            'Equal': {
              'participants': ['A', 'B', 'C', 'D'],
            },
          },
          'title': '扫码面对面同步账单 #$idx (高原露营向导费)',
          'note': '完全无无线连接环境下通过动态二维码喷泉码面对面同步',
          'revision_reason': '同伴创建',
          'voided': false,
        });
        _opticalSolved = 6;
        _opticalTotal = 6;
        _opticalComplete = true;
        _lastSyncReport = const SyncActivityReportModel(
          channel: '动态二维码光学通道 (UR/喷泉码)',
          summaryTitle: '喷泉码中途起扫恢复完成并验签入账：新增 1 条',
          addedEvents: 1,
          duplicateEvents: 0,
          rejectedOrTampered: 0,
          uploadedObjects: 0,
          failedUploads: 0,
          packageByteLen: 640,
          packageDigest: 'blake3_optical_fountain_v1',
        );
        break;
      case 'AddCustomCategory':
        final id = args['id'] as String;
        final icon = (args['icon'] as String? ?? '🏷️').trim();
        final name = (args['name'] as String? ?? '').trim();
        if (name.isEmpty) {
          throw StateError('自定义分类名称不能为空');
        }
        final existingIdx = _customCategories.indexWhere(
          (c) => c.id == id || c.name == name,
        );
        final item = ExpenseCategoryModel(
          id: id,
          icon: icon.isEmpty ? '🏷️' : icon,
          name: name,
          isCustom: true,
        );
        if (existingIdx >= 0) {
          _customCategories[existingIdx] = item;
        } else {
          _customCategories.add(item);
        }
        break;
      case 'RemoveCustomCategory':
        final id = args['id'] as String;
        _customCategories.removeWhere((c) => c.id == id);
        break;
    }

    return _buildSnapshot();
  }

  void _handleConfirmRepayment(Map<String, dynamic> args) {
    final actorId = args['actor_id'] as String;
    final paymentId = args['payment_id'] as String;
    final idx = _repayments.indexWhere((r) => r.paymentId == paymentId);
    if (idx < 0) throw StateError('未找到该还款记录');
    final old = _repayments[idx];
    if (old.payeeId != actorId) {
      throw StateError('权限拒绝：只有收款人本人 (${old.payeeId}) 可以确认收到还款');
    }

    int overpay = 0;
    if (old.targetObligationId != null) {
      final obIdx = _activeObligations.indexWhere(
        (ob) => ob.obligationId == old.targetObligationId,
      );
      if (obIdx >= 0) {
        final ob = _activeObligations[obIdx];
        final rem = ob.remainingMinor;
        final nextPaid = (ob.paidAmountMinor + old.amountMinor)
            .clamp(0, ob.totalAmountMinor);
        if (old.amountMinor > rem) {
          overpay = old.amountMinor - rem;
        }
        _activeObligations[obIdx] = SettlementObligationModel(
          obligationId: ob.obligationId,
          snapshotId: ob.snapshotId,
          debtorId: ob.debtorId,
          creditorId: ob.creditorId,
          currency: ob.currency,
          totalAmountMinor: ob.totalAmountMinor,
          paidAmountMinor: nextPaid,
        );
      }
    }

    _repayments[idx] = RepaymentItemModel(
      paymentId: old.paymentId,
      declareEventId: old.declareEventId,
      confirmEventId: 'ev_conf_${++_seqCounter}',
      payerId: old.payerId,
      payeeId: old.payeeId,
      currency: old.currency,
      amountMinor: old.amountMinor,
      targetObligationId: old.targetObligationId,
      note: old.note,
      statusLabel: '双方已确认入账',
      isConfirmed: true,
      overpaymentMinor: overpay,
    );
  }

  void _handleProposeSettlement(Map<String, dynamic> args) {
    if (_expenses.any((e) => e.hasConflict)) {
      throw StateError('存在未解决的并发账单冲突，请先解决冲突后再发起正式结算快照');
    }
    final mode = SettlementModeOption.fromWire(args['mode'] as String);
    final previews = _computeAllPreviews();
    final preview = previews[mode.wireName]!;

    final reqApprovers = <String>{};
    for (final tr in preview.transfers) {
      reqApprovers.add(tr.debtorId);
      reqApprovers.add(tr.creditorId);
    }
    final sortedReq = reqApprovers.toList()..sort();
    final snapId = args['snapshot_id'] as String;

    _snapshots.insert(
      0,
      SnapshotProjectionModel(
        snapshotId: snapId,
        snapshotEventId: 'ev_snap_${++_seqCounter}',
        mode: mode,
        settlementCurrency: preview.settlementCurrency,
        transfers: preview.transfers,
        requiredApprovers: sortedReq,
        approvedBy: const {},
        commitEventId: null,
        statusWire: sortedReq.isEmpty ? 'ReadyToCommit' : 'AwaitingApprovals',
        snapshotDigest: 'blake3_${snapId}_v1',
        provenOptimal: preview.provenOptimal,
      ),
    );
  }

  void _handleApproveSettlement(Map<String, dynamic> args) {
    final actorId = args['actor_id'] as String;
    final snapId = args['snapshot_id'] as String;
    final idx = _snapshots.indexWhere((s) => s.snapshotId == snapId);
    if (idx < 0) throw StateError('未找到该结算快照');
    final old = _snapshots[idx];
    final nextApproved = Map<String, String>.from(old.approvedBy);
    nextApproved[actorId] = 'ev_app_${++_seqCounter}';
    final allApproved =
        old.requiredApprovers.every((r) => nextApproved.containsKey(r));

    _snapshots[idx] = SnapshotProjectionModel(
      snapshotId: old.snapshotId,
      snapshotEventId: old.snapshotEventId,
      mode: old.mode,
      settlementCurrency: old.settlementCurrency,
      transfers: old.transfers,
      requiredApprovers: old.requiredApprovers,
      approvedBy: nextApproved,
      commitEventId: old.commitEventId,
      statusWire: old.isCommitted
          ? 'Committed'
          : (allApproved ? 'ReadyToCommit' : 'AwaitingApprovals'),
      snapshotDigest: old.snapshotDigest,
      provenOptimal: old.provenOptimal,
    );
  }

  void _handleCommitSettlement(Map<String, dynamic> args) {
    final actorId = args['actor_id'] as String;
    final snapId = args['snapshot_id'] as String;
    final actor = _participants.firstWhere((p) => p.participantId == actorId);
    if (!actor.role.canPublishSettlement) {
      throw StateError('权限拒绝：仅结算协调者或管理员可正式提交结算快照');
    }
    final idx = _snapshots.indexWhere((s) => s.snapshotId == snapId);
    if (idx < 0) throw StateError('未找到该结算快照');
    final snap = _snapshots[idx];
    for (final req in snap.requiredApprovers) {
      if (!snap.approvedBy.containsKey(req)) {
        throw StateError('尚有受影响成员 ($req) 未签名确认该结算快照');
      }
    }

    for (final exp in _expenses) {
      if (exp.activeRevisionEventId != null) {
        _settledExpenseRevisions[exp.expenseId] = exp.activeRevisionEventId!;
      }
    }

    _activeObligations
      ..clear()
      ..addAll(
        snap.transfers.asMap().entries.map(
              (entry) => SettlementObligationModel(
                obligationId: 'ob_${snap.snapshotId}_00${entry.key}',
                snapshotId: snap.snapshotId,
                debtorId: entry.value.debtorId,
                creditorId: entry.value.creditorId,
                currency: entry.value.currency,
                totalAmountMinor: entry.value.amountMinor,
                paidAmountMinor: 0,
              ),
            ),
      );

    _snapshots[idx] = SnapshotProjectionModel(
      snapshotId: snap.snapshotId,
      snapshotEventId: snap.snapshotEventId,
      mode: snap.mode,
      settlementCurrency: snap.settlementCurrency,
      transfers: snap.transfers,
      requiredApprovers: snap.requiredApprovers,
      approvedBy: snap.approvedBy,
      commitEventId: 'ev_commit_${++_seqCounter}',
      statusWire: 'Committed',
      snapshotDigest: snap.snapshotDigest,
      provenOptimal: snap.provenOptimal,
    );
  }

  void _seedInitialExpenses() {
    final hotelRev = _makeRevision(
      expenseId: 'exp_hotel_cny',
      parentIds: const [],
      currency: 'CNY',
      totalMinor: 100000,
      payers: const [
        PayerContributionModel(participantId: 'A', amountMinor: 60000),
        PayerContributionModel(participantId: 'B', amountMinor: 40000),
      ],
      splitRule: const SplitRuleModel(
        kind: SplitModeKind.equal,
        equalParticipants: ['A', 'B', 'C', 'D'],
      ),
      title: '温泉酒店两晚合住',
      note: 'A垫付600元，B垫付400元，四人平摊',
      reason: '创建账单',
      voided: false,
    );
    _expenses.add(
      UiExpenseViewModel(
        expenseId: 'exp_hotel_cny',
        creatorMemberId: 'A',
        hasConflict: false,
        isSettledInPriorCommit: false,
        activeRevisionEventId: 'ev_rev_hotel_v1',
        activeRevision: hotelRev,
        conflictBranches: const [],
        history: [
          UiRevisionEntryModel(
            eventId: 'ev_rev_hotel_v1',
            authorMemberId: 'A',
            deviceId: 'dev_a',
            sequence: 1,
            payload: hotelRev,
          ),
        ],
      ),
    );

    final dinnerRev = _makeRevision(
      expenseId: 'exp_dinner_usd',
      parentIds: const [],
      currency: 'USD',
      totalMinor: 10000,
      payers: const [
        PayerContributionModel(participantId: 'C', amountMinor: 10000),
      ],
      splitRule: const SplitRuleModel(
        kind: SplitModeKind.equal,
        equalParticipants: ['A', 'B', 'C', 'D'],
      ),
      title: '抵达首日晚餐 (USD)',
      note: '程远刷美元卡垫付 100 USD',
      reason: '创建账单',
      voided: false,
    );
    _expenses.add(
      UiExpenseViewModel(
        expenseId: 'exp_dinner_usd',
        creatorMemberId: 'C',
        hasConflict: false,
        isSettledInPriorCommit: false,
        activeRevisionEventId: 'ev_rev_dinner_v1',
        activeRevision: dinnerRev,
        conflictBranches: const [],
        history: [
          UiRevisionEntryModel(
            eventId: 'ev_rev_dinner_v1',
            authorMemberId: 'C',
            deviceId: 'dev_c',
            sequence: 1,
            payload: dinnerRev,
          ),
        ],
      ),
    );
  }

  void _handleUpsertExpense(Map<String, dynamic> args) {
    final actorId = args['actor_id'] as String;
    final actor = _participants.firstWhere((p) => p.participantId == actorId);
    final expenseId = args['expense_id'] as String;
    final parentIds =
        (args['parent_revision_event_ids'] as List).cast<String>();
    final existingIdx = _expenses.indexWhere((e) => e.expenseId == expenseId);

    if (existingIdx >= 0) {
      final existing = _expenses[existingIdx];
      if (existing.creatorMemberId != actorId && !actor.role.canEditAnyBill) {
        throw StateError('权限拒绝：普通成员只能修改自己创建的账单，修改他人账单需财务管理员或群主权限');
      }
    }

    final payers = (args['payers'] as List)
        .map((e) => PayerContributionModel.fromJson(
            Map<String, dynamic>.from(e as Map)))
        .toList();
    final splitRule = SplitRuleModel.fromJson(
      Map<String, dynamic>.from(args['split_rule'] as Map),
    );
    final totalMinor = (args['total_minor'] as num).toInt();
    final voided = args['voided'] as bool? ?? false;

    final rev = _makeRevision(
      expenseId: expenseId,
      parentIds: parentIds,
      currency: args['currency'] as String,
      totalMinor: totalMinor,
      payers: payers,
      splitRule: splitRule,
      title: args['title'] as String,
      note: args['note'] as String,
      reason: args['revision_reason'] as String,
      voided: voided,
      details: args['details'] == null ? null : ExpenseDetailsModel.fromJson(
        Map<String, dynamic>.from(args['details'] as Map)), 
    );

    final evId = 'ev_rev_${++_seqCounter}';
    final entry = UiRevisionEntryModel(
      eventId: evId,
      authorMemberId: actorId,
      deviceId: 'dev_${actorId.toLowerCase()}',
      sequence: _seqCounter,
      payload: rev,
    );

    if (existingIdx < 0) {
      _expenses.insert(
        0,
        UiExpenseViewModel(
          expenseId: expenseId,
          creatorMemberId: actorId,
          hasConflict: false,
          isSettledInPriorCommit: false,
          activeRevisionEventId: evId,
          activeRevision: rev,
          conflictBranches: const [],
          history: [entry],
        ),
      );
    } else {
      final old = _expenses[existingIdx];
      _expenses[existingIdx] = UiExpenseViewModel(
        expenseId: old.expenseId,
        creatorMemberId: old.creatorMemberId,
        hasConflict: false,
        isSettledInPriorCommit: old.isSettledInPriorCommit,
        activeRevisionEventId: evId,
        activeRevision: rev,
        conflictBranches: const [],
        history: [...old.history, entry],
      );
    }
  }

  void _handleSimulateConflict(String expenseId) {
    final idx = _expenses.indexWhere((e) => e.expenseId == expenseId);
    if (idx < 0) return;
    final old = _expenses[idx];
    final baseRev = old.displayRevision;
    final baseId = old.activeRevisionEventId ?? old.history.last.eventId;

    final revA = _makeRevision(
      expenseId: expenseId,
      parentIds: [baseId],
      currency: baseRev.currency,
      totalMinor: baseRev.totalMinor + 5000,
      payers: [
        PayerContributionModel(
          participantId: baseRev.payers.first.participantId,
          amountMinor: baseRev.payers.first.amountMinor + 5000,
        ),
        ...baseRev.payers.skip(1),
      ],
      splitRule: baseRev.splitRule,
      title: '${baseRev.title} (创建人离线改)',
      note: baseRev.note,
      reason: '创建人离线补记小费 +50.00',
      voided: false,
    );

    final revB = _makeRevision(
      expenseId: expenseId,
      parentIds: [baseId],
      currency: baseRev.currency,
      totalMinor: baseRev.totalMinor + 12000,
      payers: [
        PayerContributionModel(
          participantId: baseRev.payers.first.participantId,
          amountMinor: baseRev.payers.first.amountMinor + 12000,
        ),
        ...baseRev.payers.skip(1),
      ],
      splitRule: baseRev.splitRule,
      title: '${baseRev.title} (管理员离线改)',
      note: baseRev.note,
      reason: '管理员白露离线核对水单 +120.00',
      voided: false,
    );

    final entryA = UiRevisionEntryModel(
      eventId: 'ev_conf_a_${++_seqCounter}',
      authorMemberId: old.creatorMemberId,
      deviceId: 'dev_${old.creatorMemberId.toLowerCase()}',
      sequence: _seqCounter,
      payload: revA,
    );
    final entryB = UiRevisionEntryModel(
      eventId: 'ev_conf_b_${++_seqCounter}',
      authorMemberId: 'B',
      deviceId: 'dev_b',
      sequence: _seqCounter,
      payload: revB,
    );

    _expenses[idx] = UiExpenseViewModel(
      expenseId: old.expenseId,
      creatorMemberId: old.creatorMemberId,
      hasConflict: true,
      isSettledInPriorCommit: old.isSettledInPriorCommit,
      activeRevisionEventId: null,
      activeRevision: null,
      conflictBranches: [entryA, entryB],
      history: [...old.history, entryA, entryB],
    );
  }

  ExpenseRevisionModel _makeRevision({
    required String expenseId,
    required List<String> parentIds,
    required String currency,
    required int totalMinor,
    required List<PayerContributionModel> payers,
    required SplitRuleModel splitRule,
    required String title,
    required String note,
    required String reason,
    required bool voided,
    ExpenseDetailsModel? details,
  }) {
    if (details == null && parentIds.isNotEmpty) {
      final parents = _expenses.expand((e) => e.history)
          .where((entry) => parentIds.contains(entry.eventId)).toList();
      if (parents.length != parentIds.length) {
        throw StateError('账目修订前驱不存在');
      }
      details = parents.first.payload.details;
      if (parents.any((entry) => jsonEncode(entry.payload.details?.toJson()) != jsonEncode(details?.toJson()))) {
        throw StateError('分支时间或分类不同，请明确选择合并后的账目资料');
      }
    }
    final shares = _resolveShares(totalMinor, splitRule, voided);
    final matrix = _resolveMatrix(totalMinor, payers, shares, voided);
    return ExpenseRevisionModel(
      expenseId: expenseId,
      parentRevisionEventIds: parentIds,
      currency: currency,
      totalMinor: totalMinor,
      payers: payers,
      splitRule: splitRule,
      resolvedShares: shares,
      attributionMatrix: matrix,
      title: title,
      note: note,
      revisionReason: reason,
      voided: voided,
      details: details,
    );
  }

  Map<String, int> _resolveShares(
    int totalMinor,
    SplitRuleModel rule,
    bool voided,
  ) {
    if (voided) return {};
    switch (rule.kind) {
      case SplitModeKind.equal:
        return MoneyFormatter.apportionByWeights(
          totalMinor,
          {for (final p in rule.equalParticipants) p: 1},
        );
      case SplitModeKind.exactAmounts:
        return rule.exactShares;
      case SplitModeKind.ratios:
        return MoneyFormatter.apportionByWeights(totalMinor, rule.ratios);
      case SplitModeKind.weights:
        return MoneyFormatter.apportionByWeights(totalMinor, rule.weights);
    }
  }

  Map<String, Map<String, int>> _resolveMatrix(
    int totalMinor,
    List<PayerContributionModel> payers,
    Map<String, int> shares,
    bool voided,
  ) {
    if (voided || totalMinor <= 0) return {};
    final paidBy = <String, int>{};
    for (final p in payers) {
      paidBy[p.participantId] = (paidBy[p.participantId] ?? 0) + p.amountMinor;
    }
    final matrix = <String, Map<String, int>>{};
    for (final debtor in shares.keys) {
      for (final creditor in paidBy.keys) {
        if (debtor == creditor) continue;
        final dShare = shares[debtor] ?? 0;
        final cPaid = paidBy[creditor] ?? 0;
        final cShare = shares[creditor] ?? 0;
        final dPaid = paidBy[debtor] ?? 0;
        final dOwesC = (dShare * cPaid) ~/ totalMinor;
        final cOwesD = (cShare * dPaid) ~/ totalMinor;
        final net = dOwesC - cOwesD;
        if (net > 0) {
          (matrix[debtor] ??= {})[creditor] = net;
        }
      }
    }
    return matrix;
  }

  Map<String, UiSettlementPreviewModel> _computeAllPreviews() {
    // Collect canonical pair debts per currency: `currency -> "u:v" -> signed_amount`
    final pairByCurr = <String, Map<String, int>>{};
    void addPair(String curr, String debtor, String creditor, int amt) {
      if (debtor == creditor || amt == 0) return;
      final first = debtor.compareTo(creditor) < 0 ? debtor : creditor;
      final second = debtor.compareTo(creditor) < 0 ? creditor : debtor;
      final signed = debtor == first ? amt : -amt;
      final key = '$first:$second';
      final m = pairByCurr.putIfAbsent(curr, () => {});
      final next = (m[key] ?? 0) + signed;
      if (next == 0) {
        m.remove(key);
      } else {
        m[key] = next;
      }
    }

    for (final ob in _activeObligations) {
      if (ob.remainingMinor > 0) {
        addPair(ob.currency, ob.debtorId, ob.creditorId, ob.remainingMinor);
      }
    }

    for (final exp in _expenses) {
      if (exp.hasConflict || exp.activeRevision == null) continue;
      final settledRevId = _settledExpenseRevisions[exp.expenseId];
      if (settledRevId == exp.activeRevisionEventId) continue;
      final rev = exp.activeRevision!;
      if (!rev.voided) {
        for (final dEntry in rev.attributionMatrix.entries) {
          for (final cEntry in dEntry.value.entries) {
            addPair(rev.currency, dEntry.key, cEntry.key, cEntry.value);
          }
        }
      }
    }

    for (final rep in _repayments) {
      if (!rep.isConfirmed) continue;
      if (rep.targetObligationId != null) {
        if (rep.overpaymentMinor > 0) {
          addPair(rep.currency, rep.payeeId, rep.payerId, rep.overpaymentMinor);
        }
      } else {
        addPair(rep.currency, rep.payerId, rep.payeeId, -rep.amountMinor);
      }
    }

    List<TransferEdgeModel> pairMapToEdges(
      String curr,
      Map<String, int> pairMap,
    ) {
      final list = <TransferEdgeModel>[];
      final keys = pairMap.keys.toList()..sort();
      for (final k in keys) {
        final val = pairMap[k] ?? 0;
        if (val == 0) continue;
        final parts = k.split(':');
        if (val > 0) {
          list.add(TransferEdgeModel(
            debtorId: parts[0],
            creditorId: parts[1],
            currency: curr,
            amountMinor: val,
          ));
        } else {
          list.add(TransferEdgeModel(
            debtorId: parts[1],
            creditorId: parts[0],
            currency: curr,
            amountMinor: -val,
          ));
        }
      }
      return list;
    }

    Map<String, int> balancesFromPairMap(Map<String, int> pairMap) {
      final bal = {for (final p in _participants) p.participantId: 0};
      for (final e in pairMap.entries) {
        final parts = e.key.split(':');
        bal[parts[0]] = (bal[parts[0]] ?? 0) - e.value;
        bal[parts[1]] = (bal[parts[1]] ?? 0) + e.value;
      }
      return bal;
    }

    List<TransferEdgeModel> minTransfersForBalances(
      String curr,
      Map<String, int> bal,
    ) {
      final debtors = <MapEntry<String, int>>[];
      final creditors = <MapEntry<String, int>>[];
      for (final e in bal.entries) {
        if (e.value < 0) debtors.add(MapEntry(e.key, -e.value));
        if (e.value > 0) creditors.add(MapEntry(e.key, e.value));
      }
      final out = <TransferEdgeModel>[];
      while (debtors.isNotEmpty && creditors.isNotEmpty) {
        debtors.sort((a, b) => b.value != a.value
            ? b.value.compareTo(a.value)
            : a.key.compareTo(b.key));
        creditors.sort((a, b) => b.value != a.value
            ? b.value.compareTo(a.value)
            : a.key.compareTo(b.key));
        final d = debtors.removeAt(0);
        final c = creditors.removeAt(0);
        final amt = d.value < c.value ? d.value : c.value;
        out.add(TransferEdgeModel(
          debtorId: d.key,
          creditorId: c.key,
          currency: curr,
          amountMinor: amt,
        ));
        if (d.value > amt) debtors.add(MapEntry(d.key, d.value - amt));
        if (c.value > amt) creditors.add(MapEntry(c.key, c.value - amt));
      }
      out.sort((a, b) {
        final c1 = a.debtorId.compareTo(b.debtorId);
        return c1 != 0 ? c1 : a.creditorId.compareTo(b.creditorId);
      });
      return out;
    }

    final byCurrBalances = <String, Map<String, int>>{};
    final byCurrPairEdges = <TransferEdgeModel>[];
    final byCurrMinEdges = <TransferEdgeModel>[];

    final sortedCurrs = pairByCurr.keys.toList()..sort();
    for (final curr in sortedCurrs) {
      final pm = pairByCurr[curr]!;
      final bal = balancesFromPairMap(pm);
      if (bal.values.any((v) => v != 0)) {
        byCurrBalances[curr] = bal;
        byCurrPairEdges.addAll(pairMapToEdges(curr, pm));
        byCurrMinEdges.addAll(minTransfersForBalances(curr, bal));
      }
    }

    final mergedPairMap = <String, int>{};
    for (final curr in sortedCurrs) {
      final pm = pairByCurr[curr]!;
      final rate = _fxRates.firstWhere(
        (r) => r.baseCurrency == curr && r.quoteCurrency == 'CNY',
        orElse: () => const FxRateSpecModel(
          baseCurrency: 'CNY',
          quoteCurrency: 'CNY',
          numerator: 1,
          denominator: 1,
        ),
      );
      for (final e in pm.entries) {
        final converted = (e.value * rate.numerator) ~/ rate.denominator;
        if (converted != 0) {
          final next = (mergedPairMap[e.key] ?? 0) + converted;
          if (next == 0) {
            mergedPairMap.remove(e.key);
          } else {
            mergedPairMap[e.key] = next;
          }
        }
      }
    }

    final mergedBalances = balancesFromPairMap(mergedPairMap);
    final mergedPairEdges = pairMapToEdges('CNY', mergedPairMap);
    final mergedMinEdges = minTransfersForBalances('CNY', mergedBalances);

    return {
      'ByCurrencyPairwise': UiSettlementPreviewModel(
        modeKey: 'ByCurrencyPairwise',
        settlementCurrency: null,
        netBalancesByCurrency: byCurrBalances,
        transfers: byCurrPairEdges,
        provenOptimal: true,
      ),
      'ByCurrencyMinTransfers': UiSettlementPreviewModel(
        modeKey: 'ByCurrencyMinTransfers',
        settlementCurrency: null,
        netBalancesByCurrency: byCurrBalances,
        transfers: byCurrMinEdges,
        provenOptimal: true,
      ),
      'MergedCurrencyPairwise': UiSettlementPreviewModel(
        modeKey: 'MergedCurrencyPairwise',
        settlementCurrency: 'CNY',
        netBalancesByCurrency: {'CNY': mergedBalances},
        transfers: mergedPairEdges,
        provenOptimal: true,
      ),
      'MergedCurrencyMinTransfers': UiSettlementPreviewModel(
        modeKey: 'MergedCurrencyMinTransfers',
        settlementCurrency: 'CNY',
        netBalancesByCurrency: {'CNY': mergedBalances},
        transfers: mergedMinEdges,
        provenOptimal: true,
      ),
    };
  }

  UiWorkspaceSnapshotModel _buildSnapshot() {
    final previews = _computeAllPreviews();
    return UiWorkspaceSnapshotModel(
      groupId: 'trip_autumn_2026',
      groupName: '川西·东京秋日同行账本',
      activeActorId: _activeActorId,
      activePolicyEventId: 'ev_policy_v1',
      currencies: const {
        'CNY': CurrencySpecModel(code: 'CNY', minorDecimals: 2),
        'USD': CurrencySpecModel(code: 'USD', minorDecimals: 2),
        'JPY': CurrencySpecModel(code: 'JPY', minorDecimals: 0),
        'EUR': CurrencySpecModel(code: 'EUR', minorDecimals: 2),
        'HKD': CurrencySpecModel(code: 'HKD', minorDecimals: 2),
      },
      participants: List.unmodifiable(_participants),
      defaultFxRates: List.unmodifiable(_fxRates),
      customCategories: List.unmodifiable(_customCategories),
      expenses: List.unmodifiable(_expenses),
      repayments: List.unmodifiable(_repayments),
      activeObligations: List.unmodifiable(_activeObligations),
      snapshots: List.unmodifiable(_snapshots),
      settlementPreviews: previews,
      webDavStatus: _webDavStatus,
      lanStatus: LanSyncStatusModel(
        multicastLockActive: !_apIsolation,
        apIsolationDetected: _apIsolation,
        localEndpointTicket:
            'sbill-lan://trip_autumn_2026/$_activeActorId@192.168.43.100:9443',
        discoveredPeers: _apIsolation
            ? const []
            : _participants
                .where((p) =>
                    p.participantId != _activeActorId && p.hasBoundDevice)
                .map(
                  (p) => LanPeerItemModel(
                    memberId: p.participantId,
                    displayName: p.displayName,
                    deviceId: 'dev_${p.participantId.toLowerCase()}',
                    endpointAddr: '192.168.43.102:9443 (QUIC/mDNS)',
                    contiguousSeq: 1,
                    maxSeenSeq: 1,
                    missingSeqs: const [],
                  ),
                )
                .toList(),
      ),
      opticalSession: OpticalSessionViewModel(
        outgoingFrames: const [
          OpticalQrFrameModel(
            packageId: 'pkg_optical_v1',
            totalSourceSlices: 4,
            sliceByteLen: 180,
            totalByteLen: 640,
            sourceIndices: [0],
            payloadB64: 'U0JJTExfRlJBTUVfMA',
            frameDigest: 'blake3_f0',
          ),
          OpticalQrFrameModel(
            packageId: 'pkg_optical_v1',
            totalSourceSlices: 4,
            sliceByteLen: 180,
            totalByteLen: 640,
            sourceIndices: [1, 2],
            payloadB64: 'U0JJTExfRk9VTlRBSU5fMTI',
            frameDigest: 'blake3_f12',
          ),
        ],
        recommendedFps: _opticalSlowMode ? 2 : 5,
        slowMode: _opticalSlowMode,
        receiverActivePackageId: 'pkg_optical_v1',
        receiverSolvedSlices: _opticalSolved,
        receiverTotalSlices: _opticalTotal,
        receiverComplete: _opticalComplete,
      ),
      lastSyncReport: _lastSyncReport,
      conflictCount: _expenses.where((e) => e.hasConflict).length,
      pendingRepaymentCount: _repayments.where((r) => !r.isConfirmed).length,
      pendingReauthCount: 0,
      totalEventCount: _seqCounter,
    );
  }
}
