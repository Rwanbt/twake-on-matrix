import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twake_chat/generated/l10n/app_localizations.dart';
import 'package:twake_chat/pages/key_verification/key_verification_qr_scan_view.dart';

Widget _wrap(Widget child) => MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: const [
        L10n.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  testWidgets('a scanned QR waits for the other device without granting trust',
      (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(const KeyVerificationQrScanView(waitingForPartner: true)),
    );

    expect(find.text('Check your other device'), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.verified_user), findsOneWidget);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.verified_user)).color,
      Colors.green.shade700,
    );
    expect(find.text('Match'), findsNothing);
    expect(find.text("Don't match"), findsNothing);
    expect(find.text('Device verified'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('QR confirmation requires a deliberate positive choice', (
    tester,
  ) async {
    var matches = 0;
    var rejected = 0;
    await tester.pumpWidget(
      _wrap(
        KeyVerificationQrScanView(
          waitingForPartner: false,
          onMatch: () => matches++,
          onDontMatch: () => rejected++,
        ),
      ),
    );

    expect(find.text('Device verified'), findsNothing);
    expect(matches, 0);
    await tester.tap(find.text("Don't match"));
    await tester.pump();
    expect(rejected, 1);
    expect(matches, 0, reason: 'Rejecting QR must not confirm SDK trust');

    await tester.tap(find.text('Match'));
    await tester.pump();
    expect(matches, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('busy QR confirmation prevents duplicate trust actions', (
    tester,
  ) async {
    var matches = 0;
    var rejected = 0;
    await tester.pumpWidget(
      _wrap(
        KeyVerificationQrScanView(
          waitingForPartner: false,
          busy: true,
          onMatch: () => matches++,
          onDontMatch: () => rejected++,
        ),
      ),
    );

    expect(tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNull);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    expect(matches, 0);
    expect(rejected, 0);
  });

  testWidgets('keyboard can reject QR without confirming a fingerprint', (
    tester,
  ) async {
    var matches = 0;
    var rejected = 0;
    await tester.pumpWidget(
      _wrap(
        KeyVerificationQrScanView(
          waitingForPartner: false,
          onMatch: () => matches++,
          onDontMatch: () => rejected++,
        ),
      ),
    );
    await tester.ensureVisible(find.text("Don't match"));
    Focus.of(tester.element(find.text("Don't match"))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(rejected, 1);
    expect(matches, 0);
  });

  testWidgets('QR confirmation fits on a 320px wide screen', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _wrap(
        KeyVerificationQrScanView(
          waitingForPartner: false,
          onMatch: () {},
          onDontMatch: () {},
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Match'), findsOneWidget);
    expect(find.text("Don't match"), findsOneWidget);
  });
}
