import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:twake_chat/generated/l10n/app_localizations.dart';
import 'package:twake_chat/widgets/twake_components/twake_qr_code_view.dart';

/// Presents QR bytes created by the Matrix SDK; no trust decision is made here.
class KeyVerificationQrChoiceView extends StatelessWidget {
  const KeyVerificationQrChoiceView({
    super.key,
    this.qrBytes,
    required this.canScan,
    required this.canUseSas,
    required this.busy,
    required this.onScan,
    required this.onSas,
    this.errorMessage,
  });

  final Uint8List? qrBytes;
  final bool canScan;
  final bool canUseSas;
  final bool busy;
  final VoidCallback onScan;
  final VoidCallback onSas;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context)!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l10n.verifyTitle, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        if (qrBytes != null) ...[
          TwakeQrCodeView.fromBytes(bytes: qrBytes!, size: 208),
          const SizedBox(height: 8),
          Text(
            l10n.checkYourOtherDeviceDescription,
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 12),
        if (errorMessage != null)
          Text(errorMessage!, textAlign: TextAlign.center),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            if (canScan)
              FilledButton.icon(
                onPressed: busy ? null : onScan,
                icon: const Icon(Icons.qr_code_scanner),
                label: Text(l10n.scanQrCode),
              ),
            if (canUseSas)
              OutlinedButton(
                onPressed: busy ? null : onSas,
                child: Text(l10n.compareNumbersMatch),
              ),
          ],
        ),
      ],
    );
  }
}
