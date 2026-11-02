// The record format and recovery rules of the Rust Bridge's klog, on real bytes:
//
//   offset  0..4   length    u32, little-endian
//   offset  4..8   checksum  u32, little-endian, CRC-32C of the payload
//   offset  8..    payload   `length` bytes

export const HEADER_LEN = 8;
export const MAX_PAYLOAD = 1 << 20;

const POLYNOMIAL = 0x82f63b78;
const TABLE = Array.from({ length: 256 }, (_, i) => {
  let crc = i;
  for (let bit = 0; bit < 8; bit++) crc = crc & 1 ? (crc >>> 1) ^ POLYNOMIAL : crc >>> 1;
  return crc >>> 0;
});

export function crc32c(bytes: Uint8Array): number {
  let crc = 0xffffffff;
  for (const byte of bytes) crc = TABLE[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

function u32le(value: number): number[] {
  return [value & 0xff, (value >>> 8) & 0xff, (value >>> 16) & 0xff, (value >>> 24) & 0xff];
}

function readU32(bytes: Uint8Array, at: number): number {
  return (bytes[at] | (bytes[at + 1] << 8) | (bytes[at + 2] << 16) | (bytes[at + 3] << 24)) >>> 0;
}

export function encode(payload: string): Uint8Array {
  const body = new TextEncoder().encode(payload);
  return Uint8Array.from([...u32le(body.length), ...u32le(crc32c(body)), ...body]);
}

export type DecodeError = "truncated" | "corrupt" | "too-large";

type Decoded = { used: number; payload: string } | { error: DecodeError };

export function decode(buf: Uint8Array): Decoded {
  if (buf.length < HEADER_LEN) return { error: "truncated" };
  const length = readU32(buf, 0);
  if (length > MAX_PAYLOAD) return { error: "too-large" };
  const end = HEADER_LEN + length;
  if (buf.length < end) return { error: "truncated" };
  const payload = buf.subarray(HEADER_LEN, end);
  if (crc32c(payload) !== readU32(buf, 4)) return { error: "corrupt" };
  return { used: end, payload: new TextDecoder().decode(payload) };
}

// A torn write can only leave the last record incomplete: either too few
// bytes, or a full-length record whose bytes didn't all reach the disk.
function isTornTail(rest: Uint8Array, error: DecodeError): boolean {
  if (error === "truncated") return true;
  if (error === "corrupt") return HEADER_LEN + readU32(rest, 0) === rest.length;
  return false;
}

export type Recovery =
  | { status: "ok"; records: string[]; validLength: number; truncated: number }
  | { status: "refused"; records: string[]; offset: number; cause: DecodeError };

// Reads from the start. Damage is accepted only if it's a torn last record.
export function recover(data: Uint8Array): Recovery {
  const records: string[] = [];
  let offset = 0;
  while (offset < data.length) {
    const rest = data.subarray(offset);
    const decoded = decode(rest);
    if ("error" in decoded) {
      if (isTornTail(rest, decoded.error)) break;
      return { status: "refused", records, offset, cause: decoded.error };
    }
    records.push(decoded.payload);
    offset += decoded.used;
  }
  return { status: "ok", records, validLength: offset, truncated: data.length - offset };
}

// The file as the program sees it, in two parts: the bytes fsync has put on
// the disk, and the bytes still in the page cache.
export interface LogFile {
  durable: Uint8Array;
  cached: Uint8Array;
  acknowledged: string[]; // records the program told its caller were written
  synced: number; // how many of those fsync has covered
}

export function createLog(): LogFile {
  return { durable: new Uint8Array(0), cached: new Uint8Array(0), acknowledged: [], synced: 0 };
}

function join(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length);
  out.set(a);
  out.set(b, a.length);
  return out;
}

export function write(log: LogFile, payload: string): LogFile {
  return {
    ...log,
    cached: join(log.cached, encode(payload)),
    acknowledged: [...log.acknowledged, payload],
  };
}

export function fsync(log: LogFile): LogFile {
  return {
    ...log,
    durable: join(log.durable, log.cached),
    cached: new Uint8Array(0),
    synced: log.acknowledged.length,
  };
}

// The power fails after this many of the unsynced bytes reached the disk.
export function powerCut(log: LogFile, reachedDisk: number): Uint8Array {
  return join(log.durable, log.cached.subarray(0, reachedDisk));
}

export function flipByte(data: Uint8Array, at: number): Uint8Array {
  const out = data.slice();
  out[at] ^= 0xff;
  return out;
}
