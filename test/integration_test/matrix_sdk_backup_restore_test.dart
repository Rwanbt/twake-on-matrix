import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:twake_chat/utils/matrix_sdk_extensions/twake_client.dart';
import 'package:twake_chat/utils/matrix_sensitive_log_guard.dart';
import 'package:vodozemac/vodozemac.dart' as vod;

import 'live_synapse_support.dart';

const runLiveSynapse = bool.fromEnvironment('TWAKE_LIVE_SYNAPSE');

/// Body of the synthetic message sent in the disposable encrypted room.
const String disposableMessage = 'disposable backup message';

/// Body of the synthetic attachment sent in the disposable encrypted room.
const String disposableAttachment = 'disposable-attachment.bin';

/// Tells whether the client knows the cross-signing master key.
bool hasMasterKey(TwakeClient client) {
  final ssss = client.encryption!.sss;
  return ssss.getCached(EventTypes.CrossSigningMasterKey) != null;
}

/// Tells whether the client knows the Megolm session of a room.
bool hasRoomKey(TwakeClient client, String roomId, String sessionId) {
  final manager = client.encryption!.keyManager;
  return manager.getInboundGroupSession(roomId, sessionId) != null;
}

void main() {
  // Live integration binding permits actual loopback HTTP requests; the
  // regular widget-test binding intercepts HttpClient and returns HTTP 400.
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MatrixSensitiveLogGuard.install();

  test(
    'real Synapse: a second device refuses a wrong recovery key and '
    'recovers the cross-signing keys with the right one',
    () async {
      if (!vod.isInitialized()) {
        await vod.init(libraryPath: './vodozemac/debug/');
      }
      sqfliteFfiInit();
      final temp = await Directory.systemTemp.createTemp(
        'twake-ssss-recovery-',
      );
      addTearDown(() => temp.delete(recursive: true));

      // ---- Step 1: account on the disposable Synapse ----
      final session = await registerDisposableUser();
      final userId = session['user_id'] as String;

      // ---- Step 2: Olm/Megolm, SSSS and cross-signing ----
      final first = await openSdkClient(
        'ssss-source',
        session,
        databasePath: path.join(temp.path, 'source.sqlite'),
      );
      addTearDown(first.dispose);
      await first.oneShotSync(timeout: const Duration(milliseconds: 100));
      final recoveryKey = await bootstrapRealCrossSigning(first);
      expect(recoveryKey, isNotEmpty);

      // ---- Step 3: encrypted room with a message and an attachment ----
      final roomId = await first.createRoom(
        name: 'disposable-recovery-room',
        preset: CreateRoomPreset.trustedPrivateChat,
      );
      final room = first.getRoomById(roomId);
      expect(room, isNotNull);
      await room!.enableEncryption();
      final messageId = await room.sendTextEvent(disposableMessage);
      expect(messageId, isNotNull);
      final fileEventId = await room.sendFileEvent(
        MatrixFile(
          bytes: Uint8List.fromList(
            List<int>.generate(256, (index) => index % 256),
          ),
          name: disposableAttachment,
          mimetype: 'application/octet-stream',
        ),
      );
      expect(fileEventId, isNotNull);

      // ---- Step 5: a second device without any initial trust ----
      final secondSession = await loginSecondDisposableDevice(userId);
      final second = await openSdkClient(
        'ssss-candidate',
        secondSession,
        databasePath: path.join(temp.path, 'candidate.sqlite'),
      );
      addTearDown(second.dispose);
      await second.oneShotSync(timeout: const Duration(milliseconds: 100));
      await second.updateUserDeviceKeys();
      expect(
        second.userDeviceKeys[userId]?.masterKey?.directVerified,
        isNot(true),
        reason: 'A fresh device must not inherit a direct verification',
      );
      expect(
        second.userDeviceKeys[userId]?.masterKey?.verified,
        isNot(true),
        reason: 'A fresh device must not inherit the master trust',
      );

      // The second device learns the SSSS key of the account from the server.
      await syncUntil(
        [second],
        () => second.encryption!.sss.defaultKeyId != null,
        'ssss default key published by the server',
      );
      final keyId = second.encryption!.sss.defaultKeyId!;
      expect(
        second.encryption!.sss.getKey(keyId),
        isNotNull,
        reason: 'The server must publish the SSSS key information',
      );
      final openSsss = second.encryption!.sss.open(keyId);

      // ---- Step 6: a wrong recovery key must be refused ----
      final wrongBytes = Uint8List.fromList(
        SSSS.decodeRecoveryKey(recoveryKey),
      );
      wrongBytes[wrongBytes.length - 1] ^= 0xff;
      final wrongRecoveryKey = SSSS.encodeRecoveryKey(wrongBytes);
      await expectLater(
        openSsss.unlock(recoveryKey: wrongRecoveryKey),
        throwsA(isA<InvalidPassphraseException>()),
        reason: 'A wrong recovery key must never unlock the secret storage',
      );
      expect(
        openSsss.isUnlocked,
        isFalse,
        reason: 'A refused recovery key must leave the secret storage locked',
      );
      expect(
        second.userDeviceKeys[userId]?.masterKey?.verified,
        isNot(true),
        reason: 'A refused recovery key must not create any trust',
      );

      // ---- Step 7: the correct recovery key recovers the cross-signing keys ----
      await openSsss.unlock(recoveryKey: recoveryKey);
      expect(openSsss.isUnlocked, isTrue);
      await syncUntil(
        [second],
        () => hasMasterKey(second),
        'cross-signing master key restored from the secret storage',
      );
      await second.updateUserDeviceKeys();
      expect(
        second.userDeviceKeys[userId]?.masterKey?.verified,
        isTrue,
        reason: 'The recovered master key must be trusted after the recovery',
      );
      expect(
        second.userDeviceKeys[userId]?.masterKey?.directVerified,
        isNot(true),
        reason: 'The recovery must not create a direct verification',
      );
    },
    skip: !runLiveSynapse,
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'real Synapse: the room keys are backed up on the server and restored '
    'on another device',
    () async {
      if (!vod.isInitialized()) {
        await vod.init(libraryPath: './vodozemac/debug/');
      }
      sqfliteFfiInit();
      final temp = await Directory.systemTemp.createTemp(
        'twake-room-key-backup-',
      );
      addTearDown(() => temp.delete(recursive: true));

      // ---- Step 1 and 2: account, SSSS, cross-signing, online key backup ----
      final session = await registerDisposableUser();
      final userId = session['user_id'] as String;
      final first = await openSdkClient(
        'backup-source',
        session,
        databasePath: path.join(temp.path, 'source.sqlite'),
      );
      addTearDown(first.dispose);
      await first.oneShotSync(timeout: const Duration(milliseconds: 100));
      final recoveryKey = await bootstrapRealCrossSigning(
        first,
        onlineKeyBackup: true,
      );

      // ---- Step 3: encrypted room with a message and an attachment ----
      final roomId = await first.createRoom(
        name: 'disposable-backup-room',
        preset: CreateRoomPreset.trustedPrivateChat,
      );
      final room = first.getRoomById(roomId);
      expect(room, isNotNull);
      await room!.enableEncryption();
      final messageId = await room.sendTextEvent(disposableMessage);
      expect(messageId, isNotNull);
      final fileEventId = await room.sendFileEvent(
        MatrixFile(
          bytes: Uint8List.fromList(
            List<int>.generate(256, (index) => index % 256),
          ),
          name: disposableAttachment,
          mimetype: 'application/octet-stream',
        ),
      );
      expect(fileEventId, isNotNull);

      // The application forwards a room key request of one of its own
      // devices, exactly like the Twake application does.
      first.onRoomKeyRequest.stream.listen((request) async {
        await request.forwardKey();
      });

      // ---- Step 5: a second device without any initial trust ----
      final secondSession = await loginSecondDisposableDevice(userId);
      final second = await openSdkClient(
        'backup-holder',
        secondSession,
        databasePath: path.join(temp.path, 'holder.sqlite'),
      );
      addTearDown(second.dispose);
      await second.oneShotSync(timeout: const Duration(milliseconds: 100));
      await syncUntil(
        [second],
        () => second.encryption!.sss.defaultKeyId != null,
        'ssss default key published by the server',
      );
      final keyId = second.encryption!.sss.defaultKeyId!;
      final openSsss = second.encryption!.sss.open(keyId);

      // ---- Step 6: a wrong recovery key must be refused ----
      final wrongBytes = Uint8List.fromList(
        SSSS.decodeRecoveryKey(recoveryKey),
      );
      wrongBytes[wrongBytes.length - 1] ^= 0xff;
      await expectLater(
        openSsss.unlock(recoveryKey: SSSS.encodeRecoveryKey(wrongBytes)),
        throwsA(isA<InvalidPassphraseException>()),
        reason: 'A wrong recovery key must never unlock the secret storage',
      );

      // ---- Step 7: the correct recovery key recovers the cross-signing keys ----
      await openSsss.unlock(recoveryKey: recoveryKey);
      expect(openSsss.isUnlocked, isTrue);
      await syncUntil(
        [second],
        () => hasMasterKey(second),
        'cross-signing master key restored from the secret storage',
      );

      // The second device receives the room key of the account (the SDK asks
      // for it, the first device forwards it) and can decrypt the history.
      await syncUntil(
        [second],
        () => second.getRoomById(roomId) != null,
        'the room on the second device',
      );
      final secondRoom = second.getRoomById(roomId)!;
      final encrypted = await secondRoom.getEventById(messageId!);
      expect(encrypted, isNotNull);
      expect(encrypted!.type, EventTypes.Encrypted);
      final sessionId = encrypted.content['session_id'] as String;
      final senderKey = encrypted.content['sender_key'] as String;
      // The application asks the other devices of the account for the room
      // key it is missing.
      await second.encryption!.keyManager.request(
        secondRoom,
        sessionId,
        senderKey,
      );
      await syncUntil(
        [second, first],
        () => hasRoomKey(second, roomId, sessionId),
        'the room key received by the second device',
      );

      // ---- Step 4: the room key is uploaded to the server side backup ----
      await second.encryption!.keyManager.uploadInboundGroupSessions();
      final backup = await readServerRoomKeyBackup(
        secondSession['access_token'] as String,
        roomId,
      );
      expect(
        backup,
        isNotEmpty,
        reason: 'The homeserver must hold the room key of the account',
      );
      expect(
        backup.containsKey(sessionId),
        isTrue,
        reason: 'The server side backup must hold the Megolm session',
      );

      // ---- Step 8: another device restores the room key from the backup ----
      final thirdSession = await loginSecondDisposableDevice(userId);
      final third = await openSdkClient(
        'backup-restorer',
        thirdSession,
        databasePath: path.join(temp.path, 'restorer.sqlite'),
      );
      addTearDown(third.dispose);
      await third.oneShotSync(timeout: const Duration(milliseconds: 100));
      await syncUntil(
        [third],
        () => third.encryption!.sss.defaultKeyId != null,
        'ssss default key published by the server',
      );
      final thirdSsss = third.encryption!.sss.open(
        third.encryption!.sss.defaultKeyId!,
      );
      await thirdSsss.unlock(recoveryKey: recoveryKey);
      expect(thirdSsss.isUnlocked, isTrue);
      await third.updateUserDeviceKeys();
      expect(
        third.userDeviceKeys[userId]?.masterKey?.verified,
        isTrue,
        reason: 'The recovered master key must be trusted after the recovery',
      );
      // The third device never received a forwarded room key: the only way
      // for it to decrypt the history is the server side backup.
      expect(
        third.encryption!.keyManager.getInboundGroupSession(roomId, sessionId),
        isNull,
        reason: 'The third device must not know the room key yet',
      );
      await third.encryption!.keyManager.loadAllKeysFromRoom(roomId);
      expect(
        third.encryption!.keyManager.getInboundGroupSession(roomId, sessionId),
        isNotNull,
        reason: 'The room key must be restored from the server side backup',
      );
      // The restored room key really decrypts the historical message.
      await syncUntil(
        [third],
        () => third.getRoomById(roomId) != null,
        'the room on the third device',
      );
      final thirdRoom = third.getRoomById(roomId)!;
      final rawEvent = await thirdRoom.getEventById(messageId!);
      expect(rawEvent, isNotNull);
      final decrypted = await third.encryption!.decryptRoomEvent(rawEvent!);
      expect(
        decrypted.type,
        EventTypes.Message,
        reason: 'The restored room key must decrypt the historical message',
      );
      expect(decrypted.content['body'], disposableMessage);

      // ---- Step 9: the restored state survives a restart of the app ----
      await third.dispose();
      final restarted = await openSdkClient(
        'backup-restorer',
        thirdSession,
        databasePath: path.join(temp.path, 'restorer.sqlite'),
        restoreStoredSession: true,
      );
      addTearDown(restarted.dispose);
      await restarted.oneShotSync(timeout: const Duration(milliseconds: 100));
      await restarted.updateUserDeviceKeys();
      expect(
        restarted.userDeviceKeys[userId]?.masterKey?.verified,
        isTrue,
        reason: 'The recovered trust must survive the SQLite reopen',
      );
      expect(
        restarted.encryption!.keyManager.getInboundGroupSession(
          roomId,
          sessionId,
        ),
        isNotNull,
        reason: 'The restored room key must survive the SQLite reopen',
      );

      // ---- Step 10: the first device is revoked ----
      final revoked = await revokeDevice(
        secondSession['access_token'] as String,
        first.deviceID!,
      );
      expect(revoked, isTrue, reason: 'The device revocation must succeed');
      final firstToken = session['access_token'] as String;
      expect(
        await isSessionAlive(firstToken),
        isFalse,
        reason: 'A revoked device must not be able to use its session',
      );
      await syncUntil(
        [second, third],
        () => second.userDeviceKeys[userId]?.deviceKeys[first.deviceID] == null,
        'the revoked device is removed from the device list',
      );

      // ---- Step 10: a new security verification after the revocation ----
      // The remaining devices must be able to verify each other again, and
      // the verification must be explicit: no implicit trust is created by
      // the revocation.
      await verifyDevicesByQr(shower: second, scanner: third);
      await second.updateUserDeviceKeys();
      await third.updateUserDeviceKeys();
      expect(
        third.userDeviceKeys[userId]?.deviceKeys[second.deviceID]?.verified,
        isTrue,
        reason: 'The new QR verification must establish the trust explicitly',
      );
    },
    skip: !runLiveSynapse,
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
