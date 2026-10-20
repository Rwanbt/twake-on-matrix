import 'package:collection/collection.dart';
import 'package:twake_chat/domain/app_state/device_settings/get_devices_state.dart';
import 'package:twake_chat/pages/device_settings/device_settings_state.dart';
import 'package:twake_chat/pages/device_settings/providers/device_settings_providers.dart';
import 'package:matrix/matrix.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'device_settings_view_model.g.dart';

@riverpod
class DevicesSettingsViewModel extends _$DevicesSettingsViewModel {
  Future<void>? _loadInFlight;
  int _localDeviceRevision = 0;
  Client? _activeClient;
  String? _activeUserId;
  String? _activeDeviceId;
  Uri? _activeHomeserver;
  int _clientGeneration = 0;

  @override
  DevicesSettingsState build() {
    return const DevicesSettingsState.initial();
  }

  // This provider may outlive a Matrix login session. Never display cached
  // sessions from another account or apply responses that complete after it
  // has been replaced.
  void _activateClient(Client client) {
    if (_belongsToCurrentClient(client)) return;
    _activeClient = client;
    _activeUserId = client.userID;
    _activeDeviceId = client.deviceID;
    _activeHomeserver = client.homeserver;
    _clientGeneration++;
    _localDeviceRevision = 0;
    _loadInFlight = null;
    state = const DevicesSettingsState.initial();
  }

  bool _belongsToCurrentClient(Client client) =>
      identical(_activeClient, client) &&
      _activeUserId == client.userID &&
      _activeDeviceId == client.deviceID &&
      _activeHomeserver == client.homeserver;

  bool _isCurrentClient(Client client, int generation) =>
      _belongsToCurrentClient(client) && _clientGeneration == generation;

  /// Lease for asynchronous device actions. The lease expires on logout,
  /// account switch, or reinitialization of the same Matrix Client instance.
  int? deviceSessionGeneration(Client client) =>
      _belongsToCurrentClient(client) ? _clientGeneration : null;

  Future<void> _trackLoad(Future<void> operation) {
    late final Future<void> pending;
    pending = operation.whenComplete(() {
      // An obsolete request must not unlock a newer account's pending fetch.
      if (identical(_loadInFlight, pending)) _loadInFlight = null;
    });
    _loadInFlight = pending;
    return pending;
  }

  bool _isOwnDevice(Device userDevice, Client client) =>
      userDevice.deviceId == client.deviceID;

  List<Device>? get _devices => switch (state) {
    DevicesSettingsLoaded(:final devices) => devices,
    DevicesSettingsDeletingDevices(:final devices) => devices,
    DevicesSettingsDeleteDevicesError(:final devices) => devices,
    _ => null,
  };

  VerificationBannerVisibility get _bannerVisibility => switch (state) {
    DevicesSettingsLoaded(:final bannerVisibility) => bannerVisibility,
    DevicesSettingsDeletingDevices(:final bannerVisibility) => bannerVisibility,
    DevicesSettingsDeleteDevicesError(:final bannerVisibility) =>
      bannerVisibility,
    _ => VerificationBannerVisibility.shown,
  };

  int get _keysRevision => switch (state) {
    DevicesSettingsLoaded(:final keysRevision) => keysRevision,
    DevicesSettingsDeletingDevices(:final keysRevision) => keysRevision,
    DevicesSettingsDeleteDevicesError(:final keysRevision) => keysRevision,
    _ => 0,
  };

  void _transition({
    List<Device>? devices,
    VerificationBannerVisibility? bannerVisibility,
    int? keysRevision,
    String? deleteError,
    bool? deleting,
  }) {
    final resolvedDevices = devices ?? _devices;
    if (resolvedDevices == null) return;
    final resolvedBannerVisibility = bannerVisibility ?? _bannerVisibility;
    final resolvedKeysRevision = keysRevision ?? _keysRevision;
    if (deleteError != null) {
      state = DevicesSettingsState.deleteDevicesError(
        devices: resolvedDevices,
        message: deleteError,
        bannerVisibility: resolvedBannerVisibility,
        keysRevision: resolvedKeysRevision,
      );
    } else if (deleting ?? (state is DevicesSettingsDeletingDevices)) {
      state = DevicesSettingsState.deletingDevices(
        devices: resolvedDevices,
        bannerVisibility: resolvedBannerVisibility,
        keysRevision: resolvedKeysRevision,
      );
    } else {
      state = DevicesSettingsState.loaded(
        devices: resolvedDevices,
        bannerVisibility: resolvedBannerVisibility,
        keysRevision: resolvedKeysRevision,
      );
    }
  }

  Device? thisDevice(Client client) => _belongsToCurrentClient(client)
      ? _devices?.firstWhereOrNull((d) => _isOwnDevice(d, client))
      : null;

  List<Device> notThisDevice(Client client) =>
      List<Device>.from(_belongsToCurrentClient(client) ? _devices ?? [] : [])
        ..removeWhere((d) => _isOwnDevice(d, client))
        ..sort((a, b) => (b.lastSeenTs ?? 0).compareTo(a.lastSeenTs ?? 0));

  bool showVerificationBanner(Client client) {
    if (!_belongsToCurrentClient(client)) return false;
    final devices = _devices;
    if (devices == null) return false;
    if (_bannerVisibility == VerificationBannerVisibility.dismissed) {
      return false;
    }
    if (devices.isEmpty) return false;
    final deviceKeys = client.userDeviceKeys[client.userID]?.deviceKeys;
    return devices.any(
      (device) => deviceKeys?[device.deviceId]?.encryptToDevice == false,
    );
  }

  void dismissVerificationBanner() {
    _transition(bannerVisibility: VerificationBannerVisibility.dismissed);
  }

  Future<void> loadUserDevices(Client client) {
    _activateClient(client);
    if (_devices != null) return Future.value();
    return _loadInFlight ?? _trackLoad(_loadUserDevices(client));
  }

  Future<void> _loadUserDevices(
    Client client, {
    bool preserveStateOnFailure = false,
  }) async {
    // A refresh started before a successful revoke or rename must not restore
    // an obsolete device list when its response finally arrives.
    final startedAtRevision = _localDeviceRevision;
    final startedForGeneration = _clientGeneration;
    await ref
        .read(getDevicesInteractorProvider)
        .execute(client: client)
        .forEach((either) {
          if (!_isCurrentClient(client, startedForGeneration)) return;
          if (startedAtRevision != _localDeviceRevision) return;
          either.fold(
            (failure) {
              if (failure is GetDevicesEmpty) {
                // A zero-device response during reconnect is not evidence
                // that locally known sessions were revoked. Keep the cached
                // devices, verification warnings and revocation lock until a
                // subsequent successful device list replaces them.
                if (preserveStateOnFailure && _devices != null) {
                  return;
                }
                state = const DevicesSettingsState.loaded(devices: []);
              } else if (failure is GetDevicesFailed) {
                if (preserveStateOnFailure) return;
                state = DevicesSettingsState.error(
                  exception: failure.exception,
                );
              }
            },
            (success) {
              if (success is GetDevicesSuccess) {
                if (preserveStateOnFailure && _devices != null) {
                  // A background refresh must not reset a dismissed trust
                  // warning or the device-key revision after verification.
                  _transition(devices: success.devices);
                } else {
                  state = DevicesSettingsState.loaded(devices: success.devices);
                }
              }
            },
          );
        });
  }

  Future<void> reload(Client client) {
    _activateClient(client);
    // Reuse an active request without erasing its still-visible device list.
    final pending = _loadInFlight;
    if (pending != null) return pending;
    // A lost connection during manual refresh must not erase the last known
    // sessions, trust indicators, or an active device-revocation lock.
    if (_devices != null) return _softReload(client);
    state = const DevicesSettingsState.initial();
    return _trackLoad(_loadUserDevices(client));
  }

  Future<void> _softReload(Client client) {
    return _loadInFlight ??
        _trackLoad(_loadUserDevices(client, preserveStateOnFailure: true));
  }

  Future<void> renameDevice({
    required Client client,
    required String deviceId,
    required String displayName,
  }) async {
    // A dialog retained across logout may still call this method. It cannot
    // mutate or refresh the newly selected account's device cache.
    if (!_belongsToCurrentClient(client)) return;
    final startedForGeneration = _clientGeneration;
    await client.updateDevice(deviceId, displayName: displayName);
    if (!_isCurrentClient(client, startedForGeneration)) return;
    // Keep the new name if soft-reload fails with preserveStateOnFailure.
    _applyLocalDisplayName(deviceId, displayName);
    await _softReload(client);
  }

  void _applyLocalDisplayName(String deviceId, String displayName) {
    final devices = _devices;
    if (devices == null) return;
    _localDeviceRevision++;
    _transition(
      devices: [
        for (final device in devices)
          if (device.deviceId == deviceId)
            Device(
              deviceId: device.deviceId,
              displayName: displayName,
              lastSeenIp: device.lastSeenIp,
              lastSeenTs: device.lastSeenTs,
            )
          else
            device,
      ],
    );
  }

  void setLoadingDeletingDevices(bool loading) {
    if (loading) {
      _transition(deleting: true);
    } else if (state is DevicesSettingsDeletingDevices) {
      _transition(deleting: false);
    }
    // A failed deletion has already moved to the error state. Do not clear
    // that error in the finally block of the deletion action.
  }

  /// Atomically claims the revocation UI operation after confirmation.
  /// Two open confirmation dialogs must not submit overlapping UIA requests.
  bool tryBeginDeletingDevices() {
    if (_devices == null || state is DevicesSettingsDeletingDevices) {
      return false;
    }
    setLoadingDeletingDevices(true);
    return true;
  }

  int? tryBeginDeletingDevicesForClient(Client client) {
    if (!_belongsToCurrentClient(client) || !tryBeginDeletingDevices()) {
      return null;
    }
    return _clientGeneration;
  }

  /// A late UIA response from a previous Matrix account must never delete a
  /// matching device ID or clear the busy state of the newly signed-in user.
  void finishDeletingDevicesForClient({
    required Client client,
    required int generation,
    List<String> removedIds = const [],
    String? error,
  }) {
    if (!_isCurrentClient(client, generation)) return;
    if (error != null) {
      setErrorDeletingDevices(error);
    } else {
      removeDevicesFromState(removedIds);
    }
    setLoadingDeletingDevices(false);
  }

  void setErrorDeletingDevices(String? error) {
    if (error != null) {
      _transition(deleteError: error);
    } else if (state is DevicesSettingsDeleteDevicesError) {
      _transition();
    }
    // Clearing an old error must not interrupt an active deletion.
  }

  void removeDevicesFromState(List<String> deviceIds) {
    final devices = _devices;
    if (devices == null) return;
    final idsToRemove = deviceIds.toSet();
    if (!devices.any((device) => idsToRemove.contains(device.deviceId))) return;
    _localDeviceRevision++;
    _transition(
      devices: devices.where((d) => !idsToRemove.contains(d.deviceId)).toList(),
    );
  }

  void refreshDeviceKeys() {
    if (_devices == null) return;
    _transition(keysRevision: _keysRevision + 1);
  }
}
