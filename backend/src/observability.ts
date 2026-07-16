const redactedKeys =
  /authorization|cookie|token|secret|password|api.?key|transcript|audio|file/i;

export function redact(value: unknown, depth = 0): unknown {
  if (depth > 8) return "[REDACTED]";
  if (Array.isArray(value)) return value.map((item) => redact(item, depth + 1));
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map((
        [key, item],
      ) => [
        key,
        redactedKeys.test(key) ? "[REDACTED]" : redact(item, depth + 1),
      ]),
    );
  }
  return value;
}

export interface Logger {
  log(event: Record<string, unknown>): void;
}

export class JsonLogger implements Logger {
  log(event: Record<string, unknown>): void {
    console.log(JSON.stringify(redact(event)));
  }
}

export class MemoryLogger implements Logger {
  events: Record<string, unknown>[] = [];
  log(event: Record<string, unknown>): void {
    this.events.push(redact(event) as Record<string, unknown>);
  }
}
