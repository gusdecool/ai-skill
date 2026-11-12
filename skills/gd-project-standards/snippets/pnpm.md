---
version: 1
---

- Use pnpm, not npm.
- Enable it with `corepack enable pnpm` and install with `pnpm install --frozen-lockfile`.
- Never edit files inside `node_modules` (use `pnpm patch` instead).
- Pass script options straight after the script name: `pnpm run <script> --flag`.

Why: pnpm is faster and uses far less disk, because every worktree links its packages from one shared store
instead of copying them, which matters when several agents work in parallel worktrees.
