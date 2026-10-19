import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twake_chat/pages/key_verification/key_verification_qr_scan_lifecycle.dart';

Uint8List _qr() {
  final bytes = Uint8List(10 + 4 + 32 + 32 + 10);
  bytes.setRange(0, 6, 'MATRIX'.codeUnits);
  bytes[6] = 2;
  bytes[7] = 1;
  bytes[9] = 4;
  bytes.setRange(10, 14, 'abcd'.codeUnits);
  bytes[14] = 0xff;
  return bytes;
}

void main() {
  testWidgets('rebind ignores old camera frames', (tester) async {
    final original = StreamController<Uint8List?>.broadcast(sync: true);
    final replacement = StreamController<Uint8List?>.broadcast(sync: true);
    addTearDown(original.close);
    addTearDown(replacement.close);
    var processed = 0;
    var renders = 0;
    final lifecycle = MatrixQrScanLifecycle(
      onScan: (_) async {
        processed++;
        return true;
      },
      onFeedback: (_) => renders++,
    );
    addTearDown(lifecycle.dispose);
    final cameraPause = () async {};
    final cameraResume = () async {};
    await tester.pumpWidget(const MaterialApp(home: Text('QR scanner')));

    lifecycle.bind(
      frames: original.stream,
      pauseCamera: cameraPause,
      resumeCamera: cameraResume,
    );
    expect(original.hasListener, isTrue);
    lifecycle.bind(
      frames: replacement.stream,
      pauseCamera: cameraPause,
      resumeCamera: cameraResume,
    );
    await tester.pump();
    expect(original.hasListener, isFalse);
    original.add(_qr());
    replacement.add(_qr());
    await tester.pump();
    expect(processed, 1);
    expect(lifecycle.completed, isTrue);
    expect(renders, greaterThan(0));
  });

  testWidgets('invalid frames are throttled', (tester) async {
    final source = StreamController<Uint8List?>.broadcast(sync: true);
    addTearDown(source.close);
    var now = DateTime.utc(2026);
    var invalidFeedback = 0;
    var calls = 0;
    final message = ValueNotifier('Waiting');
    addTearDown(message.dispose);
    final lifecycle = MatrixQrScanLifecycle(
      now: () => now,
      invalidFeedbackCooldown: const Duration(seconds: 2),
      onScan: (_) async {
        calls++;
        return true;
      },
      onFeedback: (feedback) {
        if (feedback == MatrixQrScanFeedback.invalid) {
          invalidFeedback++;
          message.value = 'Invalid $invalidFeedback';
        }
      },
    );
    addTearDown(lifecycle.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<String>(
          valueListenable: message,
          builder: (context, value, child) => Text(value),
        ),
      ),
    );
    lifecycle.bind(
      frames: source.stream,
      pauseCamera: () async {},
      resumeCamera: () async {},
    );
    for (var i = 0; i < 1000; i++) {
      source.add(Uint8List.fromList('not a Matrix QR'.codeUnits));
    }
    await tester.pump();
    expect(invalidFeedback, 1);
    expect(calls, 0);
    expect(find.text('Invalid 1'), findsOneWidget);
    now = now.add(const Duration(seconds: 2));
    source.add(null);
    await tester.pump();
    expect(invalidFeedback, 2);
    expect(find.text('Invalid 2'), findsOneWidget);
  });

  testWidgets('in-flight scan pauses then rejects safely', (tester) async {
    final source = StreamController<Uint8List?>.broadcast(sync: true);
    addTearDown(source.close);
    final pending = Completer<bool>();
    var calls = 0;
    var pauses = 0;
    var resumes = 0;
    final lifecycle = MatrixQrScanLifecycle(
      onScan: (_) {
        calls++;
        return pending.future;
      },
      onFeedback: (_) {},
    );
    addTearDown(lifecycle.dispose);
    lifecycle.bind(
      frames: source.stream,
      pauseCamera: () async => pauses++,
      resumeCamera: () async => resumes++,
    );
    source.add(_qr());
    source.add(_qr());
    await tester.pump();
    expect(calls, 1);
    expect(pauses, 1);
    expect(lifecycle.busy, isTrue);
    pending.complete(false);
    await tester.pump();
    expect(resumes, 1);
    expect(lifecycle.completed, isFalse);
  });

  testWidgets('accepted QR cannot replay', (tester) async {
    final source = StreamController<Uint8List?>.broadcast(sync: true);
    addTearDown(source.close);
    var calls = 0;
    var resumes = 0;
    final lifecycle = MatrixQrScanLifecycle(
      onScan: (_) async {
        calls++;
        return true;
      },
      onFeedback: (_) {},
    );
    addTearDown(lifecycle.dispose);
    lifecycle.bind(
      frames: source.stream,
      pauseCamera: () async {},
      resumeCamera: () async => resumes++,
    );
    source.add(_qr());
    await tester.pump();
    source.add(_qr());
    await tester.pump();
    expect(calls, 1);
    expect(resumes, 0);
    expect(lifecycle.completed, isTrue);
  });

  testWidgets('camera failure and teardown are safe', (tester) async {
    final source = StreamController<Uint8List?>.broadcast(sync: true);
    addTearDown(source.close);
    final failures = <MatrixQrScanFeedback>[];
    var calls = 0;
    final lifecycle = MatrixQrScanLifecycle(
      onScan: (_) async {
        calls++;
        return false;
      },
      onFeedback: failures.add,
    );
    lifecycle.bind(
      frames: source.stream,
      pauseCamera: () async => throw StateError('camera denied'),
      resumeCamera: () async {},
    );
    source.add(_qr());
    await tester.pump();
    expect(failures, contains(MatrixQrScanFeedback.failed));
    expect(calls, 0);
    await lifecycle.dispose();
    source.add(_qr());
    await tester.pump();
    expect(calls, 0);
    expect(source.hasListener, isFalse);
  });
}
