// Receives the OAuth redirect: a loopback listener on 127.0.0.1 (random port, one request, timeout), or a pasted URL.
import { createServer } from "node:http";
import { timingSafeEqual } from "node:crypto";
import { createInterface } from "node:readline";
import { CliError } from "./shared.mjs";

const PAGE = "<!doctype html><title>Signed in</title><p>You can close this tab and return to the terminal.</p>";

/**
 * Compares two strings in constant time.
 */
function sameSecret(a, b) {
  const x = Buffer.from(String(a));
  const y = Buffer.from(String(b));
  return x.length === y.length && timingSafeEqual(x, y);
}

/**
 * Starts the loopback listener on 127.0.0.1 and a random port. Returns the redirect URI and a promise for the
 * first request to /callback (its code and iss). The promise rejects on a wrong state, an error or the timeout.
 */
export async function listen({ state, timeoutMs }) {
  let finish;
  let fail;
  const result = new Promise((resolve, reject) => {
    finish = resolve;
    fail = reject;
  });
  const server = createServer((req, res) => {
    const url = new URL(req.url, "http://127.0.0.1");
    if (url.pathname !== "/callback") {
      res.writeHead(404).end();
      return;
    }
    const ok = !url.searchParams.has("error") && sameSecret(url.searchParams.get("state") ?? "", state);
    res.writeHead(ok ? 200 : 400, { "content-type": "text/html" }).end(ok ? PAGE : "Sign-in failed.");
    if (url.searchParams.has("error")) {
      fail(new CliError(`sign-in was refused: ${url.searchParams.get("error")}`));
    } else if (!ok) {
      fail(new CliError("the sign-in response had the wrong state; stopped"));
    } else if (!url.searchParams.get("code")) {
      fail(new CliError("the sign-in response had no code"));
    } else {
      finish({ code: url.searchParams.get("code"), iss: url.searchParams.get("iss") });
    }
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const timer = setTimeout(() => fail(new CliError("timed out after 5 minutes waiting for the sign-in")), timeoutMs);
  return {
    redirectUri: `http://127.0.0.1:${server.address().port}/callback`,
    result,
    /** Stops the listener and the timer. */
    close: () => {
      clearTimeout(timer);
      server.closeAllConnections();
      server.close();
    },
  };
}

/**
 * Reads one line from stdin (the redirect URL the user pastes) and returns its code and iss after a state check.
 * Aborting the signal stops the read.
 */
export async function readPastedRedirect({ state, signal, input = process.stdin }) {
  const rl = createInterface({ input, terminal: false });
  signal?.addEventListener("abort", () => rl.close());
  const line = await new Promise((resolve) => {
    rl.once("line", resolve);
    rl.once("close", () => resolve(""));
  });
  rl.close();
  if (signal?.aborted) throw new CliError("sign-in finished another way");
  let url;
  try {
    url = new URL(line.trim());
  } catch {
    throw new CliError("that is not a URL; paste the full address the browser was sent to");
  }
  if (url.searchParams.has("error")) throw new CliError(`sign-in was refused: ${url.searchParams.get("error")}`);
  if (!sameSecret(url.searchParams.get("state") ?? "", state)) {
    throw new CliError("the pasted URL had the wrong state; stopped");
  }
  const code = url.searchParams.get("code");
  if (!code) throw new CliError("the pasted URL has no code");
  return { code, iss: url.searchParams.get("iss") };
}
