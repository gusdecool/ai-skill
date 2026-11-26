// Token store: one macOS Keychain entry per server, or a 0600 file where no keychain exists.
// A token is written through `security -i` on stdin, never as a command-line argument, so `ps` cannot show it.
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { configDir, assertName } from "./paths.mjs";
import { CliError, redact } from "./redact.mjs";

const SERVICE = "gd-mcp";
// `security -i` silently cuts a line near 4096 characters, so a longer value is refused instead of saved cut.
const MAX_KEYCHAIN_VALUE = 3000;
const NOT_FOUND = 44;

/**
 * Returns the store in use: GD_MCP_STORE (keychain or file) when set, else the keychain on macOS, else a file.
 */
export function storeKind() {
  const forced = process.env.GD_MCP_STORE;
  if (forced === "keychain" || forced === "file") return forced;
  if (forced) throw new CliError('GD_MCP_STORE must be "keychain" or "file"');
  return process.platform === "darwin" ? "keychain" : "file";
}

/**
 * Runs the `security` command (GD_MCP_SECURITY_BIN overrides it in tests) with optional stdin.
 */
function security(args, input) {
  const bin = process.env.GD_MCP_SECURITY_BIN || "security";
  const result = spawnSync(bin, args, { input, encoding: "utf8" });
  if (result.error) throw new CliError(`cannot run ${bin}: ${result.error.message}`);
  return result;
}

/**
 * Returns the folder for token files, mode 0700.
 */
function tokenDir() {
  const dir = join(configDir(), "tokens");
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  chmodSync(configDir(), 0o700);
  chmodSync(dir, 0o700);
  return dir;
}

/**
 * Saves the secret record for a server (access token, refresh token, expiry and login metadata).
 */
export function saveSecret(name, record) {
  assertName(name);
  const value = Buffer.from(JSON.stringify(record)).toString("base64url");
  if (storeKind() === "file") {
    const file = join(tokenDir(), `${name}.json`);
    if (!existsSync(file)) {
      process.stderr.write("warning: no keychain in use; token kept in a 0600 file under ~/.config/gd-mcp/\n");
    }
    writeFileSync(file, value, { mode: 0o600 });
    chmodSync(file, 0o600);
    return;
  }
  if (value.length > MAX_KEYCHAIN_VALUE) {
    throw new CliError("token record is too large for one keychain entry; set GD_MCP_STORE=file and sign in again");
  }
  const result = security(["-i"], `add-generic-password -U -s ${SERVICE} -a ${name} -w ${value}\n`);
  if (result.status !== 0 || result.stderr.trim()) {
    throw new CliError(`keychain write failed (is the keychain locked?): ${redact(result.stderr, [value]).trim()}`);
  }
  let back = null;
  try {
    back = loadSecret(name);
  } catch (error) {
    if (!(error instanceof CliError)) throw error;
  }
  if (JSON.stringify(back) !== JSON.stringify(record)) {
    throw new CliError("keychain write could not be verified; the entry was not saved correctly");
  }
}

/**
 * Loads the secret record for a server, or null when there is none.
 */
export function loadSecret(name) {
  assertName(name);
  let value;
  if (storeKind() === "file") {
    const file = join(configDir(), "tokens", `${name}.json`);
    if (!existsSync(file)) return null;
    value = readFileSync(file, "utf8").trim();
  } else {
    const result = security(["find-generic-password", "-s", SERVICE, "-a", name, "-w"]);
    if (result.status === NOT_FOUND) return null;
    if (result.status !== 0) {
      throw new CliError(`keychain read failed (is the keychain locked?): ${redact(result.stderr).trim()}`);
    }
    value = result.stdout.trim();
  }
  try {
    return JSON.parse(Buffer.from(value, "base64url").toString("utf8"));
  } catch {
    throw new CliError(`the stored token for ${name} is unreadable; run gd-mcp-auth login ${name} again`);
  }
}

/**
 * Deletes the secret record for a server. Returns false when there was none.
 */
export function deleteSecret(name) {
  assertName(name);
  if (storeKind() === "file") {
    const file = join(configDir(), "tokens", `${name}.json`);
    if (!existsSync(file)) return false;
    rmSync(file);
    return true;
  }
  const result = security(["delete-generic-password", "-s", SERVICE, "-a", name]);
  if (result.status === NOT_FOUND) return false;
  if (result.status !== 0) throw new CliError(`keychain delete failed: ${redact(result.stderr).trim()}`);
  return true;
}
