import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../build_config.dart';
import '../bridge/sbill_rust_bridge.dart';
import '../models/ledger_models.dart';

@immutable
class TestCommandTrace {
  const TestCommandTrace(
      {required this.operation, required this.ok, required this.elapsedMs});
  final String operation;
  final bool ok;
  final int elapsedMs;
}

/// Single batched state controller for the Flutter UI (M4, M5 & M6).
/// Every mutation invokes `rust_core` in a background isolate and replaces `snapshot`
/// atomically so list animations and balance counters transition smoothly in a single frame.
class LedgerController extends ChangeNotifier {
  static const MethodChannel _fileShareChannel =
      MethodChannel('com.sbill.app/fileshare');

  UiWorkspaceSnapshotModel? _snapshot;
  bool _loading = false;
  String? _lastError;

  UiWorkspaceSnapshotModel? get snapshot => _snapshot;
  bool get isLoading => _loading;
  String? get lastError => _lastError;
  bool get isNativeRustLoaded => SbillRustBridge.instance.isNativeRustLoaded;

  bool _appMode = false;
  bool _appReady = false;
  List<LedgerSummary> _ledgers = const [];
  String? _transferCode;
  String? _accessKey;
  String _fingerprint = '';
  Map<String, dynamic>? claimPreview;
  final Map<String, String> _webDavPasswords = {};
  HttpServer? _lanServer;
  String? _lanServerUrl;
  String? get lanServerUrl => _lanServerUrl;
  bool get isLanServerRunning => _lanServer != null;
  Future<void> _operationTail = Future<void>.value();
  final List<TestCommandTrace>? _testTraces = testToolsEnabled ? [] : null;
  bool _testSessionBusy = false;
  bool get isTestSessionBusy => _testSessionBusy;
  List<TestCommandTrace> get testTraces =>
      List.unmodifiable(_testTraces ?? const []);

  void setTestSessionBusy(bool value) {
    if (!testToolsEnabled) throw StateError('普通版不开放开发者控制台');
    _testSessionBusy = value;
    notifyListeners();
  }

  Future<bool> openTestWorkspace(String dbPath) async {
    if (!testToolsEnabled) throw StateError('普通版不开放测试身份');
    final ok = await _appDispatch({
      'op': 'AppOpen',
      'args': {'db_path': dbPath}
    });
    if (ok) {
      _appReady = true;
      notifyListeners();
    }
    return ok;
  }

  Future<bool> refreshTestState() {
    if (!testToolsEnabled) throw StateError('普通版不开放开发者控制台');
    return _appDispatch({'op': 'AppGet'});
  }

  void clearTestTraces() {
    if (!testToolsEnabled) throw StateError('普通版不开放开发者控制台');
    _testTraces!.clear();
    notifyListeners();
  }

  bool get isAppMode => _appMode;
  bool get isAppReady => _appReady;
  List<LedgerSummary> get ledgers => _ledgers;
  String? get transferCode => _transferCode;
  String? get accessKey => _accessKey;
  String get identityFingerprint => _fingerprint;
  bool get canWrite =>
      _snapshot != null &&
      _snapshot!.activeActor.active &&
      _snapshot!.activeActor.role != MemberRole.viewer;

  Future<void> initializeApp({String? overrideDbPath}) async {
    _appMode = true;
    try {
      final path = overrideDbPath ??
          await _fileShareChannel.invokeMethod<String>('getDatabasePath');
      if (path == null || path.trim().isEmpty) {
        throw StateError('无法获取本机持久化目录');
      }
      _appReady = await _appDispatch({
        'op': 'AppOpen',
        'args': {'db_path': path}
      });
      notifyListeners();
      if (_appReady && _snapshot != null) await checkIncomingSystemFileIntent();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<bool> createLedger(
          {required String groupName,
          required String displayName,
          List<String> companions = const []}) =>
      _appDispatch({
        'op': 'AppCreateLedger',
        'args': {
          'group_name': groupName,
          'display_name': displayName,
          'companions': companions
        },
      });
  Future<bool> selectLedger(String id) async {
    final ok = await _appDispatch({
      'op': 'AppSelectLedger',
      'args': {'group_id': id}
    });
    if (ok && !_testSessionBusy) await checkIncomingSystemFileIntent();
    return ok;
  }

  Future<bool> showLedgers() => _appDispatch({'op': 'AppShowLedgers'});
  Future<bool> addCompanion(String displayName, MemberRole role) =>
      _appDispatch({
        'op': 'AppAddParticipant',
        'args': {
          'group_id': _snapshot?.groupId ?? '',
          'display_name': displayName,
          'role': role.wireName
        },
      });
  Future<bool> updateCompanion(
          {required String id,
          required String displayName,
          required MemberRole role,
          required bool active}) =>
      _appDispatch({
        'op': 'AppUpdateParticipant',
        'args': {
          'group_id': _snapshot?.groupId ?? '',
          'participant_id': id,
          'display_name': displayName,
          'role': role.wireName,
          'active': active
        },
      });
  Future<bool> createClaim(
          {required String groupId,
          required String participantId,
          required String displayName}) =>
      _appDispatch({
        'op': 'AppCreateClaim',
        'args': {
          'group_id': groupId,
          'participant_id': participantId,
          'display_name': displayName
        },
      });
  Future<bool> inspectClaim(String request) => _appDispatch({
        'op': 'AppInspectClaim',
        'args': {'group_id': _snapshot?.groupId ?? '', 'request': request},
      });
  Future<bool> approveClaim(String request, String id) => _appDispatch({
        'op': 'AppApproveClaim',
        'args': {
          'group_id': _snapshot?.groupId ?? '',
          'request': request,
          'participant_id': id
        },
      });
  Future<bool> joinLedger(String welcome, String key) => _appDispatch({
        'op': 'AppJoinLedger',
        'args': {'welcome': welcome, 'access_key': key},
      });

  Future<bool> _appDispatch(Map<String, dynamic> command) {
    final result = _operationTail.then((_) async {
      final watch = testToolsEnabled ? (Stopwatch()..start()) : null;
      var succeeded = false;
      _loading = true;
      _lastError = null;
      notifyListeners();
      try {
        final app = await SbillRustBridge.instance.invokeAppCommand(command);
        _ledgers = (app['ledgers'] as List)
            .map((e) =>
                LedgerSummary.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        _snapshot = app['active_ledger'] == null
            ? null
            : UiWorkspaceSnapshotModel.fromJson(
                Map<String, dynamic>.from(app['active_ledger'] as Map));
        _fingerprint = app['identity_fingerprint'] as String;
        _transferCode = app['transfer_code'] as String?;
        _accessKey = app['access_key'] as String?;
        claimPreview = app['claim_preview'] == null
            ? null
            : Map<String, dynamic>.from(app['claim_preview'] as Map);
        succeeded = true;
        return true;
      } catch (e) {
        _lastError = e.toString().replaceFirst('Bad state: ', '');
        return false;
      } finally {
        if (testToolsEnabled) {
          final operation = command['op'] == 'AppLedgerCommand'
              ? (command['args'] as Map)['command']['op'] as String
              : command['op'] as String;
          if (_testTraces!.length == 100) _testTraces.removeAt(0);
          _testTraces.add(TestCommandTrace(
              operation: operation,
              ok: succeeded,
              elapsedMs: watch!.elapsedMilliseconds));
        }
        _loading = false;
        notifyListeners();
      }
    });
    _operationTail = result.then<void>((_) {});
    return result;
  }

  /// Explicit legacy fixture entry point; the installed app uses initializeApp.
  Future<void> initialize({String? overrideDbPath}) async {
    String? dbPath = overrideDbPath;
    if (dbPath == null || dbPath.trim().isEmpty) {
      try {
        dbPath =
            await _fileShareChannel.invokeMethod<String>('getDatabasePath');
      } on MissingPluginException {
        // Running in unit test runner without Android MethodChannel
      } catch (_) {
        // Fallback if channel unavailable
      }
    }
    if (dbPath != null && dbPath.trim().isNotEmpty) {
      await _dispatch({
        'op': 'OpenPersistentWorkspace',
        'args': {'db_path': dbPath.trim()},
      });
    } else {
      await _dispatch({'op': 'InitOrGetSnapshot'});
    }
  }

  Future<bool> resetDemoWorkspace() async {
    return _dispatch({'op': 'ResetDemoWorkspace'});
  }

  void clearError() {
    if (_lastError != null) {
      _lastError = null;
      notifyListeners();
    }
  }

  Future<bool> switchActor(String actorId) async {
    return _dispatch({
      'op': 'SwitchActor',
      'args': {'actor_id': actorId},
    });
  }

  Future<bool> setSettlementCurrency(String currency) => _dispatch({
        'op': 'SetSettlementCurrency',
        'args': {'currency': currency},
      });

  Future<bool> setFxRate({
    required String baseCurrency,
    required String quoteCurrency,
    required int numerator,
    required int denominator,
  }) async {
    return _dispatch({
      'op': 'SetFxRate',
      'args': {
        'base_currency': baseCurrency,
        'quote_currency': quoteCurrency,
        'numerator': numerator,
        'denominator': denominator,
      },
    });
  }

  Future<bool> addParticipant({
    required String participantId,
    required String displayName,
    required MemberRole role,
    required bool bindDeviceKey,
  }) async {
    final actorId = _snapshot?.activeActorId ?? 'A';
    return _dispatch({
      'op': 'AddParticipant',
      'args': {
        'actor_id': actorId,
        'participant_id': participantId,
        'display_name': displayName,
        'role': role.wireName,
        'bind_device_key': bindDeviceKey,
      },
    });
  }

  Future<bool> upsertExpense({
    required String expenseId,
    required List<String> parentRevisionEventIds,
    required String currency,
    required int totalMinor,
    required List<PayerContributionModel> payers,
    required SplitRuleModel splitRule,
    required String title,
    required String note,
    required String revisionReason,
    required bool voided,
    ExpenseDetailsModel? details,
  }) async {
    final actorId = _snapshot?.activeActorId ?? 'A';
    return _dispatch({
      'op': 'UpsertExpense',
      'args': {
        'actor_id': actorId,
        'expense_id': expenseId,
        'parent_revision_event_ids': parentRevisionEventIds,
        'currency': currency,
        'total_minor': totalMinor,
        'payers': payers.map((p) => p.toJson()).toList(),
        'split_rule': splitRule.toJson(),
        'title': title,
        'note': note,
        'revision_reason': revisionReason,
        'voided': voided,
        if (details != null) 'details': details.toJson(),
      },
    });
  }

  Future<bool> simulateConcurrentConflict(String expenseId) async {
    return _dispatch({
      'op': 'SimulateConcurrentConflict',
      'args': {'expense_id': expenseId},
    });
  }

  Future<bool> declareRepayment({
    required String payerId,
    required String payeeId,
    required String currency,
    required int amountMinor,
    required String note,
    String? targetObligationId,
  }) async {
    final actorId = _snapshot?.activeActorId ?? payerId;
    final paymentId = 'pay_${DateTime.now().millisecondsSinceEpoch}';
    return _dispatch({
      'op': 'DeclareRepayment',
      'args': {
        'actor_id': actorId,
        'payment_id': paymentId,
        'payer_id': payerId,
        'payee_id': payeeId,
        'currency': currency,
        'amount_minor': amountMinor,
        'target_obligation_id': targetObligationId,
        'note': note,
      },
    });
  }

  Future<bool> confirmRepayment({
    required String paymentId,
    required String declareEventId,
    String overpaymentPolicy = 'RefundNeeded',
  }) async {
    final actorId = _snapshot?.activeActorId ?? 'A';
    return _dispatch({
      'op': 'ConfirmRepayment',
      'args': {
        'actor_id': actorId,
        'payment_id': paymentId,
        'declare_event_id': declareEventId,
        'overpayment_policy': overpaymentPolicy,
      },
    });
  }

  Future<bool> disputeRepayment({
    required String paymentId,
    required String declareEventId,
    required String reason,
  }) async {
    final actorId = _snapshot?.activeActorId ?? 'A';
    return _dispatch({
      'op': 'DisputeRepayment',
      'args': {
        'actor_id': actorId,
        'payment_id': paymentId,
        'declare_event_id': declareEventId,
        'reason': reason,
      },
    });
  }

  Future<bool> mapLateRepayment({
    required String paymentId,
    required String targetObligationId,
    String note = '映射到重组后结算义务',
  }) async {
    final actorId = _snapshot?.activeActorId ?? 'A';
    return _dispatch({
      'op': 'MapLateRepayment',
      'args': {
        'actor_id': actorId,
        'payment_id': paymentId,
        'target_obligation_id': targetObligationId,
        'note': note,
      },
    });
  }

  Future<bool> exportIdentityBackup(String passphrase) async {
    return _dispatch({
      'op': 'ExportIdentityBackup',
      'args': {'passphrase': passphrase},
    });
  }

  Future<bool> restoreIdentityBackup({
    required String backupJson,
    required String passphrase,
  }) async {
    return _dispatch({
      'op': 'RestoreIdentityBackup',
      'args': {
        'backup_json': backupJson,
        'passphrase': passphrase,
      },
    });
  }

  Future<bool> proposeSettlement({
    required SettlementModeOption mode,
    String? settlementCurrency,
  }) async {
    final actorId = _snapshot?.activeActorId ?? 'A';
    final snapshotId = 'snap_${DateTime.now().millisecondsSinceEpoch}';
    return _dispatch({
      'op': 'ProposeSettlement',
      'args': {
        'actor_id': actorId,
        'snapshot_id': snapshotId,
        'mode': mode.wireName,
        'settlement_currency':
            mode.mergeCurrency ? (settlementCurrency ?? 'CNY') : null,
      },
    });
  }

  Future<bool> approveSettlement(String snapshotId) async {
    final actorId = _snapshot?.activeActorId ?? 'A';
    return _dispatch({
      'op': 'ApproveSettlement',
      'args': {
        'actor_id': actorId,
        'snapshot_id': snapshotId,
      },
    });
  }

  Future<bool> commitSettlement(String snapshotId) async {
    final actorId = _snapshot?.activeActorId ?? 'A';
    return _dispatch({
      'op': 'CommitSettlement',
      'args': {
        'actor_id': actorId,
        'snapshot_id': snapshotId,
      },
    });
  }

  Future<bool> exportTripDelta() async {
    return _dispatch({'op': 'ExportTripDelta'});
  }

  Future<bool> importTripDelta(String payload) async {
    return _dispatch({
      'op': 'ImportTripDelta',
      'args': {'payload': payload},
    });
  }

  Future<bool> simulatePeerTripDelta({required bool autoImport}) async {
    return _dispatch({
      'op': 'SimulatePeerTripDelta',
      'args': {'auto_import': autoImport},
    });
  }

  Future<bool> configureWebDav({
    required String endpointUrl,
    required String username,
    String? password,
    required bool simulateUnreachable,
  }) async {
    final groupId = _snapshot?.groupId ?? '';
    if (password != null && password.isNotEmpty) {
      _webDavPasswords[groupId] = password;
    }
    return _dispatch({
      'op': 'ConfigureWebDav',
      'args': {
        'endpoint_url': endpointUrl,
        'username': username,
        'simulate_unreachable': simulateUnreachable,
      },
    });
  }

  Future<bool> syncWebDavNow() async {
    final dav = _snapshot?.webDavStatus;
    if (dav != null &&
        !dav.simulateUnreachable &&
        dav.endpointUrl.trim().isNotEmpty &&
        !dav.endpointUrl.contains('nas.local')) {
      return _syncWebDavOverHttp(dav);
    }
    return _dispatch({'op': 'SyncWebDavNow'});
  }

  Future<bool> _syncWebDavOverHttp(WebDavStatusModel dav) async {
    final groupId = _snapshot?.groupId ?? '';
    final password = _webDavPasswords[groupId] ?? '';
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final uploaded = <String>[];
    final failed = <String>[];
    final downloaded = <List<String>>[];
    try {
      final base = dav.endpointUrl.trim().replaceAll(RegExp(r'/+$'), '');
      final dirName = Uri.encodeComponent(dav.opaqueGroupDir);
      final dirUri = Uri.parse('$base/$dirName/');
      final authHeader = dav.username.trim().isEmpty
          ? null
          : 'Basic ${base64Encode(utf8.encode('${dav.username.trim()}:$password'))}';

      // 1. Ensure opaque directory exists (MKCOL)
      try {
        final mkReq = await client.openUrl('MKCOL', dirUri);
        if (authHeader != null) {
          mkReq.headers.set(HttpHeaders.authorizationHeader, authHeader);
        }
        final mkRes = await mkReq.close();
        await mkRes.drain<void>();
      } catch (_) {}

      // 2. Upload pending encrypted outbox objects (PUT)
      for (final item in dav.pendingUploads) {
        final safeName = '${Uri.encodeComponent(item.objectHash)}.sbill';
        final objUri = Uri.parse('$base/$dirName/$safeName');
        try {
          final bytes =
              base64Url.decode(base64Url.normalize(item.ciphertextB64));
          final putReq = await client.openUrl('PUT', objUri);
          if (authHeader != null) {
            putReq.headers.set(HttpHeaders.authorizationHeader, authHeader);
          }
          putReq.headers.contentType = ContentType.binary;
          putReq.contentLength = bytes.length;
          putReq.add(bytes);
          final putRes = await putReq.close();
          await putRes.drain<void>();
          if (putRes.statusCode >= 200 && putRes.statusCode < 300) {
            uploaded.add(item.objectHash);
          } else {
            failed.add(item.objectHash);
          }
        } catch (_) {
          failed.add(item.objectHash);
        }
      }

      // 3. List remote encrypted objects (PROPFIND Depth: 1)
      final remoteHashes = <String>{};
      try {
        final propReq = await client.openUrl('PROPFIND', dirUri);
        if (authHeader != null) {
          propReq.headers.set(HttpHeaders.authorizationHeader, authHeader);
        }
        propReq.headers.set('Depth', '1');
        final propRes = await propReq.close();
        if (propRes.statusCode >= 200 && propRes.statusCode < 300) {
          final xml = await utf8.decoder.bind(propRes).join();
          final matches = RegExp(r'([^/<>\s"]+)\.sbill').allMatches(xml);
          for (final m in matches) {
            final encodedHash = m.group(1);
            if (encodedHash != null && encodedHash.isNotEmpty) {
              remoteHashes.add(Uri.decodeComponent(encodedHash));
            }
          }
        } else {
          await propRes.drain<void>();
        }
      } catch (_) {}

      // 4. Download encrypted objects from remote
      for (final hash in remoteHashes) {
        if (uploaded.contains(hash)) continue;
        final safeName = '${Uri.encodeComponent(hash)}.sbill';
        final objUri = Uri.parse('$base/$dirName/$safeName');
        try {
          final getReq = await client.getUrl(objUri);
          if (authHeader != null) {
            getReq.headers.set(HttpHeaders.authorizationHeader, authHeader);
          }
          final getRes = await getReq.close();
          if (getRes.statusCode == 200) {
            final builder = BytesBuilder(copy: false);
            await for (final chunk in getRes) {
              builder.add(chunk);
              if (builder.length > 20 * 1024 * 1024) {
                throw StateError('WebDAV 单对象超限');
              }
            }
            final ctB64 =
                base64UrlEncode(builder.takeBytes()).replaceAll('=', '');
            downloaded.add([hash, ctB64]);
          } else {
            await getRes.drain<void>();
          }
        } catch (_) {}
      }

      if (uploaded.isEmpty &&
          dav.pendingUploads.isNotEmpty &&
          failed.length == dav.pendingUploads.length &&
          remoteHashes.isEmpty) {
        _lastError = 'WebDAV 节点连接失败，待上传对象已保留在本地队列';
      }

      return await _dispatch({
        'op': 'ApplyWebDavHttpSync',
        'args': {
          'uploaded_hashes': uploaded,
          'failed_hashes': failed,
          'downloaded_objects': downloaded,
        },
      });
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> simulateRemoteWebDavIncoming({
    required bool injectTampered,
  }) async {
    return _dispatch({
      'op': 'SimulateRemoteWebDavIncoming',
      'args': {'inject_tampered': injectTampered},
    });
  }

  Future<bool> configureLanDiscovery({
    required bool apIsolationDetected,
  }) async {
    try {
      await _fileShareChannel.invokeMethod<bool>('setMulticastLock', {
        'enable': !apIsolationDetected,
      });
    } on MissingPluginException {
      // No-op outside Android activity
    }
    return _dispatch({
      'op': 'ConfigureLanDiscovery',
      'args': {'ap_isolation_detected': apIsolationDetected},
    });
  }

  Future<bool> syncLanWithPeer({
    required String peerMemberId,
    required bool simulateGapFill,
  }) async {
    return _dispatch({
      'op': 'SyncLanWithPeer',
      'args': {
        'peer_member_id': peerMemberId,
        'simulate_gap_fill': simulateGapFill,
      },
    });
  }

  Future<bool> generateOpticalFrames({
    int sliceByteLen = 180,
    int parityFrames = 6,
    required bool slowMode,
  }) async {
    return _dispatch({
      'op': 'GenerateOpticalFrames',
      'args': {
        'slice_byte_len': sliceByteLen,
        'parity_frames': parityFrames,
        'slow_mode': slowMode,
      },
    });
  }

  Future<bool> ingestOpticalFrame(String frameJson) async {
    return _dispatch({
      'op': 'IngestOpticalFrame',
      'args': {'frame_json': frameJson},
    });
  }

  Future<String?> scanQrCodeViaNativeCamera() async {
    if (!Platform.isAndroid) {
      return 'CAMERA_READY_USE_STREAM';
    }
    try {
      return await _fileShareChannel.invokeMethod<String>('scanQrCode');
    } on MissingPluginException {
      return 'CAMERA_READY_USE_STREAM';
    } on PlatformException catch (e) {
      _lastError = e.message ?? '相机扫码不可用';
      notifyListeners();
      return null;
    }
  }

  Future<bool> ingestOpticalFrameStream(
    String rawInput, {
    bool dropFirstTwoFrames = false,
  }) async {
    final trimmed = rawInput.trim();
    if (trimmed.isEmpty) {
      _lastError = '扫码内容不能为空';
      notifyListeners();
      return false;
    }
    if (trimmed.startsWith('SBILL1:')) {
      return importTripDelta(trimmed);
    }

    final frameJsons = <String>[];
    if (trimmed.startsWith('[')) {
      try {
        final list = jsonDecode(trimmed) as List;
        for (final item in list) {
          frameJsons.add(item is String ? item : jsonEncode(item));
        }
      } catch (_) {}
    }
    if (frameJsons.isEmpty) {
      for (final line in trimmed.split(RegExp(r'\r?\n'))) {
        final l = line.trim();
        if (l.startsWith('{') && l.endsWith('}')) {
          frameJsons.add(l);
        }
      }
    }
    if (frameJsons.isEmpty && trimmed.startsWith('{')) {
      frameJsons.add(trimmed);
    }
    if (frameJsons.isEmpty) {
      return importTripDelta(trimmed);
    }

    final startIdx =
        (dropFirstTwoFrames && frameJsons.length > 4) ? 2 : 0;
    var ok = false;
    for (var i = startIdx; i < frameJsons.length; i++) {
      ok = await ingestOpticalFrame(frameJsons[i]);
      if (!ok) return false;
      if (_snapshot?.opticalSession.receiverComplete == true) {
        break;
      }
    }
    return ok;
  }

  Future<String?> startLanSyncServer({int preferredPort = 9443}) async {
    if (_lanServer != null) {
      return _lanServerUrl;
    }
    if (Platform.isAndroid) {
      try {
        await _fileShareChannel.invokeMethod<bool>('setMulticastLock', {
          'enable': true,
        });
      } catch (_) {}
    }

    HttpServer server;
    try {
      server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        preferredPort,
        shared: true,
      );
    } catch (_) {
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    _lanServer = server;
    var hostIp = '127.0.0.1';
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) {
            hostIp = addr.address;
            break;
          }
        }
        if (hostIp != '127.0.0.1') break;
      }
    } catch (_) {}
    _lanServerUrl = 'http://$hostIp:${server.port}';
    notifyListeners();

    server.listen((HttpRequest req) async {
      try {
        if (req.uri.path == '/sbill/v1/tripdelta') {
          if (req.method == 'POST') {
            final body = await utf8.decoder.bind(req).join();
            if (body.trim().isNotEmpty) {
              await importTripDelta(body);
            }
          }
          await exportTripDelta();
          final payload =
              _snapshot?.lastSyncReport?.exportedTripdeltaJson ??
                  _snapshot?.lastSyncReport?.exportedCompactCode ??
                  '';
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentType = ContentType.json;
          req.response.write(payload);
          await req.response.close();
          return;
        }
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      } catch (e) {
        try {
          req.response.statusCode = HttpStatus.badRequest;
          req.response.write(e.toString());
          await req.response.close();
        } catch (_) {}
      }
    });
    return _lanServerUrl;
  }

  Future<void> stopLanSyncServer() async {
    final s = _lanServer;
    _lanServer = null;
    _lanServerUrl = null;
    if (s != null) {
      await s.close(force: true);
    }
    if (Platform.isAndroid) {
      try {
        await _fileShareChannel.invokeMethod<bool>('setMulticastLock', {
          'enable': false,
        });
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<bool> syncWithLanPeerHttp(String peerEndpoint) async {
    final raw = peerEndpoint.trim();
    if (raw.isEmpty) {
      _lastError = '请输入伙伴的局域网地址';
      notifyListeners();
      return false;
    }
    final normalized =
        raw.startsWith('http://') || raw.startsWith('https://')
            ? raw.replaceAll(RegExp(r'/+$'), '')
            : 'http://${raw.replaceAll(RegExp(r'/+$'), '')}';
    final uri = Uri.parse(
      normalized.endsWith('/sbill/v1/tripdelta')
          ? normalized
          : '$normalized/sbill/v1/tripdelta',
    );
    if (!await exportTripDelta()) {
      return false;
    }
    final localPayload =
        _snapshot?.lastSyncReport?.exportedTripdeltaJson ??
            _snapshot?.lastSyncReport?.exportedCompactCode ??
            '';
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(localPayload));
      final res = await req.close();
      final body = await utf8.decoder.bind(res).join();
      if (res.statusCode != HttpStatus.ok) {
        _lastError = '局域网伙伴响应异常 (${res.statusCode}): $body';
        notifyListeners();
        return false;
      }
      return await importTripDelta(body);
    } catch (e) {
      _lastError = '局域网直连失败，请确认同一 Wi-Fi/热点且未开启 AP 隔离: $e';
      notifyListeners();
      return false;
    } finally {
      client.close(force: true);
    }
  }

  @override
  void dispose() {
    _lanServer?.close(force: true);
    _lanServer = null;
    super.dispose();
  }

  Future<bool> simulateOpticalAirgapTransfer({
    required bool dropFirstTwoFrames,
  }) async {
    return _dispatch({
      'op': 'SimulateOpticalAirgapTransfer',
      'args': {'drop_first_two_frames': dropFirstTwoFrames},
    });
  }

  Future<bool> addCustomCategory({
    required String icon,
    required String name,
  }) async {
    final id = 'cat_${DateTime.now().millisecondsSinceEpoch}';
    return _dispatch({
      'op': 'AddCustomCategory',
      'args': {
        'id': id,
        'icon': icon.trim(),
        'name': name.trim(),
      },
    });
  }

  Future<bool> removeCustomCategory(String id) async {
    return _dispatch({
      'op': 'RemoveCustomCategory',
      'args': {'id': id},
    });
  }

  /// Exports `.tripdelta` and invokes Android native share sheet (Xiaomi Share / Quick Share).
  Future<bool> shareTripDeltaViaSystemSheet() async {
    final ok = await exportTripDelta();
    if (!ok) return false;
    final content = _snapshot?.lastSyncReport?.exportedTripdeltaJson;
    if (content == null || content.isEmpty) return false;
    try {
      await _fileShareChannel.invokeMethod<String>('shareTripDeltaFile', {
        'fileName': 'sbill_${_snapshot?.groupId ?? "trip"}.tripdelta',
        'content': content,
      });
    } on MissingPluginException {
      if (_appMode) {
        _lastError = '系统文件分享不可用，请复制同步码';
        notifyListeners();
        return false;
      }
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
      return false;
    }
    return true;
  }

  Future<bool> importTripDeltaFromPicker() async {
    final groupId = _snapshot?.groupId;
    try {
      final content =
          await _fileShareChannel.invokeMethod<String>('pickTripDeltaFile');
      if (content == null) return true;
      if (_snapshot?.groupId != groupId) throw StateError('账本已切换，请重新导入');
      return await importTripDelta(content);
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// Checks if the Android Activity was launched or resumed via an external `.tripdelta` file Intent.
  Future<void> checkIncomingSystemFileIntent() async {
    try {
      final incoming = await _fileShareChannel
          .invokeMethod<String>('consumeIncomingTripDelta');
      if (incoming != null && incoming.trim().isNotEmpty) {
        await importTripDelta(incoming);
      }
    } on MissingPluginException {
      // No-op when running outside Android activity
    }
  }

  Future<bool> _dispatch(Map<String, dynamic> command) async {
    if (_appMode) {
      return _appDispatch({
        'op': 'AppLedgerCommand',
        'args': {
          'group_id': _snapshot?.groupId ?? '',
          'command': command,
        }
      });
    }
    _loading = true;
    _lastError = null;
    notifyListeners();
    try {
      final nextSnapshot =
          await SbillRustBridge.instance.invokeCommand(command);
      _snapshot = nextSnapshot;
      _loading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _loading = false;
      _lastError = e.toString().replaceFirst('Bad state: ', '');
      notifyListeners();
      return false;
    }
  }
}
