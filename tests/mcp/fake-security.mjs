#!/usr/bin/env node
// Stand-in for the macOS `security` command, so tests never touch the real keychain.
// Entries are files under FAKE_KEYCHAIN_DIR. Every argv is logged to argv.log to prove no secret is passed there.
// FAKE_KEYCHAIN_TRUNCATE=<n> cuts stored values to n characters, like the real `security -i` does near 4096.
import { appendFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const dir = process.env.FAKE_KEYCHAIN_DIR;
mkdirSync(dir, { recursive: true });
appendFileSync(join(dir, "argv.log"), `${JSON.stringify(process.argv.slice(2))}\n`);

/**
 * Returns the value of a flag such as -s or -a from an argument list.
 */
const flag = (args, name) => args[args.indexOf(name) + 1];

/**
 * Returns the file that holds one entry.
 */
const entry = (args) => join(dir, `entry-${flag(args, "-s")}-${flag(args, "-a")}`);

/**
 * Runs one keychain command given as an argument list.
 */
function command(args) {
  const [verb] = args;
  if (verb === "add-generic-password") {
    const limit = Number(process.env.FAKE_KEYCHAIN_TRUNCATE || Infinity);
    writeFileSync(entry(args), flag(args, "-w").slice(0, limit));
    return 0;
  }
  if (verb === "find-generic-password") {
    if (!existsSync(entry(args))) {
      process.stderr.write("security: The specified item could not be found in the keychain.\n");
      return 44;
    }
    process.stdout.write(`${readFileSync(entry(args), "utf8")}\n`);
    return 0;
  }
  if (verb === "delete-generic-password") {
    if (!existsSync(entry(args))) return 44;
    rmSync(entry(args));
    return 0;
  }
  process.stderr.write(`fake security: unsupported command ${verb}\n`);
  return 1;
}

if (process.argv[2] === "-i") {
  let status = 0;
  for (const line of readFileSync(0, "utf8").split("\n").filter(Boolean)) status ||= command(line.split(" "));
  process.exit(status);
}
process.exit(command(process.argv.slice(2)));
