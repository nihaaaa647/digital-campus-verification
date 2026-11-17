import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/key_set.dart';
import 'src/sync_client.dart';

/// Debug builds trust the public test key set. A release build does so only if it was built with
/// `--dart-define=DCID_DEV_KEYS=true`; otherwise it has no keys and refuses to scan until key sync exists.
const bool _devKeys = kDebugMode || bool.fromEnvironment('DCID_DEV_KEYS');

/// A scanner gets its token, its gate and its college keys by activation: a guard types the address of the
/// server and a one-time code from the admin. `--dart-define=DCID_SERVER_URL=https://...` prefills the address.
///
/// For development only, a build can skip activation and sync as a fixed scanner:
/// `--dart-define=DCID_SYNC_URL=https://.../functions/v1/scanner-sync --dart-define=DCID_SYNC_TOKEN=...`.
final SyncConfig? _syncConfig = SyncConfig.tryParse(const String.fromEnvironment('DCID_SYNC_URL'), const String.fromEnvironment('DCID_SYNC_TOKEN'));

void main() => runApp(ScannerApp(
      keySetSource: _devKeys ? const AssetKeySet(devKeySetAsset) : null,
      syncConfig: _syncConfig,
      defaultServer: const String.fromEnvironment('DCID_SERVER_URL'),
    ));
