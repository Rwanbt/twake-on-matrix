import 'dart:typed_data';

import 'package:twake_chat/pages/bootstrap/bootstrap_modal_chrome.dart';
import 'package:twake_chat/pages/key_verification/key_verification_emoji_view.dart';
import 'package:twake_chat/pages/key_verification/key_verification_error_view.dart';
import 'package:twake_chat/pages/key_verification/key_verification_qr_choice_view.dart';
import 'package:twake_chat/pages/key_verification/key_verification_qr_payload.dart';
import 'package:twake_chat/pages/key_verification/key_verification_qr_scanner_view.dart';
import 'package:twake_chat/pages/key_verification/key_verification_request_view.dart';
import 'package:twake_chat/pages/key_verification/key_verification_qr_scan_view.dart';
import 'package:twake_chat/pages/key_verification/key_verification_styles.dart';
import 'package:twake_chat/pages/key_verification/key_verification_success_view.dart';
import 'package:twake_chat/pages/key_verification/key_verification_waiting_view.dart';
import 'package:twake_chat/presentation/enum/key_verification/key_verification_code_enum.dart';
import 'package:twake_chat/utils/dialog/twake_dialog.dart';
import 'package:twake_chat/utils/responsive/responsive_utils.dart';
import 'package:twake_chat/widgets/twake_components/twake_text_button.dart';
import 'package:flutter/material.dart';

import 'package:adaptive_dialog/adaptive_dialog.dart';
import 'package:twake_chat/generated/l10n/app_localizations.dart';
import 'package:linagora_design_flutter/colors/linagora_sys_colors.dart';

import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';

class KeyVerificationDialog extends StatefulWidget {
  /// Shows as a centered modal on web/desktop and a bottom sheet on mobile
  /// via [BootstrapModalChrome], matching the verify-device design.
  Future<void> show(BuildContext context) async {
    await TwakeDialog.showDialogFullScreen(
      builder: () => this,
      barrierDismissible: false,
      useSafeArea: false,
    );
  }

  final KeyVerification request;

  const KeyVerificationDialog({super.key, required this.request});

  @override
  KeyVerificationPageState createState() => KeyVerificationPageState();
}

class KeyVerificationPageState extends State<KeyVerificationDialog> {
  void Function()? originalOnUpdate;
  bool _qrConfirmationInFlight = false;
  bool _qrChoiceInFlight = false;
  bool _scanningQr = false;
  String? _qrErrorMessage;

  @override
  void initState() {
    originalOnUpdate = widget.request.onUpdate;
    widget.request.onUpdate = () {
      originalOnUpdate?.call();
      if (mounted) setState(() {});
    };
    widget.request.client.getProfileFromUserId(widget.request.userId).then((p) {
      if (!mounted) return;
      profile = p;
      setState(() {});
    }, onError: (Object _) {
      // A network/profile failure must not interrupt an active verification.
    });
    super.initState();
  }

  @override
  void dispose() {
    widget.request.onUpdate =
        originalOnUpdate; // don't want to get updates anymore
    if (![
      KeyVerificationState.error,
      KeyVerificationState.done,
    ].contains(widget.request.state)) {
      widget.request.cancel(KeyVerificationCodeEnum.user.code);
    }
    super.dispose();
  }

  Profile? profile;

  Future<void> startSas() async {
    if (_qrChoiceInFlight ||
        widget.request.state != KeyVerificationState.askChoice ||
        !widget.request.possibleMethods.contains(EventTypes.Sas)) {
      return;
    }
    setState(() => _qrChoiceInFlight = true);
    try {
      await widget.request.continueVerification(EventTypes.Sas);
    } catch (_) {
      await _failQrVerification();
    } finally {
      if (mounted) setState(() => _qrChoiceInFlight = false);
    }
  }

  Future<bool> scanMatrixQr(Uint8List bytes) async {
    if (_qrChoiceInFlight ||
        widget.request.state != KeyVerificationState.askChoice ||
        !widget.request.possibleMethods.contains(EventTypes.QRScan) ||
        !widget.request.possibleMethods.contains(EventTypes.Reciprocate) ||
        !isMatrixVerificationQrPayload(bytes)) {
      return false;
    }
    setState(() => _qrChoiceInFlight = true);
    try {
      // SDK verifies transaction ID, cross-signing keys and shared secret,
      // and issues m.reciprocate.v1. UI never grants trust directly.
      await widget.request.continueVerification(
        EventTypes.Reciprocate,
        qrDataRawBytes: bytes,
      );
      return widget.request.state != KeyVerificationState.askChoice;
    } catch (_) {
      await _failQrVerification();
      return false;
    } finally {
      if (mounted) setState(() => _qrChoiceInFlight = false);
    }
  }

  Future<void> _failQrVerification() async {
    try {
      await widget.request.cancel('m.invalid_message');
    } catch (_) {
      if (mounted) {
        setState(() {
          _scanningQr = false;
          _qrErrorMessage = 'The verification could not be completed.';
        });
      }
    }
  }

  Future<void> confirmQrScan({required bool matches}) async {
    if (_qrConfirmationInFlight ||
        widget.request.state != KeyVerificationState.confirmQRScan) {
      return;
    }
    setState(() => _qrConfirmationInFlight = true);
    try {
      if (matches) {
        // This is the SDK's cryptographic confirmation boundary: only an
        // explicit match by the user can advance QR verification to trusted.
        await widget.request.acceptQRScanConfirmation();
      } else {
        await widget.request.cancel(KeyVerificationCodeEnum.user.code);
      }
    } catch (_) {
      await _failQrVerification();
    } finally {
      if (mounted) setState(() => _qrConfirmationInFlight = false);
    }
  }

  Future<void> checkInput(String input) async {
    if (input.isEmpty) return;

    final valid = await TwakeDialog.showFutureLoadingDialogFullScreen(
      future: () async {
        // make sure the loading spinner shows before we test the keys
        await Future.delayed(const Duration(milliseconds: 100));
        var valid = false;
        try {
          await widget.request.openSSSS(keyOrPassphrase: input);
          valid = true;
        } catch (_) {
          valid = false;
        }
        return valid;
      },
    );
    // A wrong recovery key is caught inside the loading callback and returned
    // as false. It does not populate FutureLoadingDialogResult.error.
    if (!mounted) return;
    if (valid.error != null || valid.result != true) {
      await showOkAlertDialog(
        useRootNavigator: false,
        context: context,
        message: L10n.of(context)!.incorrectPassphraseOrKey,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context)!;
    final theme = Theme.of(context);
    final linagoraSysColors = LinagoraSysColors.material();
    User? user;
    final directChatId = widget.request.client.getDirectChatFromUserId(
      widget.request.userId,
    );
    if (directChatId != null) {
      user = widget.request.client
          .getRoomById(directChatId)!
          .unsafeGetUserFromMemoryOrFallback(widget.request.userId);
    }
    final displayName =
        user?.calcDisplayname() ?? widget.request.userId.localpart!;
    Widget? title;
    Widget body;
    final buttons = <Widget>[];
    switch (widget.request.state) {
      case KeyVerificationState.showQRSuccess:
        // Scanning is complete, but the other device must still confirm the
        // green shield before the SDK reaches the verified/done state.
        body = const KeyVerificationQrScanView(waitingForPartner: true);
        break;
      case KeyVerificationState.confirmQRScan:
        body = KeyVerificationQrScanView(
          waitingForPartner: false,
          busy: _qrConfirmationInFlight,
          onMatch: () => confirmQrScan(matches: true),
          onDontMatch: () => confirmQrScan(matches: false),
        );
        break;
      case KeyVerificationState.askSSSS:
        // prompt the user for their ssss passphrase / key
        final textEditingController = TextEditingController();
        String input;
        title = Text(l10n.verifyTitle);
        body = Container(
          margin: const EdgeInsets.only(left: 8.0, right: 8.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(l10n.askSSSSSign, style: const TextStyle(fontSize: 20)),
              Container(height: 10),
              TextField(
                controller: textEditingController,
                autofocus: false,
                autocorrect: false,
                onSubmitted: (s) {
                  input = s;
                  checkInput(input);
                },
                minLines: 1,
                maxLines: 1,
                obscureText: true,
                decoration: InputDecoration(
                  hintText: l10n.passphraseOrKey,
                  prefixStyle: TextStyle(color: theme.primaryColor),
                  suffixStyle: TextStyle(color: theme.primaryColor),
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
        );
        buttons.add(
          TwakeTextButton(
            onTap: () => checkInput(textEditingController.text),
            message: l10n.submit,
            borderHover: KeyVerificationStyles.borderHoverButtonWaningBanner,
            styleMessage: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.primary,
            ),
            margin: KeyVerificationStyles.marginButtonWarningBanner,
            buttonDecoration: BoxDecoration(
              color: linagoraSysColors.onPrimary,
              borderRadius: const BorderRadius.all(Radius.circular(100)),
            ),
          ),
        );
        buttons.add(
          TwakeTextButton(
            onTap: () => widget.request.openSSSS(skip: true),
            message: l10n.skip,
            borderHover: KeyVerificationStyles.borderHoverButtonWaningBanner,
            styleMessage: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.primary,
            ),
            margin: KeyVerificationStyles.marginButtonWarningBanner,
            buttonDecoration: BoxDecoration(
              color: linagoraSysColors.onPrimary,
              borderRadius: const BorderRadius.all(Radius.circular(100)),
            ),
          ),
        );
        break;
      case KeyVerificationState.askAccept:
        // View owns title + body + actions — avoid a second title/button
        // layer from the outer dialog chrome below.
        body = KeyVerificationRequestView(
          displayName: displayName,
          avatarUri: profile?.avatarUrl ?? user?.avatarUrl,
          onAccept: widget.request.acceptVerification,
          onReject: () => widget.request.rejectVerification().then((_) {
            if (context.mounted) Navigator.maybePop(context);
          }),
        );
        break;
      case KeyVerificationState.askChoice:
        final qr = widget.request.qrCode;
        final showQr =
            widget.request.possibleMethods.contains(EventTypes.QRShow) &&
                qr != null;
        final canScan =
            widget.request.possibleMethods.contains(EventTypes.QRScan) &&
                widget.request.possibleMethods.contains(EventTypes.Reciprocate);
        if (_scanningQr && canScan) {
          body = KeyVerificationQrScannerView(
            onScan: scanMatrixQr,
            onCancel: () => setState(() => _scanningQr = false),
          );
        } else {
          body = KeyVerificationQrChoiceView(
            qrBytes: showQr ? Uint8List.fromList(qr!.qrDataRawBytes) : null,
            canScan: canScan,
            canUseSas: widget.request.possibleMethods.contains(EventTypes.Sas),
            busy: _qrChoiceInFlight,
            onScan: () => setState(() => _scanningQr = true),
            onSas: startSas,
            errorMessage: _qrErrorMessage,
          );
        }
        break;
      case KeyVerificationState.waitingAccept:
        body = const KeyVerificationWaitingView();
        break;
      case KeyVerificationState.askSas:
        if (widget.request.sasTypes.contains('emoji')) {
          body = KeyVerificationEmojiView(
            emojis: widget.request.sasEmojis,
            onDontMatch: widget.request.rejectSas,
            onMatch: widget.request.acceptSas,
          );
        } else {
          title = Text(l10n.compareNumbersMatch);
          final numbers = widget.request.sasNumbers;
          final numbstr = '${numbers[0]}-${numbers[1]}-${numbers[2]}';
          body = Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                numbstr,
                style: const TextStyle(fontSize: 40),
                textAlign: TextAlign.center,
              ),
            ],
          );
          buttons.add(
            TwakeTextButton(
              onTap: widget.request.rejectSas,
              message: l10n.theyDontMatch,
              borderHover: KeyVerificationStyles.borderHoverButtonWaningBanner,
              styleMessage: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
              ),
              margin: KeyVerificationStyles.marginButtonWarningBanner,
              buttonDecoration: BoxDecoration(
                color: linagoraSysColors.onPrimary,
                borderRadius: const BorderRadius.all(Radius.circular(100)),
              ),
              constraints: BoxConstraints(
                maxWidth: KeyVerificationStyles.maxWidthMatchButton(context),
              ),
            ),
          );
          buttons.add(
            TwakeTextButton(
              onTap: widget.request.acceptSas,
              message: l10n.theyMatch,
              borderHover: KeyVerificationStyles.borderHoverButtonWaningBanner,
              styleMessage: theme.textTheme.labelLarge?.copyWith(
                color: linagoraSysColors.onPrimary,
              ),
              margin: KeyVerificationStyles.marginButtonWarningBanner,
              buttonDecoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(100),
              ),
              constraints: BoxConstraints(
                maxWidth: KeyVerificationStyles.maxWidthMatchButton(context),
              ),
            ),
          );
        }
        break;
      case KeyVerificationState.waitingSas:
        final acceptText = widget.request.sasTypes.contains('emoji')
            ? l10n.waitingPartnerEmoji
            : l10n.waitingPartnerNumbers;
        body = Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const CircularProgressIndicator.adaptive(strokeWidth: 2),
            const SizedBox(height: 10),
            Text(acceptText, textAlign: TextAlign.center),
          ],
        );
        break;
      case KeyVerificationState.done:
        body = KeyVerificationSuccessView(
          onStartChatting: () => Navigator.maybePop(context),
        );
        break;
      case KeyVerificationState.error:
        body = KeyVerificationErrorView(
          canceledCode: widget.request.canceledCode,
          canceledReason: widget.request.canceledReason,
          onClose: () => Navigator.maybePop(context),
        );
        break;
    }
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null) ...[
          DefaultTextStyle.merge(
            style: theme.textTheme.titleLarge,
            textAlign: TextAlign.center,
            child: title,
          ),
          const SizedBox(height: 12),
        ],
        body,
        if (buttons.isNotEmpty) ...[
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: buttons),
        ],
      ],
    );

    return BootstrapModalChrome(
      onClose: () => Navigator.maybePop(context),
      // Mobile sheet scrolls already; wrap the web modal for short viewports.
      content: ResponsiveUtils().isMobile(context)
          ? content
          : ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.8,
              ),
              child: SingleChildScrollView(child: content),
            ),
    );
  }
}
