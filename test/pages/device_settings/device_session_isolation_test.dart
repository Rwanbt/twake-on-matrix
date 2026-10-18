import 'dart:async';

import 'package:dartz/dartz.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:mockito/mockito.dart';

import 'package:twake_chat/app_state/failure.dart';
import 'package:twake_chat/app_state/success.dart';
import 'package:twake_chat/domain/app_state/device_settings/get_devices_state.dart';
import 'package:twake_chat/domain/usecase/device_settings/get_devices_interactor.dart';
import 'package:twake_chat/pages/device_settings/device_settings_state.dart';
import 'package:twake_chat/pages/device_settings/device_settings_view_model.dart';
import 'package:twake_chat/pages/device_settings/providers/device_settings_providers.dart';

// The interactor is substituted, so these tests exercise the production
// Riverpod state machine without contacting Matrix or loading native crypto.
class _AccountClient extends Mock implements Client {
  _AccountClient(this.userID, this.deviceID);

  @override
  final String? userID;

  @override
  final String? deviceID;
}

class _QueuedDevices extends GetDevicesInteractor {
  _QueuedDevices(this._responses);

  final List<Stream<Either<Failure, Success>>> _responses;
  int calls = 0;

  @override
  Stream<Either<Failure, Success>> execute({required Client client}) {
    final next = _responses[calls];
    calls++;
    return next;
  }
}

Stream<Either<Failure, Success>> _devices(String name) => Stream.value(
  Right(GetDevicesSuccess(devices: [Device(deviceId: name)])),
);

Stream<Either<Failure, Success>> _offline() => Stream.value(
  Left(GetDevicesFailed(exception: Exception('temporarily offline'))),
);

ProviderContainer _createContainer(_QueuedDevices interactor) {
  final container = ProviderContainer(
    overrides: [getDevicesInteractorProvider.overrideWithValue(interactor)],
  );
  addTearDown(container.dispose);
  return container;
}

List<String> _deviceIds(ProviderContainer container) {
  final state = container.read(devicesSettingsViewModelProvider);
  expect(state, isA<DevicesSettingsLoaded>());
  return (state as DevicesSettingsLoaded)
      .devices
      .map((device) => device.deviceId)
      .toList();
}

void main() {
  test('offline refresh preserves devices and later reconnect replaces them', () async {
    final client = _AccountClient('@alice:example.org', 'ALICE');
    final interactor = _QueuedDevices([
      _devices('OLD'),
      _offline(),
      _devices('NEW'),
    ]);
    final container = _createContainer(interactor);
    final notifier = container.read(devicesSettingsViewModelProvider.notifier);

    await notifier.loadUserDevices(client);
    await notifier.reload(client);
    expect(_deviceIds(container), ['OLD']);
    await notifier.reload(client);
    expect(_deviceIds(container), ['NEW']);
    expect(interactor.calls, 3);
  });

  test('switching Matrix clients does not reuse a previous account device list', () async {
    final alice = _AccountClient('@alice:example.org', 'ALICE');
    final bob = _AccountClient('@bob:example.org', 'BOB');
    final interactor = _QueuedDevices([_devices('ALICE'), _devices('BOB')]);
    final container = _createContainer(interactor);
    final notifier = container.read(devicesSettingsViewModelProvider.notifier);

    await notifier.loadUserDevices(alice);
    expect(_deviceIds(container), ['ALICE']);
    await notifier.loadUserDevices(bob);
    expect(_deviceIds(container), ['BOB']);
    expect(notifier.thisDevice(bob)?.deviceId, 'BOB');
    expect(interactor.calls, 2);
  });

  test('late old-account sync cannot reveal or overwrite new-account devices', () async {
    final alice = _AccountClient('@alice:example.org', 'ALICE');
    final bob = _AccountClient('@bob:example.org', 'BOB');
    final aliceResponse = Completer<Either<Failure, Success>>();
    final interactor = _QueuedDevices([
      Stream.fromFuture(aliceResponse.future),
      _devices('BOB'),
    ]);
    final container = _createContainer(interactor);
    final notifier = container.read(devicesSettingsViewModelProvider.notifier);

    final aliceLoad = notifier.loadUserDevices(alice);
    await notifier.loadUserDevices(bob);
    expect(_deviceIds(container), ['BOB']);
    aliceResponse.complete(
      Right(GetDevicesSuccess(devices: [Device(deviceId: 'ALICE')])),
    );
    await aliceLoad;
    expect(_deviceIds(container), ['BOB']);
  });

  test('old account completion cannot unlock an active new-account request', () async {
    final alice = _AccountClient('@alice:example.org', 'ALICE');
    final bob = _AccountClient('@bob:example.org', 'BOB');
    final oldResponse = Completer<Either<Failure, Success>>();
    final newResponse = Completer<Either<Failure, Success>>();
    final interactor = _QueuedDevices([
      Stream.fromFuture(oldResponse.future),
      Stream.fromFuture(newResponse.future),
    ]);
    final container = _createContainer(interactor);
    final notifier = container.read(devicesSettingsViewModelProvider.notifier);

    final aliceLoad = notifier.loadUserDevices(alice);
    final bobLoad = notifier.loadUserDevices(bob);
    oldResponse.complete(
      Right(GetDevicesSuccess(devices: [Device(deviceId: 'ALICE')])),
    );
    await aliceLoad;
    // With the second client still loading, another call must coalesce.
    final duplicateBobLoad = notifier.loadUserDevices(bob);
    expect(interactor.calls, 2);
    newResponse.complete(
      Right(GetDevicesSuccess(devices: [Device(deviceId: 'BOB')])),
    );
    await Future.wait([bobLoad, duplicateBobLoad]);
    expect(_deviceIds(container), ['BOB']);
  });
}
