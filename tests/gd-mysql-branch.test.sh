#!/usr/bin/env bash
# Integration tests for mysql-branch.sh against a throwaway mysql:8.0 container.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/skills/gd-mysql-branch/scripts/mysql-branch.sh"
export MYSQL_BRANCH_CONTAINER="mb-test-$$"
export MYSQL_BRANCH_PASSWORD="testpw"
WORK="$(mktemp -d)"
FAILS=0

# Removes the test container and temp dir.
# shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap
cleanup() { docker rm -f "$MYSQL_BRANCH_CONTAINER" >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT

# Records a failure when two values differ.
assert_eq() {
  if [ "$2" != "$3" ]; then echo "FAIL: $1 (expected '$2', got '$3')"; FAILS=$((FAILS + 1)); else echo "ok: $1"; fi
}

# Runs a SQL statement as root in the test container and prints raw rows.
sql() { docker exec -i "$MYSQL_BRANCH_CONTAINER" mysql -uroot -ptestpw -N -e "$1" 2>/dev/null; }

# Runs the script inside the temp git repo.
mb() { (cd "$WORK/repo" && bash "$SCRIPT" "$@"); }

echo "Starting MySQL container..."
docker run -d --name "$MYSQL_BRANCH_CONTAINER" -e MYSQL_ROOT_PASSWORD=testpw mysql:8.0 >/dev/null
for _ in $(seq 1 90); do
  [ "$(docker logs "$MYSQL_BRANCH_CONTAINER" 2>&1 | grep -c 'ready for connections.*port: 3306')" -ge 1 ] && break
  sleep 1
done
until sql "SELECT 1" >/dev/null; do sleep 1; done

mkdir -p "$WORK/repo" && cd "$WORK/repo" || exit 1
git init -q -b main . && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
printf 'app=shop\nsource=shop_dev\nenv_file=.env.local\nenv_var=DATABASE_URL\n' >.mysql-branch
printf 'APP_ENV=dev\nDATABASE_URL="mysql://u:p@127.0.0.1:3306/shop_dev?serverVersion=8.0"\n' >.env.local
sql "CREATE DATABASE shop_dev; CREATE TABLE shop_dev.items (id INT PRIMARY KEY, name VARCHAR(20));
     INSERT INTO shop_dev.items VALUES (1,'a'),(2,'b');"

# template
mb template >/dev/null
assert_eq "template copies rows" "2" "$(sql 'SELECT COUNT(*) FROM shop_template.items')"

# create + isolation + use (URL value)
git checkout -q -b feat/Login-Page
mb create >/dev/null
assert_eq "branch db name" "shop_feat_login_page" "$(mb name)"
assert_eq "branch copies rows" "2" "$(sql 'SELECT COUNT(*) FROM shop_feat_login_page.items')"
sql "INSERT INTO shop_feat_login_page.items VALUES (3,'c')"
assert_eq "writes stay in the branch" "2" "$(sql 'SELECT COUNT(*) FROM shop_dev.items')"
assert_eq "env url rewritten, rest kept" \
  'DATABASE_URL="mysql://u:p@127.0.0.1:3306/shop_feat_login_page?serverVersion=8.0"' "$(grep DATABASE_URL .env.local)"
assert_eq "other env lines untouched" "APP_ENV=dev" "$(grep APP_ENV .env.local)"

# create twice fails and keeps data
mb create >/dev/null 2>&1; assert_eq "second create fails" "1" "$?"
assert_eq "data kept after failed create" "3" "$(sql 'SELECT COUNT(*) FROM shop_feat_login_page.items')"

# schema-only
mb create fix/schema-only --schema-only >/dev/null
assert_eq "schema-only has table" "1" \
  "$(sql "SELECT COUNT(*) FROM information_schema.tables
          WHERE table_schema='shop_fix_schema_only' AND table_name='items'")"
assert_eq "schema-only has no rows" "0" "$(sql 'SELECT COUNT(*) FROM shop_fix_schema_only.items')"

# use with a plain quoted value
printf 'DB_NAME="shop_dev"\n' >.env.plain
printf 'app=shop\nsource=shop_dev\nenv_file=.env.plain\nenv_var=DB_NAME\n' >.mysql-branch
mb use fix/schema-only >/dev/null
assert_eq "plain value replaced, quotes kept" 'DB_NAME="shop_fix_schema_only"' "$(cat .env.plain)"
mb use no/such-branch >/dev/null 2>&1; assert_eq "use on unregistered branch fails" "1" "$?"

# long names: valid length, stable
LONG="feature/$(printf 'x%.0s' $(seq 1 80))"
N1="$(mb name "$LONG")"; N2="$(mb name "$LONG")"
assert_eq "long name is at most 64 chars" "1" "$([ ${#N1} -le 64 ] && echo 1 || echo 0)"
assert_eq "long name is stable" "$N1" "$N2"

# template refuses to overwrite an unregistered database
printf 'app=other\nsource=shop_dev\nenv_file=.env.plain\nenv_var=DB_NAME\n' >.mysql-branch
sql "CREATE DATABASE other_template"
mb template >/dev/null 2>&1; assert_eq "template refuses unregistered target" "1" "$?"
printf 'app=shop\nsource=shop_dev\nenv_file=.env.plain\nenv_var=DB_NAME\n' >.mysql-branch

# list: active vs stale
git branch -q fix/schema-only
mb create gone/branch >/dev/null
LIST="$(mb list)"
assert_eq "list marks active" "1" "$(grep -c 'shop_fix_schema_only.*active' <<<"$LIST")"
assert_eq "list marks stale" "1" "$(grep -c 'shop_gone_branch.*stale' <<<"$LIST")"
assert_eq "list marks template" "1" "$(grep -c 'shop_template.*template' <<<"$LIST")"

# drop
mb drop gone/branch >/dev/null 2>&1; assert_eq "drop without --yes exits 2" "2" "$?"
assert_eq "drop without --yes keeps db" "1" \
  "$(sql "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='shop_gone_branch'")"
mb drop gone/branch --yes >/dev/null
assert_eq "drop --yes removes db" "0" \
  "$(sql "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='shop_gone_branch'")"
sql "CREATE DATABASE shop_manual"
mb drop manual --yes >/dev/null 2>&1; assert_eq "drop refuses unregistered db" "1" "$?"
assert_eq "unregistered db survives" "1" \
  "$(sql "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='shop_manual'")"
mb drop template --yes >/dev/null 2>&1; assert_eq "drop refuses template" "1" "$?"

echo; [ "$FAILS" -eq 0 ] && echo "All tests passed" || echo "$FAILS test(s) failed"
exit "$FAILS"
