import { ApiError } from "./http.ts";
import type { Repository } from "./repository.ts";

export interface RateLimiter {
  check(key: string, limit: number, windowMs: number): Promise<void>;
}

export class MemoryRateLimiter implements RateLimiter {
  #buckets = new Map<string, number[]>();
  async check(key: string, limit: number, windowMs: number): Promise<void> {
    const now = Date.now();
    const values = (this.#buckets.get(key) || []).filter((at) =>
      at > now - windowMs
    );
    if (values.length >= limit) {
      throw new ApiError(
        429,
        "rate_limit_exceeded",
        "Too many requests.",
        "rate_limit_error",
        Math.ceil(windowMs / 1000),
      );
    }
    values.push(now);
    this.#buckets.set(key, values);
  }
}

export class RepositoryRateLimiter implements RateLimiter {
  constructor(private repository: Repository) {}

  async check(key: string, limit: number, windowMs: number): Promise<void> {
    if (
      !await this.repository.consumeRateLimit(
        key,
        limit,
        windowMs,
        new Date(),
      )
    ) {
      throw new ApiError(
        429,
        "rate_limit_exceeded",
        "Too many requests.",
        "rate_limit_error",
        Math.ceil(windowMs / 1000),
      );
    }
  }
}
