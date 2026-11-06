import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sbill_app/models/ledger_models.dart';
import 'package:sbill_app/state/ledger_controller.dart';
import 'package:sbill_app/ui/screens/companion_center_screen.dart';
import 'package:sbill_app/ui/screens/optical_qr_sync_screen.dart';
import 'package:sbill_app/utils/qr_code_matrix.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('QrCodeMatrix encodes standard ISO/IEC 18004 QR matrices with finders', () {
    final matrix = QrCodeMatrix.encodeText('{"package_id":"pkg_123","slice":0}');
    expect(matrix.version, greaterThanOrEqualTo(1));
    expect(matrix.size, matrix.version * 4 + 17);
    // Top-left 7x7 finder pattern corners & center must be dark
    expect(matrix.modules[0][0], isTrue);
    expect(matrix.modules[0][6], isTrue);
    expect(matrix.modules[6][0], isTrue);
    expect(matrix.modules[3][3], isTrue);
    // Separator around top-left finder must be light
    expect(matrix.modules[7][0], isFalse);
    expect(matrix.modules[0][7], isFalse);
  });

  test(
      'Production App mode supports Fountain QR stream, real HTTP WebDAV, LAN HTTP sync, dispute and Argon2id backup',
      () async {
    final home = await Directory.systemTemp.createTemp('sbill_real_ch_');
    final controller = LedgerController();
    HttpServer? mockWebDavServer;
    final webDavStore = <String, List<int>>{};

    try {
      mockWebDavServer =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      mockWebDavServer.listen((HttpRequest req) async {
        final path = req.uri.path;
        if (req.method == 'MKCOL') {
          req.response.statusCode = HttpStatus.created;
          await req.response.close();
        } else if (req.method == 'PUT') {
          final bytes = await req.fold<List<int>>([], (p, e) => p..addAll(e));
          webDavStore[path] = bytes;
          req.response.statusCode = HttpStatus.created;
          await req.response.close();
        } else if (req.method == 'PROPFIND') {
          final hrefs = webDavStore.keys
              .map((k) => '<D:response><D:href>$k</D:href></D:response>')
              .join();
          req.response.statusCode = 207;
          req.response.write('<D:multistatus>$hrefs</D:multistatus>');
          await req.response.close();
        } else if (req.method == 'GET') {
          final bytes = webDavStore[path];
          if (bytes != null) {
            req.response.statusCode = HttpStatus.ok;
            req.response.add(bytes);
          } else {
            req.response.statusCode = HttpStatus.notFound;
          }
          await req.response.close();
        } else {
          req.response.statusCode = HttpStatus.methodNotAllowed;
          await req.response.close();
        }
      });

      await controller.initializeApp(
        overrideDbPath: '${home.path}/ledger.sqlite3',
      );
      await controller.createLedger(
        groupName: '全通道实测出行',
        displayName: '阿杰',
        companions: ['白露'],
      );
      final snap = controller.snapshot!;
      expect(
        await controller.upsertExpense(
          expenseId: 'exp_1',
          parentRevisionEventIds: const [],
          currency: 'CNY',
          totalMinor: 12000,
          payers: [
            PayerContributionModel(
              participantId: snap.activeActorId,
              amountMinor: 12000,
            ),
          ],
          splitRule: SplitRuleModel(
            kind: SplitModeKind.equal,
            equalParticipants:
                snap.participants.map((p) => p.participantId).toList(),
          ),
          title: '高山缆车票',
          note: '',
          revisionReason: '创建',
          voided: false,
        ),
        isTrue,
      );

      // 1. Real HTTP WebDAV configure & sync in App mode
      final davUrl =
          'http://127.0.0.1:${mockWebDavServer.port}/webdav/sbill';
      expect(
        await controller.configureWebDav(
          endpointUrl: davUrl,
          username: 'tester',
          password: 'secret_app_password',
          simulateUnreachable: false,
        ),
        isTrue,
      );
      expect(await controller.syncWebDavNow(), isTrue);
      expect(webDavStore.isNotEmpty, isTrue);
      expect(controller.snapshot!.webDavStatus.pendingUploadCount, 0);

      // 2. Real LAN HTTP Server & Peer HTTP Sync in App mode
      final lanUrl = await controller.startLanSyncServer(preferredPort: 0);
      expect(lanUrl, isNotNull);
      final port = Uri.parse(lanUrl!).port;
      expect(
        await controller.syncWithLanPeerHttp('http://127.0.0.1:$port'),
        isTrue,
      );
      await controller.stopLanSyncServer();

      // 3. Argon2id V2 Identity Backup Export & Restore in App mode
      expect(
        await controller.exportIdentityBackup('StrongPassphrase#2026'),
        isTrue,
      );
      final backupJson =
          controller.snapshot!.lastSyncReport!.exportedCompactCode!;
      expect(backupJson.contains('argon2id-v19-m65536-t3-p1'), isTrue);
      expect(
        await controller.restoreIdentityBackup(
          backupJson: backupJson,
          passphrase: 'StrongPassphrase#2026',
        ),
        isTrue,
      );

      // 4. Fountain QR frame generation & multi-frame stream ingestion (dropping first 2 frames)
      expect(await controller.generateOpticalFrames(slowMode: false), isTrue);
      final frames = controller.snapshot!.opticalSession.outgoingFrames;
      expect(frames, isNotEmpty);
      final streamPayload =
          frames.map((f) => jsonEncode(f.toJson())).join('\n');
      expect(
        await controller.ingestOpticalFrameStream(
          streamPayload,
          dropFirstTwoFrames: true,
        ),
        isTrue,
      );
      expect(controller.snapshot!.opticalSession.receiverComplete, isTrue);
    } finally {
      await mockWebDavServer?.close(force: true);
      controller.dispose();
      await home.delete(recursive: true);
    }
  });

  testWidgets(
      'CompanionCenterScreen and OpticalQrSyncScreen render real ISO QR and sync entries',
      (tester) async {
    final home = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('sbill_qr_ui_')))!;
    final controller = LedgerController();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    try {
      await tester.runAsync(() async {
        await controller.initializeApp(
          overrideDbPath: '${home.path}/ledger.sqlite3',
        );
        await controller.createLedger(
          groupName: '二维码界面验证',
          displayName: '阿杰',
          companions: ['白露'],
        );
        await controller.generateOpticalFrames(slowMode: false);
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CompanionCenterScreen(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('面对面瀑布二维码'), findsOneWidget);
      expect(find.text('局域网直连与 WebDAV 异步留存'), findsOneWidget);

      await tester.pumpWidget(
        MaterialApp(
          home: OpticalQrSyncScreen(controller: controller),
        ),
      );
      await tester.pump();
      expect(find.textContaining('ISO QR v'), findsOneWidget);
      expect(find.text('相机扫码 / 粘贴帧流'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await tester.runAsync(() => home.delete(recursive: true));
      await tester.binding.setSurfaceSize(null);
    }
  });
}
