// Reads and writes the server registry, ~/.config/gd-mcp/registry.json. It holds names and URLs, never a secret.
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { configDir, assertName } from "./paths.mjs";
import { CliError } from "./redact.mjs";

/**
 * Returns the registry file path.
 */
export const registryPath = () => join(configDir(), "registry.json");

/**
 * Creates the config folder with mode 0700 when it is missing and returns its path.
 */
export function ensureConfigDir() {
  const dir = configDir();
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  chmodSync(dir, 0o700);
  return dir;
}

/**
 * Loads the registry. A missing file is an empty registry; a broken one is an explicit error.
 */
export function loadRegistry() {
  const file = registryPath();
  if (!existsSync(file)) return { version: 1, servers: {} };
  let data;
  try {
    data = JSON.parse(readFileSync(file, "utf8"));
  } catch (error) {
    throw new CliError(`registry ${file} is not valid JSON: ${error.message}`);
  }
  if (data?.version !== 1 || typeof data.servers !== "object" || data.servers === null) {
    throw new CliError(`registry ${file} must be {"version": 1, "servers": {...}}`);
  }
  return data;
}

/**
 * Writes the registry through a temporary file and a rename, with mode 0600.
 */
export function saveRegistry(registry) {
  ensureConfigDir();
  const file = registryPath();
  const temp = `${file}.${process.pid}.tmp`;
  writeFileSync(temp, `${JSON.stringify(registry, null, 2)}\n`, { mode: 0o600 });
  chmodSync(temp, 0o600);
  renameSync(temp, file);
}

/**
 * Returns the registry entry for a name, or null when the server is not registered.
 */
export function findServer(registry, name) {
  assertName(name);
  return Object.hasOwn(registry.servers, name) ? registry.servers[name] : null;
}
