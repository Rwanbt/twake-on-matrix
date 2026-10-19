import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:qr_code_scanner/qr_code_scanner.dart';
import 'package:twake_chat/generated/l10n/app_localizations.dart';
import 'package:twake_chat/pages/key_verification/key_verification_qr_payload.dart';

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
  StreamSubscription<Barcode>? _subscription;
  bool _busy = false;
  String? _error;

  void _onQRViewCreated(QRViewController controller) {
    _controller = controller;
    _subscription = controller.scannedDataStream.listen((scan) {
      if (!_busy) unawaited(_handleScan(scan));
    });
    unawaited(controller.resumeCamera());
  }

  Future<void> _handleScan(Barcode scan) async {
    if (!mounted || _busy) return;
    final raw = scan.rawBytes;
    if (raw == null ||
        !isMatrixVerificationQrPayload(Uint8List.fromList(raw))) {
      setState(() => _error = 'Not a valid Matrix verification QR code.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _controller?.pauseCamera();
      final accepted = await widget.onScan(Uint8List.fromList(raw));
      if (mounted && !accepted) {
        setState(() => _error = 'The Matrix verification was rejected.');
        await _controller?.resumeCamera();
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Unable to complete Matrix QR verification.');
        await _controller?.resumeCamera();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
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
