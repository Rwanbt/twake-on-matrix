import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twake_chat/generated/l10n/app_localizations.dart';
import 'package:twake_chat/pages/key_verification/key_verification_qr_choice_view.dart';
import 'package:twake_chat/pages/key_verification/key_verification_qr_payload.dart';
import 'package:twake_chat/widgets/twake_components/twake_qr_code_view.dart';

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

Uint8List _matrixQrPayload() {
  final bytes = Uint8List(10 + 4 + 32 + 32 + 11);
  bytes.setRange(0, 6, 'MATRIX'.codeUnits);
  bytes[6] = 0x02;
  bytes[7] = 0x01;
  bytes[8] = 0;
  bytes[9] = 4;
  bytes.setRange(10, 14, 'abcd'.codeUnits);
  // Binary crypto keys and random secret must be passed byte-for-byte.
  bytes[14] = 0xff;
  bytes[15] = 0x80;
  bytes[bytes.length - 1] = 0xfe;
  return bytes;
}

void main() {
  test('Matrix QR framing accepts byte-exact payload', () {
    final qr = _matrixQrPayload();
    expect(isMatrixVerificationQrPayload(qr), isTrue);
    expect(qr[14], 0xff);
    expect(qr.last, 0xfe);
  });

  test('unrelated, truncated or corrupted Matrix QR is never accepted', () {
    final qr = _matrixQrPayload();
    expect(
      isMatrixVerificationQrPayload(
        Uint8List.fromList('https://example.com'.codeUnits),
      ),
      isFalse,
    );
    expect(
      isMatrixVerificationQrPayload(Uint8List.fromList(qr.sublist(0, 20))),
      isFalse,
    );
    final version = Uint8List.fromList(qr)..[6] = 1;
    expect(isMatrixVerificationQrPayload(version), isFalse);
    final mode = Uint8List.fromList(qr)..[7] = 9;
    expect(isMatrixVerificationQrPayload(mode), isFalse);
    final txn = Uint8List.fromList(qr)..[9] = 99;
    expect(isMatrixVerificationQrPayload(txn), isFalse);
  });

  testWidgets(
    'QR choice renders binary payload and exposes supported SDK options',
    (tester) async {
      var scanCalls = 0;
      var sasCalls = 0;
      final qr = _matrixQrPayload();
      await tester.pumpWidget(
        _wrap(
          KeyVerificationQrChoiceView(
            qrBytes: qr,
            canScan: true,
            canUseSas: true,
            busy: false,
            onScan: () => scanCalls++,
            onSas: () => sasCalls++,
          ),
        ),
      );

      final visual = tester.widget<TwakeQrCodeView>(
        find.byType(TwakeQrCodeView),
      );
      expect(visual.rawBytes, same(qr));
      expect(find.byIcon(Icons.qr_code_scanner), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byIcon(Icons.qr_code_scanner));
      await tester.pump();
      expect(scanCalls, 1);
      await tester.tap(find.byType(OutlinedButton));
      expect(sasCalls, 1);
    },
  );

  testWidgets(
    'QR choices cannot activate unsupported or in-flight actions',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        _wrap(
          KeyVerificationQrChoiceView(
            canScan: false,
            canUseSas: true,
            busy: true,
            onScan: () => calls++,
            onSas: () => calls++,
          ),
        ),
      );
      expect(find.byIcon(Icons.qr_code_scanner), findsNothing);
      expect(find.byType(TwakeQrCodeView), findsNothing);
      expect(
        tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNull,
      );
      expect(calls, 0);
    },
  );

  testWidgets(
    'a new Matrix transaction redraws QR rather than retaining stale pixels',
    (tester) async {
      final original = _matrixQrPayload();
      final replacement = Uint8List.fromList(original);
      replacement[replacement.length - 1] ^= 0xff;

      Future<CustomPainter> display(Uint8List bytes) async {
        await tester.pumpWidget(
          _wrap(TwakeQrCodeView.fromBytes(bytes: bytes, size: 208)),
        );
        return tester
            .widget<CustomPaint>(
              find.descendant(
                of: find.byType(TwakeQrCodeView),
                matching: find.byType(CustomPaint),
              ),
            )
            .painter!;
      }

      final before = await display(original);
      final after = await display(replacement);
      expect(after.shouldRepaint(before), isTrue);
      final unchanged = await display(Uint8List.fromList(replacement));
      expect(unchanged.shouldRepaint(after), isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
