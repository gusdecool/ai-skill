#!/usr/bin/env bash
# Shared settings and helpers for the board-worker scripts. Source this file, do not run it.
# Settings come from the user's config file, so the skill names no organization. Run board-setup to create it.
# Config file: ${BOARD_WORKER_CONFIG:-$HOME/.config/board-worker/config}, plain KEY=VALUE lines:
#   BOARD_OWNER=<owner of the GitHub Project>  BOARD_PROJECT=<project number>
#   BOARD_ALLOWED_OWNERS=<comma-separated repo owners the worker may act on and merge in>

BOARD_CONFIG_FILE="${BOARD_WORKER_CONFIG:-$HOME/.config/board-worker/config}"

# Prints the value of KEY from the config file (last assignment wins). The file is parsed, never sourced.
board_config_value() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$BOARD_CONFIG_FILE" | tail -n 1 | tr -d '\r"'"'"
}

# Loads and validates the config into BOARD_OWNER, BOARD_PROJECT and BOARD_ALLOWED_OWNERS. Returns 2 with one stderr
# line when the file is missing or a value is invalid.
board_load_config() {
  if [ ! -r "$BOARD_CONFIG_FILE" ]; then
    echo "board-worker: no config at $BOARD_CONFIG_FILE; run $(dirname "${BASH_SOURCE[0]}")/board-setup" >&2
    return 2
  fi
  BOARD_OWNER="$(board_config_value BOARD_OWNER)"
  BOARD_PROJECT="$(board_config_value BOARD_PROJECT)"
  BOARD_ALLOWED_OWNERS="$(board_config_value BOARD_ALLOWED_OWNERS)"
  if ! [[ "$BOARD_OWNER" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ && "$BOARD_PROJECT" =~ ^[0-9]+$ \
    && "$BOARD_ALLOWED_OWNERS" =~ ^[A-Za-z0-9][A-Za-z0-9-]*(,[A-Za-z0-9][A-Za-z0-9-]*)*$ ]]; then
    echo "board-worker: invalid or incomplete config at $BOARD_CONFIG_FILE; run board-setup again" >&2
    return 2
  fi
}

# Exits 0 when the repo's owner is one of BOARD_ALLOWED_OWNERS, 1 otherwise.
board_owner_allowed() {
  case ",$BOARD_ALLOWED_OWNERS," in
    *",${1%%/*},"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Prints every item on the board as JSON, up to 500 items.
board_items() {
  gh project item-list "$BOARD_PROJECT" --owner "$BOARD_OWNER" --format json --limit 500
}

board_load_config || exit 2
