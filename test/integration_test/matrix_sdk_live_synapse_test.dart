import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:matrix/matrix.dart';
import 'package:twake_chat/utils/matrix_sdk_extensions/twake_client.dart';
import 'package:vodozemac/vodozemac.dart' as vod;

import '../fake_client.dart';

const runLiveSynapse = bool.fromEnvironment('TWAKE_LIVE_SYNAPSE');
final localSynapse = Uri.parse('http://127.0.0.1');

Future<Map<String, dynamic>> _registerDisposableUser() async {
  if (localSynapse.scheme != 'http' || localSynapse.host != '127.0.0.1') {
    throw StateError('Live SDK test is restricted to disposable loopback Synapse');
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
  expect(response.statusCode, 200,
      reason: 'The test requires a running disposable Matrix Synapse');
  final result = jsonDecode(response.body) as Map<String, dynamic>;
  expect(result['access_token'], isNotEmpty);
  return result;
}

Future<TwakeClient> _openSdkClient(
  String name,
  Map<String, dynamic> session, {
  String? token,
}) async {
  final client = TwakeClient(name, database: MockDatabase());
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

  test(
    'real TwakeClient reconnects to Synapse with the same Matrix session '
    'and rejects an invalid bearer token',
    () async {
      if (!vod.isInitialized()) {
        await vod.init(libraryPath: './vodozemac/debug/');
      }
      final session = await _registerDisposableUser();
      final first = await _openSdkClient('matrix-first', session);
      final firstSync = await first.sync(timeout: 0);
      expect(firstSync.nextBatch, isNotEmpty);

      final reconnected = await _openSdkClient('matrix-reconnected', session);
      final resumedSync = await reconnected.sync(timeout: 0);
      expect(resumedSync.nextBatch, isNotEmpty);
      expect(reconnected.userID, first.userID);
      expect(reconnected.deviceID, first.deviceID);

      final denied = await _openSdkClient(
        'matrix-invalid-token', session,
        token: 'not-a-valid-disposable-session-token',
      );
      await expectLater(
        denied.sync(timeout: 0),
        throwsA(isA<MatrixException>()),
      );
    },
    skip: !runLiveSynapse,
  );
}
