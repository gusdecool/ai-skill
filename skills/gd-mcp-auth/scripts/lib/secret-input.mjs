// Reads a secret from stdin without echo, so a token never appears on screen or in a command line.
import { CliError } from "./shared.mjs";

/**
 * Reads the whole of a piped stdin and returns it trimmed.
 */
async function readPiped(input) {
  const chunks = [];
  for await (const chunk of input) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8").trim();
}

/**
 * Reads typed characters in raw mode with no echo until Enter. Backspace works; Ctrl-C cancels.
 */
function readHidden(input, prompt) {
  return new Promise((resolve, reject) => {
    process.stderr.write(prompt);
    input.setRawMode(true);
    input.resume();
    input.setEncoding("utf8");
    let value = "";
    const done = (action) => {
      input.setRawMode(false);
      input.pause();
      input.off("data", onData);
      process.stderr.write("\n");
      action();
    };
    const onData = (chars) => {
      for (const char of chars) {
        if (char === "\r" || char === "\n") return done(() => resolve(value.trim()));
        if (char === "\u0003") return done(() => reject(new CliError("cancelled")));
        if (char === "\u007f" || char === "\b") value = value.slice(0, -1);
        else value += char;
      }
    };
    input.on("data", onData);
  });
}

/**
 * Returns a token typed with no echo (terminal) or piped on stdin. Throws when it is empty.
 */
export async function readSecret(prompt, input = process.stdin) {
  const value = input.isTTY ? await readHidden(input, prompt) : await readPiped(input);
  if (!value) throw new CliError("no token given");
  return value;
}
