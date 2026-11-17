import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'student_api.dart';

/// A signed-in student on this phone: the server's access token and who it belongs to.
class Session {
  const Session({required this.token, required this.student});

  final String token;
  final StudentProfile student;
}

/// What the phone keeps about the login, next to the pass (pass_store.dart): the session, and which server
/// the student chose to sign in to.
abstract interface class SessionStore {
  Future<Session?> load();
  Future<void> save(Session session);
  Future<void> clear();

  /// The server address the student last used, or null.
  Future<String?> loadServer();
  Future<void> saveServer(String address);
}

/// Android's encrypted preferences, like the pass. The token alone lets someone get the student's pass issued
/// to their own phone once approved, so it is kept off plain storage.
class SecureSessionStore implements SessionStore {
  SecureSessionStore({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  static const _sessionKey = 'dcid.session.v1';
  static const _serverKey = 'dcid.server.v1';

  final FlutterSecureStorage _storage;

  @override
  Future<Session?> load() async {
    final text = await _storage.read(key: _sessionKey);
    if (text == null) return null;
    try {
      final json = jsonDecode(text);
      if (json is! Map) return null;
      final token = json['token'];
      final student = StudentProfile.fromJson(json['student']);
      return token is String && student != null ? Session(token: token, student: student) : null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> save(Session session) => _storage.write(key: _sessionKey, value: jsonEncode({'token': session.token, 'student': session.student.toJson()}));

  @override
  Future<void> clear() => _storage.delete(key: _sessionKey);

  @override
  Future<String?> loadServer() => _storage.read(key: _serverKey);

  @override
  Future<void> saveServer(String address) => _storage.write(key: _serverKey, value: address);
}

/// For tests and previews.
class MemorySessionStore implements SessionStore {
  MemorySessionStore({Session? session, String? server})
      : _session = session,
        _server = server;

  Session? _session;
  String? _server;

  @override
  Future<Session?> load() async => _session;

  @override
  Future<void> save(Session session) async => _session = session;

  @override
  Future<void> clear() async => _session = null;

  @override
  Future<String?> loadServer() async => _server;

  @override
  Future<void> saveServer(String address) async => _server = address;
}
