import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../build_config.dart';
import '../../state/ledger_controller.dart';
import '../../utils/qr_code_matrix.dart';
import '../theme/app_theme.dart';

/// M7 Optical Fountain QR Sync Screen (AC-Q01..Q05):
/// - Renders standard ISO/IEC 18004 animated fountain-coded QR frames (`OpticalQrFrameModel`)
///   with a stable white quiet zone (no whole-screen strobe flashing)
/// - Supports Standard (5 FPS), Low-light/Low-end Slow Mode (2 FPS), and Manual step-by-step paging
/// - Displays live peeling fountain decoder progress (`solved_slices / total_slices`),
///   supporting mid-stream start, dropped frame recovery via XOR parity frames, camera scan & multi-frame stream ingestion
class OpticalQrSyncScreen extends StatefulWidget {
  const OpticalQrSyncScreen({
    super.key,
    required this.controller,
  });

  final LedgerController controller;

  @override
  State<OpticalQrSyncScreen> createState() => _OpticalQrSyncScreenState();
}

class _OpticalQrSyncScreenState extends State<OpticalQrSyncScreen> {
  Timer? _frameTimer;
  int _currentFrameIdx = 0;
  bool _autoPlaying = true;
  bool _slowMode = false;

  @override
  void initState() {
    super.initState();
    _slowMode = widget.controller.snapshot?.opticalSession.slowMode ?? false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final frames =
          widget.controller.snapshot?.opticalSession.outgoingFrames ?? const [];
      if (frames.isEmpty) {
        widget.controller.generateOpticalFrames(slowMode: _slowMode);
      }
    });
    _restartTimer();
  }

  @override
  void dispose() {
    _frameTimer?.cancel();
    super.dispose();
  }

  void _restartTimer() {
    _frameTimer?.cancel();
    if (!_autoPlaying) return;
    final fps = _slowMode ? 2 : 5;
    _frameTimer = Timer.periodic(
      Duration(milliseconds: 1000 ~/ fps),
      (_) {
        final frames =
            widget.controller.snapshot?.opticalSession.outgoingFrames ??
                const [];
        if (frames.isNotEmpty && mounted) {
          setState(() {
            _currentFrameIdx = (_currentFrameIdx + 1) % frames.length;
          });
        }
      },
    );
  }

  Future<void> _openScanOrStreamDialog(BuildContext context) async {
    final scanned = await widget.controller.scanQrCodeViaNativeCamera();
    if (!context.mounted) return;
    if (scanned != null &&
        scanned.isNotEmpty &&
        scanned != 'CAMERA_READY_USE_STREAM') {
      final ok = await widget.controller.ingestOpticalFrameStream(scanned);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? (widget.controller.snapshot?.lastSyncReport?.summaryTitle ??
                    '已扫入二维码分片')
                : (widget.controller.lastError ?? '二维码分片无效'),
          ),
        ),
      );
      return;
    }

    final inputCtrl = TextEditingController();
    var dropFirstTwo = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('相机扫码 / 连续帧流接收'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '用系统相机/扫码器识别对方屏幕上的瀑布二维码后粘贴到下方（支持单帧 JSON、多帧 JSON 流或 SBILL1: 同步码）。',
                    style: TextStyle(fontSize: 12, color: AppTheme.mutedSlate),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    key: const ValueKey('optical_stream_input'),
                    controller: inputCtrl,
                    minLines: 3,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      labelText: '扫码结果或喷泉码多帧 JSON 流',
                      hintText: '{"package_id":...} 或多行帧流',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: dropFirstTwo,
                    onChanged: (v) =>
                        setDialogState(() => dropFirstTwo = v ?? false),
                    title: const Text(
                      '模拟中途起扫（自动丢弃前 2 帧，验证 XOR 冗余恢复）',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('confirm_optical_stream_ingest'),
              onPressed: () async {
                final ok = await widget.controller.ingestOpticalFrameStream(
                  inputCtrl.text,
                  dropFirstTwoFrames: dropFirstTwo,
                );
                if (!ctx.mounted) return;
                if (ok) {
                  Navigator.of(ctx).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        widget.controller.snapshot?.lastSyncReport
                                ?.summaryTitle ??
                            '已更新喷泉码解码进度',
                      ),
                    ),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(widget.controller.lastError ?? '解析二维码帧失败'),
                    ),
                  );
                }
              },
              child: const Text('解码并导入'),
            ),
          ],
        ),
      ),
    );
    inputCtrl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final snap = widget.controller.snapshot!;
        final optical = snap.opticalSession;
        final frames = optical.outgoingFrames;
        final safeIdx =
            frames.isEmpty ? 0 : (_currentFrameIdx % frames.length);
        final currentFrame = frames.isEmpty ? null : frames[safeIdx];
        final frameJson =
            currentFrame == null ? null : jsonEncode(currentFrame.toJson());
        final qrMatrix =
            frameJson == null ? null : QrCodeMatrix.encodeText(frameJson);

        return Scaffold(
          appBar: AppBar(
            title: const Text('动态二维码面对面无网传输 (UR/喷泉码)'),
            actions: [
              IconButton(
                tooltip: '重新生成当前账本二维码流',
                onPressed: () => widget.controller.generateOpticalFrames(
                  slowMode: _slowMode,
                ),
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // 1. 发送端：标准 ISO/IEC 18004 动态二维码喷泉码展示器
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: currentFrame?.isParityFrame == true
                                  ? AppTheme.conflictAmber
                                      .withValues(alpha: 0.15)
                                  : AppTheme.primaryTeal
                                      .withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              currentFrame == null
                                  ? '无分片'
                                  : (currentFrame.isParityFrame
                                      ? '喷泉码 XOR 冗余帧 ${currentFrame.sourceIndices}'
                                      : '源数据分片帧 #${currentFrame.sourceIndices.first}'),
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: currentFrame?.isParityFrame == true
                                    ? AppTheme.conflictAmber
                                    : AppTheme.primaryTeal,
                              ),
                            ),
                          ),
                          Text(
                            frames.isEmpty
                                ? '0 / 0 帧'
                                : '帧 ${safeIdx + 1}/${frames.length} (${_slowMode ? "2 FPS" : "5 FPS"})',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Colors.blueGrey,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // 保持纯白 4-module Quiet Zone 背景稳定，只刷新内部标准 QR 模块，不做整屏明暗频闪 (AC-Q05)
                      Container(
                        width: 264,
                        height: 264,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: Colors.grey.shade300,
                            width: 1.5,
                          ),
                        ),
                        child: qrMatrix == null
                            ? const Center(child: Text('无二维码帧'))
                            : CustomPaint(
                                key: ValueKey(
                                  'qr_frame_${currentFrame!.frameDigest}',
                                ),
                                painter: _StandardQrMatrixPainter(
                                  matrix: qrMatrix,
                                ),
                              ),
                      ),
                      const SizedBox(height: 12),
                      if (currentFrame != null && qrMatrix != null)
                        Text(
                          'ISO QR v${qrMatrix.version} (${qrMatrix.size}×${qrMatrix.size}) · 包 ID: ${currentFrame.packageId.substring(0, currentFrame.packageId.length.clamp(0, 12))} · 总长 ${currentFrame.totalByteLen} B · 源分片 ${currentFrame.totalSourceSlices} 块',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.blueGrey,
                          ),
                        ),
                      const SizedBox(height: 12),

                      // 速率与手动翻页控制栏
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        alignment: WrapAlignment.center,
                        children: [
                          FilterChip(
                            label: Text(_autoPlaying ? '自动轮播中' : '已暂停 (手动翻页)'),
                            selected: _autoPlaying,
                            onSelected: (v) {
                              setState(() {
                                _autoPlaying = v;
                                _restartTimer();
                              });
                            },
                          ),
                          FilterChip(
                            label: const Text('低端机/反光慢速 (2 FPS)'),
                            selected: _slowMode,
                            onSelected: (v) {
                              setState(() {
                                _slowMode = v;
                                _restartTimer();
                              });
                              widget.controller.generateOpticalFrames(
                                slowMode: v,
                              );
                            },
                          ),
                          IconButton.outlined(
                            onPressed: frames.isEmpty
                                ? null
                                : () {
                                    setState(() {
                                      _autoPlaying = false;
                                      _frameTimer?.cancel();
                                      _currentFrameIdx =
                                          (_currentFrameIdx - 1 + frames.length) %
                                              frames.length;
                                    });
                                  },
                            icon: const Icon(Icons.chevron_left),
                          ),
                          IconButton.outlined(
                            onPressed: frames.isEmpty
                                ? null
                                : () {
                                    setState(() {
                                      _autoPlaying = false;
                                      _frameTimer?.cancel();
                                      _currentFrameIdx =
                                          (_currentFrameIdx + 1) %
                                              frames.length;
                                    });
                                  },
                            icon: const Icon(Icons.chevron_right),
                          ),
                          OutlinedButton.icon(
                            key: const ValueKey('copy_all_optical_frames'),
                            onPressed: frames.isEmpty
                                ? null
                                : () async {
                                    final streamText = frames
                                        .map((f) => jsonEncode(f.toJson()))
                                        .join('\n');
                                    await Clipboard.setData(
                                      ClipboardData(text: streamText),
                                    );
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            '已复制全部 ${frames.length} 帧喷泉码数据流',
                                          ),
                                        ),
                                      );
                                    }
                                  },
                            icon: const Icon(Icons.copy_all_rounded, size: 16),
                            label: const Text('复制全部帧流'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // 2. 接收端：喷泉码剥离解码器状态与中途起扫/丢帧恢复验证 (AC-Q01..Q03)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(
                            Icons.qr_code_scanner_rounded,
                            color: AppTheme.primaryTeal,
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '接收端：喷泉码剥离解码器 (Peeling Decoder)',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 15,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        '支持从动画中途任意帧开始扫描，漏扫部分源数据帧时自动通过 XOR 冗余帧方程组恢复；接收进度自动持久化落盘，切换不同包 ID 时隔离旧分片 (AC-Q02/Q03)。',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.blueGrey,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                        value: optical.receiverProgress,
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        alignment: WrapAlignment.spaceBetween,
                        children: [
                          Text(
                            '已解出源分片: ${optical.receiverSolvedSlices} / ${optical.receiverTotalSlices}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            optical.receiverComplete
                                ? '已完整恢复并验签入账'
                                : '等待继续扫描分片...',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: optical.receiverComplete
                                  ? AppTheme.creditEmerald
                                  : AppTheme.primaryTeal,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            key: const ValueKey('open_qr_scanner_button'),
                            onPressed: () => _openScanOrStreamDialog(context),
                            icon: const Icon(
                              Icons.camera_alt_outlined,
                              size: 17,
                            ),
                            label: const Text('相机扫码 / 粘贴帧流'),
                          ),
                          OutlinedButton.icon(
                            onPressed: currentFrame == null
                                ? null
                                : () {
                                    final raw =
                                        jsonEncode(currentFrame.toJson());
                                    widget.controller.ingestOpticalFrame(raw);
                                  },
                            icon: const Icon(
                              Icons.center_focus_strong_outlined,
                              size: 17,
                            ),
                            label: const Text('扫入当前展示帧'),
                          ),
                          if (!widget.controller.isAppMode ||
                              testToolsEnabled)
                            OutlinedButton.icon(
                              onPressed: () async {
                                final ok = await widget.controller
                                    .simulateOpticalAirgapTransfer(
                                  dropFirstTwoFrames: true,
                                );
                                if (ok && context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        '已模拟从第 3 帧中途起扫（漏掉前 2 帧）并靠喷泉码成功恢复同伴新账单！',
                                      ),
                                    ),
                                  );
                                }
                              },
                              icon: const Icon(Icons.auto_fix_high, size: 17),
                              label: const Text('模拟中途起扫+丢帧恢复'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Renders a genuine ISO/IEC 18004 QR code matrix with high contrast.
class _StandardQrMatrixPainter extends CustomPainter {
  _StandardQrMatrixPainter({required this.matrix});

  final QrCodeMatrix matrix;

  @override
  void paint(Canvas canvas, Size size) {
    final n = matrix.size;
    final cell = size.width / n;
    final darkPaint = Paint()
      ..color = const Color(0xFF0F172A)
      ..style = PaintingStyle.fill;

    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        if (matrix.modules[r][c]) {
          canvas.drawRect(
            Rect.fromLTWH(c * cell, r * cell, cell + 0.35, cell + 0.35),
            darkPaint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _StandardQrMatrixPainter oldDelegate) {
    return oldDelegate.matrix != matrix;
  }
}
