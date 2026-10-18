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
}
