import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:twake_chat/generated/l10n/app_localizations.dart';

/// Byte-exact scanning is unavailable in the installed Flutter Web plugin.
/// The Client therefore advertises only qrShow on this platform.
class KeyVerificationQrScannerView extends StatelessWidget {
  const KeyVerificationQrScannerView({
    super.key,
    required this.onScan,
    required this.onCancel,
  });

  final Future<bool> Function(Uint8List bytes) onScan;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => TextButton(
        onPressed: onCancel,
        child: Text(L10n.of(context)!.cancel),
      );
}
