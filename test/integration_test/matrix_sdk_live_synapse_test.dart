import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:twake_chat/pages/key_verification/key_verification_qr_trust_persistence.dart';
import 'package:twake_chat/utils/matrix_sensitive_log_guard.dart';
// Same transitive native crypto fixture as test/fake_client.dart; the app
// depends on flutter_vodozemac and this test loads its compiled debug library.
// ignore: depend_on_referenced_packages
import 'package:vodozemac/vodozemac.dart' as vod;

import 'live_synapse_support.dart';

const runLiveSynapse = bool.fromEnvironment('TWAKE_LIVE_SYNAPSE');

Future<void> _runRealQrTest() async {
  if (!vod.isInitialized()) {
    await vod.init(libraryPath: './vodozemac/debug/');
  }
  sqfliteFfiInit();
  final temp = await Directory.systemTemp.createTemp('twake-live-qr-');
  addTearDown(() => temp.delete(recursive: true));
  final registered = await registerDisposableUser();
  final firstPath = path.join(temp.path, 'qr-trusted.sqlite');
  final secondPath = path.join(temp.path, 'qr-untrusted.sqlite');
  final first = await openSdkClient(
    'qr-trusted',
    registered,
    databasePath: firstPath,
  );
  addTearDown(first.dispose);
  await first.oneShotSync(timeout: const Duration(milliseconds: 100));
  await bootstrapRealCrossSigning(first);

  final secondSession = await loginSecondDisposableDevice(
    registered['user_id'] as String,
  );
  final second = await openSdkClient(
    'qr-untrusted',
    secondSession,
    databasePath: secondPath,
  );
  await second.oneShotSync(timeout: const Duration(milliseconds: 100));
  await first.updateUserDeviceKeys();
  await second.updateUserDeviceKeys();
  final userId = first.userID!;
  expect(second.userID, userId);
  expect(first.deviceID, isNot(second.deviceID));
  expect(
    second.userDeviceKeys[userId]?.masterKey?.directVerified,
    isNot(true),
    reason: 'A fresh device cannot start with implicit master trust',
  );

  Future<(KeyVerification, KeyVerification)> beginQr() async {
    await first.updateUserDeviceKeys();
    await second.updateUserDeviceKeys();
    final otherKey = second.userDeviceKeys[userId]!.deviceKeys[first.deviceID]!;
    final scanning = await otherKey.startVerification();
    final txn = scanning.transactionId!;
    await syncUntil(
      [first, second],
      () => first.encryption!.keyVerificationManager.getRequest(txn) != null,
      'encrypted verification request',
    );
    final showing = first.encryption!.keyVerificationManager.getRequest(txn)!;
    expect(showing.state, KeyVerificationState.askAccept);
    await showing.acceptVerification();
    await syncUntil(
      [second, first],
      () => scanning.state == KeyVerificationState.askChoice,
      'ready + qr negotiation',
    );
    expect(scanning.possibleMethods, contains(EventTypes.Reciprocate));
    expect(scanning.possibleMethods, contains(EventTypes.QRScan));
    expect(showing.possibleMethods, contains(EventTypes.QRShow));
    expect(showing.qrCode, isNotNull);
    return (scanning, showing);
  }

  final (negativeScanner, negativeShower) = await beginQr();
  final tampered = Uint8List.fromList(negativeShower.qrCode!.qrDataRawBytes);
  // Corrupt a byte in the real transaction ID; SDK must reject before
  // authenticating/signing anything. No mock and no synthetic crypto keys.
  tampered[10] ^= 1;
  await negativeScanner.continueVerification(
    EventTypes.Reciprocate,
    qrDataRawBytes: tampered,
  );
  expect(negativeScanner.isDone, true);
  expect(negativeScanner.canceled, true);
  expect(
    second.userDeviceKeys[userId]!.masterKey!.directVerified,
    false,
    reason: 'Tampered Matrix QR must never verify the master key',
  );
  await syncUntil(
    [first, second],
    () => negativeShower.isDone,
    'negative QR cancellation',
  );
  await expectLater(
    () => persistCompletedQrTrust(
      negativeScanner,
      qrMode: QRMode.verifySelfTrusted,
      scanned: true,
    ),
    throwsA(isA<StateError>()),
  );

  final (scanner, shower) = await beginQr();
  final authenticQr = Uint8List.fromList(shower.qrCode!.qrDataRawBytes);
  await scanner.continueVerification(
    EventTypes.Reciprocate,
    qrDataRawBytes: authenticQr,
  );
  expect(scanner.state, KeyVerificationState.showQRSuccess);
  await syncUntil(
    [first, second],
    () => shower.state == KeyVerificationState.confirmQRScan,
    'authentic QR reciprocate',
  );
  await shower.acceptQRScanConfirmation();
  await syncUntil(
    [second, first],
    () => scanner.state == KeyVerificationState.done,
    'QR done receipt',
  );
  final sharedSecret = shower.qrCode!.randomSharedSecret;
  expect(
    Logs().outputEvents.every(
      (event) => !event.toFormattedString().contains(sharedSecret),
    ),
    true,
    reason: 'Real QR shared secret must not survive in SDK log history',
  );
  expect(shower.state, KeyVerificationState.done);
  expect(second.userDeviceKeys[userId]!.masterKey!.directVerified, true);
  expect(
    first.userDeviceKeys[userId]!.deviceKeys[second.deviceID]!.verified,
    true,
    reason: 'Trusted device must sign the other real device',
  );
  // Persist only keys the SDK already marked directVerified and only after
  // both cryptographic sides reached done. This does not grant new trust.
  await persistCompletedQrTrust(
    shower,
    qrMode: shower.getOurQRMode(),
    scanned: false,
  );
  await persistCompletedQrTrust(
    scanner,
    qrMode: QRMode.values.singleWhere((mode) => mode.code == authenticQr[7]),
    scanned: true,
  );

  await second.dispose();
  final restored = await openSdkClient(
    'qr-untrusted',
    secondSession,
    databasePath: secondPath,
    restoreStoredSession: true,
  );
  addTearDown(restored.dispose);
  await restored.oneShotSync(timeout: const Duration(milliseconds: 100));
  expect(restored.deviceID, secondSession['device_id']);
  expect(
    restored.userDeviceKeys[userId]?.masterKey?.verified,
    true,
    reason: 'QR-verified master trust must survive SQLite SDK reconnect',
  );
}

void main() {
  // Live integration binding permits actual loopback HTTP requests; the
  // regular widget-test binding intercepts HttpClient and returns HTTP 400.
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MatrixSensitiveLogGuard.install();

  test('real TwakeClient reconnects to Synapse with the same Matrix session '
      'and rejects an invalid bearer token', () async {
    if (!vod.isInitialized()) {
      await vod.init(libraryPath: './vodozemac/debug/');
    }
    sqfliteFfiInit();
    final temp = await Directory.systemTemp.createTemp('twake-sdk-crypto-');
    addTearDown(() => temp.delete(recursive: true));
    final databasePath = path.join(temp.path, 'device.sqlite');
    final session = await registerDisposableUser();
    final first = await openSdkClient(
      'matrix-device',
      session,
      databasePath: databasePath,
    );
    final firstSync = await first.sync(timeout: 0);
    expect(firstSync.nextBatch, isNotEmpty);
    final originalOlmIdentity = first.encryption?.identityKey;
    expect(originalOlmIdentity, isNotEmpty);
    await first.dispose();

    final reconnected = await openSdkClient(
      'matrix-device',
      session,
      databasePath: databasePath,
      restoreStoredSession: true,
    );
    final resumedSync = await reconnected.sync(timeout: 0);
    expect(resumedSync.nextBatch, isNotEmpty);
    expect(reconnected.userID, first.userID);
    expect(reconnected.deviceID, first.deviceID);
    expect(
      reconnected.encryption?.identityKey,
      originalOlmIdentity,
      reason: 'Reopening the Matrix database must retain Olm device keys',
    );
    await reconnected.dispose();

    // Confirm the server's negative authorization response, then verify
    // the actual SDK cannot initialize or sync with the invalid credential.
    const invalidToken = 'not-a-valid-disposable-session-token';
    final unauthorized = await http.get(
      localSynapse.resolve('/_matrix/client/v3/sync?timeout=0'),
      headers: {'authorization': 'Bearer $invalidToken'},
    );
    expect(unauthorized.statusCode, 401);
    await expectLater(() async {
      final denied = await openSdkClient(
        'matrix-invalid-token',
        session,
        databasePath: path.join(temp.path, 'invalid.sqlite'),
        token: invalidToken,
      );
      await denied.sync(timeout: 0);
    }, throwsA(isA<Exception>()));
  }, skip: !runLiveSynapse);

  test(
    'real Synapse revokes a previously working SDK session token',
    () async {
      sqfliteFfiInit();
      if (!vod.isInitialized()) {
        await vod.init(libraryPath: './vodozemac/debug/');
      }
      final temp = await Directory.systemTemp.createTemp(
        'twake-revoked-token-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final session = await registerDisposableUser();
      final token = session['access_token'] as String;
      final client = await openSdkClient(
        'revoked-device',
        session,
        databasePath: path.join(temp.path, 'revoked.sqlite'),
      );
      addTearDown(client.dispose);
      expect((await client.sync(timeout: 0)).nextBatch, isNotEmpty);

      // The SDK background sync is stopped here: the SDK reacts to a revoked
      // token by clearing its own database, and that reaction must be
      // observed deterministically instead of racing with the teardown of
      // this test. abortSync() also disables the background sync loop.
      await client.abortSync();

      // Actual homeserver revocation, not merely a made-up bad credential.
      final logout = await http.post(
        localSynapse.resolve('/_matrix/client/v3/logout'),
        headers: {'authorization': 'Bearer $token'},
      );
      expect(logout.statusCode, 200);
      final rejected = await http.get(
        localSynapse.resolve('/_matrix/client/v3/sync?timeout=0'),
        headers: {'authorization': 'Bearer $token'},
      );
      expect(rejected.statusCode, 401);
      // The server refuses the exact token previously used by TwakeClient,
      // so the SDK session can no longer be used at all.
      await expectLater(
        client.sync(timeout: 0),
        throwsA(isA<MatrixException>()),
      );
      // The SDK must also drop the revoked session by itself. Clearing the
      // session deletes the SDK database, which only works when the SDK
      // knows the SQLite factory that owns the file: see
      // buildMatrixSdkDatabase.
      await client.oneShotSync(timeout: const Duration(milliseconds: 100));
      expect(
        client.isLogged(),
        isFalse,
        reason: 'A revoked Matrix session must not stay logged in',
      );
    },
    skip: !runLiveSynapse,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'new device does not inherit verified master trust from SSSS setup',
    () async {
      if (!vod.isInitialized()) {
        await vod.init(libraryPath: './vodozemac/debug/');
      }
      sqfliteFfiInit();
      final temp = await Directory.systemTemp.createTemp(
        'twake-ssss-new-device-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final session = await registerDisposableUser();
      final origin = await openSdkClient(
        'ssss-original',
        session,
        databasePath: path.join(temp.path, 'original.sqlite'),
      );
      addTearDown(origin.dispose);
      await origin.oneShotSync(timeout: const Duration(milliseconds: 100));
      await bootstrapRealCrossSigning(origin);

      final secondSession = await loginSecondDisposableDevice(
        session['user_id'] as String,
      );
      final fresh = await openSdkClient(
        'ssss-fresh',
        secondSession,
        databasePath: path.join(temp.path, 'fresh.sqlite'),
      );
      addTearDown(fresh.dispose);
      await fresh.oneShotSync(timeout: const Duration(milliseconds: 100));
      await fresh.updateUserDeviceKeys();
      final keys = fresh.userDeviceKeys[fresh.userID];
      expect(keys?.masterKey, isNotNull);
      expect(
        keys?.masterKey?.directVerified,
        isNot(true),
        reason: 'New device must not implicitly trust existing SSSS master',
      );
      expect(
        fresh.deviceID,
        isNot(origin.deviceID),
        reason: 'The recovery candidate must be a distinct Matrix device',
      );
    },
    skip: !runLiveSynapse,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'real two-device QR trust with Synapse',
    _runRealQrTest,
    skip: !runLiveSynapse,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
