// Removes secrets from text before it is printed, so an error never leaks a token, code or verifier.

const FIELD = /("(?:access_token|refresh_token|id_token|code|code_verifier|client_secret)"\s*:\s*")[^"]*(")/g;
const QUERY = /([?&](?:access_token|refresh_token|code|code_verifier|client_secret)=)[^&\s"']+/g;
const BEARER = /(Bearer\s+)[A-Za-z0-9._~+/=-]+/gi;

/**
 * Returns the text with the given secret values, bearer headers, token JSON fields and token query
 * parameters replaced by a marker.
 */
export function redact(text, secrets = []) {
  let out = String(text);
  for (const secret of secrets) {
    if (typeof secret === "string" && secret.length >= 8) out = out.split(secret).join("[redacted]");
  }
  return out.replace(BEARER, "$1[redacted]").replace(FIELD, "$1[redacted]$2").replace(QUERY, "$1[redacted]");
}

/**
 * Error that carries a user-facing message and an exit code; its message is already safe to print.
 */
export class CliError extends Error {
  /**
   * Creates the error with the exit code the command should end with (default 1).
   */
  constructor(message, exitCode = 1) {
    super(message);
    this.exitCode = exitCode;
  }
}
