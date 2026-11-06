import 'package:flutter_test/flutter_test.dart';
import 'package:sbill_app/state/ledger_controller.dart';

void main() {
  // LedgerController.configureLanDiscovery goes through a MethodChannel, which needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('M7 LAN No-WAN Gap Fill & Optical Fountain QR Airgap Transfer', () async {
    final controller = LedgerController();
    await controller.resetDemoWorkspace();

    expect(controller.snapshot!.expenses.length, 2);
    expect(controller.snapshot!.lanStatus.discoveredPeers, isNotEmpty);

    // 1. Hotel AP isolation blocks direct LAN sync and advises hotspot/QR fallback (AC-L02)
    await controller.configureLanDiscovery(apIsolationDetected: true);
    expect(controller.snapshot!.lanStatus.apIsolationDetected, isTrue);
    final blockedLan = await controller.syncLanWithPeer(
      peerMemberId: 'B',
      simulateGapFill: true,
    );
    expect(blockedLan, isFalse);

    // 2. Restore LAN reachability and execute gap-filling direct sync (AC-L01, AC-L04)
    await controller.configureLanDiscovery(apIsolationDetected: false);
    final lanOk = await controller.syncLanWithPeer(
      peerMemberId: 'B',
      simulateGapFill: true,
    );
    expect(lanOk, isTrue);
    expect(controller.snapshot!.expenses.length, 4);

    // 3. Configure slow 2 FPS optical mode (AC-Q05) and run mid-stream fountain QR recovery (AC-Q01..Q03)
    await controller.generateOpticalFrames(slowMode: true);
    expect(controller.snapshot!.opticalSession.recommendedFps, 2);

    final qrOk = await controller.simulateOpticalAirgapTransfer(
      dropFirstTwoFrames: true,
    );
    expect(qrOk, isTrue);
    expect(controller.snapshot!.opticalSession.receiverComplete, isTrue);
    expect(controller.snapshot!.expenses.length, 5);
  });
}
