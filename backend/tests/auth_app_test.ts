import { assert, assertEquals, assertMatch } from "@std/assert";
import { createApplication } from "../src/app.ts";
import { flac, login, testDependencies } from "./helpers.ts";

Deno.test("health, not-found and error contracts carry request IDs", async () => {
  const deps = await testDependencies();
  const handler = createApplication(deps);
  const health = await handler(new Request("https://api.sttapp.test/healthz"));
  assertEquals(health.status, 200);
  assertMatch(health.headers.get("x-request-id")!, /^req_/);
  const missing = await handler(new Request("https://api.sttapp.test/api"));
  assertEquals(missing.status, 404);
  assertEquals((await missing.json()).error.code, "not_found");
});

Deno.test("desktop PKCE flow issues first-party credentials and detects refresh reuse", async () => {
  const deps = await testDependencies();
  const handler = createApplication(deps);
  const credentials = await login(handler);
  assertMatch(credentials.access, /^[^.]+\.[^.]+\.[^.]+$/);
  const refreshRequest = () =>
    new Request("https://api.sttapp.test/v1/auth/refresh", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ refresh_token: credentials.refresh }),
    });
  const refreshed = await handler(refreshRequest());
  assertEquals(refreshed.status, 200);
  const rotated = await refreshed.json();
  assert(rotated.refresh_token !== credentials.refresh);
  const replay = await handler(refreshRequest());
  assertEquals(replay.status, 401);
  assertEquals((await replay.json()).error.code, "refresh_token_reused");
  const revoked = await handler(
    new Request("https://api.sttapp.test/v1/account", {
      headers: { authorization: `Bearer ${rotated.access_token}` },
    }),
  );
  assertEquals(revoked.status, 401);
});

Deno.test("logout cannot revoke a session using only its public session id", async () => {
  const deps = await testDependencies();
  const handler = createApplication(deps);
  const credentials = await login(handler);
  const sessionId = credentials.refresh.split(".", 1)[0];
  const forged = await handler(
    new Request("https://api.sttapp.test/v1/auth/logout", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ refresh_token: `${sessionId}.forged` }),
    }),
  );
  assertEquals(forged.status, 204);
  const stillValid = await handler(
    new Request("https://api.sttapp.test/v1/auth/refresh", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ refresh_token: credentials.refresh }),
    }),
  );
  assertEquals(stillValid.status, 200);
});

Deno.test("protected models and transcription enforce entitlement and durable usage", async () => {
  const deps = await testDependencies();
  const handler = createApplication(deps);
  const credentials = await login(handler);
  const denied = await handler(
    new Request("https://api.sttapp.test/v1/models", {
      headers: { authorization: `Bearer ${credentials.access}` },
    }),
  );
  assertEquals(denied.status, 403);
  await deps.repository.saveSubscription({
    accountId: credentials.accountId,
    state: "active",
    cancelAtPeriodEnd: false,
  });
  await deps.repository.saveBillingCustomer(credentials.accountId, "cus_test");
  const models = await handler(
    new Request("https://api.sttapp.test/v1/models", {
      headers: { authorization: `Bearer ${credentials.access}` },
    }),
  );
  assertEquals(models.status, 200);
  assertEquals((await models.json()).data[0].id, "whisper-large-v3-turbo");
  const form = new FormData();
  form.set("model", "whisper-large-v3-turbo");
  form.set(
    "file",
    new File([Uint8Array.from(flac()).buffer], "audio.flac", {
      type: "audio/flac",
    }),
  );
  const encoded = new Request("https://encode.test", {
    method: "POST",
    body: form,
  });
  const body = new Uint8Array(await encoded.arrayBuffer());
  const response = await handler(
    new Request("https://api.sttapp.test/v1/audio/transcriptions", {
      method: "POST",
      headers: {
        authorization: `Bearer ${credentials.access}`,
        "content-type": encoded.headers.get("content-type")!,
        "content-length": String(body.byteLength),
      },
      body,
    }),
  );
  assertEquals(response.status, 200);
  assertEquals(await response.json(), { text: "hello" });
  assertEquals(deps.repository.usages.size, 1);
  assertEquals(deps.repository.outbox.size, 1);
  assertEquals([...deps.repository.usages.values()][0].retailMicros, 134n);
});
