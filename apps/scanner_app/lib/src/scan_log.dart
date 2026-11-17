import 'dart:convert';
import 'dart:math';

import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// `scans.type` on the server (supabase/migrations/20261021000000_init.sql).
enum ScanType {
  out('OUT'),
  entryNoCard('ENTRY_NO_CARD'),
  visitor('VISITOR');

  const ScanType(this.wire);
  final String wire;

  static ScanType fromWire(String wire) => values.firstWhere((t) => t.wire == wire);
}

/// `scans.entry_method` on the server.
enum EntryMethod {
  scan('scan'),
  manual('manual');

  const EntryMethod(this.wire);
  final String wire;

  static EntryMethod fromWire(String wire) => values.firstWhere((m) => m.wire == wire);
}

/// One exit, in the shape `scanner-sync` sends (supabase/functions/scanner-sync/index.ts).
class ScanRecord {
  const ScanRecord({
    required this.scanId,
    required this.scannedAt,
    this.studentId,
    this.rollNumber,
    this.type = ScanType.out,
    required this.gate,
    required this.guardId,
    this.entryMethod = EntryMethod.scan,
    this.name,
    this.branch,
    this.year,
  });

  /// Made on the scanner, so re-sending a batch is harmless (the server does `on conflict do nothing`).
  final String scanId;

  /// Unix seconds on the scanner's corrected clock.
  final int scannedAt;

  /// Set for a scanned pass. A manual entry has only [rollNumber]; the server resolves the student.
  final int? studentId;
  final String? rollNumber;
  final ScanType type;
  final String gate;
  final String guardId;
  final EntryMethod entryMethod;

  /// What the pass said about the student, for the out pass register on this phone. These are not sent to the
  /// server (it has the roster); a manual entry has none.
  final String? name;
  final String? branch;
  final int? year;
}

/// One line of the out pass register: an exit, with the student's details as the pass gave them.
class OutpassEntry {
  const OutpassEntry({
    required this.scanId,
    required this.scannedAt,
    required this.rollNumber,
    required this.name,
    required this.branch,
    required this.year,
    required this.gate,
    required this.guardId,
    required this.entryMethod,
  });

  final String scanId;

  /// Unix seconds on the scanner's corrected clock.
  final int scannedAt;
  final String rollNumber;
  final String name;
  final String branch;
  final int year;
  final String gate;
  final String guardId;
  final EntryMethod entryMethod;
}

/// The out pass list: the exits this phone has let through in the last two days, kept after the server has
/// confirmed them (the scan log above is a queue and forgets a row once it is synced). It is the guard's logbook,
/// for looking at on the phone. There is no export: the college's record and its CSV are on the admin website.
abstract interface class OutpassRegister {
  /// Newest first. [sinceS] keeps only exits at or after that unix time.
  Future<List<OutpassEntry>> entries({int? sinceS, int limit = 2000});

  Future<int> registerCount({int? sinceS});
}

/// The scanner's durable record of every exit it let through, kept until the server confirms it.
abstract interface class ScanLog {
  /// Returns only after the row is committed to disk. Throws if it could not be written.
  Future<void> append(ScanRecord record);

  /// Rows not yet confirmed by the server.
  Future<int> count();

  /// Oldest first, for sync.
  Future<List<ScanRecord>> oldest(int limit);

  /// Deletes rows the server accepted. Unknown ids are ignored.
  Future<void> remove(Iterable<String> scanIds);

  Future<void> close();
}

/// What the scanner remembers between syncs, kept in the same database file as the log so that one backup
/// or one wipe covers both.
abstract interface class SyncStateStore {
  /// Server time minus this phone's time, in seconds, from the last sync; 0 if it has never synced.
  Future<int> serverOffsetS();

  /// Unix seconds (scanner clock) of the last sync that the server answered, or null if none.
  Future<int?> lastSyncAtS();

  Future<void> saveSync({required int serverOffsetS, required int syncedAtS});
}

/// The college public key set (docs/credential-spec.md section 8) the scanner got when it was activated.
/// Public keys, so it is kept beside the log and not in encrypted storage.
abstract interface class KeySetStore {
  Future<Map<String, Object?>?> storedKeySet();
  Future<void> saveKeySet(Map<String, Object?> keySet);
}

/// A random version 4 UUID, the format of `scans.scan_id`.
String newScanId([Random? random]) {
  final r = random ?? Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// SQLite on the phone. The table repeats the server's constraints, so a row the server would refuse is
/// refused here, at the gate, where the guard can still do something about it.
///
/// Every call runs on the calling isolate: one small insert is a few milliseconds. Encryption at rest is
/// a later step (SQLite3MultipleCiphers through the `sqlite3` hook options).
class SqliteScanLog implements ScanLog, SyncStateStore, KeySetStore, OutpassRegister {
  SqliteScanLog._(this._db);

  static const int schemaVersion = 3;

  /// How long the out pass list is kept on the guard's phone.
  static const int registerKeepS = 2 * 86400;

  static const _createSql = '''
    CREATE TABLE scan_log (
      seq           INTEGER PRIMARY KEY AUTOINCREMENT,
      scan_id       TEXT    NOT NULL UNIQUE,
      scanned_at    INTEGER NOT NULL,
      student_id    INTEGER,
      roll_number   TEXT,
      type          TEXT    NOT NULL CHECK (type IN ('OUT', 'ENTRY_NO_CARD', 'VISITOR')),
      gate          TEXT    NOT NULL,
      guard_id      TEXT    NOT NULL,
      entry_method  TEXT    NOT NULL CHECK (entry_method IN ('scan', 'manual')),
      CHECK (student_id IS NOT NULL OR roll_number IS NOT NULL)
    )''';

  /// Added in schema 2.
  static const _createMetaSql = '''
    CREATE TABLE meta (
      key    TEXT PRIMARY KEY,
      value  TEXT NOT NULL
    )''';

  /// Added in schema 3: the out pass register, which keeps its rows after they are synced.
  static const _createRegisterSql = '''
    CREATE TABLE outpass_register (
      scan_id       TEXT    PRIMARY KEY,
      scanned_at    INTEGER NOT NULL,
      roll_number   TEXT    NOT NULL,
      name          TEXT    NOT NULL,
      branch        TEXT    NOT NULL,
      year          INTEGER NOT NULL,
      gate          TEXT    NOT NULL,
      guard_id      TEXT    NOT NULL,
      entry_method  TEXT    NOT NULL
    )''';

  final Database _db;

  /// Opens (and creates) the log at [path].
  factory SqliteScanLog.open(String path) => SqliteScanLog._(_prepare(sqlite3.open(path), durable: true));

  /// A throwaway log for tests.
  factory SqliteScanLog.inMemory() => SqliteScanLog._(_prepare(sqlite3.openInMemory(), durable: false));

  /// The log in the app's private storage, which other apps cannot read and Android does not back up.
  static Future<SqliteScanLog> openInAppStorage() async {
    final dir = await getApplicationSupportDirectory();
    return SqliteScanLog.open('${dir.path}/scan_log.db');
  }

  static Database _prepare(Database db, {required bool durable}) {
    try {
      if (durable) {
        // WAL with a full sync on every commit: a row that append() returned for survives a crash or a
        // dead battery in the next second.
        db.execute('PRAGMA journal_mode = WAL');
        db.execute('PRAGMA synchronous = FULL');
      }
      final found = db.userVersion;
      if (found > schemaVersion) {
        throw StateError('scan log schema $found is newer than this app understands ($schemaVersion)');
      }
      if (found < schemaVersion) {
        // One transaction for the whole upgrade: a log is never left half-migrated.
        db.execute('BEGIN');
        if (found == 0) db.execute(_createSql);
        if (found < 2) db.execute(_createMetaSql);
        if (found < 3) db.execute(_createRegisterSql);
        db.userVersion = schemaVersion;
        db.execute('COMMIT');
      }
      return db;
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  @override
  Future<void> append(ScanRecord r) async {
    // The queue row and the register row go in together: a green screen means both are on disk.
    _db.execute('BEGIN');
    try {
      _db.execute(
        'INSERT INTO scan_log (scan_id, scanned_at, student_id, roll_number, type, gate, guard_id, entry_method) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [r.scanId, r.scannedAt, r.studentId, r.rollNumber, r.type.wire, r.gate, r.guardId, r.entryMethod.wire],
      );
      final name = r.name;
      if (name != null && r.rollNumber != null) {
        _db.execute(
          'INSERT OR IGNORE INTO outpass_register (scan_id, scanned_at, roll_number, name, branch, year, gate, guard_id, entry_method) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [r.scanId, r.scannedAt, r.rollNumber, name, r.branch ?? '', r.year ?? 0, r.gate, r.guardId, r.entryMethod.wire],
        );
      }
      // The phone keeps the guard's list for two days, enough for a shift that crosses midnight. The college's
      // full record is on the server.
      _db.execute('DELETE FROM outpass_register WHERE scanned_at < ?', [r.scannedAt - registerKeepS]);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<List<OutpassEntry>> entries({int? sinceS, int limit = 2000}) async {
    final rows = _db.select(
      'SELECT scan_id, scanned_at, roll_number, name, branch, year, gate, guard_id, entry_method FROM outpass_register '
      '${sinceS == null ? '' : 'WHERE scanned_at >= ?'} ORDER BY scanned_at DESC, scan_id LIMIT ?',
      [if (sinceS != null) sinceS, limit],
    );
    return [
      for (final row in rows)
        OutpassEntry(
          scanId: row['scan_id'] as String,
          scannedAt: row['scanned_at'] as int,
          rollNumber: row['roll_number'] as String,
          name: row['name'] as String,
          branch: row['branch'] as String,
          year: row['year'] as int,
          gate: row['gate'] as String,
          guardId: row['guard_id'] as String,
          entryMethod: EntryMethod.fromWire(row['entry_method'] as String),
        ),
    ];
  }

  @override
  Future<int> registerCount({int? sinceS}) async =>
      _db.select('SELECT count(*) AS n FROM outpass_register ${sinceS == null ? '' : 'WHERE scanned_at >= ?'}', [if (sinceS != null) sinceS]).first['n'] as int;

  @override
  Future<int> count() async => _db.select('SELECT count(*) AS n FROM scan_log').first['n'] as int;

  @override
  Future<List<ScanRecord>> oldest(int limit) async {
    final rows = _db.select(
      'SELECT scan_id, scanned_at, student_id, roll_number, type, gate, guard_id, entry_method '
      'FROM scan_log ORDER BY seq LIMIT ?',
      [limit],
    );
    return [
      for (final row in rows)
        ScanRecord(
          scanId: row['scan_id'] as String,
          scannedAt: row['scanned_at'] as int,
          studentId: row['student_id'] as int?,
          rollNumber: row['roll_number'] as String?,
          type: ScanType.fromWire(row['type'] as String),
          gate: row['gate'] as String,
          guardId: row['guard_id'] as String,
          entryMethod: EntryMethod.fromWire(row['entry_method'] as String),
        ),
    ];
  }

  @override
  Future<void> remove(Iterable<String> scanIds) async {
    final ids = scanIds.toList();
    _db.execute('BEGIN');
    try {
      for (var i = 0; i < ids.length; i += 500) {
        final chunk = ids.sublist(i, min(i + 500, ids.length));
        _db.execute('DELETE FROM scan_log WHERE scan_id IN (${List.filled(chunk.length, '?').join(',')})', chunk);
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  String? _meta(String key) {
    final rows = _db.select('SELECT value FROM meta WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  @override
  Future<int> serverOffsetS() async => int.tryParse(_meta('server_offset_s') ?? '') ?? 0;

  @override
  Future<int?> lastSyncAtS() async => int.tryParse(_meta('last_sync_at_s') ?? '');

  @override
  Future<void> saveSync({required int serverOffsetS, required int syncedAtS}) async {
    _db.execute('BEGIN');
    try {
      for (final (key, value) in [('server_offset_s', '$serverOffsetS'), ('last_sync_at_s', '$syncedAtS')]) {
        _db.execute('INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value', [key, value]);
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<Map<String, Object?>?> storedKeySet() async {
    final text = _meta('keyset_json');
    if (text == null) return null;
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> saveKeySet(Map<String, Object?> keySet) async {
    _db.execute("INSERT INTO meta (key, value) VALUES ('keyset_json', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [jsonEncode(keySet)]);
  }

  @override
  Future<void> close() async => _db.close();
}
