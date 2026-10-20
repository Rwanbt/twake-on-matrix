import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';

/// Commit trust that the Matrix SDK has already cryptographically verified.
///
/// Matrix 7.2.2 verifyKeysQR calls setDirectVerified (memory-only), which can
/// lose its result when the SQLite database is reopened. Never call this
/// before the peer's authenticated m.key.verification.done is processed.
Future<void> persistCompletedQrTrust(
  KeyVerification request, {
  required QRMode qrMode,
  required bool scanned,
}) async {
  if (request.canceled ||
      request.state != KeyVerificationState.done ||
      !request.possibleMethods.contains(EventTypes.Reciprocate)) {
    throw StateError('QR verification has not completed securely');
  }

  final client = request.client;
  final ownKeys = client.userDeviceKeys[client.userID];
  final otherKeys = client.userDeviceKeys[request.userId];

  final SignableKey? verifiedKey = switch ((qrMode, scanned)) {
    (QRMode.verifyOtherUser, _) => otherKeys?.masterKey,
    (QRMode.verifySelfTrusted, true) => ownKeys?.masterKey,
    (QRMode.verifySelfTrusted, false) =>
      otherKeys?.deviceKeys[request.deviceId],
    (QRMode.verifySelfUntrusted, true) => ownKeys?.deviceKeys[request.deviceId],
    (QRMode.verifySelfUntrusted, false) => ownKeys?.masterKey,
  };

  if (verifiedKey == null || !verifiedKey.directVerified) {
    throw StateError('Matrix SDK has not authenticated the QR trust key');
  }
  // This writes verified state through the real Matrix SDK SQLite database;
  // false avoids signing unrelated keys on this persistence-only operation.
  await verifiedKey.setVerified(true, false);
}
