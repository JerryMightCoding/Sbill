import 'package:flutter_test/flutter_test.dart';
import 'package:sbill_app/state/ledger_controller.dart';

void main() {
  test('M6 Sync Center: .tripdelta export/import idempotency and WebDAV async sync with tampering defense', () async {
    final controller = LedgerController();
    await controller.resetDemoWorkspace();

    expect(controller.snapshot!.expenses.length, 2);

    // 1. Export .tripdelta and verify compact code
    final expOk = await controller.exportTripDelta();
    expect(expOk, isTrue);
    final code = controller.snapshot!.lastSyncReport!.exportedCompactCode!;
    expect(code.startsWith('SBILL1:'), isTrue);

    // 2. Re-importing same compact code is idempotent
    final impOk = await controller.importTripDelta(code);
    expect(impOk, isTrue);
    expect(controller.snapshot!.lastSyncReport!.addedEvents, 0);

    // 3. Simulate receiving peer .tripdelta incremental package -> adds 1 expense
    final peerOk = await controller.simulatePeerTripDelta(autoImport: true);
    expect(peerOk, isTrue);
    expect(controller.snapshot!.expenses.length, 3);

    // 4. Simulate offline/unreachable WebDAV -> pending uploads stay queued
    await controller.configureWebDav(
      endpointUrl: 'https://nas.local:5006/webdav',
      username: 'sbill_member',
      simulateUnreachable: true,
    );
    await controller.syncWebDavNow();
    expect(controller.snapshot!.lastSyncReport!.failedUploads, greaterThan(0));

    // 5. Restore WebDAV, simulate remote async upload + tampered object, and sync
    await controller.configureWebDav(
      endpointUrl: 'https://nas.local:5006/webdav',
      username: 'sbill_member',
      simulateUnreachable: false,
    );
    await controller.simulateRemoteWebDavIncoming(injectTampered: true);
    await controller.syncWebDavNow();

    expect(controller.snapshot!.webDavStatus.pendingUploadCount, 0);
    expect(controller.snapshot!.expenses.length, 4);
    expect(
      controller.snapshot!.lastSyncReport!.rejectedOrTampered,
      greaterThanOrEqualTo(1),
    );
  });
}
