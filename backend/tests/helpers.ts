import { exportJWK, generateKeyPair } from "jose";
import type { BrowserAuthenticator } from "../src/auth.ts";
import type { AppConfig } from "../src/config.ts";
import {
  type AppDependencies,
  createDependencies,
} from "../src/dependencies.ts";
import type { CatalogEntry } from "../src/domain.ts";
import type { DodoClient, GroqClient, GroqResult } from "../src/providers.ts";
import { MemoryRepository } from "../src/repository.ts";
import { MemoryLogger } from "../src/observability.ts";

export async function testConfig(): Promise<AppConfig> {
  const { privateKey, publicKey } = await generateKeyPair("Ed25519", {
    extractable: true,
  });
  const privateJwk = await exportJWK(privateKey);
  const publicJwk = await exportJWK(publicKey);
  privateJwk.kid = "test-key";
  publicJwk.kid = "test-key";
  publicJwk.use = "sig";
  publicJwk.alg = "EdDSA";
  const catalog: CatalogEntry[] = [{
    id: "test-turbo",
    publicModel: "whisper-large-v3-turbo",
    upstreamModel: "whisper-large-v3-turbo",
    currency: "USD",
    upstreamMicrosPerHour: 40000n,
    retailMicrosPerHour: 48000n,
    markupBasisPoints: 2000,
    minimumBillableSeconds: 10,
    meterId: "meter_test",
    eventName: "stt_seconds",
    effectiveFrom: new Date("2020-01-01T00:00:00Z"),
    enabled: true,
  }];
  return {
    environment: "test",
    providerEnvironment: "test",
    port: 8000,
    publicBaseUrl: new URL("https://api.sttapp.test"),
    databaseUrl: "postgres://test:test@127.0.0.1:5432/sttapp_test",
    databasePoolSize: 2,
    databaseTls: false,
    internalReadinessToken: "readiness-test-token-at-least-32-bytes",
    corsOrigins: ["https://app.sttapp.test"],
    trustedProxyAddresses: [],
    clerkIssuer: new URL("https://clerk.sttapp.test"),
    clerkJwksUrl: new URL("https://clerk.sttapp.test/.well-known/jwks.json"),
    clerkSignInUrl: new URL("https://accounts.sttapp.test/sign-in"),
    clerkSecretKey: "sk_test_placeholder",
    clerkAuthorizedParties: ["https://app.sttapp.test"],
    clerkWebhookSecret: "whsec_dGVzdC13ZWJob29rLXNlY3JldA==",
    dodoApiBaseUrl: new URL("https://test.dodopayments.com"),
    dodoApiKey: "dodo_test_placeholder",
    dodoWebhookSecret: "whsec_dGVzdC13ZWJob29rLXNlY3JldA==",
    dodoProductId: "prod_test",
    dodoPortalHosts: ["test.checkout.dodopayments.com"],
    groqApiKey: "groq_test_placeholder",
    groqBaseUrl: new URL("https://api.groq.com/openai/v1"),
    accessPrivateJwk: privateJwk,
    accessPublicJwks: { keys: [publicJwk] },
    accessKeyId: "test-key",
    accessTokenSeconds: 600,
    refreshPepper: "test-pepper-at-least-32-characters-long",
    refreshInactivitySeconds: 3600,
    refreshAbsoluteSeconds: 86400,
    maxBodyBytes: 1024 * 1024,
    maxAudioSeconds: 3600,
    maxConcurrentPerAccount: 2,
    maxCycleRetailMicros: 5_000_000n,
    requestTimeoutMs: 5000,
    webhookToleranceSeconds: 300,
    retentionDays: 30,
    catalog,
  };
}

export class FakeBrowser implements BrowserAuthenticator {
  async authenticate() {
    return { subject: "user_test", email: "person@example.test" };
  }
}
export class FakeGroq implements GroqClient {
  calls = 0;
  constructor(
    private result: GroqResult = { text: "hello", durationMilliseconds: 1000 },
  ) {}
  async transcribe(_file: File, _entry: CatalogEntry, _signal: AbortSignal) {
    this.calls++;
    return this.result;
  }
}
export class FakeDodo implements DodoClient {
  usage: Record<string, unknown>[] = [];
  async createCustomer() {
    return "cus_test";
  }
  async createCheckout() {
    return new URL("https://test.checkout.dodopayments.com/test");
  }
  async createPortal() {
    return new URL("https://test.checkout.dodopayments.com/portal");
  }
  async ingestUsage(payload: Record<string, unknown>) {
    this.usage.push(payload);
  }
}

export async function testDependencies(): Promise<
  AppDependencies & {
    repository: MemoryRepository;
    groq: FakeGroq;
    dodo: FakeDodo;
    logger: MemoryLogger;
  }
> {
  const repository = new MemoryRepository();
  const groq = new FakeGroq();
  const dodo = new FakeDodo();
  const logger = new MemoryLogger();
  return await createDependencies({
    config: await testConfig(),
    repository,
    browser: new FakeBrowser(),
    groq,
    dodo,
    logger,
  }) as AppDependencies & {
    repository: MemoryRepository;
    groq: FakeGroq;
    dodo: FakeDodo;
    logger: MemoryLogger;
  };
}

export function flac(durationSeconds = 1, sampleRate = 48000): Uint8Array {
  const bytes = new Uint8Array(42);
  bytes.set([0x66, 0x4c, 0x61, 0x43, 0x80, 0, 0, 34]);
  const total = BigInt(durationSeconds * sampleRate);
  const packed = (BigInt(sampleRate) << 44n) | (1n << 41n) | (15n << 36n) |
    total;
  for (let i = 0; i < 8; i++) {
    bytes[18 + i] = Number((packed >> BigInt((7 - i) * 8)) & 0xffn);
  }
  return bytes;
}

export async function login(
  handler: (request: Request) => Promise<Response>,
): Promise<{ access: string; refresh: string; accountId: string }> {
  const verifier = "v".repeat(43);
  const state = "s".repeat(43);
  const digest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)),
  );
  let binary = "";
  for (const byte of digest) binary += String.fromCharCode(byte);
  const challenge = btoa(binary).replaceAll("+", "-").replaceAll("/", "_")
    .replace(/=+$/, "");
  const start = await handler(
    new Request("https://api.sttapp.test/v1/auth/desktop/start", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        code_challenge: challenge,
        state,
        callback_uri: "http://127.0.0.1:4567/callback",
      }),
    }),
  );
  const started = await start.json();
  const authorized = await handler(new Request(started.authorization_url));
  const callback = new URL(authorized.headers.get("location")!);
  const exchanged = await handler(
    new Request("https://api.sttapp.test/v1/auth/desktop/exchange", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        transaction_id: started.transaction_id,
        code: callback.searchParams.get("code"),
        code_verifier: verifier,
        state,
        callback_uri: "http://127.0.0.1:4567/callback",
      }),
    }),
  );
  if (!exchanged.ok) throw new Error(await exchanged.text());
  const value = await exchanged.json();
  return {
    access: value.access_token,
    refresh: value.refresh_token,
    accountId: JSON.parse(
      atob(
        value.access_token.split(".")[1].replaceAll("-", "+").replaceAll(
          "_",
          "/",
        ),
      ),
    ).sub,
  };
}
