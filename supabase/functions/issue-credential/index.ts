// POST /functions/v1/issue-credential
//
// Called by the student app after the admin approves the enrolment, and again to refresh
// the credential before it expires (S5, S9, S11).
//
// Request  (Authorization: Bearer <student's Supabase JWT>)
//   { "device_public_key": "<base64url, 33 bytes, compressed P-256>" }
//
// Response 200
//   { "signed_credential": "DK1.…",   // docs/credential-spec.md section 5
//     "server_time": 1793000000,       // unix seconds; the app stores the offset (spec section 6)
//     "key_version": 2 }
//
// Errors: 401 no session, 403 not approved / student paused or revoked, 422 bad key.
//
// The rules are written, tested and in use on the local server: `_shared/issue_credential.ts` (the handler)
// and `_shared/pg_student_store.ts` (the SQL), covered by `_shared/student_flow.test.ts`. This file is where
// they will be wired to Supabase, which has not been done:
//   1. Replace `authenticate` (`_shared/student_auth.ts`) with a check of the Supabase JWT -> enrolments.auth_user_id.
//   2. Build `PgStudentStore` over postgres.js, as `scanner-sync/index.ts` does for `PgSyncStore`.
//   3. Load the college signing key (`_shared/signer.ts`) and call `handleIssueCredential`.
//   Then `deno check` this file: Deno is not installed on the machine this was written on.

Deno.serve((req: Request) => {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 });
  return Response.json({ error: 'not_implemented' }, { status: 501 });
});
