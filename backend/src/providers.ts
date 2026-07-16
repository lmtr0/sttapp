import type { AppConfig } from "./config.ts";
import type { Account, CatalogEntry } from "./domain.ts";
import { ApiError, safeUrl } from "./http.ts";

export interface GroqResult {
  text: string;
  durationMilliseconds: number;
}
export interface GroqTranscriptionOptions {
  language?: string;
  prompt?: string;
  temperature?: number;
}
export interface GroqClient {
  transcribe(
    file: File,
    entry: CatalogEntry,
    signal: AbortSignal,
    options?: GroqTranscriptionOptions,
  ): Promise<GroqResult>;
}

export class FetchGroqClient implements GroqClient {
  constructor(
    private config: AppConfig,
    private fetcher: typeof fetch = fetch,
  ) {}
  async transcribe(
    file: File,
    entry: CatalogEntry,
    signal: AbortSignal,
    options: GroqTranscriptionOptions = {},
  ): Promise<GroqResult> {
    const form = new FormData();
    form.set("file", file, "audio.flac");
    form.set("model", entry.upstreamModel);
    form.set("response_format", "verbose_json");
    if (options.language) form.set("language", options.language);
    if (options.prompt) form.set("prompt", options.prompt);
    if (options.temperature !== undefined) {
      form.set("temperature", String(options.temperature));
    }
    let response: Response;
    try {
      response = await this.fetcher(
        new URL("audio/transcriptions", trailingSlash(this.config.groqBaseUrl)),
        {
          method: "POST",
          headers: { authorization: `Bearer ${this.config.groqApiKey}` },
          body: form,
          signal,
        },
      );
    } catch {
      if (signal.aborted) {
        throw new ApiError(
          504,
          "upstream_timeout",
          "The transcription provider timed out.",
          "api_error",
        );
      }
      throw new ApiError(
        503,
        "upstream_unavailable",
        "The transcription provider is unavailable.",
        "api_error",
        5,
      );
    }
    if (!response.ok) {
      if (response.status === 429) {
        throw new ApiError(
          429,
          "upstream_rate_limit",
          "The transcription provider is busy.",
          "rate_limit_error",
          Number(response.headers.get("retry-after") || 5),
        );
      }
      if (response.status >= 500) {
        throw new ApiError(
          503,
          "upstream_unavailable",
          "The transcription provider is unavailable.",
          "api_error",
          5,
        );
      }
      throw new ApiError(
        502,
        "upstream_rejected",
        "The transcription provider rejected the request.",
        "api_error",
      );
    }
    const max = 2 * 1024 * 1024;
    const length = Number(response.headers.get("content-length") || 0);
    if (length > max) {
      throw new ApiError(
        502,
        "invalid_provider_response",
        "Provider response is too large.",
        "api_error",
      );
    }
    let value: unknown;
    try {
      value = await boundedJson(response, max);
    } catch {
      throw new ApiError(
        502,
        "invalid_provider_response",
        "Provider returned an invalid response.",
        "api_error",
      );
    }
    if (!value || typeof value !== "object") {
      throw new ApiError(
        502,
        "invalid_provider_response",
        "Provider returned an invalid response.",
        "api_error",
      );
    }
    const result = value as Record<string, unknown>;
    if (
      typeof result.text !== "string" || typeof result.duration !== "number" ||
      !Number.isFinite(result.duration) || result.duration < 0
    ) {
      throw new ApiError(
        502,
        "invalid_provider_response",
        "Provider returned incomplete transcription metadata.",
        "api_error",
      );
    }
    return {
      text: result.text,
      durationMilliseconds: Math.ceil(result.duration * 1000),
    };
  }
}

export interface DodoClient {
  createCustomer(account: Account, idempotencyKey: string): Promise<string>;
  createCheckout(
    customerId: string,
    accountId: string,
    returnUrl: URL,
    idempotencyKey: string,
  ): Promise<URL>;
  createPortal(customerId: string): Promise<URL>;
  ingestUsage(payload: Record<string, unknown>): Promise<void>;
}

export class FetchDodoClient implements DodoClient {
  constructor(
    private config: AppConfig,
    private fetcher: typeof fetch = fetch,
  ) {}
  async createCustomer(
    account: Account,
    idempotencyKey: string,
  ): Promise<string> {
    if (!account.email) {
      throw new ApiError(
        409,
        "billing_profile_incomplete",
        "An email address is required before checkout.",
      );
    }
    const value = await this.call("/customers", {
      email: account.email,
      metadata: { sttapp_account_id: account.id },
    }, idempotencyKey);
    const id = stringField(value, ["customer_id", "id"]);
    if (!id) throw providerResponseError();
    return id;
  }
  async createCheckout(
    customerId: string,
    accountId: string,
    returnUrl: URL,
    idempotencyKey: string,
  ): Promise<URL> {
    const value = await this.call("/checkouts", {
      product_cart: [{ product_id: this.config.dodoProductId, quantity: 1 }],
      customer: { customer_id: customerId },
      return_url: returnUrl.href,
      metadata: { sttapp: "hosted", sttapp_account_id: accountId },
    }, idempotencyKey);
    return safeUrl(
      stringField(value, ["checkout_url"]) || "",
      this.config.dodoPortalHosts,
    );
  }
  async createPortal(customerId: string): Promise<URL> {
    const value = await this.call(
      `/customers/${encodeURIComponent(customerId)}/customer-portal/session`,
      {},
      crypto.randomUUID(),
    );
    return safeUrl(
      stringField(value, ["link", "url", "portal_url"]) || "",
      this.config.dodoPortalHosts,
    );
  }
  async ingestUsage(payload: Record<string, unknown>): Promise<void> {
    await this.call(
      "/events/ingest",
      { events: [payload] },
      String(payload.event_id || crypto.randomUUID()),
    );
  }
  private async call(
    path: string,
    body: unknown,
    idempotencyKey: string,
  ): Promise<Record<string, unknown>> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 15_000);
    try {
      const response = await this.fetcher(
        new URL(path, this.config.dodoApiBaseUrl),
        {
          method: "POST",
          headers: {
            authorization: `Bearer ${this.config.dodoApiKey}`,
            "content-type": "application/json",
            "idempotency-key": idempotencyKey,
          },
          body: JSON.stringify(body),
          signal: controller.signal,
        },
      );
      if (!response.ok) {
        if (response.status === 429 || response.status >= 500) {
          throw new ApiError(
            503,
            "billing_provider_unavailable",
            "Billing is temporarily unavailable.",
            "api_error",
            5,
          );
        }
        throw new ApiError(
          502,
          "billing_provider_error",
          "Billing provider rejected the operation.",
          "api_error",
        );
      }
      const value = await response.json();
      if (!value || typeof value !== "object" || Array.isArray(value)) {
        throw providerResponseError();
      }
      return value as Record<string, unknown>;
    } catch (error) {
      if (error instanceof ApiError) throw error;
      throw new ApiError(
        503,
        "billing_provider_unavailable",
        "Billing is temporarily unavailable.",
        "api_error",
        5,
      );
    } finally {
      clearTimeout(timeout);
    }
  }
}

function stringField(
  value: Record<string, unknown>,
  names: string[],
): string | undefined {
  for (const name of names) {
    if (typeof value[name] === "string") return value[name] as string;
  }
}
function providerResponseError() {
  return new ApiError(
    502,
    "invalid_provider_response",
    "Billing provider returned an invalid response.",
    "api_error",
  );
}
function trailingSlash(url: URL): URL {
  const result = new URL(url);
  if (!result.pathname.endsWith("/")) result.pathname += "/";
  return result;
}

async function boundedJson(
  response: Response,
  maxBytes: number,
): Promise<unknown> {
  if (!response.body) return null;
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel();
        throw providerResponseError();
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return JSON.parse(new TextDecoder().decode(bytes));
}
