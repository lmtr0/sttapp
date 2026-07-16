import type { AppConfig } from "./config.ts";
import { base64Url, constantTimeEqual } from "./crypto.ts";
import { ApiError } from "./http.ts";
import type { Repository } from "./repository.ts";

const encoder = new TextEncoder();

export async function receiveWebhook(
  provider: "clerk" | "dodo",
  request: Request,
  config: AppConfig,
  repository: Repository,
): Promise<Response> {
  const declaredLength = Number(request.headers.get("content-length") || 0);
  if (declaredLength > 1024 * 1024) {
    throw new ApiError(
      413,
      "request_too_large",
      "Webhook payload is too large.",
    );
  }
  const raw = new Uint8Array(await request.arrayBuffer());
  if (raw.byteLength > 1024 * 1024) {
    throw new ApiError(
      413,
      "request_too_large",
      "Webhook payload is too large.",
    );
  }
  const id = request.headers.get("webhook-id") ||
    request.headers.get("svix-id");
  const timestamp = request.headers.get("webhook-timestamp") ||
    request.headers.get("svix-timestamp");
  const signature = request.headers.get("webhook-signature") ||
    request.headers.get("svix-signature");
  if (!id || !timestamp || !signature) {
    throw new ApiError(
      400,
      "invalid_webhook_signature",
      "Webhook signature is missing.",
    );
  }
  const seconds = Number(timestamp);
  if (
    !Number.isSafeInteger(seconds) ||
    Math.abs(Date.now() / 1000 - seconds) > config.webhookToleranceSeconds
  ) {
    throw new ApiError(
      400,
      "stale_webhook",
      "Webhook timestamp is outside the allowed window.",
    );
  }
  const secret = provider === "dodo"
    ? config.dodoWebhookSecret
    : config.clerkWebhookSecret;
  if (!await verifyStandardWebhook(secret, id, timestamp, raw, signature)) {
    throw new ApiError(
      400,
      "invalid_webhook_signature",
      "Webhook signature is invalid.",
    );
  }
  let payload: Record<string, unknown>;
  try {
    const value = JSON.parse(new TextDecoder().decode(raw));
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      throw new Error();
    }
    payload = value;
  } catch {
    throw new ApiError(400, "invalid_json", "Webhook payload is invalid.");
  }
  const type = typeof payload.type === "string"
    ? payload.type
    : typeof payload.event_type === "string"
    ? payload.event_type
    : "unknown";
  await repository.storeWebhook(
    provider,
    id,
    type,
    safeWebhookPayload(payload),
    new Date(),
  );
  return new Response(null, { status: 202 });
}

async function verifyStandardWebhook(
  secret: string,
  id: string,
  timestamp: string,
  body: Uint8Array,
  header: string,
): Promise<boolean> {
  let keyBytes: Uint8Array;
  try {
    const encoded = secret.startsWith("whsec_") ? secret.slice(6) : secret;
    keyBytes = Uint8Array.from(
      atob(encoded.replaceAll("-", "+").replaceAll("_", "/")),
      (c) => c.charCodeAt(0),
    );
  } catch {
    keyBytes = encoder.encode(secret);
  }
  const key = await crypto.subtle.importKey(
    "raw",
    Uint8Array.from(keyBytes).buffer,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const prefix = encoder.encode(`${id}.${timestamp}.`);
  const message = new Uint8Array(prefix.length + body.length);
  message.set(prefix);
  message.set(body, prefix.length);
  const expected = base64Url(
    new Uint8Array(await crypto.subtle.sign("HMAC", key, message)),
  );
  return header.split(" ").some((part) =>
    constantTimeEqual(
      part.replace(/^v\d+,/, "").replaceAll("+", "-").replaceAll("/", "_")
        .replace(/=+$/, ""),
      expected,
    )
  );
}

function safeWebhookPayload(
  payload: Record<string, unknown>,
): Record<string, unknown> {
  return scrub(payload) as Record<string, unknown>;
}

function scrub(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(scrub);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).filter(([key]) =>
        !/^(?:email(?:_address(?:es)?)?|first_name|last_name|name|phone(?:_number)?|address|token|secret)$/i
          .test(key)
      ).map(([key, item]) => [key, scrub(item)]),
    );
  }
  return value;
}
