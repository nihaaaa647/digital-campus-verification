// The whole prototype loop with the real server, in one test: a scanner is activated with a code from the
// admin side, a student signs in, enrols, is approved and gets a pass, the scanner accepts the pass and
// syncs the exit, and the exit shows up in the admin's exits table and CSV.
//
// Skipped unless a local server is running and its address is given:
//
//   cd supabase/functions && MEMORY=1 PORT=8790 ADMIN_PASSWORD=test-admin npm run dev:server
//   cd apps/scanner_app
//   DCID_SERVER_URL=http://127.0.0.1:8790 DCID_ADMIN_PASSWORD=test-admin flutter test test/full_loop_integration_test.dart
//
// (PowerShell: $env:DCID_SERVER_URL = '...'; flutter test test/full_loop_integration_test.dart)
// The student side is plain HTTP here (the student app has its own integration test); what matters in this
// file is that a pass the real server issues is accepted by the scanner's code with the key set the real
// server hands out on activation, and that the exit comes out the other end.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:credential_core/credential_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:scanner_app/src/activation_client.dart';
import 'package:scanner_app/src/scan_log.dart';
import 'package:scanner_app/src/sync_client.dart';
import 'package:scanner_app/src/sync_service.dart';

final String? _url = Platform.environment['DCID_SERVER_URL'];
final String? _adminPassword = Platform.environment['DCID_ADMIN_PASSWORD'];

/// The admin website's session cookie, from signing in with the password the server printed.
String? _adminCookie;

Future<void> _adminSignIn() async {
  final request = http.Request('POST', Uri.parse('$_url/admin/login'))
    ..followRedirects = false // the cookie is on the redirect itself
    ..bodyFields = {'password': _adminPassword ?? ''};
  final response = await http.Response.fromStream(await request.send());
  if (response.statusCode != 303) fail('admin sign-in -> ${response.statusCode}: set DCID_ADMIN_PASSWORD to the ADMIN_PASSWORD the server was started with');
  _adminCookie = response.headers['set-cookie']!.split(';').first;
}

/// Test key dev A from spec/test-vectors/v1.json: the "phone" in this test.
final Uint8List _phoneKey = hexToBytes('0c9b9c3ee8d2ab86c0a470977de8042d349281f0bdcf3e7d037b9052fbb4e06a');

class _SoftwareSigner implements DeviceSigner {
  @override
  Future<Uint8List> signRaw(Uint8List message) async => signEcdsa(_phoneKey, message);
}

Future<Map<String, Object?>> _post(String path, Object body, {String? token}) async {
  final response = await http.post(
    Uri.parse('$_url$path'),
    headers: {'Content-Type': 'application/json', if (token != null) 'Authorization': 'Bearer $token'},
    body: jsonEncode(body),
  );
  if (response.statusCode == 429) {
    final wait = (jsonDecode(response.body) as Map)['retry_after_s'] as int? ?? 30;
    await Future<void>.delayed(Duration(seconds: wait + 1));
    return _post(path, body, token: token);
  }
  if (response.statusCode != 200) fail('POST $path -> ${response.statusCode}: ${response.body}');
  return jsonDecode(response.body) as Map<String, Object?>;
}

Future<Map<String, Object?>> _get(String path) async {
  final response = await http.get(Uri.parse('$_url$path'), headers: {if (_adminCookie != null) 'cookie': _adminCookie!});
  if (response.statusCode != 200) fail('GET $path -> ${response.statusCode}: ${response.body}');
  return jsonDecode(response.body) as Map<String, Object?>;
}

void main() {
  test(
    'activate a scanner, onboard a student, scan the pass, sync the exit, see it on the admin page',
    () async {
      final base = Uri.parse(_url!);

      // The admin website is behind a login; a guard's scanner token does not open it.
      expect((await http.get(base.replace(path: '/admin/api/exits.csv'), headers: {'Authorization': 'Bearer dev-token'})).statusCode, 401);
      await _adminSignIn();

      // The admin makes an activation code and the scanner swaps it for its identity and the college keys.
      final code = (await _get('/_dev/activation-code?scanner=SC-NEW'))['code']! as String;
      final activation = ActivationClient(base);
      addTearDown(activation.close);
      final scanner = await activation.activate(code);
      expect(scanner.scannerId, 'SC-NEW');
      final keys = parseKeySet(scanner.keySet!);

      // The student: sign in with a code, enrol (approved at once), get a pass for the phone's key.
      const email = '25071a0003@vnrvjiet.in';
      final otp = (await _post('/functions/v1/auth-request-otp', {'email': email}))['dev_otp']! as String;
      final token = (await _post('/functions/v1/auth-verify-otp', {'email': email, 'otp': otp}))['access_token']! as String;
      final photo = Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, ...List.filled(2500, 7)]);
      await _post('/functions/v1/enrol', {'phone': '+919876543210', 'photo_base64': base64Encode(photo)}, token: token);

      // No admin step: the roll-number email and its one-time code already proved who this is.
      final listed = await _get('/admin/api/state');
      final enrolment = (listed['enrolments'] as List).cast<Map<String, Object?>>().firstWhere((e) => e['roll_number'] == '25071A0003');
      expect(enrolment['status'], 'approved');

      final issued = await _post('/functions/v1/issue-credential', {'device_public_key': toBase64Url(publicKeyOf(_phoneKey))}, token: token);
      final signed = parseSignedCredential(issued['signed_credential']! as String)!;
      final credential = decodeCredential(signed.credentialBytes);
      expect(credential.name, 'Ravi Kumar');

      // At the gate: the QR the phone shows is accepted with the keys the scanner got on activation.
      final ts = (issued['server_time']! as int) + 2;
      final qr = await buildScanQr(signed, ts, _SoftwareSigner());
      final outcome = verifyScan(qr, now: ts, keys: keys);
      expect(outcome, isA<ScanAccepted>());

      // The scanner saves the exit and syncs with its own token.
      final log = SqliteScanLog.inMemory();
      addTearDown(log.close);
      final scanId = newScanId();
      await log.append(ScanRecord(
        scanId: scanId,
        scannedAt: ts,
        studentId: credential.sid,
        rollNumber: credential.roll,
        gate: scanner.gate,
        guardId: 'G-DEV',
        entryMethod: EntryMethod.scan,
      ));
      final service = SyncService(
        log: log,
        state: log,
        client: SyncClient(SyncConfig(endpoint: base.replace(path: '/functions/v1/scanner-sync'), token: scanner.token)),
      );
      addTearDown(service.dispose);
      await service.syncNow();

      expect(service.phase, SyncPhase.synced);
      expect(await log.oldest(10), isEmpty, reason: 'the server confirmed the exit, so the phone let go of it');

      // The admin sees it: in the exits table, matched to the student, and in the CSV.
      final state = await _get('/admin/api/state');
      final exit = (state['scans'] as List).cast<Map<String, Object?>>().firstWhere((s) => s['roll_number'] == '25071A0003');
      expect(exit['name'], 'Ravi Kumar');
      expect(exit['scanner_id'], 'SC-NEW');
      expect(exit['gate'], scanner.gate);
      expect(exit['entry_method'], 'scan');

      final csv = utf8.decode((await http.get(base.replace(path: '/admin/api/exits.csv'), headers: {if (_adminCookie != null) 'cookie': _adminCookie!})).bodyBytes);
      expect(csv, contains('25071A0003'));
      expect(csv, contains('Ravi Kumar'));
    },
    skip: _url == null ? 'set DCID_SERVER_URL to a running local server (see the top of this file)' : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
