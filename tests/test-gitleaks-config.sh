#!/usr/bin/env bash
# Verify the scaffolded Gitleaks configuration against the real scanner.
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-gitleaks.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "FAIL: gitleaks is required; run bash setup.sh" >&2
  exit 1
fi

PROJECT="$TEST_DIR/project"
mkdir -p "$PROJECT"
cp "$TOUCHSTONE_ROOT/templates/.gitleaks.toml" "$PROJECT/.gitleaks.toml"
cp "$TOUCHSTONE_ROOT/templates/.gitleaks.local.toml" "$PROJECT/.gitleaks.local.toml"
git -C "$PROJECT" init -q
git -C "$PROJECT" config user.email test@example.test
git -C "$PROJECT" config user.name "Touchstone Test"
git -C "$PROJECT" add .gitleaks.toml .gitleaks.local.toml
git -C "$PROJECT" commit -q -m "configure secret scanning"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

expect_rule() {
  local fixture="$1"
  local rule_id="$2"
  local report="$TEST_DIR/$rule_id.json"
  local scan_status=0

  (cd "$PROJECT" && gitleaks dir --config .gitleaks.toml --no-banner --redact=100 \
    --report-format json --report-path "$report" "$fixture") >/dev/null 2>&1 || scan_status=$?
  [ "$scan_status" -eq 1 ] || fail "$rule_id fixture exited $scan_status instead of reporting a leak"
  grep -q "\"RuleID\": \"$rule_id\"" "$report" \
    || fail "$rule_id was absent from its Gitleaks report"
}

expect_clean() {
  local fixture="$1"
  if ! (cd "$PROJECT" && gitleaks dir --config .gitleaks.toml --no-banner --redact=100 "$fixture") >/dev/null 2>&1; then
    fail "placeholder fixture was reported as a secret: $fixture"
  fi
}

printf 'DATABASE_URL=%s%s\n' 'postgres://convoy:' 'correct-horse-battery@db.internal/game' \
  >"$PROJECT/db-secret.txt"
expect_rule db-secret.txt db-uri-with-password

printf '%s\n' 'DATABASE_URL=postgres://${DB_USER}:correct-horse-battery@db.internal/game' \
  >"$PROJECT/db-placeholder-user-secret.txt"
expect_rule db-placeholder-user-secret.txt db-uri-with-password

printf '%s\n' 'REDIS_URL=redis://:correct-horse-battery@cache.internal/0' \
  >"$PROJECT/redis-secret.txt"
expect_rule redis-secret.txt db-uri-with-password

printf '%s\n' 'REDIS_URL=rediss://:correct-horse-battery@cache.internal/0' \
  >"$PROJECT/rediss-secret.txt"
expect_rule rediss-secret.txt db-uri-with-password

printf '%s\n' 'DATABASE_URL=postgresql+psycopg2://convoy:correct-horse-battery@db.internal/game' \
  >"$PROJECT/sqlalchemy-postgres-secret.txt"
expect_rule sqlalchemy-postgres-secret.txt db-uri-with-password

printf '%s\n' 'DATABASE_URL=mysql+pymysql://convoy:correct-horse-battery@db.internal/game' \
  >"$PROJECT/sqlalchemy-mysql-secret.txt"
expect_rule sqlalchemy-mysql-secret.txt db-uri-with-password
git -C "$PROJECT" add db-secret.txt
STAGED_REPORT="$TEST_DIR/staged.json"
STAGED_STATUS=0
(cd "$PROJECT" && gitleaks git --pre-commit --staged --no-banner --redact=100 \
  --report-format json --report-path "$STAGED_REPORT") >/dev/null 2>&1 || STAGED_STATUS=$?
[ "$STAGED_STATUS" -eq 1 ] || fail "pre-commit invocation did not load the repository config"
grep -q '"RuleID": "db-uri-with-password"' "$STAGED_REPORT" \
  || fail "pre-commit invocation did not apply the managed database rule"
git -C "$PROJECT" reset -q HEAD -- db-secret.txt

printf 'PGPASSWORD=%s\n' 'correct-horse-battery' >"$PROJECT/pg-secret.txt"
expect_rule pg-secret.txt pgpassword-env

printf '%s\n' 'PGPASSWORD=secret1234' >"$PROJECT/pg-placeholder-prefix-secret.txt"
expect_rule pg-placeholder-prefix-secret.txt pgpassword-env

printf '%s\n' 'PGPASSWORD=password-prod-db' >"$PROJECT/pg-password-prefix-secret.txt"
expect_rule pg-password-prefix-secret.txt pgpassword-env

{
  printf '%s\n' 'DATABASE_URL=postgres://convoy:${{Postgres.PGPASSWORD}}@db.internal/game'
  printf '%s\n' 'DATABASE_URL=postgres://convoy:${DB_PASSWORD}@db.internal/game'
  printf '%s\n' 'DATABASE_URL=postgres://convoy:<NEW_PASSWORD>@db.internal/game'
  printf '%s\n' 'REDIS_URL=rediss://:${REDIS_PASSWORD}@cache.internal/0'
  printf '%s\n' 'PGPASSWORD=${PGPASSWORD}'
  printf '%s\n' 'PGPASSWORD=changeme'
  printf '%s\n' 'PGPASSWORD=<NEW_PASSWORD>'
  printf '%s\n' 'PGPASSWORD=[PGPASSWORD]'
} >"$PROJECT/placeholders.txt"
expect_clean placeholders.txt

# Prove the managed wrapper preserves both Gitleaks defaults and project-local
# rules through the documented two-level configuration chain.
cat >>"$PROJECT/.gitleaks.local.toml" <<'EOF_LOCAL_RULE'

[[rules]]
id = "project-local-secret"
description = "Synthetic project-local rule"
regex = '''LOCAL_SECRET=[A-Za-z0-9_-]{12,}'''
EOF_LOCAL_RULE
printf 'LOCAL_SECRET=%s\n' 'projectownedvalue' >"$PROJECT/local-secret.txt"
expect_rule local-secret.txt project-local-secret

printf 'aws_access_key_id=%s%s\n' 'AKIA' 'QWERTYUIOPASDFGH' >"$PROJECT/default-secret.txt"
expect_rule default-secret.txt aws-access-token

echo "PASS: managed, default, and project-owned Gitleaks rules compose safely"
