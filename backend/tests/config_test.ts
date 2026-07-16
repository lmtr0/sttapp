import { assertEquals, assertThrows } from "@std/assert";
import { ConfigError, loadConfig } from "../src/config.ts";
import { testConfig } from "./helpers.ts";

async function validEnv(): Promise<Record<string, string>> {
  const c = await testConfig();
  return {
    STTAPP_ENV: "test",
    PROVIDER_ENV: "test",
    PUBLIC_BASE_URL: c.publicBaseUrl.href,
    DATABASE_URL: c.databaseUrl,
    INTERNAL_READINESS_TOKEN: c.internalReadinessToken,
    CLERK_ISSUER: c.clerkIssuer.href,
    CLERK_JWKS_URL: c.clerkJwksUrl.href,
    CLERK_SIGN_IN_URL: c.clerkSignInUrl.href,
    CLERK_AUTHORIZED_PARTIES: "https://app.sttapp.test",
    CLERK_SECRET_KEY: c.clerkSecretKey,
    CLERK_WEBHOOK_SECRET: c.clerkWebhookSecret,
    DODO_API_KEY: c.dodoApiKey,
    DODO_WEBHOOK_SECRET: c.dodoWebhookSecret,
    DODO_PRODUCT_ID: c.dodoProductId,
    DODO_METER_TURBO_ID: "meter_test_turbo",
    DODO_METER_LARGE_ID: "meter_test_large",
    GROQ_API_KEY: c.groqApiKey,
    ACCESS_TOKEN_PRIVATE_JWK: JSON.stringify(c.accessPrivateJwk),
    ACCESS_TOKEN_PUBLIC_JWKS: JSON.stringify(c.accessPublicJwks),
    ACCESS_TOKEN_KEY_ID: c.accessKeyId,
    REFRESH_TOKEN_PEPPER: c.refreshPepper,
  };
}

Deno.test("configuration rejects missing values without exposing secrets", async () => {
  const env = await validEnv();
  delete env.GROQ_API_KEY;
  const error = assertThrows(() => loadConfig(env), ConfigError);
  assertEquals(
    error.message,
    "Invalid configuration: GROQ_API_KEY is required",
  );
});
Deno.test("configuration rejects test/live cross wiring", async () => {
  const env = await validEnv();
  env.PROVIDER_ENV = "live";
  assertThrows(() => loadConfig(env), ConfigError);
});
Deno.test("configuration rejects lookalike provider hosts and mismatched keys", async () => {
  const hostEnv = await validEnv();
  hostEnv.DODO_API_BASE_URL = "https://test.dodopayments.com.attacker.test";
  assertThrows(() => loadConfig(hostEnv), ConfigError);

  const keyEnv = await validEnv();
  const privateJwk = JSON.parse(keyEnv.ACCESS_TOKEN_PRIVATE_JWK);
  privateJwk.kid = "unexpected-key";
  keyEnv.ACCESS_TOKEN_PRIVATE_JWK = JSON.stringify(privateJwk);
  assertThrows(() => loadConfig(keyEnv), ConfigError);
});
Deno.test("configuration loads pinned catalog", async () => {
  const config = loadConfig(await validEnv());
  assertEquals(config.catalog.length, 2);
  assertEquals(config.catalog[0].retailMicrosPerHour, 48000n);
});
