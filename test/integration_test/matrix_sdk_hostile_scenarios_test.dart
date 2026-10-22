import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:twake_chat/utils/matrix_sensitive_log_guard.dart';
import 'package:vodozemac/vodozemac.dart' as vod;

import 'live_synapse_support.dart';

const runLiveSynapse = bool.fromEnvironment('TWAKE_LIVE_SYNAPSE');

/// Session identifier of the malformed room key injected by the tests.
const String bogusSessionId = 'disposable_bogus_session';

/// Transaction identifier of the malformed events injected by the tests.
const String bogusTransactionId = 'disposable_bogus_transaction';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MatrixSensitiveLogGuard.install();

  test(
    'real Synapse: malformed encrypted events never turn an untrusted device '
    'into a trusted device',
    () async {
      if (!vod.isInitialized()) {
        await vod.init(libraryPath: './vodozemac/debug/');
      }
      sqfliteFfiInit();
      final temp = await Directory.systemTemp.createTemp(
        'twake-hostile-events-',
      );
      addTearDown(() => temp.delete(recursive: true));

      final session = await registerDisposableUser();
      final userId = session['user_id'] as String;
      final token = session['access_token'] as String;

      final first = await openSdkClient(
        'hostile-source',
        session,
        databasePath: path.join(temp.path, 'source.sqlite'),
      );
      addTearDown(first.dispose);
      await first.oneShotSync(timeout: const Duration(milliseconds: 100));
      await bootstrapRealCrossSigning(first);

      final roomId = await first.createRoom(
        name: 'disposable-hostile-room',
        preset: CreateRoomPreset.trustedPrivateChat,
      );
      final room = first.getRoomById(roomId);
      expect(room, isNotNull);
      await room!.enableEncryption();

      // A malformed encrypted event, injected straight in the room.
      final malformed = await http.post(
        localSynapse.resolve(
          '/_matrix/client/v3/rooms/$roomId/send/m.room.encrypted/$bogusTransactionId',
        ),
        headers: {
          'authorization': 'Bearer $token',
          'content-type': 'application/json',
        },
        body: jsonEncode({
          'algorithm': 'm.megolm.v1.aes-sha2',
          'ciphertext': 'this-is-not-a-megolm-payload',
          'device_id': 'DISPOSABLE_DEVICE',
          'sender_key': 'disposable+sender+key',
          'session_id': bogusSessionId,
        }),
      );
      expect(malformed.statusCode, 200);

      // A malformed room key, injected straight in the to-device queue.
      final secondSession = await loginSecondDisposableDevice(userId);
      final malformedKey = await http.put(
        localSynapse.resolve(
          '/_matrix/client/v3/sendToDevice/m.room_key/$bogusTransactionId',
        ),
        headers: {
          'authorization': 'Bearer $token',
          'content-type': 'application/json',
        },
        body: jsonEncode({
          'messages': {
            userId: {
              secondSession['device_id']: {
                'room_id': roomId,
                'session_id': bogusSessionId,
                'algorithm': 'm.megolm.v1.aes-sha2',
                'ciphertext': 'AAAA',
                'sender_key': 'disposable+sender+key',
              },
            },
          },
        }),
      );
      expect(malformedKey.statusCode, 200);

      // The second device receives all of it and must stay untrusted.
      final second = await openSdkClient(
        'hostile-candidate',
        secondSession,
        databasePath: path.join(temp.path, 'candidate.sqlite'),
      );
      addTearDown(second.dispose);
      await second.oneShotSync(timeout: const Duration(milliseconds: 100));
      await syncUntil(
        [second],
        () => second.getRoomById(roomId) != null,
        'the hostile room on the second device',
      );
      await second.updateUserDeviceKeys();

      expect(
        second.userDeviceKeys[userId]?.masterKey?.directVerified,
        isNot(true),
        reason: 'A malformed event must never create a direct verification',
      );
      expect(
        second.userDeviceKeys[userId]?.masterKey?.verified,
        isNot(true),
        reason: 'A malformed event must never create a master trust',
      );
      final stored = second.encryption!.keyManager.getInboundGroupSession(
        roomId,
        bogusSessionId,
      );
      expect(
        stored?.isValid ?? false,
        isFalse,
        reason: 'A malformed room key must never be stored as a valid session',
      );

      // The client stays usable and consistent after the hostile events.
      await second.oneShotSync(timeout: const Duration(milliseconds: 100));
      expect(second.userID, userId);
      expect(
        second.userDeviceKeys[userId]?.masterKey?.directVerified,
        isNot(true),
        reason: 'The device must stay untrusted after a further sync',
      );
    },
    skip: !runLiveSynapse,
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'a corrupted SDK database fails closed instead of opening a trusted '
    'device',
    () async {
      if (!vod.isInitialized()) {
        await vod.init(libraryPath: './vodozemac/debug/');
      }
      sqfliteFfiInit();
      final temp = await Directory.systemTemp.createTemp('twake-corrupted-db-');
      addTearDown(() => temp.delete(recursive: true));

      final session = await registerDisposableUser();
      final userId = session['user_id'] as String;
      final databasePath = path.join(temp.path, 'corrupted.sqlite');

      final first = await openSdkClient(
        'corrupted-source',
        session,
        databasePath: databasePath,
      );
      addTearDown(first.dispose);
      await first.oneShotSync(timeout: const Duration(milliseconds: 100));
      await bootstrapRealCrossSigning(first);
      await first.dispose();

      // Corrupt the local database of the device.
      final file = File(databasePath);
      final bytes = await file.readAsBytes();
      expect(bytes, isNotEmpty);
      final corrupted = List<int>.from(bytes);
      for (var index = 0; index < 512 && index < corrupted.length; index++) {
        corrupted[index] = 0x5a;
      }
      await file.writeAsBytes(corrupted);

      // Reopening must fail: a corrupted storage must never come back as a
      // trusted device.
      await expectLater(
        openSdkClient('corrupted-source', session, databasePath: databasePath),
        throwsA(anything),
        reason: 'A corrupted database must fail closed',
      );
      expect(userId, isNotEmpty);
    },
    skip: !runLiveSynapse,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
