import 'dart:typed_data';

import 'package:twake_chat/domain/app_state/recovery/self_verification_state.dart';
import 'package:twake_chat/pages/key_verification/key_verification_qr_payload.dart';
import 'package:twake_chat/pages/bootstrap/bootstrap_providers.dart';
import 'package:twake_chat/pages/bootstrap/bootstrap_state.dart';
import 'package:twake_chat/pages/bootstrap/bootstrap_view_model.dart';
import 'package:twake_chat/pages/bootstrap/verify_device_option.dart';
import 'package:twake_chat/pages/bootstrap/verify_device_state.dart';
import 'package:twake_chat/presentation/enum/key_verification/key_verification_code_enum.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'verify_device_view_model.g.dart';

@riverpod
class VerifyDeviceViewModel extends _$VerifyDeviceViewModel {
  KeyVerification? _request;
  bool _showRecoveryKeyForm = false;
  bool _recoveryKeyVerified = false;
  bool _showResetConfirm = false;
  bool _resetComplete = false;
  bool _isStartingVerification = false;
  bool _isResetting = false;
  bool _retryErrorDismissed = false;
  bool _isScanningQr = false;
  bool _isQrInFlight = false;
  String? _qrErrorMessage;
  String? _recoveryKeyError;

  BootstrapViewModel get _bootstrapNotifier =>
      ref.read(bootstrapViewModelProvider(client, wipe: wipe).notifier);

  BootstrapUiState get _bootstrapState =>
      ref.read(bootstrapViewModelProvider(client, wipe: wipe));

  @override
  VerifyDeviceUiState build(Client client, {required bool wipe}) {
    ref.onDispose(_cancelPendingRequest);
    // Keeps ref.watch confined to build (Riverpod 3 requirement) while still
    // reacting to BootstrapViewModel updates — _bootstrapState below reads
    // the current value with ref.read from callback contexts instead.
    ref.listen(bootstrapViewModelProvider(client, wipe: wipe), (_, _) {
      _refresh();
    });
    return _computeState();
  }

  void _cancelPendingRequest() {
    final request = _request;
    if (request == null) return;
    // Detach first so cancel() can't call back into a disposing notifier.
    request.onUpdate = null;
    if (![
      KeyVerificationState.error,
      KeyVerificationState.done,
    ].contains(request.state)) {
      request.cancel(KeyVerificationCodeEnum.user.code);
    }
  }

  void _refresh() => state = _computeState();

  VerifyDeviceUiState _computeState() {
    if (_recoveryKeyVerified) return const VerifyDeviceSuccessState();

    final bootstrapState = _bootstrapState;
    final retryState = _computeRetryState(bootstrapState);
    if (retryState != null) return retryState;

    if (_resetComplete) return const VerifyDeviceResetCompleteState();
    if (_showResetConfirm) {
      return VerifyDeviceResetConfirmState(isResetting: _isResetting);
    }
    if (_showRecoveryKeyForm) {
      return VerifyDeviceRecoveryKeyFormState(
        initialValue: bootstrapState is BootstrapVerifyDeviceState
            ? bootstrapState.prefilledRecoveryKey
            : null,
        errorText: _recoveryKeyError,
      );
    }

    final request = _request;
    if (request != null) {
      return VerifyDeviceSasState(
        request: request,
        requestState: request.state,
        isScanningQr: _isScanningQr,
        isQrInFlight: _isQrInFlight,
        qrErrorMessage: _qrErrorMessage,
      );
    }

    return VerifyDeviceChooserState(
      isStartingVerification: _isStartingVerification,
    );
  }

  /// Surfaces the outcome of the caller's own "Retry automatically" flow,
  /// read off [BootstrapViewModel]'s state — `null` when there's nothing to
  /// show (no retry ran, or its failure was already dismissed).
  VerifyDeviceUiState? _computeRetryState(BootstrapUiState bootstrapState) {
    if (bootstrapState is! BootstrapVerifyDeviceState) return null;
    if (bootstrapState.retrySucceeded) return const VerifyDeviceSuccessState();
    if (bootstrapState.retryFailed && !_retryErrorDismissed) {
      return const VerifyDeviceRetryErrorState();
    }
    return null;
  }

  void dismissRetryError() {
    _retryErrorDismissed = true;
    _showRecoveryKeyForm = false;
    _showResetConfirm = false;
    _refresh();
  }

  Future<void> startVerification() async {
    if (_isStartingVerification) return;
    _isStartingVerification = true;
    _refresh();
    try {
      final result = await ref
          .read(startSelfVerificationInteractorProvider)
          .execute(client: client);
      // The provider may have disposed while awaiting; bail before
      // attaching callbacks or writing state.
      if (!ref.mounted) return;
      if (result is StartSelfVerificationSuccessState) {
        _attachRequest(result.request);
      }
    } catch (error, stackTrace) {
      Logs().e('startVerification failed', error, stackTrace);
    } finally {
      if (ref.mounted) {
        _isStartingVerification = false;
        _refresh();
      }
    }
  }

  void _attachRequest(KeyVerification request) {
    _request = request;
    _isScanningQr = false;
    _isQrInFlight = false;
    _qrErrorMessage = null;
    request.onUpdate = _refresh;
    _refresh();
  }

  void startQrScan() {
    if (_isQrInFlight || _request?.state != KeyVerificationState.askChoice) {
      return;
    }
    _isScanningQr = true;
    _qrErrorMessage = null;
    _refresh();
  }

  void cancelQrScan() {
    if (_isQrInFlight) return;
    _isScanningQr = false;
    _refresh();
  }

  Future<void> startSasChoice() async {
    final request = _request;
    if (request == null ||
        _isQrInFlight ||
        request.state != KeyVerificationState.askChoice ||
        !request.possibleMethods.contains(EventTypes.Sas)) {
      return;
    }
    _isQrInFlight = true;
    _refresh();
    try {
      await request.continueVerification(EventTypes.Sas);
    } catch (_) {
      await _cancelFailedVerification(request);
    } finally {
      _isQrInFlight = false;
      if (ref.mounted) _refresh();
    }
  }

  Future<bool> scanMatrixQr(Uint8List bytes) async {
    final request = _request;
    if (request == null ||
        _isQrInFlight ||
        request.state != KeyVerificationState.askChoice ||
        !request.possibleMethods.contains(EventTypes.QRScan) ||
        !request.possibleMethods.contains(EventTypes.Reciprocate) ||
        !isMatrixVerificationQrPayload(bytes)) {
      return false;
    }
    _isQrInFlight = true;
    _refresh();
    try {
      await request.continueVerification(
        EventTypes.Reciprocate,
        qrDataRawBytes: bytes,
      );
      return request.state != KeyVerificationState.askChoice;
    } catch (_) {
      await _cancelFailedVerification(request);
      return false;
    } finally {
      _isQrInFlight = false;
      if (ref.mounted) _refresh();
    }
  }

  Future<void> confirmQrScan({required bool matches}) async {
    final request = _request;
    if (request == null ||
        _isQrInFlight ||
        request.state != KeyVerificationState.confirmQRScan) {
      return;
    }
    _isQrInFlight = true;
    _refresh();
    try {
      if (matches) {
        await request.acceptQRScanConfirmation();
      } else {
        await request.cancel(KeyVerificationCodeEnum.user.code);
      }
    } catch (_) {
      await _cancelFailedVerification(request);
    } finally {
      _isQrInFlight = false;
      if (ref.mounted) _refresh();
    }
  }

  Future<void> _cancelFailedVerification(KeyVerification request) async {
    try {
      await request.cancel('m.invalid_message');
    } catch (_) {
      if (ref.mounted && identical(request, _request)) {
        _isScanningQr = false;
        _qrErrorMessage = 'The verification could not be completed.';
        _refresh();
      }
    }
  }

  /// Drops a finished or failed verification request so the chooser is shown
  /// again, instead of leaving the flow stuck on its terminal state.
  void dismissSasRequest() {
    _request?.onUpdate = null;
    _request = null;
    _refresh();
  }

  void rejectSas() => _request?.rejectSas();

  void acceptSas() => _request?.acceptSas();

  Future<bool> verifyRecoveryKey(String recoveryKey) async {
    final success = await _bootstrapNotifier.unlockWithRecoveryKey(recoveryKey);
    if (success) {
      _recoveryKeyVerified = true;
      _recoveryKeyError = null;
      _refresh();
    }
    return success;
  }

  void setRecoveryKeyError(String message) {
    _recoveryKeyError = message;
    _refresh();
  }

  void showRecoveryKeyForm() {
    _showRecoveryKeyForm = true;
    _refresh();
  }

  void closeRecoveryKeyForm() {
    _showRecoveryKeyForm = false;
    _refresh();
  }

  void showResetConfirm() {
    _showResetConfirm = true;
    _refresh();
  }

  void closeResetConfirm() {
    if (_isResetting) return;
    _showResetConfirm = false;
    _refresh();
  }

  Future<void> resetEncryption(Future<bool> Function() performReset) async {
    if (_isResetting) return;
    _isResetting = true;
    _refresh();
    try {
      final success = await performReset();
      if (success) {
        _resetComplete = true;
      } else {
        _showResetConfirm = false;
      }
    } catch (_) {
      _showResetConfirm = false;
      rethrow;
    } finally {
      _isResetting = false;
      _refresh();
    }
  }

  void retry() {
    _retryErrorDismissed = false;
    _bootstrapNotifier.retry();
  }

  List<VerifyDeviceOption> resolveOptions(List<VerifyDeviceOption> options) {
    return options.map((option) {
      if (option.isUseAnotherDevice) {
        return option.copyWith(
          onTap: startVerification,
          isLoading: _isStartingVerification,
        );
      }
      if (option.isUseRecoveryKey) {
        return option.copyWith(onTap: showRecoveryKeyForm);
      }
      if (option.isNotPossibleToVerify) {
        return option.copyWith(onTap: showResetConfirm);
      }
      return option;
    }).toList();
  }
}
