import type { CatalogEntry } from "./domain.ts";
import { ApiError } from "./http.ts";

export function lookupCatalog(
  catalog: readonly CatalogEntry[],
  model: string,
  at = new Date(),
): CatalogEntry {
  const matches = catalog.filter((entry) =>
    entry.enabled && entry.publicModel === model && entry.effectiveFrom <= at &&
    (!entry.effectiveTo || entry.effectiveTo > at)
  );
  if (matches.length !== 1) {
    throw new ApiError(
      400,
      "model_not_available",
      "The requested model is not available.",
    );
  }
  return matches[0];
}

export interface RatedUsage {
  actualMilliseconds: number;
  billableMilliseconds: number;
  retailMicros: bigint;
}

export function rateUsage(
  actualMilliseconds: number,
  entry: CatalogEntry,
): RatedUsage {
  if (!Number.isSafeInteger(actualMilliseconds) || actualMilliseconds < 0) {
    throw new RangeError(
      "actualMilliseconds must be a non-negative safe integer",
    );
  }
  const billableMilliseconds = Math.max(
    actualMilliseconds,
    entry.minimumBillableSeconds * 1000,
  );
  // Round once, up to the nearest micro-dollar. This never under-collects fractions.
  const numerator = BigInt(billableMilliseconds) * entry.retailMicrosPerHour;
  const denominator = 3_600_000n;
  return {
    actualMilliseconds,
    billableMilliseconds,
    retailMicros: (numerator + denominator - 1n) / denominator,
  };
}
