import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix_api_lite/utils/logs.dart';
import 'package:twake_chat/config/app_config.dart';
import 'package:twake_chat/utils/debug_utils.dart';
import 'package:twake_chat/utils/logging/init_matrix_logger.dart';
import 'package:twake_chat/utils/matrix_sensitive_log_guard.dart';

void main() {
  test('QR reciprocate secrets do not reach log history or external sinks', () {
    const secret = 'QR_TEST_ONLY_SECRET_DO_NOT_LOG';
    final logger = Logs();
    final forwarded = <LogEvent>[];
    logger.level = Level.verbose;
    logger.onLog = forwarded.add;

    MatrixSensitiveLogGuard.install();
    expect(logger.level, Level.wtf);
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

  test('QR warning exceptions and stack traces never escape to log sinks', () {
    const secret = 'QR_PRIVATE_ERROR_SECRET_DO_NOT_LOG';
    final logger = Logs();
    final forwarded = <LogEvent>[];
    logger.level = Level.warning;
    logger.onLog = forwarded.add;
    MatrixSensitiveLogGuard.install();

    final printed = <String>[];
    runZoned(
      () => logger.w(
        'Failed m.key.verification.start with secret: $secret',
        StateError('camera exception $secret'),
        StackTrace.fromString('verification stack $secret'),
      ),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => printed.add(line),
      ),
    );

    final last = logger.outputEvents.last;
    expect(last.toFormattedString(), isNot(contains(secret)));
    expect(forwarded.last.toFormattedString(), isNot(contains(secret)));
    expect(last.title, contains('[REDACTED]'));
    expect(forwarded.last.exception?.toString(), isNot(contains(secret)));
    expect(printed.join('\n'), isNot(contains(secret)));
    expect(printed.join('\n'), contains('[REDACTED]'));
  });

  test('QR error exceptions cannot bypass sanitization through SDK stdout', () {
    const secret = 'QR_ERROR_LEVEL_SECRET_NOT_FOR_STDOUT';
    final logger = Logs();
    final forwarded = <LogEvent>[];
    final printed = <String>[];
    logger.level = Level.verbose;
    logger.onLog = forwarded.add;
    MatrixSensitiveLogGuard.install();

    runZoned(
      () => logger.e(
        'Rejected m.key.verification.start {secret: $secret}',
        StateError(secret),
        StackTrace.fromString(secret),
      ),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => printed.add(line),
      ),
    );

    expect(logger.level, Level.wtf);
    expect(printed.join('\n'), isNot(contains(secret)));
    expect(printed.join('\n'), contains('[REDACTED]'));
    expect(forwarded.last.toFormattedString(), isNot(contains(secret)));
    expect(
      logger.outputEvents.last.toFormattedString(),
      isNot(contains(secret)),
    );
  });

  test('enable_logs cannot reactivate Matrix QR secret stdout', () {
    const secret = 'QR_PRIVATE_SHARED_SECRET_NOT_FOR_STDOUT';
    final logger = Logs();
    final output = <String>[];
    final oldEnableLogs = DebugUtils.enableLogs;
    addTearDown(() {
      DebugUtils.enableLogs = oldEnableLogs;
      MatrixSensitiveLogGuard.install();
    });

    // Reinitialize the normal forwarding callback, then load configuration
    // *after* MatrixSensitiveLogGuard has previously been installed.
    initMatrixLogger();
    logger.level = Level.verbose;
    AppConfig.loadFromJson({'enable_logs': true});
    expect(DebugUtils.enableLogs, true);
    expect(logger.level, Level.wtf);

    runZoned(
      () {
        logger.i(
          '[Key Verification] Sending type m.key.verification.start: '
          '{method: m.reciprocate.v1, secret: $secret, from_device: DEVICE}',
        );
        logger.w('QR_WARNING_IS_STILL_VISIBLE');
      },
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => output.add(line),
      ),
    );

    final printable = output.join('\n');
    expect(printable, isNot(contains(secret)));
    expect(printable, contains('QR_WARNING_IS_STILL_VISIBLE'));
    final sanitized = logger.outputEvents.lastWhere(
      (event) => event.title.contains('m.key.verification.start'),
    );
    expect(sanitized.title, contains('[REDACTED]'));
    expect(
      logger.outputEvents.every((e) => !e.toFormattedString().contains(secret)),
      true,
    );
  });
}
