import type {
  CatalogEntry,
  Environment,
  ProviderEnvironment,
} from "./domain.ts";

export class ConfigError extends Error {
  constructor(setting: string, reason = "is required") {
    super(`Invalid configuration: ${setting} ${reason}`);
    this.name = "ConfigError";
  }
}

export interface AppConfig {
  environment: Environment;
  providerEnvironment: ProviderEnvironment;
  port: number;
  publicBaseUrl: URL;
  databaseUrl: string;
  databasePoolSize: number;
  databaseTls: boolean;
  internalReadinessToken: string;
  corsOrigins: string[];
  trustedProxyAddresses: string[];
  clerkIssuer: URL;
  clerkJwksUrl: URL;
  clerkSignInUrl: URL;
  clerkSecretKey: string;
  clerkAuthorizedParties: string[];
  clerkWebhookSecret: string;
  dodoApiBaseUrl: URL;
  dodoApiKey: string;
  dodoWebhookSecret: string;
  dodoProductId: string;
  dodoPortalHosts: string[];
  groqApiKey: string;
  groqBaseUrl: URL;
  accessPrivateJwk: JsonWebKey;
  accessPublicJwks: { keys: JsonWebKey[] };
  accessKeyId: string;
  accessTokenSeconds: number;
  refreshPepper: string;
  refreshInactivitySeconds: number;
  refreshAbsoluteSeconds: number;
  maxBodyBytes: number;
  maxAudioSeconds: number;
  maxConcurrentPerAccount: number;
  maxCycleRetailMicros: bigint;
  requestTimeoutMs: number;
  webhookToleranceSeconds: number;
  retentionDays: number;
  catalog: CatalogEntry[];
}

function required(env: Record<string, string>, key: string): string {
  const value = env[key]?.trim();
  if (!value) throw new ConfigError(key);
  return value;
}

function secret(
  env: Record<string, string>,
  key: string,
  minimumLength = 32,
): string {
  const value = required(env, key);
  if (new TextEncoder().encode(value).byteLength < minimumLength) {
    throw new ConfigError(key, `must be at least ${minimumLength} bytes`);
  }
  return value;
}

function integer(
  env: Record<string, string>,
  key: string,
  fallback: number,
  min = 1,
): number {
  const raw = env[key]?.trim();
  if (!raw) return fallback;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < min) {
    throw new ConfigError(key, `must be an integer >= ${min}`);
  }
  return value;
}

function url(env: Record<string, string>, key: string, fallback?: string): URL {
  const raw = env[key]?.trim() || fallback;
  if (!raw) throw new ConfigError(key);
  try {
    const parsed = new URL(raw);
    if (
      parsed.protocol !== "https:" &&
      !(parsed.protocol === "http:" &&
        ["localhost", "127.0.0.1"].includes(parsed.hostname))
    ) {
      throw new Error();
    }
    if (parsed.username || parsed.password) throw new Error();
    return parsed;
  } catch {
    throw new ConfigError(key, "must be a safe HTTP(S) URL");
  }
}

function parseJwk(raw: string, key: string): JsonWebKey {
  try {
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object") throw new Error();
    return parsed;
  } catch {
    throw new ConfigError(key, "must be valid JWK JSON");
  }
}

function origins(env: Record<string, string>, key: string): string[] {
  const values = (env[key] || "").split(",").map((value) => value.trim())
    .filter(Boolean);
  for (const value of values) {
    let parsed: URL;
    try {
      parsed = new URL(value);
    } catch {
      throw new ConfigError(key, "must contain valid origins");
    }
    if (
      parsed.origin !== value.replace(/\/$/, "") || parsed.username ||
      parsed.password ||
      (parsed.protocol !== "https:" &&
        !(parsed.protocol === "http:" &&
          ["127.0.0.1", "localhost"].includes(parsed.hostname)))
    ) throw new ConfigError(key, "must contain safe HTTP(S) origins");
  }
  return values.map((value) => new URL(value).origin);
}

export function loadConfig(env: Record<string, string>): AppConfig {
  const environment = (env.STTAPP_ENV || "development") as Environment;
  if (!["development", "test", "production"].includes(environment)) {
    throw new ConfigError("STTAPP_ENV");
  }
  const providerEnvironment =
    (env.PROVIDER_ENV || "test") as ProviderEnvironment;
  if (!["test", "live"].includes(providerEnvironment)) {
    throw new ConfigError("PROVIDER_ENV");
  }
  if (environment !== "production" && providerEnvironment === "live") {
    throw new ConfigError("PROVIDER_ENV", "cannot be live outside production");
  }
  if (environment === "production" && providerEnvironment !== "live") {
    throw new ConfigError("PROVIDER_ENV", "must be live in production");
  }

  const dodoBase = providerEnvironment === "live"
    ? "https://live.dodopayments.com"
    : "https://test.dodopayments.com";
  const dodoApiBaseUrl = url(env, "DODO_API_BASE_URL", dodoBase);
  const expectedDodoHost = providerEnvironment === "test"
    ? "test.dodopayments.com"
    : "live.dodopayments.com";
  if (dodoApiBaseUrl.hostname !== expectedDodoHost) {
    throw new ConfigError("DODO_API_BASE_URL", "does not match provider mode");
  }
  const databaseTlsRaw = env.DATABASE_TLS ||
    (environment === "production" ? "true" : "false");
  if (!["true", "false"].includes(databaseTlsRaw)) {
    throw new ConfigError("DATABASE_TLS", "must be true or false");
  }
  const databaseTls = databaseTlsRaw === "true";
  if (environment === "production" && !databaseTls) {
    throw new ConfigError("DATABASE_TLS", "must be true in production");
  }
  const clerkIssuer = url(env, "CLERK_ISSUER");
  const clerkJwksUrl = url(env, "CLERK_JWKS_URL");
  if (clerkIssuer.origin !== clerkJwksUrl.origin) {
    throw new ConfigError("CLERK_JWKS_URL", "must match CLERK_ISSUER");
  }
  const groqBaseUrl = url(
    env,
    "GROQ_BASE_URL",
    "https://api.groq.com/openai/v1",
  );
  if (
    groqBaseUrl.hostname !== "api.groq.com" ||
    !groqBaseUrl.pathname.startsWith("/openai/v1")
  ) throw new ConfigError("GROQ_BASE_URL", "must be the Groq OpenAI API");

  const accessKeyId = required(env, "ACCESS_TOKEN_KEY_ID");
  const privateJwk = parseJwk(
    required(env, "ACCESS_TOKEN_PRIVATE_JWK"),
    "ACCESS_TOKEN_PRIVATE_JWK",
  );
  let publicJwks: { keys: JsonWebKey[] };
  try {
    publicJwks = JSON.parse(required(env, "ACCESS_TOKEN_PUBLIC_JWKS"));
    if (!Array.isArray(publicJwks.keys) || publicJwks.keys.length === 0) {
      throw new Error();
    }
  } catch {
    throw new ConfigError(
      "ACCESS_TOKEN_PUBLIC_JWKS",
      "must contain at least one key",
    );
  }
  const privateKid = (privateJwk as JsonWebKey & { kid?: string }).kid;
  if (
    privateJwk.kty !== "OKP" || privateJwk.crv !== "Ed25519" ||
    privateKid !== accessKeyId || !privateJwk.d || !privateJwk.x
  ) {
    throw new ConfigError(
      "ACCESS_TOKEN_PRIVATE_JWK",
      "must be the active Ed25519 private key and match ACCESS_TOKEN_KEY_ID",
    );
  }
  const publicKids = new Set<string>();
  for (const key of publicJwks.keys) {
    const kid = (key as JsonWebKey & { kid?: string }).kid;
    if (
      key.kty !== "OKP" || key.crv !== "Ed25519" || !kid || !key.x || key.d ||
      publicKids.has(kid)
    ) {
      throw new ConfigError(
        "ACCESS_TOKEN_PUBLIC_JWKS",
        "must contain unique Ed25519 public signing keys only",
      );
    }
    publicKids.add(kid);
  }
  if (!publicKids.has(accessKeyId)) {
    throw new ConfigError(
      "ACCESS_TOKEN_PUBLIC_JWKS",
      "must contain ACCESS_TOKEN_KEY_ID",
    );
  }
  const corsOrigins = origins(env, "CORS_ORIGINS");
  const clerkAuthorizedParties = origins(env, "CLERK_AUTHORIZED_PARTIES");
  if (clerkAuthorizedParties.length === 0) {
    throw new ConfigError("CLERK_AUTHORIZED_PARTIES");
  }
  const dodoPortalHosts = (env.DODO_PORTAL_HOSTS ||
    (providerEnvironment === "test"
      ? "test.checkout.dodopayments.com"
      : "checkout.dodopayments.com"))
    .split(",").map((value) => value.trim().toLowerCase()).filter(Boolean);
  const expectedCheckoutHost = providerEnvironment === "test"
    ? "test.checkout.dodopayments.com"
    : "checkout.dodopayments.com";
  if (
    dodoPortalHosts.length === 0 ||
    dodoPortalHosts.some((host) => host !== expectedCheckoutHost)
  ) throw new ConfigError("DODO_PORTAL_HOSTS", "does not match provider mode");
  const refreshInactivitySeconds = integer(
    env,
    "REFRESH_INACTIVITY_SECONDS",
    2592000,
    300,
  );
  const refreshAbsoluteSeconds = integer(
    env,
    "REFRESH_ABSOLUTE_SECONDS",
    7776000,
    600,
  );
  if (refreshAbsoluteSeconds < refreshInactivitySeconds) {
    throw new ConfigError(
      "REFRESH_ABSOLUTE_SECONDS",
      "must be at least REFRESH_INACTIVITY_SECONDS",
    );
  }

  const catalog: CatalogEntry[] = [
    {
      id: "2026-07-turbo",
      publicModel: "whisper-large-v3-turbo",
      upstreamModel: "whisper-large-v3-turbo",
      currency: "USD",
      upstreamMicrosPerHour: 40000n,
      retailMicrosPerHour: 48000n,
      markupBasisPoints: 2000,
      minimumBillableSeconds: 10,
      meterId: required(env, "DODO_METER_TURBO_ID"),
      eventName: "stt_whisper_turbo_seconds",
      effectiveFrom: new Date("2026-07-01T00:00:00Z"),
      enabled: true,
    },
    {
      id: "2026-07-large",
      publicModel: "whisper-large-v3",
      upstreamModel: "whisper-large-v3",
      currency: "USD",
      upstreamMicrosPerHour: 111000n,
      retailMicrosPerHour: 133200n,
      markupBasisPoints: 2000,
      minimumBillableSeconds: 10,
      meterId: required(env, "DODO_METER_LARGE_ID"),
      eventName: "stt_whisper_large_seconds",
      effectiveFrom: new Date("2026-07-01T00:00:00Z"),
      enabled: true,
    },
  ];

  return {
    environment,
    providerEnvironment,
    port: integer(env, "PORT", 8000),
    publicBaseUrl: url(env, "PUBLIC_BASE_URL", "http://127.0.0.1:8000"),
    databaseUrl: required(env, "DATABASE_URL"),
    databasePoolSize: integer(env, "DATABASE_POOL_SIZE", 10),
    databaseTls,
    internalReadinessToken: secret(env, "INTERNAL_READINESS_TOKEN"),
    corsOrigins,
    trustedProxyAddresses: (env.TRUSTED_PROXY_ADDRESSES || "").split(",")
      .map((value) => value.trim()).filter((value) =>
        /^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9a-f:]+$/i.test(value)
      ),
    clerkIssuer,
    clerkJwksUrl,
    clerkSignInUrl: url(env, "CLERK_SIGN_IN_URL"),
    clerkSecretKey: required(env, "CLERK_SECRET_KEY"),
    clerkAuthorizedParties,
    clerkWebhookSecret: required(env, "CLERK_WEBHOOK_SECRET"),
    dodoApiBaseUrl,
    dodoApiKey: required(env, "DODO_API_KEY"),
    dodoWebhookSecret: required(env, "DODO_WEBHOOK_SECRET"),
    dodoProductId: required(env, "DODO_PRODUCT_ID"),
    dodoPortalHosts,
    groqApiKey: required(env, "GROQ_API_KEY"),
    groqBaseUrl,
    accessPrivateJwk: privateJwk,
    accessPublicJwks: publicJwks,
    accessKeyId,
    accessTokenSeconds: integer(env, "ACCESS_TOKEN_SECONDS", 600, 60),
    refreshPepper: secret(env, "REFRESH_TOKEN_PEPPER"),
    refreshInactivitySeconds,
    refreshAbsoluteSeconds,
    maxBodyBytes: integer(env, "MAX_BODY_BYTES", 25 * 1024 * 1024, 1024),
    maxAudioSeconds: integer(env, "MAX_AUDIO_SECONDS", 7200, 10),
    maxConcurrentPerAccount: integer(env, "MAX_CONCURRENT_PER_ACCOUNT", 2),
    maxCycleRetailMicros: BigInt(
      integer(env, "MAX_CYCLE_RETAIL_MICROS", 5000000),
    ),
    requestTimeoutMs: integer(env, "REQUEST_TIMEOUT_MS", 120000, 1000),
    webhookToleranceSeconds: integer(env, "WEBHOOK_TOLERANCE_SECONDS", 300, 30),
    retentionDays: integer(env, "RETENTION_DAYS", 90),
    catalog,
  };
}
