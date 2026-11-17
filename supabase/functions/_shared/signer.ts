// Where the college signing key lives. Everything that signs goes through a CollegeSigner,
// so moving the key from an environment variable (prototype) to a cloud KMS (pilot) changes
// this file and nothing else.

import { hexToBytes } from '@noble/hashes/utils';
import { signEcdsa } from './credential.ts';
import type { SignFn } from './credential.ts';

export interface CollegeSigner {
  /** Key version written into every credential and revocation list this signer produces. */
  kv: number;
  /** Returns a raw 64-byte r||s signature. */
  sign: SignFn;
}

declare const Deno: { env: { get(name: string): string | undefined } };

/**
 * Prototype signer: a P-256 private key in a function secret.
 *   supabase secrets set COLLEGE_SIGNING_KEY_HEX=<64 hex chars> COLLEGE_SIGNING_KEY_VERSION=1
 * Generate a key with: node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
 * (any 32 random bytes below the P-256 group order is a valid key).
 * Do not use the test keys from spec/test-vectors for anything real.
 */
export function envSigner(): CollegeSigner {
  const keyHex = Deno.env.get('COLLEGE_SIGNING_KEY_HEX');
  if (!keyHex || !/^[0-9a-fA-F]{64}$/.test(keyHex)) {
    throw new Error('COLLEGE_SIGNING_KEY_HEX must be 64 hex characters');
  }
  const kv = Number(Deno.env.get('COLLEGE_SIGNING_KEY_VERSION') ?? '1');
  if (!Number.isInteger(kv) || kv < 1) throw new Error('COLLEGE_SIGNING_KEY_VERSION must be a positive integer');
  const key = hexToBytes(keyHex);
  return { kv, sign: (message) => Promise.resolve(signEcdsa(key, message)) };
}

// TODO(kms): a KMS-backed signer. AWS KMS (ECC_NIST_P256, ECDSA_SHA_256) and GCP Cloud KMS
// (EC_SIGN_P256_SHA256) both sign a message or digest and return DER, so wrap the result in
// ecdsaDerToRaw() from credential.ts before returning it from `sign`.
