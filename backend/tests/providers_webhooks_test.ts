import { assertEquals } from "@std/assert";
import { FetchDodoClient } from "../src/providers.ts";
import { MemoryRepository } from "../src/repository.ts";
import { receiveWebhook } from "../src/webhooks.ts";
import { testConfig } from "./helpers.ts";

Deno.test("Dodo requests use current usage endpoint and account-bound checkout metadata", async () => {
  const config = await testConfig();
  const calls: Array<{ url: URL; body: Record<string, unknown> }> = [];
  const client = new FetchDodoClient(config, async (input, init) => {
    const url = new URL(String(input));
    calls.push({
      url,
      body: JSON.parse(String(init?.body)) as Record<string, unknown>,
    });
    return Response.json(
      url.pathname === "/checkouts"
        ? {
          checkout_url: "https://test.checkout.dodopayments.com/session/test",
        }
        : {},
    );
  });

  await client.createCheckout(
    "cus_test",
    "account_test",
    new URL("https://api.sttapp.test/billing/return"),
    "checkout_test",
  );
  await client.ingestUsage({ event_id: "usage_test", customer_id: "cus_test" });

  assertEquals(calls[0].url.pathname, "/checkouts");
  assertEquals(calls[0].body.metadata, {
    sttapp: "hosted",
    sttapp_account_id: "account_test",
  });
  assertEquals(calls[1].url.pathname, "/events/ingest");
});

Deno.test("webhooks retain signed delivery id and recursively remove PII", async () => {
  const config = await testConfig();
  const repository = new MemoryRepository();
  const deliveryId = "msg_signed_delivery";
  const timestamp = String(Math.floor(Date.now() / 1000));
  const payload = {
    id: "business_entity_id",
    type: "subscription.active",
    data: {
      object: {
        id: "sub_test",
        email: "private@example.test",
        metadata: { sttapp_account_id: "account_test" },
      },
    },
  };
  const raw = new TextEncoder().encode(JSON.stringify(payload));
  const signature = await standardWebhookSignature(
    config.dodoWebhookSecret,
    deliveryId,
    timestamp,
    raw,
  );
  const response = await receiveWebhook(
    "dodo",
    new Request("https://api.sttapp.test/webhooks/dodo", {
      method: "POST",
      headers: {
        "content-length": String(raw.byteLength),
        "webhook-id": deliveryId,
        "webhook-timestamp": timestamp,
        "webhook-signature": `v1,${signature}`,
      },
      body: raw,
    }),
    config,
    repository,
  );

  assertEquals(response.status, 202);
  assertEquals(repository.webhooks.has(`dodo:${deliveryId}`), true);
  const stored = repository.webhooks.get(`dodo:${deliveryId}`)!.payload;
  assertEquals(
    ((stored.data as Record<string, unknown>).object as Record<string, unknown>)
      .email,
    undefined,
  );
  assertEquals(
    (((stored.data as Record<string, unknown>).object as Record<
      string,
      unknown
    >)
      .metadata as Record<string, unknown>).sttapp_account_id,
    "account_test",
  );
});

async function standardWebhookSignature(
  secret: string,
  id: string,
  timestamp: string,
  body: Uint8Array,
): Promise<string> {
  const encoded = secret.startsWith("whsec_") ? secret.slice(6) : secret;
  const keyBytes = Uint8Array.from(
    atob(encoded),
    (value) => value.charCodeAt(0),
  );
  const key = await crypto.subtle.importKey(
    "raw",
    keyBytes,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const prefix = new TextEncoder().encode(`${id}.${timestamp}.`);
  const message = new Uint8Array(prefix.length + body.length);
  message.set(prefix);
  message.set(body, prefix.length);
  const signature = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, message),
  );
  return btoa(String.fromCharCode(...signature));
}
