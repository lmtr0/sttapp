import { ApiError } from "./http.ts";

export interface FlacMetadata {
  sampleRate: number;
  totalSamples: bigint;
  durationMilliseconds: number;
}

export function parseFlacMetadata(bytes: Uint8Array): FlacMetadata {
  if (
    bytes.byteLength < 42 || bytes[0] !== 0x66 || bytes[1] !== 0x4c ||
    bytes[2] !== 0x61 || bytes[3] !== 0x43
  ) {
    throw new ApiError(
      400,
      "invalid_audio",
      "File is not a valid FLAC stream.",
    );
  }
  let offset = 4;
  let blocks = 0;
  while (offset + 4 <= bytes.length && blocks++ < 64) {
    const header = bytes[offset];
    const last = (header & 0x80) !== 0;
    const type = header & 0x7f;
    const length = (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) |
      bytes[offset + 3];
    offset += 4;
    if (length < 0 || offset + length > bytes.length) {
      throw new ApiError(400, "invalid_audio", "FLAC metadata is truncated.");
    }
    if (type === 0) {
      if (length !== 34) {
        throw new ApiError(400, "invalid_audio", "FLAC STREAMINFO is invalid.");
      }
      const p = offset + 10;
      const packed = bytes.slice(p, p + 8);
      const sampleRate = (packed[0] << 12) | (packed[1] << 4) |
        (packed[2] >> 4);
      const totalSamples = (BigInt(packed[3] & 0x0f) << 32n) |
        (BigInt(packed[4]) << 24n) | (BigInt(packed[5]) << 16n) |
        (BigInt(packed[6]) << 8n) | BigInt(packed[7]);
      if (sampleRate < 1000 || sampleRate > 768000 || totalSamples === 0n) {
        throw new ApiError(
          400,
          "invalid_audio",
          "FLAC duration metadata is invalid.",
        );
      }
      const duration = (totalSamples * 1000n + BigInt(sampleRate) - 1n) /
        BigInt(sampleRate);
      if (duration > BigInt(Number.MAX_SAFE_INTEGER)) {
        throw new ApiError(400, "invalid_audio", "FLAC duration is too large.");
      }
      return {
        sampleRate,
        totalSamples,
        durationMilliseconds: Number(duration),
      };
    }
    offset += length;
    if (last) break;
  }
  throw new ApiError(400, "invalid_audio", "FLAC STREAMINFO is missing.");
}
