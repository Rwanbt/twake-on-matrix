import 'dart:async';
import 'dart:typed_data';

import 'key_verification_qr_payload.dart';

/// Camera-independent Matrix QR handshake gate. The SDK, not this class,
/// authenticates the transaction, cross-signing keys and QR secret.
enum MatrixQrScanFeedback { invalid, busy, rejected, failed, accepted, idle }

class MatrixQrScanLifecycle {
  MatrixQrScanLifecycle({
    required this.onScan,
    required this.onFeedback,
    DateTime Function()? now,
    this.invalidFeedbackCooldown = const Duration(seconds: 2),
  }) : _now = now ?? DateTime.now;

  final Future<bool> Function(Uint8List rawBytes) onScan;
  final void Function(MatrixQrScanFeedback feedback) onFeedback;
  final DateTime Function() _now;
  final Duration invalidFeedbackCooldown;

  StreamSubscription<Uint8List?>? _subscription;
  late Future<void> Function() _pauseCamera;
  late Future<void> Function() _resumeCamera;
  DateTime? _lastInvalidFeedback;
  int _generation = 0;
  bool _busy = false;
  bool _completed = false;
  bool _disposed = false;

  bool get busy => _busy;
  bool get completed => _completed;

  /// Rebinding invalidates an old stream immediately, even while cancellation
  /// is asynchronous. Only a single current stream may initiate an SDK call.
  void bind({
    required Stream<Uint8List?> frames,
    required Future<void> Function() pauseCamera,
    required Future<void> Function() resumeCamera,
  }) {
    if (_disposed || _completed) return;
    final generation = ++_generation;
    unawaited(_subscription?.cancel());
    _pauseCamera = pauseCamera;
    _resumeCamera = resumeCamera;
    _subscription = frames.listen(
      (raw) {
        if (_isCurrent(generation) && !_busy && !_completed) {
          unawaited(_scan(raw, generation));
        }
      },
      onError: (Object _, StackTrace __) {
        if (_isCurrent(generation)) cameraFailure();
      },
    );
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  /// Exposes camera start/permission failures rather than silently ignoring
  /// them, while keeping the secret bytes out of logs and error messages.
  void cameraFailure() {
    if (!_disposed && !_completed) onFeedback(MatrixQrScanFeedback.failed);
  }

  Future<void> _scan(Uint8List? raw, int generation) async {
    if (raw == null || !isMatrixVerificationQrPayload(raw)) {
      final now = _now();
      if (_lastInvalidFeedback == null ||
          now.difference(_lastInvalidFeedback!) >= invalidFeedbackCooldown) {
        _lastInvalidFeedback = now;
        onFeedback(MatrixQrScanFeedback.invalid);
      }
      return;
    }

    _busy = true;
    onFeedback(MatrixQrScanFeedback.busy);
    try {
      await _pauseCamera();
      if (!_isCurrent(generation)) return;
      // Snapshot camera memory; never convert the secret to a text encoding.
      final accepted = await onScan(Uint8List.fromList(raw));
      if (!_isCurrent(generation)) return;
      if (accepted) {
        _completed = true;
        onFeedback(MatrixQrScanFeedback.accepted);
      } else {
        onFeedback(MatrixQrScanFeedback.rejected);
        await _resumeCamera();
      }
    } catch (_) {
      if (_isCurrent(generation)) {
        onFeedback(MatrixQrScanFeedback.failed);
        try {
          await _resumeCamera();
        } catch (_) {
          // Failure already surfaced. Do not log QR bytes or secret material.
        }
      }
    } finally {
      _busy = false;
      if (_isCurrent(generation)) onFeedback(MatrixQrScanFeedback.idle);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    await _subscription?.cancel();
    _subscription = null;
  }
}
