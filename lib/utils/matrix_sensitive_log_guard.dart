import 'package:matrix/matrix_api_lite/utils/logs.dart';

/// Matrix SDK 7.2.2 writes the QR shared secret in INFO key-verification
/// events. Its logger appends events to outputEvents before calling onLog.
///
/// A warning-level console floor stops raw SDK INFO events being printed.
/// The callback also sanitizes in-memory log history and external log sinks,
/// while retaining ordinary error and warning messages.
abstract final class MatrixSensitiveLogGuard {
  static LogCallback? _guardedCallback;

  static final RegExp _qrSecret = RegExp(r'(\bsecret\s*:\s*)([^,}\s]+)');

  static String redact(String message) {
    if (!message.contains('m.key.verification.start')) return message;
    return message.replaceAllMapped(
      _qrSecret,
      (match) => '${match.group(1)}[REDACTED]',
    );
  }

  static void install() {
    final logger = Logs();
    if (logger.level.index > Level.warning.index) {
      logger.level = Level.warning;
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
      previousCallback?.call(safeEvent);
    }

    logger.onLog = guardCallback;
    _guardedCallback = guardCallback;
  }
}
