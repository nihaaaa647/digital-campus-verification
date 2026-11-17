// The Postgres side of student login, enrolment and pass issuing, as plain SQL against the tables in
// supabase/migrations/20261021000000_init.sql plus the local-only tables in supabase/dev/dev_auth.sql.
//
// The login tables (dev_otps, dev_sessions) and the photo table (dev_photos) exist only on the local server:
// on Supabase, Auth and Storage do those jobs.

import type { Db } from './pg_sync_store.ts';
import type { EnrolStore, EnrolmentRecord, EnrolmentStatus, Photo } from './enrolment.ts';
import type { IssueState, IssueStore, IssuedAt } from './issue_credential.ts';
import type { AuthStore, Caller, RosterStudent } from './student_auth.ts';

/** A bytea parameter. Raw bytes are what both postgres.js and PGlite want (PGlite refuses hex text). */
export const bytea = (bytes: Uint8Array): Uint8Array => bytes;

const toBytes = (value: unknown): Uint8Array | null => (value === null || value === undefined ? null : new Uint8Array(value as ArrayLike<number>));

interface StudentRow {
  id: string;
  name: string;
  roll_number: string;
  branch: string;
  year: number | string;
  college_email: string;
  status: string;
  profile_complete: boolean;
}

const studentFrom = (r: StudentRow): RosterStudent => ({
  id: Number(r.id),
  name: r.name,
  roll_number: r.roll_number,
  branch: r.branch,
  year: Number(r.year),
  college_email: r.college_email,
  status: r.status,
  profile_complete: r.profile_complete,
});

const STUDENT_COLUMNS = 'id::text as id, name, roll_number, branch, year, college_email, status, profile_complete';

export class PgStudentStore implements AuthStore, EnrolStore, IssueStore {
  db: Db;

  constructor(db: Db) {
    this.db = db;
  }

  // ---------------------------------------------------------------- AuthStore

  async findOrCreateStudent(rollNumber: string, email: string): Promise<RosterStudent> {
    const found = await this.db.query<StudentRow>(`select ${STUDENT_COLUMNS} from public.students where roll_number = $1`, [rollNumber]);
    if (found[0]) return studentFrom(found[0]);
    // A student the roster did not list: name, branch and year are placeholders until they give them at enrolment.
    const made = await this.db.query<StudentRow>(
      `insert into public.students (roll_number, name, branch, year, college_email, profile_complete)
       values ($1, $1, '-', 1, $2, false)
       on conflict (roll_number) do update set roll_number = excluded.roll_number
       returning ${STUDENT_COLUMNS}`,
      [rollNumber, email],
    );
    return studentFrom(made[0]);
  }

  async secondsSinceLastOtp(email: string): Promise<number | null> {
    const rows = await this.db.query<{ s: number | string }>('select extract(epoch from now() - created_at)::float8 as s from public.dev_otps where email = $1', [email]);
    return rows[0] ? Number(rows[0].s) : null;
  }

  async saveOtp(email: string, codeHash: string, ttlMinutes: number): Promise<void> {
    await this.db.query(
      `insert into public.dev_otps (email, code_hash, attempts, created_at, expires_at)
       values ($1, $2, 0, now(), now() + make_interval(mins => $3::int))
       on conflict (email) do update
         set code_hash = excluded.code_hash, attempts = 0, created_at = now(), expires_at = excluded.expires_at`,
      [email, codeHash, ttlMinutes],
    );
  }

  async takeOtpTry(email: string): Promise<{ codeHash: string } | 'locked' | null> {
    // One statement counts the try and returns the hash, so tries cannot be skipped by racing requests.
    const rows = await this.db.query<{ code_hash: string }>(
      'update public.dev_otps set attempts = attempts + 1 where email = $1 and expires_at > now() and attempts < 5 returning code_hash',
      [email],
    );
    if (rows[0]) return { codeHash: rows[0].code_hash };
    const live = await this.db.query<{ attempts: number }>('select attempts from public.dev_otps where email = $1 and expires_at > now()', [email]);
    return live[0] ? 'locked' : null;
  }

  async clearOtp(email: string): Promise<void> {
    await this.db.query('delete from public.dev_otps where email = $1', [email]);
  }

  async ensureAuthUser(email: string): Promise<string> {
    await this.db.query('insert into auth.users (email) values ($1) on conflict (email) do nothing', [email]);
    return (await this.db.query<{ id: string }>('select id::text as id from auth.users where email = $1', [email]))[0].id;
  }

  async createSession(studentId: number, authUserId: string, tokenHash: string, ttlDays: number): Promise<void> {
    await this.db.query(
      `insert into public.dev_sessions (token_hash, student_id, auth_user_id, expires_at)
       values ($1, $2::bigint, $3::uuid, now() + make_interval(days => $4::int))`,
      [tokenHash, studentId, authUserId, ttlDays],
    );
  }

  async findSession(tokenHash: string): Promise<Caller | null> {
    const rows = await this.db.query<{ student_id: string; auth_user_id: string }>(
      'select student_id::text as student_id, auth_user_id::text as auth_user_id from public.dev_sessions where token_hash = $1 and expires_at > now()',
      [tokenHash],
    );
    return rows[0] ? { studentId: Number(rows[0].student_id), authUserId: rows[0].auth_user_id } : null;
  }

  async endSession(tokenHash: string): Promise<void> {
    await this.db.query('delete from public.dev_sessions where token_hash = $1', [tokenHash]);
  }

  // ---------------------------------------------------------------- EnrolStore

  async findStudentById(id: number): Promise<RosterStudent | null> {
    const rows = await this.db.query<StudentRow>(`select ${STUDENT_COLUMNS} from public.students where id = $1::bigint`, [id]);
    return rows[0] ? studentFrom(rows[0]) : null;
  }

  async getEnrolment(studentId: number): Promise<EnrolmentRecord | null> {
    const rows = await this.db.query<{ id: string; status: EnrolmentStatus; flags: string[] }>(
      'select id::text as id, status, flags from public.enrolments where student_id = $1::bigint order by submitted_at desc limit 1',
      [studentId],
    );
    return rows[0] ? { id: Number(rows[0].id), status: rows[0].status, flags: rows[0].flags ?? [] } : null;
  }

  async completeProfile(studentId: number, profile: { name: string; branch: string; year: number }): Promise<void> {
    await this.db.query(
      'update public.students set name = $2, branch = $3, year = $4::smallint, profile_complete = true where id = $1::bigint and profile_complete = false',
      [studentId, profile.name, profile.branch, profile.year],
    );
  }

  async saveEnrolment(caller: Caller, phone: string, photo: Photo, status: EnrolmentStatus): Promise<EnrolmentRecord> {
    return await this.db.transaction(async (tx) => {
      await tx.query(
        `insert into public.dev_photos (student_id, content_type, bytes, updated_at) values ($1::bigint, $2, $3::bytea, now())
         on conflict (student_id) do update set content_type = excluded.content_type, bytes = excluded.bytes, updated_at = now()`,
        [caller.studentId, photo.contentType, bytea(photo.bytes)],
      );
      // 'duplicate': somebody else already enrolled with this very photo (sharing a card, or a stolen one).
      const same = await tx.query('select 1 from public.enrolments where photo_hash = $1::bytea and student_id <> $2::bigint limit 1', [bytea(photo.hash), caller.studentId]);
      const flags = same.length > 0 ? ['duplicate'] : [];

      const rows = await tx.query<{ id: string; status: EnrolmentStatus; flags: string[] }>(
        `insert into public.enrolments (student_id, auth_user_id, phone, photo_path, photo_hash, status, flags, submitted_at, reviewed_at)
         values ($1::bigint, $2::uuid, $3, $4, $5::bytea, $6, $7::text[], now(), case when $6 = 'approved' then now() end)
         on conflict (auth_user_id) do update
           set phone = excluded.phone, photo_path = excluded.photo_path, photo_hash = excluded.photo_hash,
               status = excluded.status, flags = excluded.flags, submitted_at = now(), reviewed_by = null,
               reviewed_at = case when excluded.status = 'approved' then now() end
           where public.enrolments.status <> 'approved'
         returning id::text as id, status, flags`,
        [caller.studentId, caller.authUserId, phone, `dev_photos/${caller.studentId}`, bytea(photo.hash), status, flags],
      );
      if (rows.length === 0) throw new Error('enrolment is already approved');
      await tx.query('update public.students set phone = coalesce(phone, $2) where id = $1::bigint', [caller.studentId, phone]);
      return { id: Number(rows[0].id), status: rows[0].status, flags: rows[0].flags ?? [] };
    });
  }

  // ---------------------------------------------------------------- IssueStore

  async loadIssueState(studentId: number): Promise<IssueState | null> {
    const student = await this.findStudentById(studentId);
    if (student === null) return null;
    const rows = await this.db.query<{ status: EnrolmentStatus; photo_hash: unknown }>(
      'select status, photo_hash from public.enrolments where student_id = $1::bigint order by submitted_at desc limit 1',
      [studentId],
    );
    return {
      student: { id: student.id, roll_number: student.roll_number, name: student.name, branch: student.branch, year: student.year, status: student.status },
      enrolmentStatus: rows[0]?.status ?? null,
      photoHash: toBytes(rows[0]?.photo_hash),
    };
  }

  async swapDevice<T>(
    studentId: number,
    devicePublicKey: Uint8Array,
    keyVersion: number,
    build: (latestRevokedAtS: number | null) => Promise<IssuedAt & { value: T }>,
  ): Promise<T> {
    return await this.db.transaction(async (tx) => {
      // A new phone replaces the old one; the old one is revoked in the same transaction as the new pass.
      await tx.query('update public.devices set revoked_at = now() where student_id = $1::bigint and revoked_at is null and device_public_key <> $2::bytea', [studentId, bytea(devicePublicKey)]);
      const latest = await tx.query<{ t: string | null }>('select extract(epoch from max(revoked_at))::bigint::text as t from public.devices where student_id = $1::bigint', [studentId]);
      const built = await build(latest[0]?.t ? Number(latest[0].t) : null);

      const updated = await tx.query(
        `update public.devices set issued_at = to_timestamp($3::bigint), expires_at = to_timestamp($4::bigint), key_version = $5::smallint
          where student_id = $1::bigint and device_public_key = $2::bytea and revoked_at is null returning id`,
        [studentId, bytea(devicePublicKey), built.iat, built.exp, keyVersion],
      );
      if (updated.length === 0) {
        await tx.query(
          `insert into public.devices (student_id, device_public_key, key_version, issued_at, expires_at)
           values ($1::bigint, $2::bytea, $3::smallint, to_timestamp($4::bigint), to_timestamp($5::bigint))`,
          [studentId, bytea(devicePublicKey), keyVersion, built.iat, built.exp],
        );
      }
      return built.value;
    });
  }
}
