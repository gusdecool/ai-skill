// Tests for gd-mcp-client against the local mock MCP server. No live API is called.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { startMock } from "./mock-server.mjs";
import { CLIENT, makeEnv, runScript, writeRegistry } from "./helpers.mjs";
import { loadSecret, saveSecret } from "../../skills/gd-mcp-client/scripts/lib/store.mjs";
import { redact } from "../../skills/gd-mcp-client/scripts/lib/redact.mjs";

const { env } = makeEnv();
let mock;

before(async () => {
  mock = await startMock({});
});
after(async () => {
  await mock.close();
});

/**
 * Registers an oauth server named "example" that points at the mock, and seeds its token record.
 */
function seed(record, url = mock.mcpUrl) {
  writeRegistry(env, {
    example: { transport: "http", url, auth: { type: "oauth" } },
    "example-local": { transport: "stdio", command: "example-mcp-server", auth: { type: "none" } },
  });
  saveSecret("example", {
    tokenEndpoint: `${mock.base}/token`,
    clientId: "seed-client",
    ...record,
  });
}

/**
 * Asserts that no secret value appears in the command's output.
 */
function assertNoSecrets(result, secrets) {
  for (const secret of secrets) {
    assert.ok(!result.stdout.includes(secret) && !result.stderr.includes(secret), "a secret was printed");
  }
}

test("mcp-list shows registered servers and no secret", async () => {
  const tokens = mock.issueTokens();
  seed({ accessToken: tokens.access_token, refreshToken: tokens.refresh_token });
  const result = await runScript(join(CLIENT, "mcp-list"), []);
  assert.equal(result.code, 0);
  assert.match(result.stdout, /^example http oauth http:\/\/127\.0\.0\.1:\d+\/mcp$/m);
  assertNoSecrets(result, [tokens.access_token, tokens.refresh_token]);
});

test("an unknown server prints 'not registered' and exits 3 so the agent can fall back", async () => {
  seed({ accessToken: "unused-value" });
  for (const [script, args] of [["list-tools", ["nope"]], ["mcp-call", ["nope", "ping", "{}"]]]) {
    const result = await runScript(join(CLIENT, script), args);
    assert.equal(result.code, 3);
    assert.match(result.stdout, /not registered: nope/);
  }
});

test("list-tools lists the tools with a valid token", async () => {
  const tokens = mock.issueTokens();
  seed({ accessToken: tokens.access_token, expiresAt: Date.now() + 600_000 });
  const result = await runScript(join(CLIENT, "list-tools"), ["example"]);
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /^echo: Returns the text it is given$/m);
  assert.match(result.stdout, /^ping: Returns pong$/m);
  assertNoSecrets(result, [tokens.access_token]);
});

test("mcp-call returns the tool result (SSE reply) and passes the arguments", async () => {
  const tokens = mock.issueTokens();
  seed({ accessToken: tokens.access_token, expiresAt: Date.now() + 600_000 });
  const result = await runScript(join(CLIENT, "mcp-call"), ["example", "echo", '{"text":"hi"}']);
  assert.equal(result.code, 0, result.stderr);
  assert.equal(result.stdout.trim(), "echo:hi");
});

test("mcp-call exits 1 when the tool reports an error, and rejects bad JSON", async () => {
  const tokens = mock.issueTokens();
  seed({ accessToken: tokens.access_token, expiresAt: Date.now() + 600_000 });
  const failed = await runScript(join(CLIENT, "mcp-call"), ["example", "missing-tool", "{}"]);
  assert.equal(failed.code, 1);
  assert.match(failed.stdout, /unknown tool missing-tool/);
  const bad = await runScript(join(CLIENT, "mcp-call"), ["example", "ping", "{not json"]);
  assert.equal(bad.code, 1);
  assert.match(bad.stderr, /not valid JSON/);
});

test("an expired token is refreshed before the call and the new token is saved", async () => {
  const tokens = mock.issueTokens();
  seed({ accessToken: tokens.access_token, refreshToken: tokens.refresh_token, expiresAt: Date.now() - 1000 });
  const before = mock.stats.tokenGrants.length;
  const result = await runScript(join(CLIENT, "mcp-call"), ["example", "ping", "{}"]);
  assert.equal(result.code, 0, result.stderr);
  assert.equal(result.stdout.trim(), "pong");
  assert.deepEqual(mock.stats.tokenGrants.slice(before), [{ grant: "refresh_token", resource: mock.mcpUrl }]);
  const saved = loadSecret("example");
  assert.notEqual(saved.accessToken, tokens.access_token);
  assert.ok(saved.expiresAt > Date.now());
  assertNoSecrets(result, [tokens.access_token, tokens.refresh_token, saved.accessToken, saved.refreshToken]);
});

test("a token the server rejects is refreshed once and the call retried", async () => {
  const tokens = mock.issueTokens();
  seed({ accessToken: "rejected-by-server", refreshToken: tokens.refresh_token, expiresAt: Date.now() + 600_000 });
  const result = await runScript(join(CLIENT, "list-tools"), ["example"]);
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /^echo:/m);
});

test("a failed refresh tells the user to log in again and prints no token", async () => {
  seed({ accessToken: "old-access-value", refreshToken: "unknown-refresh-value", expiresAt: Date.now() - 1000 });
  const result = await runScript(join(CLIENT, "mcp-call"), ["example", "ping", "{}"]);
  assert.equal(result.code, 1);
  assert.match(result.stderr, /refresh failed \(invalid_grant\); run gd-mcp-auth login example/);
  assertNoSecrets(result, ["old-access-value", "unknown-refresh-value"]);
});

test("a server with no saved token says to log in and never starts a login", async () => {
  seed({ accessToken: "x" });
  const { stdout } = await runScript(join(CLIENT, "mcp-list"), []);
  assert.ok(stdout.includes("example"));
  writeRegistry(env, { other: { transport: "http", url: mock.mcpUrl, auth: { type: "oauth" } } });
  const result = await runScript(join(CLIENT, "list-tools"), ["other"]);
  assert.equal(result.code, 1);
  assert.match(result.stderr, /no token saved for other; run gd-mcp-auth login other/);
});

test("a redirect is refused and the token never reaches the other host", async () => {
  const other = await startMock({ requireAuth: false });
  const redirecting = await startMock({ redirectTo: other.mcpUrl });
  try {
    const tokens = redirecting.issueTokens();
    seed({ accessToken: tokens.access_token, expiresAt: Date.now() + 600_000 }, `${redirecting.base}/redirect-me`);
    const result = await runScript(join(CLIENT, "list-tools"), ["example"]);
    assert.equal(result.code, 1);
    assert.match(result.stderr, /redirected/);
    assert.deepEqual(other.stats.authHeaders, []);
  } finally {
    await other.close();
    await redirecting.close();
  }
});

test("a stdio server is reported as unsupported by the shared client", async () => {
  seed({ accessToken: "x" });
  const result = await runScript(join(CLIENT, "list-tools"), ["example-local"]);
  assert.equal(result.code, 1);
  assert.match(result.stderr, /stdio server; the shared client calls http servers only/);
});

test("a token is never passed on a command line to the keychain command", async () => {
  const tokens = mock.issueTokens();
  seed({ accessToken: tokens.access_token, refreshToken: tokens.refresh_token, expiresAt: Date.now() - 1000 });
  await runScript(join(CLIENT, "mcp-call"), ["example", "ping", "{}"]);
  const log = readFileSync(join(env.FAKE_KEYCHAIN_DIR, "argv.log"), "utf8");
  assert.ok(log.includes('["-i"]'));
  assert.ok(!log.includes(tokens.access_token) && !log.includes(tokens.refresh_token));
  assert.ok(!log.includes("add-generic-password"), "writes go through stdin, not argv");
});

test("a keychain write that gets cut short is detected, not saved as good", () => {
  process.env.FAKE_KEYCHAIN_TRUNCATE = "20";
  try {
    assert.throws(() => saveSecret("example", { accessToken: "a".repeat(50) }), /could not be verified/);
  } finally {
    delete process.env.FAKE_KEYCHAIN_TRUNCATE;
  }
});

test("a record too large for one keychain entry is refused with advice", () => {
  assert.throws(() => saveSecret("example", { accessToken: "a".repeat(4000) }), /GD_MCP_STORE=file/);
});

test("the file store keeps the token in a 0600 file inside a 0700 folder", async () => {
  process.env.GD_MCP_STORE = "file";
  try {
    saveSecret("example", { accessToken: "file-store-value" });
    const { statSync } = await import("node:fs");
    const file = join(env.GD_MCP_HOME, "tokens", "example.json");
    assert.ok(existsSync(file));
    assert.equal(statSync(file).mode & 0o777, 0o600);
    assert.equal(statSync(join(env.GD_MCP_HOME, "tokens")).mode & 0o777, 0o700);
    assert.equal(loadSecret("example").accessToken, "file-store-value");
  } finally {
    process.env.GD_MCP_STORE = "keychain";
  }
});

test("redact removes known secrets, bearer headers and token fields", () => {
  const text = 'Bearer abc.def-ghi {"access_token":"zzzz1234","x":1} ?code=qqq111&state=s secret-value-1234';
  const out = redact(text, ["secret-value-1234"]);
  assert.ok(!/abc\.def|zzzz1234|qqq111|secret-value/.test(out));
  assert.match(out, /state=s/);
});
