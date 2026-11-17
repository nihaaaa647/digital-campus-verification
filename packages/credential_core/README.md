# credential_core

The Dart implementation of the Digital Campus ID credential and QR format. Both apps depend on it so that the student app and the scanner cannot drift apart. The format itself is defined in [`docs/credential-spec.md`](../../docs/credential-spec.md) and tested by [`spec/test-vectors/v1.json`](../../spec/test-vectors/v1.json).

## What each app uses

| Student app | Guard scanner |
|---|---|
| `parseSignedCredential`, `decodeCredential` to read what the server issued | `verifyScan` for every QR |
| `buildScanQr` with a `DeviceSigner` every 30 s | `verifyRevocationList` after each sync |
| `ecdsaDerToRaw`, `compressedPublicKeyFromSpki` to turn Android Keystore output into wire format | `parseKeySet` for the bundled and synced college keys |

```dart
// Scanner, per scan
final outcome = verifyScan(qrText, now: correctedNowSeconds, keys: keys, revoked: revokedEntries);
switch (outcome) {
  case ScanAccepted(:final credential): /* green, log the row */
  case ScanRejected(:final failure):    /* red, show failure.code's one-line next step */
}
```

## Implementing `DeviceSigner` on Android

The Keystore returns a DER signature, and the wire format is raw `r || s`. Wrap the platform call like this:

```dart
class KeystoreSigner implements DeviceSigner {
  @override
  Future<Uint8List> signRaw(Uint8List message) async {
    final der = await _channel.invokeMethod<Uint8List>('sign', message);
    return ecdsaDerToRaw(der!);
  }
}
```

## Tests

```bash
dart test
```

The suite loads the shared vectors, so a change to the format needs a change to `tools/gen-vectors/gen.mjs`, a regenerated vectors file and a matching change in `supabase/functions/_shared/credential.ts`.
