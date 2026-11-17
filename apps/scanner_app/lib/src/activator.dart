import 'package:credential_core/credential_core.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'activation_client.dart';
import 'scan_log.dart';
import 'scanner_identity.dart';

sealed class ActivationResult {
  const ActivationResult();
}

class Activated extends ActivationResult {
  const Activated(this.identity, this.keys);

  final ScannerIdentity identity;

  /// The college public keys from the server, ready for `verifyScan`.
  final Map<int, Uint8List> keys;
}

class ActivationFailed extends ActivationResult {
  const ActivationFailed(this.message);

  /// Words for the guard, saying what to do.
  final String message;
}

/// What a guard is told for each way activation can fail.
String activationMessage(ActivationFailure failure) => switch (failure) {
      ActivationFailure.invalidCode => "That code isn't valid or has expired. Check it, or ask the admin for a new one.",
      ActivationFailure.disabled => 'The admin has disabled this scanner. Ask them to enable it.',
      ActivationFailure.network => "Can't reach the server. Check the address and the internet connection.",
      ActivationFailure.server => 'The server had a problem. Try again in a minute.',
      ActivationFailure.badResponse => "The server's answer wasn't what this app expects. Check the server address.",
    };

const String badAddressMessage = "That server address doesn't look right. It should look like https://your-project.supabase.co";
const String noKeysMessage = 'The server has no college keys set up yet, so this scanner could not check passes. Tell the admin: they need to fix it and give you a new code.';
const String badKeysMessage = "The college keys the server sent are damaged, so this scanner could not use them. Tell the admin: they need to fix it and give you a new code.";
const String saveFailedMessage = "The scanner couldn't save its activation on this phone. Try again; if it repeats, ask the admin for a new code.";

/// Activating a scanner: swap the code for the scanner's identity and keys, and keep both.
///
/// Nothing is kept unless everything worked: the scanner is never left holding a token without the keys to
/// check passes. (If the keys are saved and the token is not, the scanner just stays not activated.)
class Activator {
  Activator({required this.identityStore, required this.keyStore, this.httpClient, this.allowInsecure = kDebugMode});

  final IdentityStore identityStore;
  final KeySetStore keyStore;
  final http.Client? httpClient;

  /// Accept `http://` server addresses (development only).
  final bool allowInsecure;

  Future<ActivationResult> activate({required String server, required String code}) async {
    final base = parseServerAddress(server, allowInsecure: allowInsecure);
    if (base == null) return const ActivationFailed(badAddressMessage);

    final client = ActivationClient(base, httpClient: httpClient);
    final ActivationReply reply;
    try {
      reply = await client.activate(code);
    } on ActivationException catch (e) {
      return ActivationFailed(activationMessage(e.failure));
    } finally {
      client.close();
    }

    final keySet = reply.keySet;
    if (keySet == null) return const ActivationFailed(noKeysMessage);
    final Map<int, Uint8List> keys;
    try {
      keys = parseKeySet(keySet);
    } on FormatException {
      return const ActivationFailed(badKeysMessage);
    }

    final identity = ScannerIdentity(serverBase: base, scannerId: reply.scannerId, name: reply.name, gate: reply.gate, token: reply.token);
    try {
      await keyStore.saveKeySet(keySet);
      await identityStore.save(identity);
    } catch (_) {
      // Keep nothing half done: without its token the scanner is simply not activated. (The keys are public
      // and harmless to leave.)
      try {
        await identityStore.clear();
      } catch (_) {}
      return const ActivationFailed(saveFailedMessage);
    }
    return Activated(identity, keys);
  }
}
