#!/usr/bin/env bash
# Shared settings and helpers for the gusdecool-board-worker scripts. Source this file, do not run it.
# Settings come from the user's config file, so the skill names no organization. Run board-setup to create it.
# Config file: ${BOARD_WORKER_CONFIG:-$HOME/.config/board-worker/config}, plain KEY=VALUE lines:
#   BOARD_ALLOWED_OWNERS=<comma-separated repo owners the worker may act on and merge in>
# Old BOARD_OWNER and BOARD_PROJECT lines (from the GitHub Project days) are ignored. The Jira credentials live in a
# separate file, see the Jira helpers below.
# Optional flags (enforced by scripts, never by the model, so issue text cannot change them):
#   BOARD_BLOCKED_VISIBILITIES=<comma list of public|internal|private, may be empty>  default: public
#   BOARD_ALLOW_INFRA_CHANGE=<true|false>  default: false (an infra change is never auto-merged)
#   BOARD_EXTRA_CICD_PATHS / BOARD_EXTRA_INFRA_PATHS=<comma-separated path globs>  default: none

BOARD_CONFIG_FILE="${BOARD_WORKER_CONFIG:-$HOME/.config/board-worker/config}"

# Prints the value of KEY from the config file (last assignment wins). The file is parsed, never sourced.
board_config_value() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$BOARD_CONFIG_FILE" | tail -n 1 | tr -d '\r"'"'"
}

# Exits 0 when the config file sets KEY at all, even to an empty value.
board_config_has() {
  grep -qE "^[[:space:]]*$1[[:space:]]*=" "$BOARD_CONFIG_FILE"
}

# Prints the config value of KEY, or the default ($2) when the key is not set at all.
board_flag() {
  if board_config_has "$1"; then board_config_value "$1"; else printf '%s' "$2"; fi
}

# Loads and validates the config into BOARD_ALLOWED_OWNERS and the optional flags. Returns 2 with one stderr line
# when the file is missing or a value is invalid.
board_load_config() {
  if [ ! -r "$BOARD_CONFIG_FILE" ]; then
    echo "gusdecool-board-worker: no config at $BOARD_CONFIG_FILE; run $(dirname "${BASH_SOURCE[0]}")/board-setup" >&2
    return 2
  fi
  BOARD_ALLOWED_OWNERS="$(board_config_value BOARD_ALLOWED_OWNERS)"
  BOARD_BLOCKED_VISIBILITIES="$(board_flag BOARD_BLOCKED_VISIBILITIES public)"
  BOARD_ALLOW_INFRA_CHANGE="$(board_flag BOARD_ALLOW_INFRA_CHANGE false)"
  BOARD_EXTRA_CICD_PATHS="$(board_config_value BOARD_EXTRA_CICD_PATHS)"
  BOARD_EXTRA_INFRA_PATHS="$(board_config_value BOARD_EXTRA_INFRA_PATHS)"
  if ! [[ "$BOARD_BLOCKED_VISIBILITIES" =~ ^((public|internal|private)(,(public|internal|private))*)?$ \
    && "$BOARD_ALLOW_INFRA_CHANGE" =~ ^(true|false)$ \
    && "$BOARD_EXTRA_CICD_PATHS$BOARD_EXTRA_INFRA_PATHS" =~ ^[A-Za-z0-9_./*?,-]*$ ]]; then
    echo "gusdecool-board-worker: invalid flag in $BOARD_CONFIG_FILE (see board-lib.sh for the allowed values)" >&2
    return 2
  fi
  if ! [[ "$BOARD_ALLOWED_OWNERS" =~ ^[A-Za-z0-9][A-Za-z0-9-]*(,[A-Za-z0-9][A-Za-z0-9-]*)*$ ]]; then
    echo "gusdecool-board-worker: invalid or incomplete config at $BOARD_CONFIG_FILE; run board-setup again" >&2
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

# Prints a repo's visibility (public, private or internal) in lower case. Returns 2 when it cannot be read.
board_repo_visibility() {
  gh repo view "$1" --json visibility 2>/dev/null | jq -er '.visibility | ascii_downcase' || return 2
}

# Exits 0 when the repo's visibility is blocked by config, 1 when it is allowed, 2 when it cannot be read (treat as
# blocked: fail closed).
board_visibility_blocked() {
  local vis
  vis="$(board_repo_visibility "$1")" || return 2
  case ",$BOARD_BLOCKED_VISIBILITIES," in
    *",$vis,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- Jira helpers ---------------------------------------------------------------------------------------------------
# Jira Cloud REST API v2 with Basic auth. Config file: ${BOARD_JIRA_CONFIG:-$HOME/.config/board-worker/jira}, lines:
#   JIRA_SITE='https://x.atlassian.net'  JIRA_EMAIL='a@b.c'  JIRA_TOKEN='<api token>'  JIRA_PROJECT=BM (optional)
# The config is loaded lazily by the first Jira call, never when this file is sourced.

# Prints the unquoted value of KEY from the Jira config file (last assignment wins). The file is parsed, never
# sourced, and exactly one pair of surrounding quotes is removed so tokens keep their characters.
jira_config_value() {
  local file="${BOARD_JIRA_CONFIG:-$HOME/.config/board-worker/jira}" line value="" re
  [ -r "$file" ] || return 1
  re="^[[:space:]]*$1[[:space:]]*=[[:space:]]*(.*)$"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ $re ]]; then value="${BASH_REMATCH[1]}"; fi
  done <"$file"
  value="${value%"${value##*[![:space:]]}"}"
  if [[ "$value" =~ ^\'(.*)\'$ ]] || [[ "$value" =~ ^\"(.*)\"$ ]]; then value="${BASH_REMATCH[1]}"; fi
  printf '%s' "$value"
}

# Loads and validates the Jira config into JIRA_SITE, JIRA_EMAIL, JIRA_TOKEN and JIRA_PROJECT, once per process.
# Returns 2 with one stderr line when the file is missing or a value is invalid.
jira_load_config() {
  [ -z "${JIRA_CONFIG_LOADED:-}" ] || return 0
  local file="${BOARD_JIRA_CONFIG:-$HOME/.config/board-worker/jira}" site email token project
  if [ ! -r "$file" ]; then
    echo "gusdecool-board-worker: no Jira config at $file" >&2
    return 2
  fi
  site="$(jira_config_value JIRA_SITE)"
  email="$(jira_config_value JIRA_EMAIL)"
  token="$(jira_config_value JIRA_TOKEN)"
  project="$(jira_config_value JIRA_PROJECT)"
  [ -n "$project" ] || project="BM"
  if ! [[ "$site" =~ ^https://[A-Za-z0-9.-]+$ && "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+$ \
    && "$project" =~ ^[A-Z][A-Z0-9]+$ && -n "$token" && ! "$token" =~ [[:space:]] ]]; then
    echo "gusdecool-board-worker: invalid or incomplete Jira config at $file (JIRA_SITE, JIRA_EMAIL, JIRA_TOKEN)" >&2
    return 2
  fi
  JIRA_SITE="$site"
  JIRA_EMAIL="$email"
  JIRA_TOKEN="$token"
  JIRA_PROJECT="$project"
  JIRA_CONFIG_LOADED=1
}

# Calls the Jira REST API: jira_api METHOD PATH [JSON_BODY]. Prints the response body on 2xx and returns 0. Any other
# result prints one stderr line and returns 2. The token goes to curl on stdin only, never in its arguments.
jira_api() {
  local method="${1:-}" path="${2:-}" body="${3:-}" bodyfile="" resp status payload msg
  local -a args
  case "$method" in GET | POST | PUT | DELETE) ;; *)
    echo "gusdecool-board-worker: unsupported Jira method '$method'" >&2
    return 2
    ;;
  esac
  if ! [[ "$path" =~ ^/[^[:space:][:cntrl:]]*$ ]]; then
    echo "gusdecool-board-worker: invalid Jira path" >&2
    return 2
  fi
  jira_load_config || return 2
  args=(--silent --show-error --max-time 30 --config - --request "$method" --header 'Accept: application/json'
    --write-out '\n%{http_code}')
  if [ -n "$body" ]; then
    bodyfile="$(mktemp)" || return 2
    chmod 600 "$bodyfile"
    printf '%s' "$body" >"$bodyfile"
    args+=(--header 'Content-Type: application/json' --data-binary "@$bodyfile")
  fi
  # Credentials travel in a curl config on stdin, with backslash and double quote escaped.
  payload="$JIRA_EMAIL:$JIRA_TOKEN"
  payload="${payload//\\/\\\\}"
  payload="${payload//\"/\\\"}"
  if ! resp="$(printf 'user = "%s"\n' "$payload" | curl "${args[@]}" "$JIRA_SITE$path")"; then
    [ -z "$bodyfile" ] || rm -f "$bodyfile"
    echo "gusdecool-board-worker: Jira request failed (curl error)" >&2
    return 2
  fi
  [ -z "$bodyfile" ] || rm -f "$bodyfile"
  status="${resp##*$'\n'}"
  resp="${resp%$'\n'*}"
  case "$status" in
    2??)
      [ -z "$resp" ] || printf '%s\n' "$resp"
      return 0
      ;;
    401)
      echo "gusdecool-board-worker: Jira token rejected (HTTP 401): create a new API token" >&2
      return 2
      ;;
  esac
  msg="$(printf '%s' "$resp" | jq -r \
    '[(.errorMessages // [])[], ((.errors // {}) | .[])] | map(tostring) | .[0] // empty' 2>/dev/null)" || msg=""
  [ -n "$msg" ] || msg="$(printf '%s' "${resp:0:120}" | tr '\r\n' '  ')"
  echo "gusdecool-board-worker: Jira HTTP $status: $msg" >&2
  return 2
}

# Prints the ticket key from a key (BM-123) or a browse URL on the configured site. Returns 1 with no output for
# anything else, including a URL on another host once the site is loaded.
jira_key() {
  local value="${1:-}" host key
  local re_url='^https://([^/?#]+)/browse/([^/?#]+)/?([?#].*)?$'
  if [[ "$value" =~ $re_url ]]; then
    host="${BASH_REMATCH[1]}"
    key="${BASH_REMATCH[2]}"
    if [ -n "${JIRA_SITE:-}" ] && [ "$host" != "${JIRA_SITE#https://}" ]; then return 1; fi
  else
    key="$value"
  fi
  [[ "$key" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]] || return 1
  printf '%s\n' "$key"
}

# Runs a JQL search with the given comma-separated fields and follows nextPageToken. Prints one JSON array of all
# issues; never stops at the first page.
jira_search() {
  local jql fields page token="" pages="" count=0 last
  jira_load_config || return 2
  jql="$(jq -rn --arg v "$1" '$v|@uri')"
  fields="$(jq -rn --arg v "$2" '$v|@uri')"
  while :; do
    page="$(jira_api GET \
      "/rest/api/2/search/jql?jql=$jql&fields=$fields&maxResults=100${token:+&nextPageToken=$token}")" || return 2
    pages="$pages$page"$'\n'
    last="$(printf '%s' "$page" | jq -r '.isLast // false')" || return 2
    token="$(printf '%s' "$page" | jq -r '.nextPageToken // empty')" || return 2
    [ "$last" != "true" ] && [ -n "$token" ] || break
    token="$(jq -rn --arg v "$token" '$v|@uri')"
    count=$((count + 1))
    if [ "$count" -ge 200 ]; then
      echo "gusdecool-board-worker: Jira search returned more than 200 pages" >&2
      return 2
    fi
  done
  printf '%s' "$pages" | jq -s '[.[] | (.issues // [])[]]'
}

# Prints every open ticket of the Jira project as one JSON array (statusCategory is not Done, oldest first).
jira_board_items() {
  jira_load_config || return 2
  jira_search "project = $JIRA_PROJECT AND statusCategory != Done ORDER BY created ASC" \
    "summary,status,priority,components,labels,updated,created"
}

board_load_config || exit 2
