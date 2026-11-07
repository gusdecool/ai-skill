# Shared by pick-provider and board-watch. Source it; do not run it.

# Prints the orca binary to run: ORCA_BIN, else orca on PATH, else the Orca app's own copy. Why: the Orca scheduler
# runs the precheck with a PATH that lacks the app's bin folder, so a bare `orca` fails there.
orca_bin() {
  if [ -n "${ORCA_BIN:-}" ]; then echo "$ORCA_BIN"
  elif command -v orca >/dev/null 2>&1; then command -v orca
  else echo "${ORCA_FALLBACK_BIN:-/Applications/Orca.app/Contents/Resources/bin/orca}"
  fi
}
