import { assertEquals, assertThrows } from "@std/assert";
import { parseFlacMetadata } from "../src/flac.ts";
import { lookupCatalog, rateUsage } from "../src/pricing.ts";
import { flac, testConfig } from "./helpers.ts";

Deno.test("fixed-point rating applies minimum and rounds once", async () => {
  const entry = (await testConfig()).catalog[0];
  assertEquals(rateUsage(0, entry), {
    actualMilliseconds: 0,
    billableMilliseconds: 10000,
    retailMicros: 134n,
  });
  assertEquals(rateUsage(3_600_000, entry).retailMicros, 48_000n);
});

Deno.test("effective catalog lookup fails closed", async () => {
  const catalog = (await testConfig()).catalog;
  assertEquals(
    lookupCatalog(catalog, "whisper-large-v3-turbo").id,
    "test-turbo",
  );
  assertThrows(() => lookupCatalog(catalog, "../../other"));
  assertThrows(() =>
    lookupCatalog(
      [...catalog, { ...catalog[0], id: "overlap" }],
      "whisper-large-v3-turbo",
    )
  );
});

Deno.test("FLAC parser obtains bounded STREAMINFO duration", () => {
  assertEquals(parseFlacMetadata(flac(2)).durationMilliseconds, 2000);
  assertThrows(() => parseFlacMetadata(new Uint8Array([1, 2, 3])));
  const malformed = flac();
  malformed[7] = 33;
  assertThrows(() => parseFlacMetadata(malformed));
});
