import 'package:matrix/matrix_api_lite/utils/logs.dart';

/// Matrix SDK 7.2.2 writes the QR shared secret in INFO key-verification
/// events. Its logger appends events to outputEvents before calling onLog.
///
/// A warning-level console floor stops raw SDK INFO events being printed.
/// The callback also sanitizes in-memory log history and external log sinks,
/// while retaining ordinary error and warning messages.
abstract final class MatrixSensitiveLogGuard {
  static bool _installed = false;

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
    if (_installed) return;
    _installed = true;

    final previousCallback = logger.onLog;
    logger.onLog = (event) {
      final safeTitle = redact(event.title);
      final safeEvent = safeTitle == event.title
          ? event
          : LogEvent(
              safeTitle,
              exception: event.exception,
              stackTrace: event.stackTrace,
              level: event.level,
            );
      if (!identical(safeEvent, event)) {
        final history = logger.outputEvents;
        if (history.isNotEmpty && identical(history.last, event)) {
          history[history.length - 1] = safeEvent;
        }
      }
      previousCallback?.call(safeEvent);
    };
  }
}
