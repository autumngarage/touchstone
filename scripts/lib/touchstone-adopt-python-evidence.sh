# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared across sourced compiler modules

python_checker_declared() {
  local directory="$1" checker="$2" include_dev=false
  if [ -f "$directory/uv.lock" ]; then
    include_dev=true
    [ -f "$directory/pyproject.toml" ] || return 1
    python_project_has_dependency "$directory/pyproject.toml" "$checker" "$include_dev" \
      && uv_lock_has_package "$directory/uv.lock" "$checker"
    return $?
  fi
  if [ -f "$directory/requirements.txt" ]; then
    grep -Eqi "^[[:space:]]*${checker}([[:space:]<=>~!\[]|$)" "$directory/requirements.txt"
    return
  fi
  [ -f "$directory/pyproject.toml" ] || return 1
  python_project_has_dependency "$directory/pyproject.toml" "$checker" "$include_dev"
}

python_tracked_paths() {
  local directory="$1" relative prefix
  relative="${directory#"$PROJECT_ROOT"}"
  relative="${relative#/}"
  if [ -n "$relative" ]; then prefix="$relative/"; else prefix=""; fi
  git -C "$PROJECT_ROOT" ls-files | awk -v prefix="$prefix" '
    index($0, prefix) == 1 {
      print $0
    }
  '
}

python_has_tracked_source() {
  local directory="$1" path
  while IFS= read -r path; do
    case "$path" in *.py | *.pyi) ;; *) continue ;; esac
    [ -f "$PROJECT_ROOT/$path" ] && [ ! -L "$PROJECT_ROOT/$path" ] && return 0
  done < <(python_tracked_paths "$directory")
  return 1
}

python_has_tracked_tests() {
  local directory="$1" path name relative test_prefix
  relative="${directory#"$PROJECT_ROOT"}"
  relative="${relative#/}"
  if [ -n "$relative" ]; then test_prefix="$relative/tests/"; else test_prefix="tests/"; fi
  while IFS= read -r path; do
    case "$path" in "$test_prefix"*) ;; *) continue ;; esac
    name="${path##*/}"
    case "$name" in test_*.py | *_test.py) ;; *) continue ;; esac
    [ -f "$PROJECT_ROOT/$path" ] && [ ! -L "$PROJECT_ROOT/$path" ] || continue
    grep -Eq '^def[[:space:]]+test_[A-Za-z0-9_]*[[:space:]]*\([^)]*\)[[:space:]]*(->[[:space:]]*[^:]+)?[[:space:]]*:' \
      "$PROJECT_ROOT/$path" && return 0
  done < <(python_tracked_paths "$directory")
  return 1
}
