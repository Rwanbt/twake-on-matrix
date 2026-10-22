import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:twake_chat/utils/matrix_sdk_database.dart';
import 'package:twake_chat/utils/matrix_sdk_extensions/twake_client.dart';

/// Disposable loopback Synapse used by the live SDK qualification tests.
///
/// The live tests must never talk to a real homeserver: every request is
/// restricted to this loopback address.
final Uri localSynapse = Uri.parse('http://127.0.0.1');

/// Password of every disposable account created by these tests.
const String disposablePassword = 'disposable_test_only_password';

/// Registers a disposable user on the loopback Synapse.
Future<Map<String, dynamic>> registerDisposableUser() async {
  if (localSynapse.scheme != 'http' || localSynapse.host != '127.0.0.1') {
    throw StateError(
      'Live SDK test is restricted to disposable loopback Synapse',
    );
  }
  final response = await http.post(
    localSynapse.resolve('/_matrix/client/v3/register'),
    headers: {'content-type': 'application/json'},
    body: jsonEncode({
      'username': 'flutter_sdk_${DateTime.now().microsecondsSinceEpoch}',
      'password': disposablePassword,
      'auth': {'type': 'm.login.dummy'},
    }),
  );
  expect(
    response.statusCode,
    200,
    reason: 'The test requires a running disposable Matrix Synapse',
  );
  final result = jsonDecode(response.body) as Map<String, dynamic>;
  expect(result['access_token'], isNotEmpty);
  return result;
}

/// Logs a second device into the account of [userId], without any trust.
///
/// The second device gets its own access token and its own device id: it
/// starts with no cross-signing trust at all.
Future<Map<String, dynamic>> loginSecondDisposableDevice(String userId) async {
  final response = await http.post(
    localSynapse.resolve('/_matrix/client/v3/login'),
    headers: {'content-type': 'application/json'},
    body: jsonEncode({
      'type': 'm.login.password',
      'identifier': {'type': 'm.id.user', 'user': userId},
      'password': disposablePassword,
      'initial_device_display_name': 'qr-second-device',
    }),
  );
  expect(response.statusCode, 200, reason: 'Second real device login failed');
  return jsonDecode(response.body) as Map<String, dynamic>;
}

/// Opens a real SDK client backed by its own private SQLite file.
///
/// A mocked database drops the Olm account and cannot represent a real
/// reconnect of the same Matrix device.
Future<TwakeClient> openSdkClient(
  String name,
  Map<String, dynamic> session, {
  required String databasePath,
  bool restoreStoredSession = false,
  String? token,
}) async {
  final sqlite = await databaseFactoryFfi.openDatabase(databasePath);
  final database = await buildMatrixSdkDatabase(name, sqlite);
  final client = TwakeClient(
    name,
    database: database,
    logLevel: Level.warning,
    verificationMethods: {
      KeyVerificationMethod.numbers,
      KeyVerificationMethod.qrShow,
      KeyVerificationMethod.qrScan,
    },
  );
  if (restoreStoredSession) {
    // Match ClientManager.getClients: a reconnect reads Olm account and
    // credentials from the SDK database. Supplying newToken/newDeviceID would
    // erroneously register a fresh cryptographic identity for the same ID.
    await client.init(
      waitForFirstSync: false,
      waitUntilLoadCompletedLoaded: false,
    );
    return client;
  }
  await client.checkHomeserver(localSynapse, checkWellKnown: false);
  await client.init(
    newToken: token ?? session['access_token'] as String,
    newUserID: session['user_id'] as String,
    newHomeserver: localSynapse,
    newDeviceID: session['device_id'] as String,
    newDeviceName: name,
    waitForFirstSync: false,
    waitUntilLoadCompletedLoaded: false,
  );
  return client;
}

/// Syncs [clients] until [condition] holds, or fails after 45 seconds.
Future<void> syncUntil(
  List<TwakeClient> clients,
  bool Function() condition,
  String stage,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    for (final client in clients) {
      await client
          .oneShotSync(timeout: const Duration(milliseconds: 100))
          .timeout(const Duration(seconds: 8));
      if (condition()) return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }
  throw StateError('Real Synapse two-device QR timeout at stage: $stage');
}

/// Bootstraps the real SSSS and cross-signing of [client].
///
/// This is the real SDK bootstrap: signing keys are generated and uploaded
/// through the disposable Synapse, no manually trusted device or master key
/// is involved. Returns the SSSS recovery key of the account.
///
/// When [onlineKeyBackup] is true, the server side room key backup is
/// created as well, which is the server side storage of the room keys.
Future<String> bootstrapRealCrossSigning(
  TwakeClient client, {
  bool onlineKeyBackup = false,
}) async {
  final bootstrap = client.encryption!.bootstrap();
  expect(bootstrap.state, BootstrapState.askNewSsss);
  final createStorage = bootstrap.newSsss('disposable_qr_test_passphrase');
  await createStorage.timeout(const Duration(seconds: 50));
  expect(bootstrap.state, BootstrapState.askSetupCrossSigning);
  await bootstrap
      .askSetupCrossSigning(
        setupMasterKey: true,
        setupSelfSigningKey: true,
        setupUserSigningKey: true,
      )
      .timeout(const Duration(seconds: 50));
  expect(
    bootstrap.state,
    BootstrapState.askSetupOnlineKeyBackup,
    reason: 'Real Synapse must accept and return cross-signing keys',
  );
  await bootstrap.askSetupOnlineKeyBackup(onlineKeyBackup);
  expect(bootstrap.state, BootstrapState.done);
  expect(client.userDeviceKeys[client.userID]?.masterKey?.verified, true);
  final recoveryKey = bootstrap.newSsssKey?.recoveryKey;
  expect(recoveryKey, isNotNull);
  return recoveryKey!;
}

/// Runs a real two-device QR verification between [shower] and [scanner].
///
/// [shower] displays the QR code, [scanner] scans it. Both devices are real
/// SDK clients of the same account, no mock is involved.
Future<void> verifyDevicesByQr({
  required TwakeClient shower,
  required TwakeClient scanner,
}) async {
  await shower.updateUserDeviceKeys();
  await scanner.updateUserDeviceKeys();
  final userId = shower.userID!;
  final otherKey = scanner.userDeviceKeys[userId]!.deviceKeys[shower.deviceID]!;
  final scanning = await otherKey.startVerification();
  final txn = scanning.transactionId!;
  await syncUntil(
    [shower, scanner],
    () => shower.encryption!.keyVerificationManager.getRequest(txn) != null,
    'encrypted verification request',
  );
  final showing = shower.encryption!.keyVerificationManager.getRequest(txn)!;
  expect(showing.state, KeyVerificationState.askAccept);
  await showing.acceptVerification();
  await syncUntil(
    [scanner, shower],
    () => scanning.state == KeyVerificationState.askChoice,
    'ready + qr negotiation',
  );
  final authenticQr = Uint8List.fromList(showing.qrCode!.qrDataRawBytes);
  await scanning.continueVerification(
    EventTypes.Reciprocate,
    qrDataRawBytes: authenticQr,
  );
  expect(scanning.state, KeyVerificationState.showQRSuccess);
  await syncUntil(
    [shower, scanner],
    () => showing.state == KeyVerificationState.confirmQRScan,
    'authentic QR reciprocate',
  );
  await showing.acceptQRScanConfirmation();
  await syncUntil(
    [scanner, shower],
    () => scanning.state == KeyVerificationState.done,
    'QR done receipt',
  );
}

/// Reads the server side room key backup of the room [roomId].
///
/// The backup is the encrypted storage of the Megolm sessions of the
/// account: it is what a device restores its room keys from.
Future<Map<String, dynamic>> readServerRoomKeyBackup(
  String token,
  String roomId,
) async {
  final response = await http.get(
    localSynapse.resolve(
      '/_matrix/client/v3/room_keys/keys?room_id=${Uri.encodeQueryComponent(roomId)}',
    ),
    headers: {'authorization': 'Bearer $token'},
  );
  if (response.statusCode != 200) {
    return {};
  }
  final body = jsonDecode(response.body) as Map<String, dynamic>;
  final rooms = body['rooms'] as Map<String, dynamic>? ?? {};
  final room = rooms[roomId] as Map<String, dynamic>? ?? {};
  return (room['sessions'] as Map<String, dynamic>? ?? {});
}

/// Revokes the device [deviceId] with the session of [token].
///
/// Returns true when the homeserver accepted the revocation.
Future<bool> revokeDevice(String token, String deviceId) async {
  final response = await http.delete(
    localSynapse.resolve('/_matrix/client/v3/devices/$deviceId'),
    headers: {'authorization': 'Bearer $token'},
  );
  if (response.statusCode == 405) {
    // Older homeservers only expose the POST variant.
    final fallback = await http.post(
      localSynapse.resolve('/_matrix/client/v3/devices/$deviceId'),
      headers: {
        'authorization': 'Bearer $token',
        'content-type': 'application/json',
      },
      body: jsonEncode({'device_id': deviceId}),
    );
    return fallback.statusCode == 200;
  }
  return response.statusCode == 200;
}

/// Tells whether the session of [token] is still accepted by the homeserver.
Future<bool> isSessionAlive(String token) async {
  final response = await http.get(
    localSynapse.resolve('/_matrix/client/v3/sync?timeout=0'),
    headers: {'authorization': 'Bearer $token'},
  );
  return response.statusCode == 200;
}
