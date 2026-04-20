#!/usr/bin/env bash
#
# tests/test-swift-swiftlint.sh — end-to-end regression for the swift
# .swiftlint.yml template. Scaffolds a swift project, builds it (which
# generates .build/), and runs `swiftlint --strict`. Asserts zero
# violations on a clean scaffold — the template's `excluded:` block must
# keep SwiftPM-generated build artifacts out of swiftlint's path.
#
# Skips gracefully when swift or swiftlint are not installed (Linux CI,
# bare runners). The unit-level coverage in test-bootstrap.sh and
# test-update.sh asserts the template lands in the right places without
# needing the real toolchain — this test is the integration backstop.
#
set -euo pipefail

TOUCHSTONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t touchstone-test-swift-swiftlint.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

echo "==> Test: swift profile ships .swiftlint.yml that survives swift build"
echo "    Test dir: $TEST_DIR/swift-app"

if ! command -v swift >/dev/null 2>&1; then
  echo "==> SKIP: swift toolchain not on PATH (Linux CI / bare runner — covered by unit tests)"
  exit 0
fi

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "==> SKIP: swiftlint not installed (covered by unit tests in test-bootstrap.sh / test-update.sh)"
  exit 0
fi

PROJECT="$TEST_DIR/swift-app"
bash "$TOUCHSTONE_ROOT/bootstrap/new-project.sh" "$PROJECT" --no-register --type swift >/dev/null

# Sanity: scaffold dropped the template.
if [ ! -f "$PROJECT/.swiftlint.yml" ]; then
  echo "FAIL: scaffold did not create .swiftlint.yml" >&2
  exit 1
fi

# `swift build` populates .build/arm64-apple-macosx/debug/... with derived
# Swift sources (XCTest runners, LinuxMain shims). Without the template's
# `excluded:` block, those files would dominate `swiftlint --strict`.
echo "==> swift build (generates .build/)"
if ! (cd "$PROJECT" && swift build) >"$TEST_DIR/swift-build.log" 2>&1; then
  echo "FAIL: swift build failed on a clean touchstone scaffold" >&2
  echo "---- swift build log ----" >&2
  cat "$TEST_DIR/swift-build.log" >&2
  exit 1
fi

# .build/ must exist after the build — otherwise the regression test isn't
# actually exercising the case the template guards against.
if [ ! -d "$PROJECT/.build" ]; then
  echo "FAIL: swift build did not produce .build/ — regression test cannot exercise the exclude" >&2
  exit 1
fi

echo "==> swiftlint --strict (must report zero violations)"
if ! (cd "$PROJECT" && swiftlint --strict) >"$TEST_DIR/swiftlint.log" 2>&1; then
  echo "FAIL: swiftlint --strict failed on a clean touchstone scaffold" >&2
  echo "---- swiftlint log (head 50) ----" >&2
  head -50 "$TEST_DIR/swiftlint.log" >&2
  echo "---- (truncated) ----" >&2
  exit 1
fi

# Defense in depth: even if `swiftlint --strict` exits 0, surface a warning
# count > 0 so a future template regression that downgrades violations from
# error to warning still fails the test.
if grep -Eq 'Found [1-9][0-9]* (violation|warning)' "$TEST_DIR/swiftlint.log"; then
  echo "FAIL: swiftlint reported violations/warnings on a clean scaffold:" >&2
  grep -E 'Found [0-9]+ (violation|warning)' "$TEST_DIR/swiftlint.log" >&2
  exit 1
fi

echo "==> PASS: swift scaffold + swift build + swiftlint --strict reports zero violations"
