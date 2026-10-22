import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twake_chat/data/repository/recovery_key_storage_repository_impl.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // FlutterSecureStorage's MethodChannel test backend. It persists across
    // repository instances but does not claim to test Android/iOS hardware.
    FlutterSecureStorage.setMockInitialValues({});
  });

  test(
    'SSSS key survives repository recreation without leaking to another account',
    () async {
      const storage = FlutterSecureStorage();
      const alice = '@alice:127.0.0.1';
      const bob = '@bob:127.0.0.1';
      const key = 'temporary test-only SSSS recovery secret';

      const writer = RecoveryKeyStorageRepositoryImpl(storage);
      expect(await writer.read(userId: alice), isNull);
      await writer.write(userId: alice, recoveryKey: key);

      // A new instance models creating the repository again after reconnect.
      const reopened = RecoveryKeyStorageRepositoryImpl(storage);
      expect(await reopened.read(userId: alice), key);
      expect(await reopened.read(userId: bob), isNull);
      expect(await storage.read(key: 'ssss_recovery_key_$bob'), isNull);
    },
  );

  test(
    'overwriting one account key does not change another account backup',
    () async {
      const storage = FlutterSecureStorage();
      const repository = RecoveryKeyStorageRepositoryImpl(storage);
      const alice = '@alice:127.0.0.1';
      const bob = '@bob:127.0.0.1';

      await repository.write(userId: alice, recoveryKey: 'old');
      await repository.write(userId: bob, recoveryKey: 'bob-only');
      await repository.write(userId: alice, recoveryKey: 'rotated');

      const reopened = RecoveryKeyStorageRepositoryImpl(storage);
      expect(await reopened.read(userId: alice), 'rotated');
      expect(await reopened.read(userId: bob), 'bob-only');
      expect(await storage.read(key: 'ssss_recovery_key_$alice'), 'rotated');
    },
  );
  test(
    'deleting a logged-out account secret preserves another account',
    () async {
      const storage = FlutterSecureStorage();
      const repository = RecoveryKeyStorageRepositoryImpl(storage);
      const alice = '@alice:127.0.0.1';
      const bob = '@bob:127.0.0.1';
  
      await repository.write(userId: alice, recoveryKey: 'alice-only');
      await repository.write(userId: bob, recoveryKey: 'bob-only');
      await repository.delete(userId: alice);
  
      const reopened = RecoveryKeyStorageRepositoryImpl(storage);
      expect(await reopened.read(userId: alice), isNull);
      expect(await reopened.read(userId: bob), 'bob-only');
      expect(await storage.read(key: 'ssss_recovery_key_$alice'), isNull);
      await reopened.delete(userId: alice); // Idempotent logout cleanup.
      expect(await reopened.read(userId: bob), 'bob-only');
    },
  );

}
