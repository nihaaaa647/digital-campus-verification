// The college signing key for the LOCAL server: the public TEST key kv 2 from spec/test-vectors/v1.json, so
// that passes it issues verify against the key set the same server hands to scanners (the vectors' key set).
// Anyone can read that key in the repository. A real deployment uses a generated key (signer.ts: envSigner,
// later a cloud KMS) and a matching COLLEGE_KEYSET_JSON.

import { readFileSync } from 'node:fs';
import { hexToBytes } from '@noble/hashes/utils';
import { signEcdsa } from '../_shared/credential.ts';
import type { CollegeSigner } from '../_shared/signer.ts';

export function devCollegeSigner(): CollegeSigner {
  const vectors = JSON.parse(readFileSync(new URL('../../../spec/test-vectors/v1.json', import.meta.url), 'utf8')) as {
    keys: { college: Array<{ kv: number; private_hex: string }> };
  };
  const entry = vectors.keys.college.find((k) => k.kv === 2);
  if (!entry) throw new Error('test vectors have no college key kv 2');
  const key = hexToBytes(entry.private_hex);
  return { kv: 2, sign: (message) => Promise.resolve(signEcdsa(key, message)) };
}
