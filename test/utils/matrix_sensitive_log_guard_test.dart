import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix_api_lite/utils/logs.dart';
import 'package:twake_chat/utils/matrix_sensitive_log_guard.dart';

void main() {
  test('QR reciprocate secrets do not reach log history or external sinks', () {
    const secret = 'QR_TEST_ONLY_SECRET_DO_NOT_LOG';
    final logger = Logs();
    final forwarded = <LogEvent>[];
    logger.level = Level.verbose;
    logger.onLog = forwarded.add;

    MatrixSensitiveLogGuard.install();
    expect(logger.level, Level.warning);
    logger.i(
      '[Key Verification] Received type m.key.verification.start: '
      '{method: m.reciprocate.v1, secret: $secret, from_device: DEVICE1}',
    );
    expect(logger.outputEvents.last.title, isNot(contains(secret)));
    expect(logger.outputEvents.last.title, contains('secret: [REDACTED]'));
    expect(forwarded.last.title, isNot(contains(secret)));
    expect(forwarded.last.title, contains('m.key.verification.start'));

    logger.i(
      '[Key Verification] Sending type m.key.verification.start: '
      '{secret: $secret, transaction_id: 1}',
    );
    expect(logger.outputEvents.last.title, isNot(contains(secret)));
    expect(forwarded.last.title, isNot(contains(secret)));

    const nonSecret = 'Diagnostic m.key.verification.done transaction complete';
    logger.w(nonSecret);
    expect(logger.outputEvents.last.title, nonSecret);
    expect(forwarded.last.title, nonSecret);
    logger.e('Camera failure must stay visible');
    expect(logger.outputEvents.last.title, 'Camera failure must stay visible');
    expect(forwarded.last.title, 'Camera failure must stay visible');
  });

  test('non-QR messages are unchanged by redaction', () {
    const nonQr = 'Application event: profile loaded';
    expect(MatrixSensitiveLogGuard.redact(nonQr), nonQr);
    expect(
      MatrixSensitiveLogGuard.redact('m.key.verification.done'),
      'm.key.verification.done',
    );
    expect(
      MatrixSensitiveLogGuard.redact(
        'm.key.verification.start: {secret: sample, from_device: A}',
      ),
      'm.key.verification.start: {secret: [REDACTED], from_device: A}',
    );
  });
}
