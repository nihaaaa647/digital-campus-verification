# Digital Campus ID: Credential and QR Format, version 1

Status: draft for the prototype. This is the single document that the Android student app, the guard scanner, the Supabase functions and a future iOS app must all follow (PRD §7, §11).

The executable form of this document is [`spec/test-vectors/v1.json`](../spec/test-vectors/v1.json). An implementation conforms if it reproduces the byte-exact encodings in that file and returns the expected result for every verification case in it. If this text and the vectors ever disagree, fix whichever is wrong and regenerate; do not let one implementation decide.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## 1. Scope

Covered here:

- the **credential** the college signs once per semester and stores on the phone;
- the **QR payload** the phone shows, rebuilt every few seconds, and that the scanner verifies offline;
- the **revocation list** scanners download when online;
- the **key set** scanners use to verify college signatures;
- the **verification algorithm**, its ordering and its result codes;
- the time policy and size budget.

Not covered (defined elsewhere): the sync API between scanner and server, the scan-log row, manual entry (a manual entry has no credential; the scanner logs the roll number the guard typed and the server resolves it from the roster), the host-issued visitor QR (pass type 2 is reserved; its payload is a phase 2 addition to this spec), OTP sign-up and the admin panel.

## 2. Objects at a glance

```
College signing key (kv N, held by the server / KMS)
        |  signs once per semester
        v
  CREDENTIAL  ----- 117 bytes typical, contains the device public key
        |
        |  stored on the phone as a SIGNED CREDENTIAL  ("DK1." text)
        v
Phone, every 30 s:  ts = corrected time
        device key signs (ts, credential)              <- key never leaves the Keystore
        |
        v
  QR PAYLOAD  "DC1." + base64url( CBOR[ credential, college_sig, ts, device_sig ] )
        |
        v
Scanner, offline: check college sig, device sig, time window, expiry, revocation list
```

| Text prefix | Object | Produced by | Consumed by |
|---|---|---|---|
| `DK1.` | signed credential | server (`issue-credential`) | student app (storage) |
| `DC1.` | QR payload | student app | scanner |
| `DR1.` | signed revocation list | server | scanner |

## 3. Conventions

### 3.1 Encodings

- **Text form.** Every `DK1.`, `DC1.` and `DR1.` string is its 3-character prefix, a dot, then **base64url without padding** (RFC 4648 §5, alphabet `A-Z a-z 0-9 - _`) of the binary object. A QR text longer than 1024 characters MUST be rejected as malformed.
- **Binary form.** A deterministic subset of CBOR (RFC 8949): unsigned integers (major type 0), byte strings (2), text strings (3), arrays (4) and maps (5) whose keys are unsigned integers. Nothing else (no negative integers, tags, floats, booleans, null or indefinite lengths).
- **Issuers MUST encode canonically:** definite lengths only, integers in their shortest form, map keys in ascending order, no duplicate keys, text in Unicode NFC.
- **Verifiers MUST NOT require canonical form.** A signature covers the exact bytes received, so verifiers never re-encode. They MUST reject indefinite lengths, tags, floats, negative integers, duplicate map keys, nesting deeper than 8, invalid UTF-8, and any bytes after the top-level item.
- **Integers MUST be below 2^53** so that every platform, including JavaScript, represents them exactly. Unix timestamps are in seconds.

### 3.2 Cryptography

| Item | Value |
|---|---|
| Signature algorithm | ECDSA over NIST P-256 with SHA-256 (JOSE `ES256`) |
| Public key | compressed SEC1 point, 33 bytes (`02` or `03`, then X) |
| Signature | raw `r || s`, 64 bytes, each 32 bytes big-endian (IEEE P1363). **Not DER.** |
| `s` normalisation | none. Android Keystore does not normalise `s`, so verifiers MUST accept both low-S and high-S signatures. |

Android Keystore and AWS/GCP KMS return **DER** signatures. Convert them to raw `r || s` before they go anywhere near a QR, a credential or the database. Every implementation provides one `derToRaw` function for this; there is a vector-backed test for it.

Android Keystore returns the public key as an X.509 `SubjectPublicKeyInfo`. Take the last 65 bytes (the uncompressed point `04 || X || Y`) and compress it: prefix `02` if Y is even, `03` if odd, followed by X.

### 3.3 Domain separation

Each signature is computed over a context string followed by the data, so that a signature made for one purpose can never be replayed for another. The context strings are ASCII followed by one NUL byte (0x00):

| Name | Bytes | Hex |
|---|---|---|
| `CTX_CRED` | `DCID1-CRED\0` | `44434944312d4352454400` |
| `CTX_SCAN` | `DCID1-SCAN\0` | `44434944312d5343414e00` |
| `CTX_REVO` | `DCID1-REVO\0` | `44434944312d5245564f00` |

| Signature | Signer | Signed message |
|---|---|---|
| college signature | college key `kv` | `CTX_CRED \|\| credential_bytes` |
| device signature | key in credential field 9 | `CTX_SCAN \|\| u64be(ts) \|\| credential_bytes` |
| revocation signature | college key `kv` | `CTX_REVO \|\| payload_bytes` |

`u64be(ts)` is `ts` as an 8-byte big-endian unsigned integer. `credential_bytes` and `payload_bytes` are the exact bytes embedded in the object, not a re-encoding.

## 4. Credential

A CBOR map with unsigned-integer keys. All fields 0 to 11 are required. Verifiers MUST ignore any additional keys of 12 or more (they are inside the signed bytes, so they are authenticated).

| Key | Name | CBOR type | Meaning and constraints |
|---|---|---|---|
| 0 | `v` | uint | format version, `1` |
| 1 | `kv` | uint | version of the college key that signed this credential |
| 2 | `sid` | uint | student ID, a server-assigned integer ≥ 1, never reused. This is what revocation refers to. |
| 3 | `roll` | text | roll or admission number, uppercase ASCII letters, digits and `-`, 1 to 16 bytes |
| 4 | `name` | text | display name, NFC, 1 to 64 bytes of UTF-8 |
| 5 | `branch` | text | branch code as in the roster, for example `CSE-AIML`, 1 to 12 ASCII bytes. Text, not a number, so adding a branch never needs an app update. |
| 6 | `year` | uint | year of study when issued, 1 to 6 |
| 7 | `pass` | uint | pass type: `0` Student, `1` Fresher (temporary), `2` Visitor (reserved) |
| 8 | `photo` | bytes(16) | first 16 bytes of SHA-256 of the approved profile photo file. Lets the app detect a changed photo; the photo itself is never in the QR. |
| 9 | `dpk` | bytes(33) | device public key, compressed P-256 |
| 10 | `iat` | uint | issued at, unix seconds |
| 11 | `exp` | uint | expiry, unix seconds, exclusive: the credential is valid while `now < exp`. Must be greater than `iat`. |

There is deliberately no phone number: a QR can be read by any app, and the server adds the phone number to the export by roll number (PRD §7, §8).

Worked example, the `student_ok` vector (117 bytes):

```
ac                          map(12)
  00 01                     v      = 1
  01 02                     kv     = 2
  02 19 0412                sid    = 1042
  03 6a 32353037314130303031            roll   = "25071A0001"
  04 6e 53616d706c652053747564656e74    name   = "Sample Student"
  05 68 4353452d41494d4c                branch = "CSE-AIML"
  06 02                     year   = 2
  07 00                     pass   = 0 (Student)
  08 50 5f9ae74e…f93da      photo  = 16 bytes
  09 58 21 02f6ff01…33a5e6  dpk    = 33 bytes
  0a 1a 6ad718fe            iat    = 1792481534
  0b 1a 6bc466fe            exp    = 1808033534
```

## 5. Signed credential (`DK1.`)

What the phone downloads and stores. A CBOR array of two byte strings:

```
[ credential_bytes, college_sig ]
```

The phone keeps this and, for every QR refresh, splices the two items into the QR payload. It never re-encodes the credential.

## 6. QR payload (`DC1.`)

A CBOR array of four items:

```
[ credential_bytes : bstr,
  college_sig      : bstr(64),
  ts               : uint,       // unix seconds, the phone's corrected clock
  device_sig       : bstr(64) ]
```

**Phone rules**

1. The app MUST sign a fresh `ts` at least every `QR_REFRESH_S` (default 30 seconds; PRD S6 allows 30 to 60 but the scanner's `max_age` below must grow with it).
2. `ts` is the phone's clock plus the offset to server time recorded at its last online contact. This keeps the phone usable when its own clock is a little off.
3. The device key MUST be a non-exportable, hardware-backed key where the phone has one. It SHOULD NOT require per-use user authentication, because the QR rotates every 30 seconds. The app lock (PRD S8) gates the screen instead.
4. The QR SHOULD be drawn at error-correction level L (see §12). Try M at the gate if scanning in glare is slow.

## 7. Revocation list (`DR1.`)

A CBOR array `[ payload_bytes, sig ]` where `sig` is the revocation signature over `payload_bytes`. The payload is a map:

| Key | Name | Meaning |
|---|---|---|
| 0 | `v` | `1` |
| 1 | `kv` | key version that signed the list |
| 2 | `seq` | list number, increases by at least 1 on every publication |
| 3 | `iat` | when the list was generated, unix seconds |
| 4 | `revoked` | array of `[sid, revoked_at]` pairs |

**Meaning.** A credential is revoked when the list has an entry with the same `sid` and `credential.iat <= revoked_at`.

This one rule covers every case the PRD needs without a separate "device revoked" list:

| Event | Server action |
|---|---|
| Pause or revoke a pass | add `[sid, now]`; refuse to issue new credentials while the student is not active |
| Reinstate | remove the entry. Credentials issued before the pause work again. |
| Change phone (S11) | add `[sid, now]`, then issue a credential for the new key. The new `iat` is greater than `now`, so the new phone works and the old one does not. |

**Server rules**

- A new credential's `iat` MUST be strictly greater than every `revoked_at` held for that student. (If a revocation and an issue land in the same second, use `iat = revoked_at + 1`.)
- Entries older than the longest possible credential life (200 days) can be dropped, since every credential issued before them has expired.

**Scanner rules**

- Verify the list when downloading (§8 result codes). Replace the stored list only if verification passes and `seq` is higher than the stored one.
- The stored list's `iat` drives the staleness warning (PRD G10, default warn after 24 hours). That warning is app policy, not part of `verifyScan`.
- A revoked pass keeps working until the scanner next syncs; that is why credentials are short-lived (PRD §7).

## 8. Key set and key versions

The college signing key has a version number `kv`. Every credential and revocation list names the version that signed it. A scanner holds the public keys for the **current and previous** versions at least, so a rotation never strands a gate.

Key set document (JSON, bundled in the scanner build and refreshed on every sync):

```json
{ "v": 1, "current": 2,
  "keys": [ { "kv": 1, "alg": "ES256", "pub": "<base64url, 33 bytes>" },
            { "kv": 2, "alg": "ES256", "pub": "<base64url, 33 bytes>" } ] }
```

**Rotation procedure**

1. Create key `kv+1` in the KMS. Add it to the key set. Do not issue with it yet.
2. Wait until every scanner has synced (the admin panel shows each scanner's last sync, A6).
3. Switch issuance to `kv+1`.
4. Remove key `kv` from the key set once no unexpired credential names it.

**Trust.** The bundled keys are the root of trust. A key set fetched on sync is trusted because it arrives over TLS from the scanner's authenticated session. Signing new key sets with the previous key is a later hardening step (PRD phase P2).

## 9. Verification algorithm

`verifyScan(text, now, keys, revoked)` runs these steps **in this order** and stops at the first failure. The order matters: two implementations given the same input must return the same code, and no field of the credential is acted on until its signatures check out (except `v` and `kv`, which are needed to pick the right rules and key).

| # | Step | On failure |
|---|---|---|
| 1 | Reject text over 1024 characters. Match `^DC([0-9]{1,3})\.`. | no match or too long: `MALFORMED` |
| 2 | The number after `DC` must be `1`. | `UNSUPPORTED_VERSION` |
| 3 | Decode base64url, then CBOR. It must be an array of exactly `[bstr, bstr(64), uint, bstr(64)]`. | `MALFORMED` |
| 4 | Decode `credential_bytes` as a CBOR map. Read field 0. | not a map, or field 0 missing: `MALFORMED` |
| 5 | Field 0 must be `1`. | `UNSUPPORTED_VERSION` |
| 6 | Validate fields 1 to 11: presence, type, lengths, ranges from §4, `exp > iat`, `dpk` starting `02` or `03`. | `MALFORMED` |
| 7 | Look up `kv` in the scanner's key set. | `UNKNOWN_KEY_VERSION` |
| 8 | Verify the college signature. | `BAD_COLLEGE_SIG` |
| 9 | Verify the device signature with `dpk` from the credential. | `BAD_DEVICE_SIG` |
| 10 | Check the time window (§10). | `CLOCK_MISMATCH` |
| 11 | `now >= exp`. | `EXPIRED` |
| 12 | Revocation rule from §7. | `REVOKED` |
| 13 | All passed. | `OK` |

Revocation-list verification returns `MALFORMED`, `UNSUPPORTED_VERSION`, `UNKNOWN_KEY_VERSION` or `BAD_SIGNATURE`, checked in that order.

### Result codes and the guard's red screen (PRD §5)

| Code | Red screen reason | Guard's one-line next step |
|---|---|---|
| `EXPIRED` | Expired pass | Ask the student to open the app online to refresh; otherwise send to the desk. |
| `REVOKED` | Revoked pass | Send to the desk. |
| `BAD_COLLEGE_SIG`, `BAD_DEVICE_SIG`, `MALFORMED` | Bad signature | Ask the student to wait for the QR to refresh and scan again; if it repeats, log manually or send to the desk. |
| `UNSUPPORTED_VERSION` | Pass needs an update | Ask the student to update the app; log manually meanwhile. |
| `UNKNOWN_KEY_VERSION` | Unknown ID | The scanner has not synced a newer key. Sync on Wi-Fi and rescan; log manually meanwhile. |
| `CLOCK_MISMATCH` | Clock mismatch | Ask the student to rescan once the QR refreshes; if it repeats, check the phone's automatic time and the scanner's last sync. |

The PRD's "unknown roster ID" reason cannot be produced offline, because the scanner holds no roster. `UNKNOWN_KEY_VERSION` is the closest honest equivalent. Unknown students are caught at export time instead, when the server resolves each scan against the roster.

## 10. Time policy

All times are unix seconds. `now` is the scanner's clock corrected by its offset from the server (PRD G14).

| Parameter | Default | Meaning |
|---|---|---|
| `QR_REFRESH_S` | 30 | the phone signs a new `ts` at least this often |
| `max_age_s` | 45 | accept if `now - ts <= 45` (refresh interval plus 15 s for scan time and drift) |
| `max_future_s` | 10 | accept if `ts - now <= 10` |

These are starting values to tune at the gate, and `max_age_s` MUST be at least `QR_REFRESH_S` plus a few seconds of margin. The PRD says "a few seconds"; a window that short would reject a QR that is still on screen, because the countdown shows the QR for the whole refresh interval. A forwarded or screenshotted QR is therefore accepted for at most `max_age_s` seconds.

`expired` is exclusive: at `now == exp` the credential is expired, at `now == exp - 1` it is valid.

Phone clocks are the likely source of false red screens. The student app SHOULD warn when its stored server-time offset is larger than about 10 seconds.

## 11. Issuer rules

- `sid` is stable for a student for life. `roll` is uppercase; `name` is NFC; `branch` is the roster's code.
- `iat` is the issue time and obeys the revocation rule in §7. `exp` is about one semester after `iat`, at most 200 days. A fresher pass uses the expiry date the admin set (A7).
- `photo` is computed from the bytes of the approved photo file.
- Issue only for an active student with an approved enrolment, and only against an authenticated session.
- Sign with the current `kv`. The signer returns raw `r || s`; convert KMS DER output first.
- The phone refreshes the credential while online once it is older than half its life, or `exp - now` is under 14 days (PRD S9).

## 12. Size budget

Measured on the test vectors:

| Item | Size |
|---|---|
| credential (typical) | 111 to 117 bytes |
| QR payload, binary | about 257 bytes |
| QR text (`DC1.` + base64url) | 340 to 347 characters |
| QR text, worst case (64-byte name, 16-byte roll, 12-byte branch) | about 430 characters |

QR codes carry byte-mode text; at 340 to 347 characters that is **version 12** at level L (65 × 65 modules) or **version 14** at level M (73 × 73). Capacity figures come from the QR standard's byte-mode table; confirm on a real phone. Fewer modules means bigger modules on screen and faster scans in sunlight, which is why the credential is lean: compressed key, truncated photo hash, integer field keys, text branch code.

If the pilot shows scanning is slow, the next saving is carrying the payload as raw binary instead of base64url, about 25 percent smaller. That is a `DC2.` change, not a tweak.

## 13. Versioning and compatibility

- `DC1`, `DK1`, `DR1` and field `v` change only for incompatible changes.
- New optional credential fields use keys 12 or more and need no version bump; v1 verifiers ignore them.
- A scanner SHOULD keep accepting the previous format for a transition period after a new version ships.
- Pass type `2` (Visitor) and the host-issued visitor QR are reserved for a later revision of this document.

## 14. Security notes

- **What the QR proves.** The college issued this credential to a key, the holder of that key signed the current time, the credential has not expired and its student ID is not on the scanner's revocation list.
- **What it does not prove.** That the person holding the phone is the student. The app lock, the guard seeing the name and the ID view are the only controls for that (PRD §13, "live QR relay").
- **A QR is readable by any camera.** Name, roll number, branch and year are visible to anyone who scans it. The PRD accepts this (§7) and blocks screenshots in the app.
- **Replay.** A copied QR works only inside the `max_age_s` window and only if the live device key signed it.
- **Revocation lag.** Offline scanners learn about a revocation on their next sync.
- **Key enrolment is not attested.** The server cannot yet prove that the submitted public key is hardware-backed. Android key attestation and Play Integrity are PRD phase P2.

## 15. Test vectors

`spec/test-vectors/v1.json` contains test keys only. It is produced by `tools/gen-vectors/gen.mjs`, which uses only `node:crypto`, signs with RFC 6979, and so produces the same file every time.

```
node tools/gen-vectors/gen.mjs
```

| Section | Contents | Used for |
|---|---|---|
| `keys`, `keyset_json` | test private and public keys, a key set document | key handling |
| `credentials` | field values, expected `cbor_hex`, college signature, `signed_text` | byte-exact encoding, signature checks |
| `revocation_lists` | entries, expected payload and encoded text | list encoding |
| `revocation_cases` | encoded text, scanner key set, expected result | list verification |
| `verify_cases` | QR text, `now`, scanner key set, attached list, expected result | the full algorithm |

The 32 verify cases cover: accepted scans (previous key, multi-byte name, both `s` halves), the age and future-skew boundaries (45 and 46 seconds, 10 and 11 seconds), the expiry boundary, tampered credential, flipped signature bit, wrong device key, moved timestamp, unknown key version, unsupported versions, every malformed shape, and five revocation outcomes including the reissue-after-revocation case.

An implementation also has to pass these additional checks:

- re-encoding each `credentials[].fields` gives exactly `cbor_hex`;
- both the TypeScript and the Dart implementations reproduce every college signature byte for byte, since they and the generator all sign deterministically with RFC 6979. Three independent ECDSA implementations (`node:crypto` in the generator, `@noble/curves`, `pointycastle`) agree on every signature in the file.

Run them:

```
cd supabase/functions && npm test                 # TypeScript
cd packages/credential_core && dart test          # Dart
```
