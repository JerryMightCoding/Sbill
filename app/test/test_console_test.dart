import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sbill_app/build_config.dart';
import 'package:sbill_app/main.dart';
import 'package:sbill_app/models/ledger_models.dart';
import 'package:sbill_app/state/ledger_controller.dart';
import 'package:sbill_app/state/test_console_controller.dart';
import 'package:sbill_app/ui/screens/expense_editor_sheet.dart';

const channel = MethodChannel('com.sbill.app/fileshare');

Future<void> waitFor(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Test identity operation did not complete');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class ProfileGateway {
  ProfileGateway(this.home, {this.enabled = true});
  final Directory home;
  final bool enabled;
  String active = 'primary';
  int profileCalls = 0;
  String path(String profile) =>
      '${home.path}/$profile/sbill_ledger_v1.sqlite3';
  Future<dynamic> handle(MethodCall call) async {
    switch (call.method) {
      case 'getDatabasePath':
        return path(active);
      case 'getTestConsoleConfig':
        return {'enabled': enabled, 'active_profile': active};
      case 'getTestProfileDatabasePath':
        profileCalls++;
        if (!enabled) throw PlatformException(code: 'TEST_TOOLS_DISABLED');
        return path((call.arguments as Map)['profile'] as String);
      case 'persistTestProfile':
        if (!enabled) throw PlatformException(code: 'TEST_TOOLS_DISABLED');
        active = (call.arguments as Map)['profile'] as String;
        return true;
      case 'consumeIncomingTripDelta':
        return null;
      default:
        throw MissingPluginException();
    }
  }
}

Future<bool> addBill(LedgerController ledger, String title) {
  final actor = ledger.snapshot!.activeActorId;
  return ledger.upsertExpense(
      expenseId: 'test_client',
      parentRevisionEventIds: [],
      currency: 'CNY',
      totalMinor: 3600,
      payers: [PayerContributionModel(participantId: actor, amountMinor: 3600)],
      splitRule:
          SplitRuleModel(kind: SplitModeKind.equal, equalParticipants: [actor]),
      title: title,
      note: '',
      revisionReason: 'test',
      voided: false);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  if (!testToolsEnabled) {
    testWidgets(
        'Normal build has no console and refuses test profile operations',
        (tester) async {
      final home = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('sbill_no_console_')))!;
      final ledger = LedgerController();
      try {
        await tester.runAsync(() => ledger.initializeApp(
            overrideDbPath: '${home.path}/ledger.sqlite3'));
        await tester.pumpWidget(SbillApp(controller: ledger));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('developer_console_bubble')),
            findsNothing);
        expect(find.byKey(const ValueKey('developer_console_panel')),
            findsNothing);
        expect(() => ledger.setTestSessionBusy(true), throwsStateError);
        await expectLater(ledger.openTestWorkspace('${home.path}/peer.sqlite3'),
            throwsStateError);
        final console = TestConsoleController(ledger);
        await expectLater(console.initialize(), throwsStateError);
        console.dispose();
        expect(ledger.testTraces, isEmpty);
        expect(ledger.isTestSessionBusy, isFalse);
      } finally {
        await tester.pumpWidget(const SizedBox());
        ledger.dispose();
        await tester.runAsync(() => home.delete(recursive: true));
      }
    });
  } else {
    test('Dart opt-in without native opt-in cannot open test profiles',
        () async {
      final home = await Directory.systemTemp.createTemp('sbill_native_guard_');
      final gateway = ProfileGateway(home, enabled: false);
      messenger.setMockMethodCallHandler(channel, gateway.handle);
      final ledger = LedgerController();
      final console = TestConsoleController(ledger);
      try {
        await console.initialize();
        expect(console.ready, isFalse);
        await console.switchProfile('peer_b');
        expect(gateway.profileCalls, 0);
        expect(console.activeProfile, 'primary');
      } finally {
        console.dispose();
        ledger.dispose();
        await home.delete(recursive: true);
      }
    });

    test(
        'Failed profile open restores the original signing identity and ledger',
        () async {
      final home =
          await Directory.systemTemp.createTemp('sbill_failed_profile_');
      final gateway = ProfileGateway(home);
      messenger.setMockMethodCallHandler(channel, gateway.handle);
      final ledger = LedgerController();
      final console = TestConsoleController(ledger);
      try {
        await ledger.initializeApp();
        await console.initialize();
        expect(await ledger.createLedger(groupName: '保留我的账本', displayName: 'A'),
            isTrue);
        final fingerprint = ledger.identityFingerprint;
        final group = ledger.snapshot!.groupId;
        final badDatabase = File(gateway.path('peer_b'));
        await badDatabase.parent.create(recursive: true);
        await badDatabase.writeAsString('not a SQLite database');
        await console.switchProfile('peer_b');
        expect(console.activeProfile, 'primary');
        expect(gateway.active, 'primary');
        expect(ledger.identityFingerprint, fingerprint);
        expect(ledger.snapshot!.groupId, group);
        expect(console.status, startsWith('Bad state:'));
        expect(
            ledger.testTraces
                .any((trace) => trace.operation == 'AppOpen' && !trace.ok),
            isTrue);
        expect(ledger.isTestSessionBusy, isFalse);
      } finally {
        console.dispose();
        ledger.dispose();
        await home.delete(recursive: true);
      }
    });

    test(
        'Four independent keys, real claims, isolated writes, package sync and restart',
        () async {
      final home =
          await Directory.systemTemp.createTemp('sbill_four_profiles_');
      final gateway = ProfileGateway(home);
      messenger.setMockMethodCallHandler(channel, gateway.handle);
      final ledger = LedgerController();
      final console = TestConsoleController(ledger);
      try {
        await ledger.initializeApp();
        await console.initialize();
        expect(console.ready, isTrue);
        await console.prepareSharedLedger();
        expect(console.status, startsWith('联调账本已准备'));
        final groupId = ledger.snapshot!.groupId;
        expect(ledger.snapshot!.participants.length, 4);
        expect(
            ledger.snapshot!.participants
                .every((p) => p.boundPublicKey != null),
            isTrue);
        expect(ledger.snapshot!.expenses, isEmpty);
        final fingerprints = <String>{ledger.identityFingerprint};
        await console.switchProfile('peer_b');
        expect(ledger.snapshot!.activeActor.role, MemberRole.financeEditor);
        fingerprints.add(ledger.identityFingerprint);
        expect(await addBill(ledger, 'B 本人录入'), isTrue);
        expect(await ledger.addCompanion('不应被添加', MemberRole.member), isFalse);
        await console.switchProfile('peer_c');
        fingerprints.add(ledger.identityFingerprint);
        expect(ledger.snapshot!.activeActor.role, MemberRole.member);
        expect(ledger.snapshot!.expenses, isEmpty);
        await console.syncSharedLedger();
        expect(console.status, contains('同机测试，不是网络直连'));
        expect(console.activeProfile, 'peer_c');
        expect(
            ledger.snapshot!.expenses.single.displayRevision.title, 'B 本人录入');
        await console.switchProfile('viewer');
        fingerprints.add(ledger.identityFingerprint);
        expect(fingerprints.length, 4);
        expect(ledger.snapshot!.groupId, groupId);
        expect(ledger.snapshot!.activeActor.role, MemberRole.viewer);
        expect(ledger.snapshot!.expenses.length, 1);
        expect(await addBill(ledger, '只读不能录入'), isFalse);
        expect(ledger.snapshot!.expenses.length, 1);
        await ledger.initializeApp();
        expect(ledger.snapshot!.activeActor.role, MemberRole.viewer);
        expect(gateway.active, 'viewer');
        for (var i = 0; i < 105; i++) {
          await ledger.refreshTestState();
        }
        expect(ledger.testTraces.length, 100);
        expect(
            ledger.testTraces.every(
                (t) => t.elapsedMs >= 0 && !t.operation.contains('SBILL-')),
            isTrue);
        ledger.clearTestTraces();
        expect(ledger.testTraces, isEmpty);
        expect(ledger.isTestSessionBusy, isFalse);
      } finally {
        console.dispose();
        ledger.dispose();
        await home.delete(recursive: true);
      }
    });

    testWidgets(
        'Floating console prepares a scene, switches out of an editor and collapses',
        (tester) async {
      final home = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('sbill_console_widget_')))!;
      final gateway = ProfileGateway(home);
      messenger.setMockMethodCallHandler(channel, gateway.handle);
      final ledger = LedgerController();
      await tester.binding.setSurfaceSize(const Size(390, 844));
      try {
        await tester.runAsync(() =>
            ledger.initializeApp(overrideDbPath: gateway.path('primary')));
        await tester.pumpWidget(SbillApp(controller: ledger));
        await tester.pumpAndSettle();
        final bubble = find.byKey(const ValueKey('developer_console_bubble'));
        await tester.tap(bubble);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('developer_console_panel')),
            findsOneWidget);
        await tester.runAsync(() => tester.tap(find.text('准备四身份联调账本')));
        await tester.pumpAndSettle();
        expect(find.text('创建联调场景'), findsOneWidget);
        await tester.runAsync(() => tester.tap(find.text('创建联调场景')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.runAsync(() => waitFor(() =>
            ledger.snapshot?.participants.length == 4 &&
            !ledger.isTestSessionBusy));
        await tester.pumpAndSettle();
        expect(ledger.snapshot!.expenses, isEmpty);
        await tester.tap(find.byTooltip('收起控制台'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('记第一笔'));
        await tester.pumpAndSettle();
        expect(find.byType(ExpenseEditorSheet), findsOneWidget);
        await tester.tap(bubble);
        await tester.pumpAndSettle();
        await tester.runAsync(() => tester.tap(find.text('身份 B')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.runAsync(() => waitFor(() =>
            ledger.snapshot?.activeActor.displayName == '测试 B' &&
            !ledger.isTestSessionBusy));
        await tester.pumpAndSettle();
        expect(find.byType(ExpenseEditorSheet), findsNothing);
        expect(ledger.snapshot!.activeActor.role, MemberRole.financeEditor);
        expect(gateway.active, 'peer_b');
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('收起控制台'));
        await tester.pumpAndSettle();
        await tester.drag(bubble, const Offset(2000, 2000));
        await tester.pumpAndSettle();
        final rect = tester.getRect(bubble);
        expect(rect.right, lessThanOrEqualTo(390));
        expect(rect.bottom, lessThanOrEqualTo(844));
      } finally {
        await tester.pumpWidget(const SizedBox());
        ledger.dispose();
        await tester.runAsync(() => home.delete(recursive: true));
        await tester.binding.setSurfaceSize(null);
      }
    });
  }
}
