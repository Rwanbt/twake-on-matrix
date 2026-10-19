import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:qr_code_scanner/qr_code_scanner.dart';
import 'package:twake_chat/generated/l10n/app_localizations.dart';
import 'package:twake_chat/pages/key_verification/key_verification_qr_scan_lifecycle.dart';

/// Reads exact QR bytes on Android/iOS. Never converts a Matrix payload from
/// Barcode.code (a string): UTF-8 replacement would corrupt its shared secret.
class KeyVerificationQrScannerView extends StatefulWidget {
  const KeyVerificationQrScannerView({
    super.key,
    required this.onScan,
    required this.onCancel,
  });

  final Future<bool> Function(Uint8List bytes) onScan;
  final VoidCallback onCancel;

  @override
  State<KeyVerificationQrScannerView> createState() =>
      _KeyVerificationQrScannerViewState();
}

class _KeyVerificationQrScannerViewState
    extends State<KeyVerificationQrScannerView> {
  final GlobalKey _qrKey = GlobalKey(debugLabel: 'matrix-verification-qr');
  QRViewController? _controller;
  late final MatrixQrScanLifecycle _lifecycle;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _lifecycle = MatrixQrScanLifecycle(
      onScan: widget.onScan,
      onFeedback: (feedback) {
        if (!mounted) return;
        String? error = _error;
        switch (feedback) {
          case MatrixQrScanFeedback.invalid:
            error = 'Not a valid Matrix verification QR code.';
          case MatrixQrScanFeedback.rejected:
            error = 'The Matrix verification was rejected.';
          case MatrixQrScanFeedback.failed:
            error = 'Unable to complete Matrix QR verification.';
          case MatrixQrScanFeedback.busy:
          case MatrixQrScanFeedback.accepted:
            error = null;
          case MatrixQrScanFeedback.idle:
            break;
        }
        if (_busy != _lifecycle.busy || error != _error) {
          setState(() {
            _busy = _lifecycle.busy;
            _error = error;
          });
        }
      },
    );
  }

  void _onQRViewCreated(QRViewController controller) {
    if (identical(_controller, controller)) return;
    final previous = _controller;
    _controller = controller;
    _lifecycle.bind(
      frames: controller.scannedDataStream.map((scan) {
        final raw = scan.rawBytes;
        return raw == null ? null : Uint8List.fromList(raw);
      }),
      pauseCamera: controller.pauseCamera,
      resumeCamera: controller.resumeCamera,
    );
    previous?.dispose();
    unawaited(controller.resumeCamera().onError((Object _, StackTrace __) {
      if (identical(_controller, controller)) {
        _lifecycle.cameraFailure();
      }
    }));
  }

  @override
  void dispose() {
    unawaited(_lifecycle.dispose());
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context)!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l10n.scanQrCode, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        SizedBox(
          height: 260,
          width: 260,
          child: QRView(
            key: _qrKey,
            onQRViewCreated: _onQRViewCreated,
            overlay: QrScannerOverlayShape(
              borderColor: Theme.of(context).colorScheme.primary,
              borderLength: 25,
              borderRadius: 8,
              borderWidth: 6,
            ),
          ),
        ),
        if (_error != null) Text(_error!, textAlign: TextAlign.center),
        if (_busy) const CircularProgressIndicator.adaptive(),
        TextButton(
          onPressed: _busy ? null : widget.onCancel,
          child: Text(l10n.cancel),
        ),
      ],
    );
  }
}
