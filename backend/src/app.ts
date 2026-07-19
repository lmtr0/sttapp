import type { AppDependencies } from "./dependencies.ts";
import { hasHostedEntitlement } from "./domain.ts";
import {
  ApiError,
  errorResponse,
  json,
  safeRequestId,
  securityHeaders,
} from "./http.ts";
import { lookupCatalog, rateUsage } from "./pricing.ts";
import { parseFlacMetadata } from "./flac.ts";
import { receiveWebhook } from "./webhooks.ts";

export function createApplication(
  deps: AppDependencies,
): (request: Request, info?: RequestContext) => Promise<Response> {
  return async (request, info) => {
    const started = performance.now();
    const requestId = safeRequestId(request.headers.get("x-request-id"));
    const url = new URL(request.url);
    let response: Response;
    try {
      if (!["GET", "HEAD", "POST", "OPTIONS"].includes(request.method)) {
        throw new ApiError(405, "method_not_allowed", "Method is not allowed.");
      }
      if (request.method === "OPTIONS") response = corsPreflight(request, deps);
      else {response = await route(
          request,
          url,
          requestId,
          remoteIp(request, info, deps),
          deps,
        );}
    } catch (error) {
      if (error instanceof ApiError) response = errorResponse(error, requestId);
      else {
        deps.logger.log({
          event: "request.error",
          request_id: requestId,
          error_class: error instanceof Error ? error.name : "unknown",
        });
        response = errorResponse(
          new ApiError(
            500,
            "internal_error",
            "An internal error occurred.",
            "api_error",
          ),
          requestId,
        );
      }
    }
    const headers = new Headers(response.headers);
    headers.set("x-request-id", requestId);
    for (const [key, value] of Object.entries(securityHeaders)) {
      headers.set(key, value);
    }
    applyCors(headers, request, deps);
    deps.logger.log({
      event: "request.complete",
      request_id: requestId,
      method: request.method,
      path: url.pathname,
      status: response.status,
      duration_ms: Math.round(performance.now() - started),
    });
    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers,
    });
  };
}

export interface RequestContext {
  peerIp?: string;
}

async function route(
  request: Request,
  url: URL,
  requestId: string,
  ip: string,
  deps: AppDependencies,
): Promise<Response> {
  if (url.pathname === "/healthz" && request.method === "GET") {
    return json({ status: "ok" });
  }
  if (url.pathname === "/internal/readyz" && request.method === "GET") {
    if (
      request.headers.get("authorization") !==
        `Bearer ${deps.config.internalReadinessToken}`
    ) throw new ApiError(404, "not_found", "Not found.");
    if (!await deps.repository.ready()) {
      throw new ApiError(
        503,
        "not_ready",
        "Service is not ready.",
        "api_error",
      );
    }
    return json({ status: "ready" });
  }
  if (url.pathname === "/billing/return" && request.method === "GET") {
    return new Response(
      '<!doctype html><meta charset="utf-8"><title>Billing updated</title><main><h1>Billing updated</h1><p>Return to sttapp to refresh your account status.</p></main>',
      { headers: { "content-type": "text/html; charset=utf-8" } },
    );
  }
  if (url.pathname === "/v1/auth/desktop/start" && request.method === "POST") {
    return deps.auth.start(request, ip);
  }
  if (url.pathname === "/authorize/desktop" && request.method === "GET") {
    return deps.auth.authorize(request);
  }
  if (
    url.pathname === "/v1/auth/desktop/exchange" && request.method === "POST"
  ) return deps.auth.exchange(request, ip);
  if (url.pathname === "/v1/auth/refresh" && request.method === "POST") {
    return deps.auth.refresh(request, ip);
  }
  if (url.pathname === "/v1/auth/logout" && request.method === "POST") {
    return deps.auth.logout(request);
  }
  if (url.pathname === "/webhooks/clerk" && request.method === "POST") {
    return receiveWebhook("clerk", request, deps.config, deps.repository);
  }
  if (url.pathname === "/webhooks/dodo" && request.method === "POST") {
    return receiveWebhook("dodo", request, deps.config, deps.repository);
  }
  if (!url.pathname.startsWith("/v1/")) {
    throw new ApiError(404, "not_found", "Not found.");
  }
  const principal = await deps.tokens.verify(request);
  await deps.limiter.check(`account:${principal.account.id}`, 120, 60_000);
  if (url.pathname === "/v1/account" && request.method === "GET") {
    const subscription = await deps.repository.getSubscription(
      principal.account.id,
    );
    const usage = await deps.repository.usageTotal(
      principal.account.id,
      subscription.periodStart,
    );
    return json({
      id: principal.account.id,
      subscription: {
        state: subscription.state,
        period_start: subscription.periodStart?.toISOString(),
        period_end: subscription.periodEnd?.toISOString(),
        cancel_at_period_end: subscription.cancelAtPeriodEnd,
        reason_code: actionFor(subscription.state),
      },
      hosted_available: hasHostedEntitlement(subscription.state),
      billing: {
        checkout_available: !hasHostedEntitlement(subscription.state),
        portal_available: Boolean(
          await deps.repository.getBillingCustomer(principal.account.id),
        ),
      },
      usage: {
        currency: "USD",
        retail_micros: usage.toString(),
        as_of: deps.now().toISOString(),
        authoritative: false,
      },
    });
  }
  if (url.pathname === "/v1/models" && request.method === "GET") {
    await requireEntitlement(principal.account.id, deps);
    const at = deps.now();
    const entries = deps.config.catalog.filter((entry) =>
      entry.enabled && entry.effectiveFrom <= at &&
      (!entry.effectiveTo || entry.effectiveTo > at)
    );
    return json({
      object: "list",
      data: entries.map((entry) => ({
        id: entry.publicModel,
        object: "model",
        created: Math.floor(entry.effectiveFrom.getTime() / 1000),
        owned_by: "sttapp",
        sttapp: {
          currency: entry.currency,
          retail_micros_per_hour: entry.retailMicrosPerHour.toString(),
          minimum_billable_seconds: entry.minimumBillableSeconds,
        },
      })),
    });
  }
  if (url.pathname === "/v1/billing/checkout" && request.method === "POST") {
    const subscription = await deps.repository.getSubscription(
      principal.account.id,
    );
    if (
      !["no_subscription", "canceled", "expired", "checkout_pending"]
        .includes(subscription.state)
    ) {
      throw new ApiError(
        409,
        "subscription_already_active",
        "An active subscription already exists.",
      );
    }
    let customer = await deps.repository.getBillingCustomer(
      principal.account.id,
    );
    if (!customer) {
      customer = await deps.dodo.createCustomer(
        principal.account,
        `customer:${principal.account.id}`,
      );
      await deps.repository.saveBillingCustomer(principal.account.id, customer);
    }
    const attemptId = await deps.repository.beginCheckout(
      principal.account.id,
      crypto.randomUUID(),
    );
    if (!attemptId) {
      throw new ApiError(
        409,
        "subscription_already_active",
        "An active subscription already exists.",
      );
    }
    const returnUrl = new URL("/billing/return", deps.config.publicBaseUrl);
    const checkout = await deps.dodo.createCheckout(
      customer,
      principal.account.id,
      returnUrl,
      `checkout:${principal.account.id}:${attemptId}`,
    );
    return json({ url: checkout.href });
  }
  if (url.pathname === "/v1/billing/portal" && request.method === "POST") {
    const customer = await deps.repository.getBillingCustomer(
      principal.account.id,
    );
    if (!customer) {
      throw new ApiError(
        409,
        "billing_customer_missing",
        "No billing account exists.",
      );
    }
    return json({ url: (await deps.dodo.createPortal(customer)).href });
  }
  if (
    url.pathname === "/v1/audio/transcriptions" && request.method === "POST"
  ) return transcribe(request, requestId, principal.account.id, deps);
  throw new ApiError(404, "not_found", "Not found.");
}

async function transcribe(
  request: Request,
  requestId: string,
  accountId: string,
  deps: AppDependencies,
): Promise<Response> {
  await requireEntitlement(accountId, deps);
  const lengthHeader = request.headers.get("content-length");
  const length = Number(lengthHeader);
  if (!lengthHeader || !Number.isSafeInteger(length) || length <= 0) {
    throw new ApiError(
      411,
      "content_length_required",
      "A valid Content-Length header is required.",
    );
  }
  if (length > deps.config.maxBodyBytes) {
    throw new ApiError(413, "request_too_large", "Audio upload is too large.");
  }
  if (
    !request.headers.get("content-type")?.toLowerCase().startsWith(
      "multipart/form-data;",
    )
  ) {
    throw new ApiError(
      415,
      "unsupported_content_type",
      "A multipart FLAC upload is required.",
    );
  }
  const form = await request.formData();
  const allowed = new Set([
    "file",
    "model",
    "language",
    "prompt",
    "temperature",
  ]);
  for (const key of form.keys()) {
    if (!allowed.has(key)) {
      throw new ApiError(
        400,
        "unknown_parameter",
        `Unsupported field: ${key}.`,
      );
    }
  }
  if (form.getAll("file").length !== 1 || form.getAll("model").length !== 1) {
    throw new ApiError(
      400,
      "invalid_multipart",
      "Exactly one file and model are required.",
    );
  }
  const file = form.get("file");
  const model = form.get("model");
  if (
    !(file instanceof File) || typeof model !== "string" ||
    file.size > deps.config.maxBodyBytes ||
    !["audio/flac", "audio/x-flac", "application/octet-stream"].includes(
      file.type || "application/octet-stream",
    )
  ) {
    throw new ApiError(
      400,
      "invalid_audio",
      "A valid FLAC file is required.",
    );
  }
  const bytes = new Uint8Array(await file.arrayBuffer());
  const metadata = parseFlacMetadata(bytes);
  if (metadata.durationMilliseconds > deps.config.maxAudioSeconds * 1000) {
    throw new ApiError(
      413,
      "audio_too_long",
      "Audio duration exceeds the configured limit.",
    );
  }
  const entry = lookupCatalog(deps.config.catalog, model, deps.now());
  const language = optionalString(form, "language", 32);
  const prompt = optionalString(form, "prompt", 2048);
  const temperature = optionalTemperature(form);
  const estimated = rateUsage(metadata.durationMilliseconds, entry);
  const customerId = await deps.repository.getBillingCustomer(accountId);
  if (!customerId) {
    throw new ApiError(
      409,
      "billing_mapping_missing",
      "The billing account is not ready. Refresh account status and retry.",
    );
  }
  const subscription = await deps.repository.getSubscription(accountId);
  const requestRecordId = crypto.randomUUID();
  const reservation = await deps.repository.reserveUsage(
    {
      id: requestRecordId,
      accountId,
      catalogId: entry.id,
      reservedRetailMicros: estimated.retailMicros,
      expiresAt: new Date(
        deps.now().getTime() + deps.config.requestTimeoutMs + 60_000,
      ),
      createdAt: deps.now(),
    },
    subscription.periodStart,
    deps.config.maxCycleRetailMicros,
    deps.config.maxConcurrentPerAccount,
    deps.now(),
  );
  if (reservation.status === "spend_limit") {
    throw new ApiError(
      402,
      "spend_limit_reached",
      "Hosted usage limit reached for this billing period.",
      "permission_error",
    );
  }
  if (reservation.status === "concurrency_limit") {
    throw new ApiError(
      429,
      "concurrency_limit",
      "Too many concurrent transcriptions.",
      "rate_limit_error",
      2,
    );
  }
  const controller = new AbortController();
  const abortForClient = () => controller.abort(request.signal.reason);
  request.signal.addEventListener("abort", abortForClient, { once: true });
  const timeout = setTimeout(
    () => controller.abort(),
    deps.config.requestTimeoutMs,
  );
  let result;
  try {
    result = await deps.groq.transcribe(file, entry, controller.signal, {
      language,
      prompt,
      temperature,
    });
  } catch (error) {
    await deps.repository.failUsageReservation(
      requestRecordId,
      error instanceof ApiError ? error.code : "upstream_error",
      deps.now(),
    );
    throw error;
  } finally {
    clearTimeout(timeout);
    request.signal.removeEventListener("abort", abortForClient);
  }
  const durationDifference = Math.abs(
    result.durationMilliseconds - metadata.durationMilliseconds,
  );
  const durationTolerance = Math.max(
    1000,
    Math.ceil(metadata.durationMilliseconds * 0.02),
  );
  if (durationDifference > durationTolerance) {
    deps.logger.log({
      event: "usage.duration_mismatch",
      request_id: requestId,
      account_id: accountId,
      estimated_milliseconds: metadata.durationMilliseconds,
      provider_milliseconds: result.durationMilliseconds,
    });
    throw new ApiError(
      503,
      "usage_duration_review",
      "The transcription duration requires reconciliation. Retry later.",
      "api_error",
      5,
    );
  }
  const rated = rateUsage(metadata.durationMilliseconds, entry);
  const eventId = `usage_${requestRecordId}`;
  try {
    await deps.repository.finalizeUsage({
      id: requestRecordId,
      accountId,
      catalogId: entry.id,
      actualMilliseconds: rated.actualMilliseconds,
      billableMilliseconds: rated.billableMilliseconds,
      retailMicros: rated.retailMicros,
      eventId,
      createdAt: deps.now(),
    }, {
      event_id: eventId,
      customer_id: customerId,
      event_name: entry.eventName,
      timestamp: deps.now().toISOString(),
      metadata: {
        request_id: requestId,
        catalog_id: entry.id,
        model: entry.publicModel,
        billable_milliseconds: String(rated.billableMilliseconds),
        retail_micros: rated.retailMicros.toString(),
      },
    });
  } catch (error) {
    deps.logger.log({
      event: "usage.finalization_pending",
      request_id: requestId,
      account_id: accountId,
      error_class: error instanceof Error ? error.name : "unknown",
    });
    throw new ApiError(
      503,
      "usage_finalization_pending",
      "The transcription result is awaiting safe finalization. Retry later.",
      "api_error",
      5,
    );
  }
  return json({ text: result.text });
}

function optionalString(
  form: FormData,
  name: string,
  maxLength: number,
): string | undefined {
  const values = form.getAll(name);
  if (values.length === 0) return undefined;
  if (values.length !== 1 || typeof values[0] !== "string") {
    throw new ApiError(400, "invalid_multipart", `${name} is invalid.`);
  }
  const value = values[0].trim();
  if (!value || value.length > maxLength) {
    throw new ApiError(400, "invalid_multipart", `${name} is invalid.`);
  }
  return value;
}

function optionalTemperature(form: FormData): number | undefined {
  const raw = optionalString(form, "temperature", 16);
  if (raw === undefined) return undefined;
  const value = Number(raw);
  if (!Number.isFinite(value) || value < 0 || value > 1) {
    throw new ApiError(400, "invalid_multipart", "temperature is invalid.");
  }
  return value;
}

async function requireEntitlement(
  accountId: string,
  deps: AppDependencies,
): Promise<void> {
  const subscription = await deps.repository.getSubscription(accountId);
  if (!hasHostedEntitlement(subscription.state)) {
    throw new ApiError(
      403,
      subscription.state === "no_subscription"
        ? "subscription_required"
        : "subscription_inactive",
      "An active hosted subscription is required.",
      "permission_error",
    );
  }
}
function actionFor(state: string): string {
  if (
    state === "no_subscription" || state === "canceled" || state === "expired"
  ) return "subscribe";
  if (state === "past_due" || state === "on_hold") return "update_payment";
  if (state === "billing_unknown") return "retry_later";
  return "none";
}
function remoteIp(
  request: Request,
  info: RequestContext | undefined,
  deps: AppDependencies,
): string {
  const peer = info?.peerIp || "unknown";
  if (deps.config.trustedProxyAddresses.includes(peer)) {
    const forwarded = request.headers.get("x-forwarded-for")?.split(",", 1)[0]
      .trim();
    if (forwarded && /^[0-9a-f:.]{3,64}$/i.test(forwarded)) return forwarded;
  }
  return peer;
}
function corsPreflight(request: Request, deps: AppDependencies): Response {
  const origin = request.headers.get("origin");
  if (!origin || !deps.config.corsOrigins.includes(origin)) {
    throw new ApiError(
      403,
      "origin_not_allowed",
      "Origin is not allowed.",
      "permission_error",
    );
  }
  return new Response(null, {
    status: 204,
    headers: {
      "access-control-allow-methods": "GET,POST,OPTIONS",
      "access-control-allow-headers": "authorization,content-type,x-request-id",
      "access-control-max-age": "600",
    },
  });
}
function applyCors(
  headers: Headers,
  request: Request,
  deps: AppDependencies,
): void {
  const origin = request.headers.get("origin");
  if (origin && deps.config.corsOrigins.includes(origin)) {
    headers.set("access-control-allow-origin", origin);
    headers.set("vary", "origin");
  }
}
