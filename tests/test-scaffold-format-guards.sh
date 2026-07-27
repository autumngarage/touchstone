#!/usr/bin/env bash
#
# Verify a fresh generic scaffold's formatting hooks are executable contracts:
# every referenced config exists, markdownlint runs, and shfmt rejects drift.
#
set -euo pipefail

exec </dev/null

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-scaffold-format.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

if ! command -v pre-commit >/dev/null 2>&1; then
  echo "FAIL: pre-commit is required for scaffold formatting contract tests" >&2
  exit 1
fi

PROJECT="$TEST_DIR/generic-project"
TEST_HOME="$TEST_DIR/home"
mkdir -p "$TEST_HOME"

HOME="$TEST_HOME" YES_MODE=true bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" \
  "$PROJECT" \
  --no-register \
  --type generic \
  --reviewer none \
  --no-gitbutler \
  --no-ci \
  --no-with-cortex \
  --no-with-sentinel \
  >/dev/null

if [ ! -f "$PROJECT/.markdownlint.json" ]; then
  echo "FAIL: generic scaffold omitted the markdownlint config referenced by pre-commit" >&2
  exit 1
fi

printf '# Valid heading\n' >"$PROJECT/formatting.md"
if ! (cd "$PROJECT" && pre-commit run markdownlint --files formatting.md); then
  echo "FAIL: generated markdownlint hook could not run against its config" >&2
  exit 1
fi

cat >"$PROJECT/format-drift.sh" <<'EOF'
#!/usr/bin/env bash
if true;then
echo drift
fi
EOF

if (cd "$PROJECT" && pre-commit run shfmt --files format-drift.sh); then
  echo "FAIL: generated shfmt hook accepted formatting drift" >&2
  exit 1
fi

if ! grep -q '^if true;then$' "$PROJECT/format-drift.sh"; then
  echo "FAIL: drift-enforcement hook must reject, not rewrite, the source file" >&2
  exit 1
fi

echo "==> PASS: scaffold formatting hooks share deterministic preflight semantics"
