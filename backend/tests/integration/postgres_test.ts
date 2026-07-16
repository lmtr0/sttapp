import { assert, assertEquals } from "@std/assert";
import { PostgresRepository } from "../../src/db/postgres.ts";
import { testConfig } from "../helpers.ts";

Deno.test({
  name: "PostgreSQL connectivity and transaction-backed repository readiness",
  ignore: !Deno.env.get("TEST_DATABASE_URL") && !Deno.env.get("DATABASE_URL"),
  async fn() {
    const config = await testConfig();
    config.databaseUrl = Deno.env.get("TEST_DATABASE_URL") ||
      Deno.env.get("DATABASE_URL")!;
    const repository = new PostgresRepository(config);
    try {
      assert(await repository.ready());
      await repository.ensureCatalog(config.catalog);
      const account = await repository.getOrCreateAccount(
        `integration_${crypto.randomUUID()}`,
      );
      assert((await repository.getAccount(account.id))?.id === account.id);
      const now = new Date();
      const reserve = (id: string) =>
        repository.reserveUsage(
          {
            id,
            accountId: account.id,
            catalogId: config.catalog[0].id,
            reservedRetailMicros: 100n,
            expiresAt: new Date(now.getTime() + 60_000),
            createdAt: now,
          },
          undefined,
          1000n,
          1,
          now,
        );
      const results = await Promise.all([
        reserve(crypto.randomUUID()),
        reserve(crypto.randomUUID()),
      ]);
      assertEquals(
        results.map((result) => result.status).sort(),
        ["concurrency_limit", "reserved"],
      );
    } finally {
      await repository.close();
    }
  },
});
