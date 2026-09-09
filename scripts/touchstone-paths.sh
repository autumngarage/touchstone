#!/usr/bin/env bash
#
# scripts/touchstone-paths.sh — classify a repository's paths against a
# declared, named path set.
#
# Usage:
#   touchstone paths classify --set NAME --policy FILE
#     (--base REV --head REV [--project DIR] | --paths-from FILE)  [--json]
#   touchstone paths match --set NAME --policy FILE PATH...
#   touchstone paths check --policy FILE
#
# A path set says what a path *is* ("these are documents"); what follows from
# that is each consumer's own rule. The point of declaring it once is that the
# same list stops being maintained by hand in a CI scoping script, a test that
# pins that script, and a prose restatement in a steering file, which is the
# state AUT-1242 was filed against.
#
# THE MATCHER IS GIT'S OWN. The patterns are gitignore's language, so rather
# than imitate it this writes the set to the `.git/info/exclude` of a scratch
# repository and asks `git check-ignore`. Anchoring, `**`, directory patterns,
# negation and last-match-wins are then correct by construction rather than by
# a reimplementation that drifts. Two things that scratch repository must get
# right, both of which were observed failing before they were handled:
#
#   * the user's global and system git config are neutralised, or a developer
#     whose `core.excludesFile` names `*.md` gets a different answer from CI
#     for the same declaration;
#   * `git init --template=` does not create `.git/info`, so the directory is
#     created before the exclude file is written. Writing it without the mkdir
#     fails, and a matcher that silently matched nothing would classify every
#     head as `none` — conservative here, but by accident rather than design.
#
# FAILURE IS NEVER AN EXEMPTION. Every error path exits non-zero and prints no
# classification. A caller may only treat `all` on a zero exit as a set match;
# anything else — including an unreadable policy, an unparseable pattern, or a
# diff that cannot be taken — means the ordinary rule applies. `classify` on an
# empty diff reports `none` for the same reason: no changed path is in the set,
# so nothing is exempt.
#
# TRUST. Only the policy-side source is read, and `--policy` is required. The
# repository-side source (AUT-1242) does not exist here deliberately: a set
# that decides whether review is required must not be editable from the head of
# the pull request being reviewed, and the way to guarantee that is to have no
# code path that can reach a repository-side declaration at all, rather than a
# precedence rule that one day resolves the wrong way.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  touchstone paths classify --set NAME --policy FILE
    (--base REV --head REV [--project DIR] | --paths-from FILE)  [--json]
  touchstone paths match --set NAME --policy FILE PATH...
  touchstone paths check --policy FILE
EOF
  exit 2
}

# Paths that decide what review means. A set that matched any of them could
# exempt its own definition or the machinery that enforces it, so a declaration
# matching one is refused when it is checked and again when it is used --
# `check` is the same function `derive-consumer-policy.sh` calls, so the
# refusal cannot be true at derivation and false at evaluation.
PROTECTED_PROBES=(
  ".github/workflows/validate.yml"
  ".github/workflows/review-gate.yml"
  ".github/workflows/any-workflow-name.yml"
  ".github/workflows/nested/any.yaml"
  ".github/review-gate/evaluate-v3.jq"
  ".github/review-binding/evaluate.jq"
  "policy/github/touchstone-main.json"
  "policy/github/consumers/example.json"
  ".touchstone.toml"
)

ACTION="${1:-}"
shift || true

SET_NAME=""
POLICY_FILE=""
BASE_REV=""
HEAD_REV=""
PROJECT_DIR=""
PATHS_FROM=""
JSON=false
OPERANDS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --set)
      [ "$#" -ge 2 ] && [ -n "$2" ] || {
        echo "ERROR: --set requires a non-empty name" >&2
        exit 2
      }
      SET_NAME="$2"
      shift 2
      ;;
    --policy)
      [ "$#" -ge 2 ] && [ -n "$2" ] || {
        echo "ERROR: --policy requires a non-empty file" >&2
        exit 2
      }
      # Absolute against the invoking directory before any cd, so --project
      # cannot rebind which policy file was meant.
      case "$2" in
        /*) POLICY_FILE="$2" ;;
        *) POLICY_FILE="$PWD/$2" ;;
      esac
      shift 2
      ;;
    --base)
      [ "$#" -ge 2 ] && [ -n "$2" ] || {
        echo "ERROR: --base requires a non-empty revision" >&2
        exit 2
      }
      BASE_REV="$2"
      shift 2
      ;;
    --head)
      [ "$#" -ge 2 ] && [ -n "$2" ] || {
        echo "ERROR: --head requires a non-empty revision" >&2
        exit 2
      }
      HEAD_REV="$2"
      shift 2
      ;;
    --project)
      [ "$#" -ge 2 ] && [ -n "$2" ] || {
        echo "ERROR: --project requires a non-empty directory" >&2
        exit 2
      }
      case "$2" in
        /*) PROJECT_DIR="$2" ;;
        *) PROJECT_DIR="$PWD/$2" ;;
      esac
      shift 2
      ;;
    --paths-from)
      # The changed paths, one per line, or `-` for stdin. The review gate is
      # the caller this exists for: a required workflow must not check out the
      # head it is judging, so it has GitHub's file list and no git range. The
      # classification below is the same code for both inputs -- only where the
      # path list comes from differs.
      [ "$#" -ge 2 ] && [ -n "$2" ] || {
        echo "ERROR: --paths-from requires a file, or - for stdin" >&2
        exit 2
      }
      if [ "$2" = "-" ]; then
        PATHS_FROM="-"
      else
        case "$2" in
          /*) PATHS_FROM="$2" ;;
          *) PATHS_FROM="$PWD/$2" ;;
        esac
      fi
      shift 2
      ;;
    --json)
      JSON=true
      shift
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        OPERANDS+=("$1")
        shift
      done
      ;;
    -*)
      echo "ERROR: unknown option: $1" >&2
      usage
      ;;
    *)
      OPERANDS+=("$1")
      shift
      ;;
  esac
done

command -v git >/dev/null 2>&1 || {
  echo "ERROR: git is required to match path sets" >&2
  exit 2
}
command -v jq >/dev/null 2>&1 || {
  echo "ERROR: jq is required to read a path-set declaration" >&2
  exit 2
}

[ -n "$POLICY_FILE" ] || {
  echo "ERROR: --policy FILE is required; the policy-side declaration is the only source a path set is read from" >&2
  exit 2
}
[ -f "$POLICY_FILE" ] || {
  echo "ERROR: policy file not found: $POLICY_FILE" >&2
  exit 2
}
jq -e . "$POLICY_FILE" >/dev/null 2>&1 || {
  echo "ERROR: policy file is not valid JSON: $POLICY_FILE" >&2
  exit 2
}

MATCH_DIR=""
PATTERNS_FILE=""
CHANGED_FILE=""
# Always returns 0. An EXIT trap whose last command fails replaces the status
# the script exited with, and this one failed whenever MATCH_DIR was unset:
# `exit 2` for an undeclared set arrived at the caller as 1, which for `match`
# is the ordinary "not in the set" answer. An input error reported as a clean
# negative is the exact shape of "failure is never an exemption" being broken.
cleanup() {
  [ -n "$MATCH_DIR" ] && rm -rf "$MATCH_DIR"
  # The patterns file is cleaned here too, not only on the success path: every
  # refusal below exits straight out of read_set or the self-exemption check,
  # which would otherwise leave one file per rejected invocation in TMPDIR.
  [ -n "$PATTERNS_FILE" ] && rm -f "$PATTERNS_FILE"
  [ -n "$CHANGED_FILE" ] && rm -f "$CHANGED_FILE"
  return 0
}
trap cleanup EXIT

# Write one set's patterns to a scratch repository and answer with git's own
# matcher. Neutralising global and system config is what makes the answer the
# same on a developer's machine and in CI.
matcher_init() {
  local patterns_file="$1"
  MATCH_DIR="$(mktemp -d -t touchstone-paths.XXXXXX)"
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    git -C "$MATCH_DIR" init -q --template= >/dev/null 2>&1 || {
    echo "ERROR: could not create the scratch repository the matcher needs" >&2
    exit 2
  }
  mkdir -p "$MATCH_DIR/.git/info"
  cp "$patterns_file" "$MATCH_DIR/.git/info/exclude"
}

# Normalisation and validation live here, in the one place both `match` and
# `classify` reach the matcher, rather than at each call site -- they disagreed
# once already, with `match` stripping a leading `./` and `classify` not.
#
# An absolute path is refused rather than answered. `check-ignore` errors on a
# path outside its repository, and the error was being swallowed into "not in
# the set" -- conservative for every consumer, but a wrong answer arrived at
# silently, which is the shape this whole surface is meant to avoid.
normalise_path() {
  local candidate="$1"
  case "$candidate" in
    "")
      echo "ERROR: an empty path cannot be classified" >&2
      exit 2
      ;;
    /*)
      echo "ERROR: path must be relative to the repository root, not absolute: $candidate" >&2
      exit 2
      ;;
  esac
  while [ "${candidate#./}" != "$candidate" ]; do candidate="${candidate#./}"; done
  printf '%s' "$candidate"
}

# 0 = the declared patterns match this path. `check-ignore -q` is the decision;
# `-v` is not, because with -v git also reports paths matched by a negated
# pattern and so its exit status stops meaning "ignored".
pattern_matches() {
  local target
  target="$(normalise_path "$1")" || exit 2
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    git -C "$MATCH_DIR" check-ignore --no-index -q -- "$target" 2>/dev/null
}

# 0 = this path decides what review means. These are never in any set, whatever
# a declaration says.
#
# This is the guarantee; the probe list below is only a diagnostic. Refusing
# declarations that match a fixed list of example paths is enumeration, and
# enumeration cannot be complete: a set naming `.github/workflows/deploy.yml`
# matches no probe, passes the refusal, and then classifies that workflow as
# part of the set -- which is precisely the self-service review bypass the
# policy-side declaration exists to prevent. Structural exclusion closes it for
# every path, including ones no probe list will ever name.
is_protected_path() {
  case "$1" in
    # `policy/github/`, not `policy/`: AUT-1242's invariant names "the policy",
    # and Touchstone's policy lives at that exact prefix. Protecting all of
    # `policy/` would silently change behaviour for any consumer that happens
    # to keep unrelated documents in a directory of that common name, which is
    # confusing rather than safe -- the guarantee should cover the machinery it
    # names and nothing else.
    .github/workflows/* | .github/review-gate/* | .github/review-binding/* | \
      policy/github/* | .touchstone.toml)
      return 0
      ;;
  esac
  return 1
}

# 0 = the path is in the set: the patterns match it AND it is not machinery
# that decides review.
in_set() {
  local target
  target="$(normalise_path "$1")" || exit 2
  is_protected_path "$target" && return 1
  pattern_matches "$target"
}

# Read one named set's patterns out of the policy file. A set that is not
# declared is an error, never an empty set: an empty set classifies every head
# as `none`, which is conservative for the review gate but would silently
# disable a consumer that used the set to skip a paid CI lane.
read_set() {
  local name="$1" out="$2"
  jq -e --arg n "$name" 'has("pathSets") and (.pathSets | has($n))' \
    "$POLICY_FILE" >/dev/null 2>&1 || {
    echo "ERROR: policy declares no path set named '$name': $POLICY_FILE" >&2
    exit 2
  }
  jq -e --arg n "$name" '
    (.pathSets[$n] | type) == "array" and (.pathSets[$n] | length) > 0
    and (.pathSets[$n] | all(type == "string" and length > 0))
  ' "$POLICY_FILE" >/dev/null 2>&1 || {
    echo "ERROR: path set '$name' must be a non-empty array of non-empty strings" >&2
    exit 2
  }
  jq -r --arg n "$name" '.pathSets[$n][]' "$POLICY_FILE" >"$out"
  # A pattern carrying a newline would smuggle a second rule past review of
  # the declaration; jq -r would have already split it, so compare counts.
  local declared emitted
  declared="$(jq -r --arg n "$name" '.pathSets[$n] | length' "$POLICY_FILE")"
  emitted="$(wc -l <"$out" | tr -d ' ')"
  [ "$declared" = "$emitted" ] || {
    echo "ERROR: path set '$name' contains a pattern with an embedded newline" >&2
    exit 2
  }
}

# Refuse a set that can match the machinery deciding what review means.
assert_not_self_exempting() {
  local name="$1" probe hits=()
  for probe in "${PROTECTED_PROBES[@]}"; do
    if pattern_matches "$probe"; then hits+=("$probe"); fi
  done
  [ "${#hits[@]}" -eq 0 ] || {
    echo "ERROR: path set '$name' matches paths that decide what review means, which no set may exempt:" >&2
    printf '  %s\n' "${hits[@]}" >&2
    exit 2
  }
}

json_array() {
  if [ "$#" -eq 0 ]; then
    printf '[]'
  else
    printf '%s\n' "$@" | jq -R . | jq -sc .
  fi
}

case "$ACTION" in
  check)
    [ "${#OPERANDS[@]}" -eq 0 ] || usage
    names="$(jq -r 'if has("pathSets") then (.pathSets | keys[]) else empty end' "$POLICY_FILE")"
    if [ -z "$names" ]; then
      echo "no path sets declared in $POLICY_FILE"
      exit 0
    fi
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      PATTERNS_FILE="$(mktemp -t touchstone-paths-patterns.XXXXXX)"
      read_set "$name" "$PATTERNS_FILE"
      matcher_init "$PATTERNS_FILE"
      assert_not_self_exempting "$name"
      cleanup
      MATCH_DIR=""
      PATTERNS_FILE=""
      echo "OK: path set '$name' exempts nothing that decides what review means"
    done <<<"$names"
    ;;

  match)
    [ -n "$SET_NAME" ] || usage
    [ "${#OPERANDS[@]}" -ge 1 ] || usage
    PATTERNS_FILE="$(mktemp -t touchstone-paths-patterns.XXXXXX)"
    read_set "$SET_NAME" "$PATTERNS_FILE"
    matcher_init "$PATTERNS_FILE"
    assert_not_self_exempting "$SET_NAME"
    rc=0
    for operand in "${OPERANDS[@]}"; do
      if in_set "$operand"; then
        echo "in  $operand"
      else
        echo "out $operand"
        rc=1
      fi
    done
    exit "$rc"
    ;;

  classify)
    [ -n "$SET_NAME" ] || usage
    [ "${#OPERANDS[@]}" -eq 0 ] || usage
    # Exactly one source of paths. Accepting both would leave the precedence
    # to be discovered from behaviour, and a caller that passed a stale list
    # alongside a correct range would silently get one of them.
    if [ -n "$PATHS_FROM" ]; then
      { [ -z "$BASE_REV" ] && [ -z "$HEAD_REV" ] && [ -z "$PROJECT_DIR" ]; } || {
        echo "ERROR: --paths-from is the path list itself; it takes no --base, --head, or --project" >&2
        exit 2
      }
    else
      [ -n "$BASE_REV" ] && [ -n "$HEAD_REV" ] || usage
    fi

    CHANGED_FILE="$(mktemp -t touchstone-paths-changed.XXXXXX)"
    if [ -n "$PATHS_FROM" ]; then
      if [ "$PATHS_FROM" = "-" ]; then
        cat >"$CHANGED_FILE"
      else
        [ -f "$PATHS_FROM" ] || {
          echo "ERROR: --paths-from file not found: $PATHS_FROM" >&2
          exit 2
        }
        cp "$PATHS_FROM" "$CHANGED_FILE"
      fi
    else
      [ -n "$PROJECT_DIR" ] || PROJECT_DIR="$PWD"
      [ -d "$PROJECT_DIR" ] || {
        echo "ERROR: --project is not a directory: $PROJECT_DIR" >&2
        exit 2
      }
      git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1 || {
        echo "ERROR: not a git repository: $PROJECT_DIR" >&2
        exit 2
      }
      for rev in "$BASE_REV" "$HEAD_REV"; do
        git -C "$PROJECT_DIR" rev-parse --verify --quiet "$rev^{commit}" >/dev/null || {
          echo "ERROR: cannot resolve revision in $PROJECT_DIR: $rev" >&2
          exit 2
        }
      done
      # --no-renames so a file moved out of the set appears under its new name.
      # A rename is otherwise reported as one path, and moving a source file
      # into a documents directory would read as a documents-only change. A
      # caller passing --paths-from owes the same: GitHub's file list reports a
      # rename as one entry plus `previous_filename`, and both are changed.
      git -C "$PROJECT_DIR" diff --name-only --no-renames \
        "$BASE_REV" "$HEAD_REV" >"$CHANGED_FILE" || {
        echo "ERROR: could not diff $BASE_REV..$HEAD_REV in $PROJECT_DIR" >&2
        exit 2
      }
    fi

    PATTERNS_FILE="$(mktemp -t touchstone-paths-patterns.XXXXXX)"
    read_set "$SET_NAME" "$PATTERNS_FILE"
    matcher_init "$PATTERNS_FILE"
    assert_not_self_exempting "$SET_NAME"

    IN_PATHS=()
    OUT_PATHS=()
    while IFS= read -r changed; do
      [ -n "$changed" ] || continue
      if in_set "$changed"; then IN_PATHS+=("$changed"); else OUT_PATHS+=("$changed"); fi
    done <"$CHANGED_FILE"
    rm -f "$CHANGED_FILE"

    # An empty diff is `none`, not a vacuous `all`: nothing changed, so nothing
    # is exempt, and a consumer reading `all` would skip a lane for a head it
    # never looked at.
    if [ "${#IN_PATHS[@]}" -eq 0 ]; then
      CLASSIFICATION=none
    elif [ "${#OUT_PATHS[@]}" -eq 0 ]; then
      CLASSIFICATION=all
    else
      CLASSIFICATION=mixed
    fi

    if [ "$JSON" = true ]; then
      jq -nc \
        --arg set "$SET_NAME" \
        --arg source policy \
        --arg policy "$POLICY_FILE" \
        --arg classification "$CLASSIFICATION" \
        --arg base "$BASE_REV" \
        --arg head "$HEAD_REV" \
        --arg input "$([ -n "$PATHS_FROM" ] && echo path-list || echo git-range)" \
        --argjson in "$(json_array ${IN_PATHS+"${IN_PATHS[@]}"})" \
        --argjson out "$(json_array ${OUT_PATHS+"${OUT_PATHS[@]}"})" \
        '{set:$set, source:$source, policy:$policy, classification:$classification,
          input:$input, base:$base, head:$head, in:$in, out:$out}'
    else
      echo "$CLASSIFICATION"
      for p in ${IN_PATHS+"${IN_PATHS[@]}"}; do echo "  in  $p"; done
      for p in ${OUT_PATHS+"${OUT_PATHS[@]}"}; do echo "  out $p"; done
    fi
    ;;

  *)
    usage
    ;;
esac
