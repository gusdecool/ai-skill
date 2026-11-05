#!/usr/bin/env bash
# Shared settings and helpers for the board-worker scripts. Source this file, do not run it.

# GitHub Project number of the BM board.
BOARD_PROJECT=9
# Owner that holds the BM board.
BOARD_OWNER=bungamata

# Exits 0 when the repo's owner is one the board may act on (gusdecool or bungamata), 1 otherwise.
board_owner_allowed() {
  case "${1%%/*}" in
    gusdecool | bungamata) return 0 ;;
    *) return 1 ;;
  esac
}

# Prints every item on the BM board as JSON, up to 500 items.
board_items() {
  gh project item-list "$BOARD_PROJECT" --owner "$BOARD_OWNER" --format json --limit 500
}
