// Shared test helpers: a temp config folder with a fake keychain, and an async runner for the skill scripts.
import { execFile } from "node:child_process";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
export const REPO = join(here, "..", "..");
export const CLIENT = join(REPO, "skills", "gd-mcp-client", "scripts");
export const AUTH = join(REPO, "skills", "gd-mcp-auth", "scripts");

/**
 * Makes a temp config folder and fake keychain, points this process and the returned env at them.
 */
export function makeEnv() {
  const root = mkdtempSync(join(tmpdir(), "gd-mcp-test-"));
  const env = {
    GD_MCP_HOME: join(root, "config"),
    GD_MCP_STORE: "keychain",
    GD_MCP_SECURITY_BIN: join(here, "fake-security.mjs"),
    FAKE_KEYCHAIN_DIR: join(root, "keychain"),
  };
  Object.assign(process.env, env);
  return { root, env };
}

/**
 * Writes a registry file into the temp config folder.
 */
export function writeRegistry(env, servers) {
  mkdirSync(env.GD_MCP_HOME, { recursive: true });
  const file = join(env.GD_MCP_HOME, "registry.json");
  writeFileSync(file, JSON.stringify({ version: 1, servers }));
}

/**
 * Runs a skill script without blocking the event loop (the mock servers live in this process).
 * Resolves to {code, stdout, stderr}; extra env values and stdin text are optional.
 */
export function runScript(script, args, { env = {}, input = "", timeout = 20_000 } = {}) {
  return new Promise((resolve) => {
    const child = execFile(
      script,
      args,
      { env: { ...process.env, ...env }, timeout },
      (error, stdout, stderr) => resolve({ code: error ? (error.code ?? 1) : 0, stdout, stderr }),
    );
    child.stdin.end(input);
  });
}
