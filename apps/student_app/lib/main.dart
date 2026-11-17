import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/keystore_signer.dart';
import 'src/pass_store.dart';
import 'src/server_address.dart';

/// The college server this build talks to, e.g. `--dart-define=DCID_SERVER_URL=http://127.0.0.1:8787` for the
/// local server over `adb reverse`. Without it the student types the address on the sign-in screen.
const String _serverUrl = String.fromEnvironment('DCID_SERVER_URL');

void main() => runApp(StudentApp(
      store: SecurePassStore(),
      signer: KeystoreSigner(),
      defaultServer: _serverUrl.isEmpty ? null : parseServerAddress(_serverUrl, allowInsecure: true),
    ));
