export type ErrorType =
  | "invalid_request_error"
  | "authentication_error"
  | "permission_error"
  | "rate_limit_error"
  | "api_error";

export class ApiError extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string,
    public type: ErrorType = "invalid_request_error",
    public retryAfter?: number,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

export function errorResponse(error: ApiError, requestId: string): Response {
  const headers = new Headers({
    "content-type": "application/json",
    "x-request-id": requestId,
  });
  if (error.retryAfter) headers.set("retry-after", String(error.retryAfter));
  return Response.json({
    error: {
      message: error.message,
      type: error.type,
      code: error.code,
      request_id: requestId,
    },
  }, { status: error.status, headers });
}

export function json(
  data: unknown,
  status = 200,
  headers?: HeadersInit,
): Response {
  const responseHeaders = new Headers(headers);
  responseHeaders.set("content-type", "application/json");
  return Response.json(data, { status, headers: responseHeaders });
}

export async function readJson<T>(
  request: Request,
  maxBytes = 32_768,
): Promise<T> {
  const type = request.headers.get("content-type")?.split(";", 1)[0].trim();
  if (type !== "application/json") {
    throw new ApiError(
      415,
      "unsupported_content_type",
      "Content-Type must be application/json.",
    );
  }
  const length = Number(request.headers.get("content-length") || "0");
  if (length > maxBytes) {
    throw new ApiError(413, "request_too_large", "Request body is too large.");
  }
  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.byteLength > maxBytes) {
    throw new ApiError(413, "request_too_large", "Request body is too large.");
  }
  try {
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw new ApiError(400, "invalid_json", "Request body is not valid JSON.");
  }
}

export function requireObject(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new ApiError(
      400,
      "invalid_request",
      "Request body must be an object.",
    );
  }
  return value as Record<string, unknown>;
}

export function requireString(
  object: Record<string, unknown>,
  name: string,
  max = 2048,
): string {
  const value = object[name];
  if (typeof value !== "string" || !value.trim() || value.length > max) {
    throw new ApiError(400, "invalid_request", `${name} is invalid.`);
  }
  return value.trim();
}

export function assertOnlyKeys(
  object: Record<string, unknown>,
  allowed: string[],
): void {
  const extra = Object.keys(object).filter((key) => !allowed.includes(key));
  if (extra.length) {
    throw new ApiError(
      400,
      "unknown_parameter",
      `Unknown parameter: ${extra[0]}.`,
    );
  }
}

export function safeRequestId(value: string | null): string {
  return value && /^[A-Za-z0-9_-]{8,128}$/.test(value)
    ? value
    : `req_${crypto.randomUUID().replaceAll("-", "")}`;
}

export function safeUrl(raw: string, allowedHosts: readonly string[]): URL {
  let value: URL;
  try {
    value = new URL(raw);
  } catch {
    throw new ApiError(
      502,
      "invalid_provider_response",
      "Provider returned an invalid URL.",
      "api_error",
    );
  }
  if (
    value.protocol !== "https:" || value.username || value.password ||
    value.port ||
    !allowedHosts.includes(value.hostname)
  ) {
    throw new ApiError(
      502,
      "invalid_provider_response",
      "Provider returned a URL outside the allowlist.",
      "api_error",
    );
  }
  return value;
}

export const securityHeaders: Readonly<Record<string, string>> = {
  "cache-control": "no-store",
  "content-security-policy": "default-src 'none'; frame-ancestors 'none'",
  "referrer-policy": "no-referrer",
  "strict-transport-security": "max-age=31536000; includeSubDomains",
  "x-content-type-options": "nosniff",
  "x-frame-options": "DENY",
};
