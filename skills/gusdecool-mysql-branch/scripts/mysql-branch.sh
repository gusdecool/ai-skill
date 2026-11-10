#!/usr/bin/env bash
# gusdecool-mysql-branch: one MySQL database per git branch, cloned from a template database, for a MySQL running in Docker.
# Usage: mysql-branch.sh <template|create|use|name|list|drop> [branch] [--schema-only] [--yes]
set -euo pipefail

CONTAINER="${MYSQL_BRANCH_CONTAINER:-mysql}"
DB_USER="${MYSQL_BRANCH_USER:-root}"
META_DB="mysql_branch_meta"
TEMPLATE_KEY="__template__"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG_FILE="$ROOT/.mysql-branch"

# Prints an error and exits 1.
die() { echo "gusdecool-mysql-branch: $*" >&2; exit 1; }

# Runs a MySQL client tool (mysql, mysqldump) inside the container; the password never hits a command line.
client() {
  local tool="$1"; shift
  docker exec -i -e "MYSQL_BRANCH_PASSWORD=${MYSQL_BRANCH_PASSWORD:-}" -e "U=$DB_USER" "$CONTAINER" sh -c \
    'MYSQL_PWD="${MYSQL_BRANCH_PASSWORD:-$MYSQL_ROOT_PASSWORD}" exec "$0" -u"$U" "$@"' "$tool" "$@"
}

# Runs one SQL statement and prints raw rows without headers.
sql() { client mysql -N -e "$1"; }

# Escapes a string for use inside a single-quoted SQL literal.
esc() { local s="${1//\\/\\\\}"; printf '%s' "${s//\'/\'\'}"; }

# Reads one key from the .mysql-branch file.
cfg() {
  [ -f "$CONFIG_FILE" ] || die "no .mysql-branch file in $ROOT (see the skill's SKILL.md)"
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONFIG_FILE" | head -n1 |
    sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//'
}

# Loads and validates app and source from the config file.
load_config() {
  APP="$(cfg app)"; SOURCE="$(cfg source)"
  [[ "$APP" =~ ^[A-Za-z0-9_]{1,40}$ ]] || die "config 'app' must match [A-Za-z0-9_]{1,40}"
  [[ "$SOURCE" =~ ^[A-Za-z0-9_]{1,64}$ ]] || die "config 'source' must match [A-Za-z0-9_]{1,64}"
  TEMPLATE_DB="${APP}_template"
}

# Prints the current git branch, failing on a detached HEAD.
current_branch() {
  local b; b="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)" || die "not a git repo; pass a branch name"
  [ "$b" != "HEAD" ] || die "detached HEAD; pass a branch name"
  echo "$b"
}

# Turns a branch name into a lowercase [a-z0-9_] slug.
slugify() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g; s/__*/_/g; s/^_//; s/_$//'; }

# Prints the database name for a branch: <app>_<slug>, cut to 64 chars with a sha1 suffix when too long.
db_name() {
  local slug full hash; slug="$(slugify "$1")"
  [ -n "$slug" ] || die "branch '$1' has no usable characters"
  [ "$slug" != "template" ] || die "branch slug 'template' is reserved"
  full="${APP}_${slug}"
  if [ ${#full} -gt 64 ]; then
    hash="$(printf '%s' "$1" | shasum | cut -c1-6)"; full="${full:0:57}_${hash}"
  fi
  echo "$full"
}

# Creates the registry table that records every database this tool made.
ensure_meta() {
  sql "CREATE DATABASE IF NOT EXISTS $META_DB;
       CREATE TABLE IF NOT EXISTS $META_DB.branches (db_name VARCHAR(64) PRIMARY KEY, app VARCHAR(64) NOT NULL,
       branch VARCHAR(255) NOT NULL, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);" >/dev/null
}

# True when the database exists on the server.
db_exists() { [ "$(sql "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='$1'")" = "1" ]; }

# True when the database is in the registry.
is_registered() { [ "$(sql "SELECT COUNT(*) FROM $META_DB.branches WHERE db_name='$1'")" = "1" ]; }

# Copies schema (and data unless $3 is --schema-only) from database $1 into the existing database $2.
copy_db() {
  local flags=(--single-transaction --routines --triggers --events)
  [ "${3:-}" = "--schema-only" ] && flags+=(--no-data)
  client mysqldump "${flags[@]}" "$1" | client mysql "$2"
}

# Creates database $1 using the charset and collation of database $2 (or server defaults).
create_like() {
  local cs col
  cs="$(sql "SELECT default_character_set_name FROM information_schema.schemata WHERE schema_name='$2'")"
  col="$(sql "SELECT default_collation_name FROM information_schema.schemata WHERE schema_name='$2'")"
  sql "CREATE DATABASE \`$1\` CHARACTER SET ${cs:-utf8mb4} COLLATE ${col:-utf8mb4_0900_ai_ci}" >/dev/null
}

# Records a database in the registry.
register() {
  sql "INSERT INTO $META_DB.branches (db_name, app, branch) VALUES ('$1', '$APP', '$(esc "$2")')" >/dev/null
}

# Splits the arguments into BRANCH (optional positional), SCHEMA_ONLY and YES.
parse_args() {
  BRANCH=""; SCHEMA_ONLY=""; YES=""
  local a
  for a in "$@"; do
    case "$a" in
      --schema-only) SCHEMA_ONLY="--schema-only" ;;
      --yes) YES=1 ;;
      -*) die "unknown flag $a" ;;
      *) BRANCH="$a" ;;
    esac
  done
}

# Rebuilds <app>_template from the source database.
cmd_template() {
  parse_args "$@"; load_config; ensure_meta
  db_exists "$SOURCE" || die "source database '$SOURCE' does not exist"
  if db_exists "$TEMPLATE_DB"; then
    is_registered "$TEMPLATE_DB" || die "'$TEMPLATE_DB' was not created by gusdecool-mysql-branch; refusing to drop it"
    sql "DROP DATABASE \`$TEMPLATE_DB\`; DELETE FROM $META_DB.branches WHERE db_name='$TEMPLATE_DB'" >/dev/null
  fi
  create_like "$TEMPLATE_DB" "$SOURCE"
  copy_db "$SOURCE" "$TEMPLATE_DB" "$SCHEMA_ONLY"
  register "$TEMPLATE_DB" "$TEMPLATE_KEY"
  echo "Template $TEMPLATE_DB built from $SOURCE${SCHEMA_ONLY:+ (schema only)}"
}

# Clones the template into the branch database, registers it, then points the env file at it.
cmd_create() {
  parse_args "$@"; load_config; ensure_meta
  local branch="${BRANCH:-$(current_branch)}" db
  db="$(db_name "$branch")"
  db_exists "$TEMPLATE_DB" || die "template '$TEMPLATE_DB' not found; run: mysql-branch.sh template"
  db_exists "$db" && die "database '$db' already exists"
  create_like "$db" "$TEMPLATE_DB"
  copy_db "$TEMPLATE_DB" "$db" "$SCHEMA_ONLY"
  register "$db" "$branch"
  echo "Created $db"
  if [ -n "$(cfg env_file)" ]; then cmd_use "$branch"; fi
}

# Prints the awk program that rewrites the database name in one env var.
rewrite_awk() {
  cat <<'AWK'
BEGIN { v = ENVIRON["MB_VAR"]; d = ENVIRON["MB_DB"] }
{
  if (match($0, "^[ \t]*(export[ \t]+)?" v "=")) {
    head = substr($0, 1, RLENGTH); val = substr($0, RLENGTH + 1)
    if (match(val, /^["']?[A-Za-z0-9+.-]+:\/\/[^\/]*\//)) {
      pre = substr(val, 1, RLENGTH); rest = substr(val, RLENGTH + 1)
      match(rest, /^[^?"' \t#]*/)
      print head pre d substr(rest, RLENGTH + 1)
    } else {
      q = substr(val, 1, 1); if (q != "\"" && q != "'") q = ""
      print head q d q
    }
  } else print
}
AWK
}

# Rewrites env_var in env_file to the branch database name.
cmd_use() {
  parse_args "$@"; load_config; ensure_meta
  local branch="${BRANCH:-$(current_branch)}" db envf var tmp
  db="$(db_name "$branch")"
  is_registered "$db" || die "'$db' is not a gusdecool-mysql-branch database; run: mysql-branch.sh create $branch"
  envf="$ROOT/$(cfg env_file)"; var="$(cfg env_var)"
  [ -f "$envf" ] || die "env file $envf not found"
  [[ "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "config 'env_var' is missing or invalid"
  grep -Eq "^[[:space:]]*(export[[:space:]]+)?$var=" "$envf" || die "$var not found in $envf; add it first"
  tmp="$(mktemp)"
  MB_VAR="$var" MB_DB="$db" awk -f <(rewrite_awk) "$envf" >"$tmp"
  cat "$tmp" >"$envf"; rm -f "$tmp"
  echo "Set $var in $(basename "$envf") to use $db"
}

# Prints the database name for a branch.
cmd_name() { parse_args "$@"; load_config; db_name "${BRANCH:-$(current_branch)}"; }

# Lists registered databases for this app: template, active, or stale (git branch gone).
cmd_list() {
  load_config; ensure_meta
  local rows db branch status cur=""
  cur="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  rows="$(sql "SELECT db_name, branch FROM $META_DB.branches WHERE app='$(esc "$APP")' ORDER BY db_name")"
  [ -n "$rows" ] || { echo "No gusdecool-mysql-branch databases for $APP"; return 0; }
  while IFS=$'\t' read -r db branch; do
    if [ "$branch" = "$TEMPLATE_KEY" ]; then status="template"
    elif git -C "$ROOT" show-ref --verify --quiet "refs/heads/$branch"; then status="active"
    else status="stale (git branch gone)"; fi
    printf '%s %-40s %-8s %s\n' "$([ "$branch" = "$cur" ] && echo '*' || echo ' ')" "$db" "$status" "$branch"
  done <<<"$rows"
}

# Drops a registered branch database; needs --yes.
cmd_drop() {
  parse_args "$@"; load_config; ensure_meta
  local branch="${BRANCH:-$(current_branch)}" db
  db="$(db_name "$branch")"
  is_registered "$db" || die "'$db' was not created by gusdecool-mysql-branch; refusing to drop it"
  if [ -z "$YES" ]; then echo "Would drop $db. Re-run with --yes to confirm."; exit 2; fi
  sql "DROP DATABASE \`$db\`; DELETE FROM $META_DB.branches WHERE db_name='$db'" >/dev/null
  echo "Dropped $db"
}

case "${1:-}" in
  template) shift; cmd_template "$@" ;;
  create) shift; cmd_create "$@" ;;
  use) shift; cmd_use "$@" ;;
  name) shift; cmd_name "$@" ;;
  list) shift; cmd_list "$@" ;;
  drop) shift; cmd_drop "$@" ;;
  *) echo "Usage: mysql-branch.sh <template|create|use|name|list|drop> [branch] [--schema-only] [--yes]" >&2; exit 1 ;;
esac
