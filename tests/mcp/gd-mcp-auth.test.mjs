// Tests for gd-mcp-auth against the local mock login server. No live API is called.
import { test, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { readFileSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { startMock } from "./mock-server.mjs";
import { AUTH, CLIENT, makeEnv, runScript } from "./helpers.mjs";
import { loadSecret } from "../../skills/gd-mcp-client/scripts/lib/store.mjs";
import { listen } from "../../skills/gd-mcp-auth/scripts/lib/callback.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const BROWSER = join(here, "fake-browser.mjs");
const { env } = makeEnv();
let mock;
const auth = (args, options = {}) => {
  return runScript(join(AUTH, "mcp-auth"), args, { env: { GD_MCP_BROWSER: BROWSER }, ...options });
};

beforeEach(() => {
  mock = null;
});
afterEach(async () => {
  await mock?.close();
  await auth(["remove", "example"]);
});

/**
 * Starts a mock with options and registers it as the oauth server "example".
 */
async function setup(options = {}, addArgs = []) {
  mock = await startMock(options);
  const added = await auth(["add", "example", mock.mcpUrl, ...addArgs]);
  assert.equal(added.code, 0, added.stderr);
}

/**
 * Asserts that no secret value appears in the command's output.
 */
function assertClean(result, secrets) {
  for (const secret of secrets) {
    assert.ok(!result.stdout.includes(secret) && !result.stderr.includes(secret), "a secret was printed");
  }
}

test("add writes a registry entry with no secret, and refuses bad input", async () => {
  await setup();
  const file = join(env.GD_MCP_HOME, "registry.json");
  assert.equal(statSync(file).mode & 0o777, 0o600);
  const entry = JSON.parse(readFileSync(file, "utf8")).servers.example;
  assert.deepEqual(entry, { transport: "http", url: mock.mcpUrl, auth: { type: "oauth" } });
  assert.match((await auth(["add", "example", mock.mcpUrl])).stderr, /already registered/);
  assert.match((await auth(["add", "Bad_Name", mock.mcpUrl])).stderr, /invalid server name/);
  assert.match((await auth(["add", "other", "http://example.com/mcp"])).stderr, /must use https/);
  assert.match((await auth(["add", "other", "https://user:pw@example.com/mcp"])).stderr, /user name or password/);
});

test("login signs in with PKCE, resource, state and a loopback redirect, then the client can call", async () => {
  await setup();
  const result = await auth(["login", "example"]);
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /signed in as example, expires at \d{4}-\d\d-\d\dT/);
  const query = mock.stats.authorizeQueries[0];
  assert.equal(query.code_challenge_method, "S256");
  assert.equal(query.resource, mock.mcpUrl);
  assert.ok(query.state.length >= 20);
  assert.match(query.redirect_uri, /^http:\/\/127\.0\.0\.1:\d+\/callback$/);
  assert.equal(mock.stats.registrations, 1);
  assert.deepEqual(mock.stats.tokenGrants, [{ grant: "authorization_code", resource: mock.mcpUrl }]);
  const record = loadSecret("example");
  assertClean(result, [record.accessToken, record.refreshToken]);
  const call = await runScript(join(CLIENT, "mcp-call"), ["example", "echo", '{"text":"ok"}']);
  assert.equal(call.stdout.trim(), "echo:ok");
});

test("a pre-registered client id is used and no registration is made", async () => {
  await setup({}, ["--client-id", "preregistered-client"]);
  const result = await auth(["login", "example"]);
  assert.equal(result.code, 0, result.stderr);
  assert.equal(mock.stats.registrations, 0);
  assert.equal(mock.stats.authorizeQueries[0].client_id, "preregistered-client");
  assert.equal(loadSecret("example").clientId, "preregistered-client");
});

test("a wrong issuer on the redirect stops the login before the code is exchanged", async () => {
  await setup({ issuerOverride: "https://other.example.com" });
  const result = await auth(["login", "example"]);
  assert.equal(result.code, 1);
  assert.match(result.stderr, /different issuer/);
  assert.deepEqual(mock.stats.tokenGrants, []);
  assert.equal(loadSecret("example"), null);
});

test("a wrong state on the redirect stops the login", async () => {
  await setup({ stateOverride: "forged-state-value" });
  const result = await auth(["login", "example"]);
  assert.equal(result.code, 1);
  assert.match(result.stderr, /wrong state/);
  assert.deepEqual(mock.stats.tokenGrants, []);
});

test("a server that does not advertise PKCE S256 is refused", async () => {
  await setup({ noPkce: true });
  const result = await auth(["login", "example"]);
  assert.equal(result.code, 1);
  assert.match(result.stderr, /PKCE S256/);
  assert.deepEqual(mock.stats.authorizeQueries, []);
});

test("login gives up when nobody finishes the sign-in before the timeout", async () => {
  await setup();
  const result = await auth(["login", "example"], { env: { GD_MCP_BROWSER: "true", GD_MCP_LOGIN_TIMEOUT_MS: "300" } });
  assert.equal(result.code, 1);
  assert.match(result.stderr, /timed out/);
  assert.equal(loadSecret("example"), null);
});

test("--no-browser prints the address and accepts the pasted redirect URL", async () => {
  await setup();
  const child = spawn(join(AUTH, "mcp-auth"), ["login", "example", "--no-browser"], { env: { ...process.env } });
  let out = "";
  const finished = new Promise((resolve) => child.on("close", (code) => resolve(code)));
  const address = new Promise((resolve) => {
    child.stdout.on("data", (chunk) => {
      out += chunk;
      const found = /(http:\/\/127\.0\.0\.1:\d+\/authorize\S+)/.exec(out);
      if (found) resolve(found[1]);
    });
  });
  const landing = (await fetch(await address, { redirect: "manual" })).headers.get("location");
  child.stdin.end(`${landing}\n`);
  assert.equal(await finished, 0);
  assert.match(out, /signed in as example/);
  assert.ok(loadSecret("example").accessToken);
});

test("an API token is read from stdin, saved, and never printed", async () => {
  mock = await startMock({});
  await auth(["add", "example", mock.mcpUrl, "--auth", "bearer"]);
  const secret = ["tok", "from", "stdin", "1234567890"].join("-");
  const result = await auth(["login", "example"], { input: `${secret}\n` });
  assert.equal(result.code, 0, result.stderr);
  assertClean(result, [secret]);
  assert.equal(loadSecret("example").accessToken, secret);
  assert.match((await auth(["status", "example"])).stdout, /example: signed in, expires never \(api token\)/);
  const log = readFileSync(join(env.FAKE_KEYCHAIN_DIR, "argv.log"), "utf8");
  assert.ok(!log.includes(secret));
});

test("status, logout and remove work and print only status lines", async () => {
  await setup();
  assert.match((await auth(["status"])).stdout, /example: not signed in/);
  await auth(["login", "example"]);
  const signedIn = await auth(["status"]);
  assert.match(signedIn.stdout, /example: signed in, expires \d{4}-/);
  assert.match((await auth(["logout", "example"])).stdout, /signed out example/);
  assert.equal(loadSecret("example"), null);
  assert.match((await auth(["status", "example"])).stdout, /not signed in/);
  assert.match((await auth(["remove", "example"])).stdout, /removed example/);
  assert.match((await auth(["status", "example"])).stderr, /not registered: example/);
});

test("the loopback listener binds 127.0.0.1, takes one request and then closes", async () => {
  const state = "state-value-for-test";
  const callback = await listen({ state, timeoutMs: 5000 });
  assert.match(callback.redirectUri, /^http:\/\/127\.0\.0\.1:\d+\/callback$/);
  assert.equal((await fetch(callback.redirectUri.replace("/callback", "/favicon.ico"))).status, 404);
  const hit = await fetch(`${callback.redirectUri}?code=abc&state=${state}&iss=x`);
  assert.equal(hit.status, 200);
  assert.deepEqual(await callback.result, { code: "abc", iss: "x" });
  callback.close();
  await assert.rejects(fetch(`${callback.redirectUri}?code=abc&state=${state}`));
});
