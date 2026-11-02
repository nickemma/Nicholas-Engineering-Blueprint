// A hash chain and a Merkle tree over the same records, with real SHA-256 and
// the tree of RFC 9162, as in Phase 6, step 10. The leading byte tells a leaf
// from an inner node, so an inner node can never be passed off as a record.

export type Hash = Uint8Array;

const encoder = new TextEncoder();

async function sha256(...parts: Uint8Array[]): Promise<Hash> {
  const total = parts.reduce((sum, part) => sum + part.length, 0);
  const joined = new Uint8Array(total);
  let at = 0;
  for (const part of parts) {
    joined.set(part, at);
    at += part.length;
  }
  return new Uint8Array(await crypto.subtle.digest("SHA-256", joined));
}

export const hex = (hash: Hash) =>
  [...hash].map((byte) => byte.toString(16).padStart(2, "0")).join("");

export const leafHash = (record: Uint8Array) => sha256(Uint8Array.of(0), record);
export const nodeHash = (left: Hash, right: Hash) => sha256(Uint8Array.of(1), left, right);
export const textBytes = (text: string) => encoder.encode(text);

// The largest power of two smaller than n (n > 1): where the tree splits.
function split(n: number): number {
  let k = 1;
  while (k * 2 < n) k *= 2;
  return k;
}

export async function root(leaves: Hash[]): Promise<Hash> {
  if (leaves.length === 0) return sha256();
  if (leaves.length === 1) return leaves[0];
  const k = split(leaves.length);
  return nodeHash(await root(leaves.slice(0, k)), await root(leaves.slice(k)));
}

// The hashes that prove leaf `index` is in the tree, from the leaf upwards.
export async function inclusionProof(leaves: Hash[], index: number): Promise<Hash[]> {
  if (leaves.length <= 1) return [];
  const k = split(leaves.length);
  return index < k
    ? [...(await inclusionProof(leaves.slice(0, k), index)), await root(leaves.slice(k))]
    : [...(await inclusionProof(leaves.slice(k), index - k)), await root(leaves.slice(0, k))];
}

// RFC 9162, 2.1.3.2.
export async function verifyInclusion(
  leaf: Hash,
  index: number,
  size: number,
  proof: Hash[],
  expected: Hash,
): Promise<boolean> {
  if (index >= size) return false;
  let fn = index;
  let sn = size - 1;
  let r = leaf;
  for (const p of proof) {
    if (sn === 0) return false;
    if (fn % 2 === 1 || fn === sn) {
      r = await nodeHash(p, r);
      while (fn % 2 === 0 && fn !== 0) {
        fn >>= 1;
        sn >>= 1;
      }
    } else {
      r = await nodeHash(r, p);
    }
    fn >>= 1;
    sn >>= 1;
  }
  return sn === 0 && hex(r) === hex(expected);
}

// Each link hashes the one before and the record. The chain's only anchor is
// the file itself, which is what an attacker who can rewrite it controls.
export async function chain(records: string[]): Promise<string[]> {
  const links: string[] = [];
  let previous = new Uint8Array(32) as Uint8Array;
  for (const record of records) {
    previous = await sha256(previous, textBytes(record));
    links.push(hex(previous));
  }
  return links;
}

export async function verifyChain(records: string[], links: string[]): Promise<number | null> {
  const expected = await chain(records);
  const bad = expected.findIndex((link, i) => link !== links[i]);
  return bad === -1 && records.length === links.length ? null : Math.max(bad, 0);
}

export interface Checkpoint {
  size: number;
  root: string;
}

export async function checkpointOf(records: string[]): Promise<Checkpoint> {
  const leaves = await Promise.all(records.map((record) => leafHash(textBytes(record))));
  return { size: records.length, root: hex(await root(leaves)) };
}

// What a witness does with a log claiming to extend its checkpoint: the first
// `size` records must still produce the root it co-signed.
export async function witnessAccepts(records: string[], checkpoint: Checkpoint): Promise<boolean> {
  if (records.length < checkpoint.size) return false;
  const again = await checkpointOf(records.slice(0, checkpoint.size));
  return again.root === checkpoint.root;
}
