import postgres from "postgres";

const direction = Deno.args[0];
if (direction !== "up" && direction !== "down") {
  throw new Error("Usage: deno task migrate [up|down]");
}
const databaseUrl = Deno.env.get("DATABASE_URL");
if (!databaseUrl) throw new Error("DATABASE_URL is required");
const sql = postgres(databaseUrl, {
  max: 1,
  connect_timeout: 10,
  idle_timeout: 5,
});
try {
  await sql`CREATE TABLE IF NOT EXISTS schema_migrations (version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())`;
  const migrations = [
    ...Deno.readDirSync(new URL("../../migrations", import.meta.url)),
  ].map((item) => item.name).filter((name) =>
    name.endsWith(`.${direction}.sql`)
  ).sort();
  if (direction === "down") migrations.reverse();
  for (const name of migrations) {
    const version = name.split(".", 1)[0];
    const applied =
      await sql`SELECT 1 FROM schema_migrations WHERE version=${version}`;
    if (
      (direction === "up" && applied.length) ||
      (direction === "down" && !applied.length)
    ) continue;
    const source = await Deno.readTextFile(
      new URL(`../../migrations/${name}`, import.meta.url),
    );
    await sql.begin(async (tx) => {
      await tx.unsafe(source);
      if (direction === "up") {
        await tx`INSERT INTO schema_migrations(version) VALUES (${version})`;
      } else await tx`DELETE FROM schema_migrations WHERE version=${version}`;
    });
    console.log(`${direction}: ${version}`);
  }
} finally {
  await sql.end();
}
