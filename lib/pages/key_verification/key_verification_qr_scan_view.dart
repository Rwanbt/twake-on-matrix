import 'package:flutter/material.dart';
import 'package:twake_chat/generated/l10n/app_localizations.dart';

/// Confirmation step for the Matrix SDK's m.reciprocate.v1 QR verification.
///
/// A scan alone does not establish trust. The person showing the QR must
/// explicitly confirm that the other device displays the green shield.
class KeyVerificationQrScanView extends StatelessWidget {
  const KeyVerificationQrScanView({
    super.key,
    required this.waitingForPartner,
    this.busy = false,
    this.onMatch,
    this.onDontMatch,
  });

  final bool waitingForPartner;
  final bool busy;
  final VoidCallback? onMatch;
  final VoidCallback? onDontMatch;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context)!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          waitingForPartner
              ? Icons.verified_user
              : Icons.verified_user_outlined,
          // The SDK's scanner shows a green shield after validating QR bytes.
          // The other person must visibly compare this before confirming.
          color: waitingForPartner
              ? Colors.green.shade700
              : Theme.of(context).colorScheme.primary,
          size: 56,
          semanticLabel: waitingForPartner
              ? l10n.checkYourOtherDevice
              : l10n.verifyTitle,
        ),
        const SizedBox(height: 16),
        Text(
          waitingForPartner ? l10n.checkYourOtherDevice : l10n.verifyTitle,
          style: Theme.of(context).textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          waitingForPartner
              ? l10n.checkYourOtherDeviceDescription
              : 'Does the other device show the green verification shield?',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        if (waitingForPartner)
          const CircularProgressIndicator.adaptive()
        else
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: busy ? null : onDontMatch,
                child: Text(l10n.theyDontMatch),
              ),
              FilledButton(
                onPressed: busy ? null : onMatch,
                child: Text(l10n.theyMatch),
              ),
            ],
          ),
      ],
    );
  }
}
