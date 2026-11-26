#!/usr/bin/env node
// Stand-in for the user's browser: opens the sign-in address, follows the redirects back to the loopback listener.
const response = await fetch(process.argv[2], { redirect: "follow" });
await response.arrayBuffer();
