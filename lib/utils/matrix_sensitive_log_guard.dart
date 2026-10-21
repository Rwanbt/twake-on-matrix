import 'package:matrix/matrix_api_lite/utils/logs.dart';

/// Matrix SDK 7.2.2 writes the QR shared secret in INFO key-verification
/// events. Its logger appends events to outputEvents before calling onLog.
///
/// Keep the SDK console at its lowest level: its own printOut() serializes
/// the original immutable LogEvent *after* onLog, so redacting onLog alone
/// cannot stop raw WARNING or ERROR diagnostics being printed.
/// The callback also sanitizes in-memory log history and external log sinks,
/// while retaining ordinary error and warning messages.
abstract final class MatrixSensitiveLogGuard {
  static LogCallback? _guardedCallback;

  // Matrix key-verification diagnostics are emitted as Dart maps and JSON.
  // Cover unquoted tokens, single/double quoted keys, escaped quotes, and
  // spaces inside quoted values. Match only a key named "secret", not fields
  // such as "shared_secret_type", and never echo the original captured value.
  static final RegExp _qrSecret = RegExp(
    r'''(\bsecret(?:"|')?\s*:\s*)(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^,}\s]+)''',
    caseSensitive: false,
  );

  static String redact(String message) {
    if (!message.contains('m.key.verification.start')) return message;
    return message.replaceAllMapped(
      _qrSecret,
      (match) => '${match.group(1)}[REDACTED]',
    );
  }

  static void install() {
    final logger = Logs();
    if (logger.level.index > Level.wtf.index) {
      logger.level = Level.wtf;
    }
    // Another subsystem (e.g. initMatrixLogger) may replace Logs.onLog.
    // Re-wrap it when necessary instead of relying on a one-time flag.
    if (_guardedCallback != null && identical(logger.onLog, _guardedCallback)) {
      return;
    }

    final previousCallback = logger.onLog;
    void guardCallback(LogEvent event) {
      final safeTitle = redact(event.title);
      // QR protocol failures can also serialize the shared secret in the
      // exception or stack trace. Never forward those raw SDK diagnostics.
      final qrEvent = event.title.contains('m.key.verification.start');
      final safeException = qrEvent && event.exception != null
          ? '[REDACTED QR VERIFICATION DIAGNOSTIC]'
          : event.exception;
      final safeStackTrace = qrEvent ? null : event.stackTrace;
      final safeEvent = safeTitle == event.title && !qrEvent
          ? event
          : LogEvent(
              safeTitle,
              exception: safeException,
              stackTrace: safeStackTrace,
              level: event.level,
            );
      if (!identical(safeEvent, event)) {
        final history = logger.outputEvents;
        if (history.isNotEmpty && identical(history.last, event)) {
          history[history.length - 1] = safeEvent;
        }
      }
      // Restore useful warnings/errors through the sanitized callback, not
      // the SDK printOut() path that still holds the unredacted event.
      if (event.level == Level.warning || event.level == Level.error) {
        // ignore: avoid_print
        print('[Matrix] ${safeEvent.toFormattedString()}');
      }
      previousCallback?.call(safeEvent);
    }

    logger.onLog = guardCallback;
    _guardedCallback = guardCallback;
  }
}
