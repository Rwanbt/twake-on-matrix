import 'package:twake_chat/config/localizations/localization_service.dart';
import 'package:twake_chat/generated/l10n/app_localizations.dart';
import 'package:twake_chat/pages/key_verification/key_verification_emoji_view.dart';
import 'package:twake_chat/pages/key_verification/key_verification_error_view.dart';
import 'package:twake_chat/pages/key_verification/key_verification_success_view.dart';
import 'package:twake_chat/pages/key_verification/key_verification_waiting_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/encryption.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: const [
      L10n.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    supportedLocales: LocalizationService.supportedLocales,
    home: Scaffold(body: child),
  );
}

void main() {
  group('KeyVerificationWaitingView', _waitingViewTests);
  group('KeyVerificationEmojiView', _emojiViewTests);
  group('KeyVerificationSuccessView', _successViewTests);
  group('KeyVerificationErrorView', _errorViewTests);
}

void _waitingViewTests() {
  testWidgets('renders check-other-device content', (tester) async {
    await tester.pumpWidget(_wrap(const KeyVerificationWaitingView()));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Check your other device'), findsOneWidget);
    final spinner = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    // LinagoraSysColors.outlineVariant, not the app's accent color.
    expect(spinner.color, const Color(0xFFCAC4D0));
  });
}

void _emojiViewTests() {
  testWidgets('renders emoji and buttons', (tester) async {
    var dontMatchTapped = false;
    var matchTapped = false;

    await tester.pumpWidget(
      _wrap(
        KeyVerificationEmojiView(
          emojis: [
            KeyVerificationEmoji(0),
            KeyVerificationEmoji(1),
            KeyVerificationEmoji(2),
          ],
          onDontMatch: () => dontMatchTapped = true,
          onMatch: () => matchTapped = true,
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Verify emoji'), findsOneWidget);
    expect(find.text("Don't match"), findsOneWidget);
    expect(find.text('Match'), findsOneWidget);

    await tester.tap(find.text("Don't match"));
    await tester.tap(find.text('Match'));
    expect(dontMatchTapped, isTrue);
    expect(matchTapped, isTrue);
  });

  testWidgets('keyboard Enter can reject mismatched E2EE SAS', (tester) async {
    var rejected = 0;
    var confirmed = 0;
    await tester.pumpWidget(
      _wrap(
        KeyVerificationEmojiView(
          emojis: [KeyVerificationEmoji(0)],
          onDontMatch: () => rejected++,
          onMatch: () => confirmed++,
        ),
      ),
    );

    // A hardware keyboard must be able to reject a mismatched SAS without
    // accidentally marking the device as trusted.
    Focus.of(tester.element(find.text("Don't match"))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(rejected, 1);
    expect(confirmed, 0);
  });

  testWidgets('keyboard Space can confirm only an explicitly matched SAS', (
    tester,
  ) async {
    var rejected = 0;
    var confirmed = 0;
    await tester.pumpWidget(
      _wrap(
        KeyVerificationEmojiView(
          emojis: [KeyVerificationEmoji(0), KeyVerificationEmoji(1)],
          onDontMatch: () => rejected++,
          onMatch: () => confirmed++,
        ),
      ),
    );

    Focus.of(tester.element(find.text('Match'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    expect(confirmed, 1);
    expect(rejected, 0);
  });

  testWidgets('six SAS emoji stay usable at 320px without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _wrap(
        KeyVerificationEmojiView(
          emojis: [for (var i = 0; i < 6; i++) KeyVerificationEmoji(i)],
          onDontMatch: () {},
          onMatch: () {},
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text("Don't match"), findsOneWidget);
    expect(find.text('Match'), findsOneWidget);
  });
}

void _successViewTests() {
  testWidgets('renders device-verified content', (tester) async {
    var startChattingTapped = false;

    await tester.pumpWidget(
      _wrap(
        KeyVerificationSuccessView(
          onStartChatting: () => startChattingTapped = true,
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Device verified'), findsOneWidget);
    expect(
      find.text('Your encrypted messages are now unlocked'),
      findsOneWidget,
    );
    expect(find.text('Start chatting'), findsOneWidget);

    await tester.tap(find.text('Start chatting'));
    expect(startChattingTapped, isTrue);
  });
}

void _errorViewTests() {
  testWidgets('renders failure content and closes', (tester) async {
    var closeTapped = false;

    await tester.pumpWidget(
      _wrap(
        KeyVerificationErrorView(
          canceledCode: 'm.mismatched_sas',
          canceledReason: 'Emoji did not match',
          onClose: () => closeTapped = true,
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Verification failed'), findsOneWidget);
    expect(
      find.text('The request was cancelled or rejected. Please try again.'),
      findsOneWidget,
    );
    expect(find.text('Close'), findsOneWidget);

    await tester.tap(find.text('Close'));
    expect(closeTapped, isTrue);
  });
}
