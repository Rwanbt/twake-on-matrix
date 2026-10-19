import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:twake_chat/utils/matrix_sdk_extensions/twake_client.dart';
// Same transitive native crypto fixture as test/fake_client.dart; the app
// depends on flutter_vodozemac and this test loads its compiled debug library.
// ignore: depend_on_referenced_packages
import 'package:vodozemac/vodozemac.dart' as vod;

const runLiveSynapse = bool.fromEnvironment('TWAKE_LIVE_SYNAPSE');
final localSynapse = Uri.parse('http://127.0.0.1');

Future<Map<String, dynamic>> _registerDisposableUser() async {
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
      'password': 'disposable_test_only_password',
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

Future<TwakeClient> _openSdkClient(
  String name,
  Map<String, dynamic> session, {
  required String databasePath,
  bool restoreStoredSession = false,
  String? token,
}) async {
  // Use the same MatrixSdkDatabase implementation as ClientManager, backed
  // by a private SQLite file. A Mockito database drops the Olm account and
  // cannot represent a real reconnect of the same Matrix device.
  final sqlite = await databaseFactoryFfi.openDatabase(databasePath);
  final database = await MatrixSdkDatabase.init(name, database: sqlite);
  final client = TwakeClient(name, database: database);
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

void main() {
  // Live integration binding permits actual loopback HTTP requests; the
  // regular widget-test binding intercepts HttpClient and returns HTTP 400.
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('real TwakeClient reconnects to Synapse with the same Matrix session '
      'and rejects an invalid bearer token', () async {
    if (!vod.isInitialized()) {
      await vod.init(libraryPath: './vodozemac/debug/');
    }
    sqfliteFfiInit();
    final temp = await Directory.systemTemp.createTemp('twake-sdk-crypto-');
    addTearDown(() => temp.delete(recursive: true));
    final databasePath = path.join(temp.path, 'device.sqlite');
    final session = await _registerDisposableUser();
    final first = await _openSdkClient(
      'matrix-device',
      session,
      databasePath: databasePath,
    );
    final firstSync = await first.sync(timeout: 0);
    expect(firstSync.nextBatch, isNotEmpty);
    final originalOlmIdentity = first.encryption?.identityKey;
    expect(originalOlmIdentity, isNotEmpty);
    await first.dispose();

    final reconnected = await _openSdkClient(
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
      final denied = await _openSdkClient(
        'matrix-invalid-token',
        session,
        databasePath: path.join(temp.path, 'invalid.sqlite'),
        token: invalidToken,
      );
      await denied.sync(timeout: 0);
    }, throwsA(isA<Exception>()));
  }, skip: !runLiveSynapse);
}
