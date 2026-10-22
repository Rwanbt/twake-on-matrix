import 'dart:typed_data';

/// Rejects unrelated QR codes before handing the *original binary bytes*
/// to Matrix SDK 7.2.2. The SDK performs transaction, key and secret checks.
bool isMatrixVerificationQrPayload(Uint8List bytes) {
  if (bytes.length < 10 + 32 + 32 + 8 ||
      bytes[0] != 0x4d ||
      bytes[1] != 0x41 ||
      bytes[2] != 0x54 ||
      bytes[3] != 0x52 ||
      bytes[4] != 0x49 ||
      bytes[5] != 0x58 ||
      bytes[6] != 0x02 ||
      bytes[7] > 0x02) {
    return false;
  }
  final transactionLength = (bytes[8] << 8) | bytes[9];
  return transactionLength > 0 &&
      bytes.length >= 10 + transactionLength + 32 + 32 + 8;
}
