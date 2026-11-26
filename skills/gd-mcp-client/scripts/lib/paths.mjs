// Where the shared MCP files live, and the checks on names and URLs that every command applies.
import { homedir } from "node:os";
import { join } from "node:path";
import { CliError } from "./redact.mjs";

const NAME = /^[a-z0-9][a-z0-9-]{0,62}$/;

/**
 * Returns the config folder: GD_MCP_HOME when set (tests), else ~/.config/gd-mcp.
 */
export function configDir() {
  return process.env.GD_MCP_HOME || join(homedir(), ".config", "gd-mcp");
}

/**
 * Throws unless the server name is lowercase letters, digits and hyphens, so it is safe in a keychain command.
 */
export function assertName(name) {
  if (typeof name !== "string" || !NAME.test(name)) {
    throw new CliError(`invalid server name "${name ?? ""}": use a-z, 0-9 and hyphen (max 63 characters)`);
  }
  return name;
}

/**
 * Throws unless the URL is https, or http on the loopback address (used by local servers and tests).
 */
export function assertSafeUrl(value, label) {
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new CliError(`${label} is not a valid URL`);
  }
  const loopback = url.hostname === "127.0.0.1" || url.hostname === "localhost" || url.hostname === "[::1]";
  if (url.protocol !== "https:" && !(url.protocol === "http:" && loopback)) {
    throw new CliError(`${label} must use https (http is allowed only on 127.0.0.1)`);
  }
  if (url.username || url.password) throw new CliError(`${label} must not contain a user name or password`);
  return url;
}
