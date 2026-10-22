import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:twake_chat/utils/matrix_sdk_database.dart';

void main() {
  // The Matrix SDK deletes the database file itself when a session is
  // dropped (`Client.clear` -> `database.delete`). That deletion resolves
  // the *global* sqflite factory when the SDK database was built without an
  // explicit one, and that global is only initialized on mobile: the SDK
  // then aborts the logout sequence with
  // `Bad state: databaseFactory not initialized`, keeps the revoked access
  // token in memory and never emits `LoginState.loggedOut`.
  //
  // This test guards the wiring: the SDK database must know the factory that
  // owns its file, so a revoked session can always be dropped.

  test(
    'the SDK database knows the SQLite factory that owns its file',
    () async {
      final temp = await Directory.systemTemp.createTemp('twake-sdk-db-');
      addTearDown(() => temp.delete(recursive: true));
      final dbPath = path.join(temp.path, 'client.sqlite');

      final sqlite = await databaseFactoryFfi.openDatabase(dbPath);
      final database = await buildMatrixSdkDatabase('sdk-db-wiring', sqlite);

      expect(
        database.sqfliteFactory,
        isNotNull,
        reason: 'the SDK must delete its own file without the global factory',
      );
    },
  );

  test(
    'the SDK database file can be deleted once the client is closed',
    () async {
      final temp = await Directory.systemTemp.createTemp('twake-sdk-db-');
      addTearDown(() => temp.delete(recursive: true));
      final dbPath = path.join(temp.path, 'client.sqlite');

      final sqlite = await databaseFactoryFfi.openDatabase(dbPath);
      final database = await buildMatrixSdkDatabase('sdk-db-delete', sqlite);
      expect(File(dbPath).existsSync(), isTrue);

      // This is what the Matrix SDK does when the homeserver revokes the
      // access token: the session is cleared and the database file is
      // dropped.
      await database.close();
      await database.delete();

      expect(
        File(dbPath).existsSync(),
        isFalse,
        reason: 'a dropped session must not leave its database behind',
      );
    },
  );
}
