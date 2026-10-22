import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Builds the Matrix SDK database of the Matrix client [name] on top of the
/// already opened SQLite [database].
///
/// The Matrix SDK owns that file and deletes it by itself when a session must
/// be dropped: `Client.clear()` ends with `database.delete()`. That call
/// resolves the *global* `databaseFactory` when the SDK database was built
/// without an explicit factory, and that global is only initialized on mobile
/// (`databaseFactory = databaseFactoryFfi` in `main.dart`).
///
/// Without an explicit factory the SDK therefore aborts the logout sequence
/// with `Bad state: databaseFactory not initialized`, keeps the revoked access
/// token in memory and never emits `LoginState.loggedOut`: the application
/// stays "logged in" with a token the homeserver already refused, and the
/// local E2EE database is never dropped.
///
/// The factory that owns the file must therefore be handed to the SDK
/// explicitly, on every target.
Future<MatrixSdkDatabase> buildMatrixSdkDatabase(
  String name,
  Database database,
) async {
  return MatrixSdkDatabase.init(
    name,
    database: database,
    sqfliteFactory: databaseFactoryFfi,
  );
}
