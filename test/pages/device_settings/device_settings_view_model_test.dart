import 'dart:async';

import 'package:dartz/dartz.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:twake_chat/app_state/failure.dart';
import 'package:twake_chat/app_state/success.dart';
import 'package:twake_chat/domain/app_state/device_settings/get_devices_state.dart';
import 'package:twake_chat/domain/usecase/device_settings/get_devices_interactor.dart';
import 'package:twake_chat/pages/device_settings/device_settings_state.dart';
import 'package:twake_chat/pages/device_settings/device_settings_view_model.dart';
import 'package:twake_chat/pages/device_settings/providers/device_settings_providers.dart';

import '../../fake_client.dart';

class FakeGetDevicesInteractor extends GetDevicesInteractor {
  final List<Stream<Either<Failure, Success>>> _results;
  var callCount = 0;

  FakeGetDevicesInteractor(this._results);

  @override
  Stream<Either<Failure, Success>> execute({required Client client}) {
    final result = _results[callCount.clamp(0, _results.length - 1)];
    callCount++;
    return result;
  }
}

Stream<Either<Failure, Success>> _success(List<Device> devices) =>
    Stream.value(Right(GetDevicesSuccess(devices: devices)));

Stream<Either<Failure, Success>> _failure() =>
    Stream.value(Left(GetDevicesFailed(exception: Exception('network error'))));

Stream<Either<Failure, Success>> _empty() =>
    Stream.value(Left(GetDevicesEmpty()));

ProviderContainer _container(FakeGetDevicesInteractor interactor) {
  return ProviderContainer(
    overrides: [getDevicesInteractorProvider.overrideWithValue(interactor)],
  );
}

Future<void> _softReloadFailurePreservesLoadedDevices(_) async {
  final client = await getClient();
  final devices = [Device(deviceId: 'QBUAZIFURK', displayName: 'android')];
  final interactor = FakeGetDevicesInteractor([_success(devices), _failure()]);
  final container = _container(interactor);
  addTearDown(container.dispose);
  final notifier = container.read(devicesSettingsViewModelProvider.notifier);

  await notifier.loadUserDevices(client);
  expect(
    container.read(devicesSettingsViewModelProvider),
    isA<DevicesSettingsLoaded>(),
  );

  await notifier.renameDevice(
    client: client,
    deviceId: 'QBUAZIFURK',
    displayName: 'New name',
  );

  final state = container.read(devicesSettingsViewModelProvider);
  expect(
    state,
    isA<DevicesSettingsLoaded>(),
    reason:
        'a soft-reload failure after a successful rename must not blank the '
        'list into an error state',
  );
  expect(
    (state as DevicesSettingsLoaded).devices.single.displayName,
    'New name',
    reason:
        'a successful updateDevice must keep the new name even when the '
        'follow-up fetch fails',
  );
}

Future<void> _initialLoadFailureSetsErrorState(_) async {
  final client = await getClient();
  final interactor = FakeGetDevicesInteractor([_failure()]);
  final container = _container(interactor);
  addTearDown(container.dispose);
  final notifier = container.read(devicesSettingsViewModelProvider.notifier);

  await notifier.loadUserDevices(client);

  expect(
    container.read(devicesSettingsViewModelProvider),
    isA<DevicesSettingsError>(),
  );
}

Future<void> _deletionFailureRemainsVisibleAndCannotInterruptProgress() async {
  final client = await getClient();
  final devices = [
    Device(deviceId: 'GHTYAJCE', displayName: 'Current device'),
    Device(deviceId: 'OTHER', displayName: 'Other device'),
  ];
  final container = _container(FakeGetDevicesInteractor([_success(devices)]));
  addTearDown(container.dispose);
  final notifier = container.read(devicesSettingsViewModelProvider.notifier);
  await notifier.loadUserDevices(client);
  notifier.dismissVerificationBanner();
  notifier.refreshDeviceKeys();

  notifier.setLoadingDeletingDevices(true);
  notifier.setErrorDeletingDevices(null);
  notifier.refreshDeviceKeys();
  expect(
    container.read(devicesSettingsViewModelProvider),
    isA<DevicesSettingsDeletingDevices>(),
    reason:
        'clearing an error or refreshing E2EE trust must keep deletion busy',
  );

  notifier.setErrorDeletingDevices('M_FORBIDDEN');
  notifier.setLoadingDeletingDevices(false);
  final failed = container.read(devicesSettingsViewModelProvider);
  expect(failed, isA<DevicesSettingsDeleteDevicesError>());
  final error = failed as DevicesSettingsDeleteDevicesError;
  expect(error.message, 'M_FORBIDDEN');
  expect(error.devices, hasLength(2));
  expect(error.bannerVisibility, VerificationBannerVisibility.dismissed);
  expect(error.keysRevision, 2);

  notifier.setLoadingDeletingDevices(true);
  expect(
    container.read(devicesSettingsViewModelProvider),
    isA<DevicesSettingsDeletingDevices>(),
    reason: 'a user retry must clear the old failure and enter busy state',
  );
  notifier.removeDevicesFromState(['OTHER']);
  expect(
    container.read(devicesSettingsViewModelProvider),
    isA<DevicesSettingsDeletingDevices>(),
    reason: 'optimistic device-list mutation must not re-enable deletion',
  );
  notifier.setLoadingDeletingDevices(false);
  final recovered = container.read(devicesSettingsViewModelProvider);
  expect(recovered, isA<DevicesSettingsLoaded>());
  expect(
    (recovered as DevicesSettingsLoaded).devices.single.deviceId,
    'GHTYAJCE',
  );
}

Future<void> _deviceListExcludesCurrentAndSortsByLastSeen() async {
  final client = await getClient();
  final devices = [
    Device(deviceId: 'OLD', lastSeenTs: 10),
    Device(deviceId: 'GHTYAJCE', lastSeenTs: 100),
    Device(deviceId: 'NEW', lastSeenTs: 30),
    Device(deviceId: 'UNKNOWN'),
  ];
  final container = _container(FakeGetDevicesInteractor([_success(devices)]));
  addTearDown(container.dispose);
  final notifier = container.read(devicesSettingsViewModelProvider.notifier);
  await notifier.loadUserDevices(client);

  expect(notifier.thisDevice(client)?.deviceId, 'GHTYAJCE');
  expect(
    notifier.notThisDevice(client).map((device) => device.deviceId),
    ['NEW', 'OLD', 'UNKNOWN'],
    reason: 'the current Matrix session cannot appear in bulk removal',
  );
  expect(
    devices.first.deviceId,
    'OLD',
    reason: 'sorting must not mutate cache',
  );
}

Future<void> _softReloadRetainsVerificationState() async {
  final client = await getClient();
  // FakeMatrixApi supports updateDevice for this fixture ID.
  const supportedDeviceId = 'QBUAZIFURK';
  final previous = [Device(deviceId: supportedDeviceId, displayName: 'Laptop')];
  final updated = [
    Device(deviceId: supportedDeviceId, displayName: 'Trusted laptop'),
  ];
  final container = _container(
    FakeGetDevicesInteractor([_success(previous), _success(updated)]),
  );
  addTearDown(container.dispose);
  final notifier = container.read(devicesSettingsViewModelProvider.notifier);
  await notifier.loadUserDevices(client);
  notifier.dismissVerificationBanner();
  notifier.refreshDeviceKeys();

  await notifier.renameDevice(
    client: client,
    deviceId: supportedDeviceId,
    displayName: 'Trusted laptop',
  );
  final state = container.read(devicesSettingsViewModelProvider);
  expect(state, isA<DevicesSettingsLoaded>());
  final loaded = state as DevicesSettingsLoaded;
  expect(loaded.devices.single.displayName, 'Trusted laptop');
  expect(loaded.bannerVisibility, VerificationBannerVisibility.dismissed);
  expect(loaded.keysRevision, 1);
}

Future<void> _concurrentSyncIsCoalescedAndFailureCanRetry() async {
  final client = await getClient();
  final gate = Completer<Either<Failure, Success>>();
  final devices = [Device(deviceId: 'GHTYAJCE')];
  final interactor = FakeGetDevicesInteractor([
    Stream.fromFuture(gate.future),
    _success(devices),
  ]);
  final container = _container(interactor);
  addTearDown(container.dispose);
  final notifier = container.read(devicesSettingsViewModelProvider.notifier);

  final first = notifier.loadUserDevices(client);
  final second = notifier.loadUserDevices(client);
  gate.complete(Left(GetDevicesFailed(exception: Exception('offline'))));
  await Future.wait([first, second]);
  expect(interactor.callCount, 1);
  expect(
    container.read(devicesSettingsViewModelProvider),
    isA<DevicesSettingsError>(),
  );

  await notifier.reload(client);
  expect(interactor.callCount, 2);
  expect(
    container.read(devicesSettingsViewModelProvider),
    isA<DevicesSettingsLoaded>(),
  );
}

Future<void> _reloadDuringSoftSyncKeepsDeviceListVisible() async {
  final client = await getClient();
  const supportedDeviceId = 'QBUAZIFURK';
  final devices = [Device(deviceId: supportedDeviceId, displayName: 'Laptop')];
  final refreshStarted = Completer<void>();
  final refresh = StreamController<Either<Failure, Success>>(
    onListen: refreshStarted.complete,
  );
  addTearDown(refresh.close);
  final interactor = FakeGetDevicesInteractor([
    _success(devices),
    refresh.stream,
  ]);
  final container = _container(interactor);
  addTearDown(container.dispose);
  final notifier = container.read(devicesSettingsViewModelProvider.notifier);
  await notifier.loadUserDevices(client);

  final rename = notifier.renameDevice(
    client: client,
    deviceId: supportedDeviceId,
    displayName: 'Updated laptop',
  );
  await refreshStarted.future.timeout(const Duration(seconds: 10));
  final reload = notifier.reload(client);
  expect(interactor.callCount, 2);
  expect(
    container.read(devicesSettingsViewModelProvider),
    isA<DevicesSettingsLoaded>(),
    reason: 'a simultaneous refresh cannot blank a usable device list',
  );

  refresh.add(Right(GetDevicesSuccess(devices: devices)));
  await refresh.close().timeout(const Duration(seconds: 10));
  await Future.wait([rename, reload]).timeout(const Duration(seconds: 10));
  expect(
    container.read(devicesSettingsViewModelProvider),
    isA<DevicesSettingsLoaded>(),
  );
}

Future<void> _staleSyncCannotRestoreRevokedDevice() async {
  final client = await getClient();
  final devices = [
    Device(deviceId: 'QBUAZIFURK', displayName: 'Laptop'),
    Device(deviceId: 'OTHER', displayName: 'Revoked phone'),
  ];
  final refreshStarted = Completer<void>();
  final refresh = StreamController<Either<Failure, Success>>(
    onListen: refreshStarted.complete,
  );
  addTearDown(refresh.close);
  final container = _container(
    FakeGetDevicesInteractor([_success(devices), refresh.stream]),
  );
  addTearDown(container.dispose);
  final notifier = container.read(devicesSettingsViewModelProvider.notifier);
  await notifier.loadUserDevices(client);

  final rename = notifier.renameDevice(
    client: client,
    deviceId: 'QBUAZIFURK',
    displayName: 'Renamed laptop',
  );
  await refreshStarted.future.timeout(const Duration(seconds: 10));

  expect(notifier.tryBeginDeletingDevices(), isTrue);
  expect(
    notifier.tryBeginDeletingDevices(),
    isFalse,
    reason: 'two confirmed revocations cannot start overlapping UIA calls',
  );
  notifier.removeDevicesFromState(['OTHER']);
  notifier.refreshDeviceKeys();
  refresh.add(Right(GetDevicesSuccess(devices: devices)));
  await refresh.close().timeout(const Duration(seconds: 10));
  await rename.timeout(const Duration(seconds: 10));

  final busy = container.read(devicesSettingsViewModelProvider);
  expect(busy, isA<DevicesSettingsDeletingDevices>());
  final deleting = busy as DevicesSettingsDeletingDevices;
  expect(deleting.keysRevision, 1);
  expect(deleting.devices.map((d) => d.deviceId), ['QBUAZIFURK']);

  notifier.setLoadingDeletingDevices(false);
  final settled = container.read(devicesSettingsViewModelProvider);
  expect(settled, isA<DevicesSettingsLoaded>());
  expect(
    (settled as DevicesSettingsLoaded).devices.single.displayName,
    'Renamed laptop',
  );
}

Future<void> _manualReloadCannotInterruptRevocation() async {
  final client = await getClient();
  final devices = [Device(deviceId: 'GHTYAJCE')];
  final refreshStarted = Completer<void>();
  final refresh = StreamController<Either<Failure, Success>>(
    onListen: refreshStarted.complete,
  );
  addTearDown(refresh.close);
  final interactor = FakeGetDevicesInteractor([
    _success(devices),
    refresh.stream,
  ]);
  final container = _container(interactor);
  addTearDown(container.dispose);
  final notifier = container.read(devicesSettingsViewModelProvider.notifier);
  await notifier.loadUserDevices(client);

  expect(notifier.tryBeginDeletingDevices(), isTrue);
  final first = notifier.reload(client);
  await refreshStarted.future.timeout(const Duration(seconds: 10));
  final second = notifier.reload(client);
  expect(interactor.callCount, 2);
  expect(
    container.read(devicesSettingsViewModelProvider),
    isA<DevicesSettingsDeletingDevices>(),
  );

  refresh.add(Right(GetDevicesSuccess(devices: devices)));
  await refresh.close().timeout(const Duration(seconds: 10));
  await Future.wait([first, second]).timeout(const Duration(seconds: 10));
  expect(
    container.read(devicesSettingsViewModelProvider),
    isA<DevicesSettingsDeletingDevices>(),
    reason: 'a completed Matrix sync must not re-enable device revocation',
  );
  notifier.setLoadingDeletingDevices(false);
  expect(
    container.read(devicesSettingsViewModelProvider),
    isA<DevicesSettingsLoaded>(),
  );
}

Future<void> _emptySyncCannotUnlockRevocation() async {
  final client = await getClient();
  final devices = [Device(deviceId: 'GHTYAJCE')];
  final container = _container(
    FakeGetDevicesInteractor([_success(devices), _empty()]),
  );
  addTearDown(container.dispose);
  final notifier = container.read(devicesSettingsViewModelProvider.notifier);
  await notifier.loadUserDevices(client);

  expect(notifier.tryBeginDeletingDevices(), isTrue);
  await notifier.reload(client);
  expect(
    container.read(devicesSettingsViewModelProvider),
    isA<DevicesSettingsDeletingDevices>(),
    reason: 'empty Matrix sync must not permit a second UIA revoke',
  );
  expect(notifier.tryBeginDeletingDevices(), isFalse);
  notifier.setLoadingDeletingDevices(false);
  expect(
    container.read(devicesSettingsViewModelProvider),
    isA<DevicesSettingsLoaded>(),
  );
}

Future<void> _emptyOfflineSyncRetainsSessionsAndTrustUntilRecovery() async {
  final client = await getClient();
  final cached = [
    Device(deviceId: 'GHTYAJCE', displayName: 'This device'),
    Device(deviceId: 'OTHER', displayName: 'Unverified phone'),
  ];
  final recovered = [
    Device(deviceId: 'GHTYAJCE', displayName: 'This device'),
    Device(deviceId: 'NEW', displayName: 'Reconnected phone'),
  ];
  final interactor = FakeGetDevicesInteractor([
    _success(cached),
    _empty(),
    _success(recovered),
  ]);
  final container = _container(interactor);
  addTearDown(container.dispose);
  final notifier = container.read(devicesSettingsViewModelProvider.notifier);

  await notifier.loadUserDevices(client);
  notifier.dismissVerificationBanner();
  notifier.refreshDeviceKeys();

  // An incomplete/empty server response during reconnect must not erase the
  // devices we can still verify or revoke, or reset their E2EE trust display.
  await notifier.reload(client);
  final offline = container.read(devicesSettingsViewModelProvider);
  expect(offline, isA<DevicesSettingsLoaded>());
  final retained = offline as DevicesSettingsLoaded;
  expect(retained.devices.map((d) => d.deviceId), ['GHTYAJCE', 'OTHER']);
  expect(retained.bannerVisibility, VerificationBannerVisibility.dismissed);
  expect(retained.keysRevision, 1);

  await notifier.reload(client);
  final online = container.read(devicesSettingsViewModelProvider);
  expect(online, isA<DevicesSettingsLoaded>());
  expect(
    (online as DevicesSettingsLoaded).devices.map((d) => d.deviceId),
    ['GHTYAJCE', 'NEW'],
  );
  expect(online.bannerVisibility, VerificationBannerVisibility.dismissed);
  expect(online.keysRevision, 1);
  expect(interactor.callCount, 3);
}

void main() {
  test(
    'soft reload failure after renameDevice preserves the loaded devices '
    '(does not blank the list into an error state)',
    () => _softReloadFailurePreservesLoadedDevices(null),
  );

  test(
    'initial load failure still surfaces an error state',
    () => _initialLoadFailureSetsErrorState(null),
  );
  test(
    'device deletion stays busy while clearing errors and preserves failures',
    _deletionFailureRemainsVisibleAndCannotInterruptProgress,
  );
  test(
    'Matrix bulk device actions exclude own session and order remote sessions',
    _deviceListExcludesCurrentAndSortsByLastSeen,
  );
  test(
    'successful device sync retains dismissed trust banner and key revision',
    _softReloadRetainsVerificationState,
  );
  test(
    'concurrent device sync coalesces requests and permits recovery offline',
    _concurrentSyncIsCoalescedAndFailureCanRetry,
  );
  test(
    'manual reload during background device sync keeps sessions visible',
    _reloadDuringSoftSyncKeepsDeviceListVisible,
  );
  test(
    'a stale Matrix sync cannot resurrect a revoked device or clear busy',
    _staleSyncCannotRestoreRevokedDevice,
  );
  test(
    'manual device sync remains coalesced and busy during active revocation',
    _manualReloadCannotInterruptRevocation,
  );
  test(
    'an empty Matrix sync cannot unlock an active device revocation',
    _emptySyncCannotUnlockRevocation,
  );
  test(
    'empty offline device sync retains E2EE trust and cache until recovery',
    _emptyOfflineSyncRetainsSessionsAndTrustUntilRecovery,
  );
}
