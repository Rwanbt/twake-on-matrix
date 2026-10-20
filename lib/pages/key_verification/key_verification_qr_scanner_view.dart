// qr_code_scanner 1.0.1 uses removed Flutter Web APIs. Its native camera
// implementation must not be imported into a web build.
export 'key_verification_qr_scanner_view_web.dart'
    if (dart.library.io) 'key_verification_qr_scanner_view_native.dart';
