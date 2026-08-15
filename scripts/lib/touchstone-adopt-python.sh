# shellcheck shell=bash

python_has_unverifiable_build_hook() {
  local directory="$1" file
  file="$directory/pyproject.toml"
  [ ! -f "$directory/setup.py" ] || return 0
  [ -f "$file" ] || return 1
  awk '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }
    /^[[:space:]]*\[[^]]+\][[:space:]]*(#.*)?$/ {
      section = $0
      sub(/^[[:space:]]*\[/, "", section)
      sub(/\][[:space:]]*(#.*)?$/, "", section)
      normalized_section = section
      gsub(/[[:space:]"\047]/, "", normalized_section)
      if (normalized_section ~ /^tool[.]hatch[.](build|metadata)[.]hooks([.]|$)/) unsafe=1
      next
    }
    normalized_section == "build-system" && /^[[:space:]]*backend-path[[:space:]]*=/ { unsafe=1 }
    normalized_section == "build-system" && /^[[:space:]]*build-backend[[:space:]]*=/ {
      value = $0
      sub(/^[^=]*=[[:space:]]*/, "", value)
      sub(/[[:space:]]*#.*/, "", value)
      value = trim(value)
      if (value !~ /^"[^"]+"$/ && value !~ /^\047[^\047]+\047$/) { unsafe=1; next }
      value = substr(value, 2, length(value) - 2)
      if (value != "setuptools.build_meta" && value != "setuptools.build_meta:__legacy__" &&
          value != "hatchling.build" && value != "flit_core.buildapi" &&
          value != "poetry.core.masonry.api" && value != "uv_build") unsafe=1
    }
    END { exit !unsafe }
  ' "$file"
}
python_poetry_build_system_valid() {
  local file="$1"
  awk '
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      section = $0
      sub(/^[[:space:]]*\[/, "", section)
      sub(/\][[:space:]]*$/, "", section)
      gsub(/[[:space:]"\047]/, "", section)
      in_requires = 0
      next
    }
    section == "build-system" {
      line = $0
      sub(/[[:space:]]*#.*/, "", line)
      if (line ~ /^[[:space:]]*build-backend[[:space:]]*=[[:space:]]*["\047]poetry[.]core[.]masonry[.]api["\047][[:space:]]*$/) backend=1
      if (line ~ /^[[:space:]]*requires[[:space:]]*=/) in_requires=1
      if (in_requires && tolower(line) ~ /["\047][[:space:]]*poetry-core([<=>~![]|["\047])/) requirement=1
      if (in_requires && line ~ /\]/) in_requires=0
    }
    END { exit !(backend && requirement) }
  ' "$file"
}
python_has_remote_reference() {
  local pyproject="$1" requirements="$2"
  if [ -f "$requirements" ] && awk '
    {
      line = $0
      sub(/[[:space:]]+#.*/, "", line)
      line = tolower(line)
      if (line ~ /[A-Za-z][A-Za-z0-9+.-]*:\/\// ||
          line ~ /(^|[[:space:]"\047=])git@/ ||
          line ~ /(^|[[:space:]])(-f|--find-links|--index-url|--extra-index-url|--trusted-host|-e|--editable|-r|--requirement|-c|--constraint)([=[:space:]]|$)/ ||
          line ~ /@[[:space:]]*(\/|[.][.]?\/)/ || line ~ /^[[:space:]]*(\/|[.][.]?\/)/) found = 1
    }
    END { exit !found }
  ' "$requirements"; then
    return 0
  fi
  if [ -f "$pyproject" ] && awk '
    function scan_array(value, position, character, quote, escaped) {
      quote = ""
      escaped = 0
      for (position = 1; position <= length(value); position++) {
        character = substr(value, position, 1)
        if (quote != "") {
          if (quote == "\"" && escaped) { escaped = 0; continue }
          if (quote == "\"" && character == "\\") { escaped = 1; continue }
          if (character == quote) quote = ""
          continue
        }
        if (character == "\"" || character == "\047") { quote = character; continue }
        if (character == "#") break
        if (character == "[") { dependency_depth++; dependency_started = 1 }
        if (character == "]") dependency_depth--
      }
    }
    function remote(value) {
      value = tolower(value)
      return value ~ /[A-Za-z][A-Za-z0-9+.-]*:\/\// ||
        value ~ /(^|[[:space:]"\047=])git@/ ||
        value ~ /@[[:space:]]*([A-Za-z][A-Za-z0-9+.-]*:|\/|[.][.]?\/)/ ||
        value ~ /(^|[, {])(git|url|path)[[:space:]]*=/
    }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      section = $0
      sub(/^[[:space:]]*\[/, "", section)
      sub(/\][[:space:]]*$/, "", section)
      gsub(/[[:space:]"\047]/, "", section)
      dependency_value = 0
      dependency_depth = 0
      dependency_started = 0
      next
    }
    {
      line = $0
      sub(/[[:space:]]+#.*/, "", line)
      if (section == "project" && line ~ /^[[:space:]]*dependencies[[:space:]]*=/) {
        dependency_value = 1; dependency_depth = 0; dependency_started = 0
      }
      if (section == "build-system" && line ~ /^[[:space:]]*requires[[:space:]]*=/) {
        dependency_value = 1; dependency_depth = 0; dependency_started = 0
      }
      if (section == "dependency-groups" && line ~ /^[[:space:]]*[A-Za-z0-9_.-]+[[:space:]]*=/) {
        dependency_value = 1; dependency_depth = 0; dependency_started = 0
      }
      if (section == "tool.poetry.dependencies" || dependency_value) {
        if (remote(line)) found = 1
        if (dependency_value) {
          scan_array(line)
          if (dependency_started && dependency_depth == 0) dependency_value = 0
        }
      }
    }
    END { exit !found }
  ' "$pyproject"; then
    return 0
  fi
  return 1
}

python_has_environment_marker() {
  local pyproject="$1" requirements="$2"
  if [ -f "$requirements" ] && awk '
    {
      line = $0
      sub(/[[:space:]]+#.*/, "", line)
      if (line ~ /;/) found = 1
    }
    END { exit !found }
  ' "$requirements"; then
    return 0
  fi
  if [ -f "$pyproject" ] && awk '
    function scan_array(value, position, character, quote, escaped) {
      quote = ""
      escaped = 0
      for (position = 1; position <= length(value); position++) {
        character = substr(value, position, 1)
        if (quote != "") {
          if (quote == "\"" && escaped) { escaped = 0; continue }
          if (quote == "\"" && character == "\\") { escaped = 1; continue }
          if (character == quote) quote = ""
          continue
        }
        if (character == "\"" || character == "\047") { quote = character; continue }
        if (character == "#") break
        if (character == "[") { dependency_depth++; dependency_started = 1 }
        if (character == "]") dependency_depth--
      }
    }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      section = $0
      sub(/^[[:space:]]*\[/, "", section)
      sub(/\][[:space:]]*$/, "", section)
      gsub(/[[:space:]"\047]/, "", section)
      dependency_value = 0
      dependency_depth = 0
      dependency_started = 0
      next
    }
    {
      line = $0
      sub(/[[:space:]]+#.*/, "", line)
      if (section == "project" && line ~ /^[[:space:]]*dependencies[[:space:]]*=/) {
        dependency_value = 1; dependency_depth = 0; dependency_started = 0
      }
      if (section == "build-system" && line ~ /^[[:space:]]*requires[[:space:]]*=/) {
        dependency_value = 1; dependency_depth = 0; dependency_started = 0
      }
      if (section == "dependency-groups" && line ~ /^[[:space:]]*[A-Za-z0-9_.-]+[[:space:]]*=/) {
        dependency_value = 1; dependency_depth = 0; dependency_started = 0
      }
      if (section == "tool.poetry.dependencies" || dependency_value) {
        if (line ~ /;/ || line ~ /(^|[^A-Za-z])markers[[:space:]]*=/ \
          || line ~ /[,{][[:space:]]*(python|platform)[[:space:]]*=/) found = 1
        if (dependency_value) {
          scan_array(line)
          if (dependency_started && dependency_depth == 0) dependency_value = 0
        }
      }
    }
    END { exit !found }
  ' "$pyproject"; then
    return 0
  fi
  return 1
}

python_project_dependencies_valid() {
  local file="$1"
  awk '
    function requirement_valid(value) {
      return value ~ /^[A-Za-z0-9][A-Za-z0-9._-]*(\[[A-Za-z0-9._-]+([[:space:]]*,[[:space:]]*[A-Za-z0-9._-]+)*\])?([[:space:]]*(===|==|~=|!=|<=|>=|<|>)[[:space:]]*[A-Za-z0-9*+._!-]+([[:space:]]*,[[:space:]]*(===|==|~=|!=|<=|>=|<|>)[[:space:]]*[A-Za-z0-9*+._!-]+)*)?$/
    }
    function scan(value, position, character) {
      for (position = 1; position <= length(value); position++) {
        character = substr(value, position, 1)
        if (quote != "") {
          if (quote == "\"" && escaped) {
            token = token character
            escaped = 0
            continue
          }
          if (quote == "\"" && character == "\\") { escaped = 1; continue }
          if (character == quote) {
            if (!requirement_valid(token)) invalid = 1
            quote = ""
            token = ""
            continue
          }
          token = token character
          continue
        }
        if (comment) continue
        if (character == "#") { comment = 1; continue }
        if (character == "\"" || character == "\047") {
          quote = character
          token = ""
          continue
        }
        if (character == "[") { depth++; started = 1; continue }
        if (character == "]") {
          depth--
          if (depth < 0) invalid = 1
          if (started && depth == 0) closed = 1
          continue
        }
        if (closed && character !~ /[[:space:]]/) invalid = 1
        else if (!closed && character !~ /[[:space:],]/) invalid = 1
      }
      comment = 0
    }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      if (in_dependencies) invalid = 1
      section = $0
      sub(/^[[:space:]]*\[/, "", section)
      sub(/\][[:space:]]*$/, "", section)
      gsub(/[[:space:]"\047]/, "", section)
      next
    }
    !in_dependencies && section == "project" && /^[[:space:]]*dependencies[[:space:]]*=/ {
      if (dependencies_seen) invalid = 1
      dependencies_seen = 1
      in_dependencies = 1
      depth = 0
      started = 0
      closed = 0
      line = $0
      sub(/^[^=]*=/, "", line)
      scan(line)
      if (closed) in_dependencies = 0
      next
    }
    in_dependencies {
      scan($0)
      if (closed) in_dependencies = 0
    }
    END {
      if (invalid || in_dependencies || quote != "" || depth != 0) exit 1
    }
  ' "$file" >/dev/null 2>&1
}

validate_requirements_document() {
  local file="$1"
  awk '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }
    {
      line = $0
      sub(/[[:space:]]+#.*/, "", line)
      line = trim(line)
      if (line == "") next
      name = "[A-Za-z0-9][A-Za-z0-9._-]*(\\[[A-Za-z0-9._,-]+\\])?"
      version = "[A-Za-z0-9*+!._-]+"
      comparison = "(===|==|!=|~=|<=|>=|<|>)[[:space:]]*" version
      if (line !~ ("^" name "([[:space:]]*" comparison "([[:space:]]*,[[:space:]]*" comparison ")*)?$")) exit 2
    }
  ' "$file" >/dev/null 2>&1 \
    || contract_refusal "requirements.txt is malformed or outside the portable named-requirement subset; pass --task NAME=COMMAND for a manual contract"
}

validate_uv_lock() {
  local file="$1" pyproject="$2" lock_requires project_metadata project_name project_requires
  validate_toml_document "$file" uv.lock
  awk '
    function finish_package() {
      if (in_package && (!name_seen || !version_seen || !source_seen)) exit 2
    }
    /^[[:space:]]*\[\[package\]\][[:space:]]*$/ {
      finish_package()
      in_package=1
      nested=0
      name_seen=version_seen=source_seen=0
      packages++
      next
    }
    in_package && /^[[:space:]]*\[/ { nested=1; next }
    !in_package || nested { next }
    /^[[:space:]]*name[[:space:]]*=[[:space:]]*"[A-Za-z0-9][A-Za-z0-9._-]*"[[:space:]]*$/ {
      if (name_seen) exit 2
      name_seen=1
      next
    }
    /^[[:space:]]*name[[:space:]]*=/ { exit 2 }
    /^[[:space:]]*version[[:space:]]*=[[:space:]]*"[^"]+"[[:space:]]*$/ {
      if (version_seen) exit 2
      version_seen=1
      next
    }
    /^[[:space:]]*version[[:space:]]*=/ { exit 2 }
    /^[[:space:]]*source[[:space:]]*=[[:space:]]*\{[^{}]+\}[[:space:]]*$/ {
      if (source_seen) exit 2
      source_seen=1
      next
    }
    /^[[:space:]]*source[[:space:]]*=/ { exit 2 }
    END {
      finish_package()
      if (!packages) exit 2
    }
  ' "$file" >/dev/null 2>&1 \
    || contract_refusal "uv.lock has incomplete package records; regenerate it or pass --task NAME=COMMAND"
  lock_requires="$(awk '
    BEGIN { in_root=1 }
    /^[[:space:]]*\[/ { in_root=0 }
    !in_root { next }
    /^[[:space:]]*version[[:space:]]*=[[:space:]]*1[[:space:]]*$/ {
      if (version_seen) exit 2
      version_seen=1
      next
    }
    /^[[:space:]]*version[[:space:]]*=/ { exit 2 }
    /^[[:space:]]*revision[[:space:]]*=[[:space:]]*3[[:space:]]*$/ {
      if (revision_seen) exit 2
      revision_seen=1
      next
    }
    /^[[:space:]]*revision[[:space:]]*=/ { exit 2 }
    /^[[:space:]]*requires-python[[:space:]]*=/ {
      if (requires_seen) exit 2
      value=$0
      sub(/^[^=]*=[[:space:]]*/, "", value)
      sub(/[[:space:]]*$/, "", value)
      if (value !~ /^"[^"]+"$/) exit 2
      requires=substr(value, 2, length(value) - 2)
      requires_seen=1
      next
    }
    END {
      if (!version_seen || !revision_seen || !requires_seen) exit 2
      print requires
    }
  ' "$file" 2>/dev/null)" \
    || contract_refusal "uv.lock lacks the unique supported version, revision, or requires-python fields; regenerate it or pass --task NAME=COMMAND"
  project_metadata="$(awk '
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      section=$0
      sub(/^[[:space:]]*\[/, "", section)
      sub(/\][[:space:]]*$/, "", section)
      gsub(/[[:space:]"\047]/, "", section)
      next
    }
    section == "project" && /^[[:space:]]*name[[:space:]]*=/ {
      if (name_seen) exit 2
      value=$0
      sub(/^[^=]*=[[:space:]]*/, "", value)
      sub(/[[:space:]]*$/, "", value)
      if (value !~ /^"[A-Za-z0-9][A-Za-z0-9._-]*"$/) exit 2
      name=substr(value, 2, length(value) - 2)
      name_seen=1
      next
    }
    section == "project" && /^[[:space:]]*requires-python[[:space:]]*=/ {
      if (requires_seen) exit 2
      value=$0
      sub(/^[^=]*=[[:space:]]*/, "", value)
      sub(/[[:space:]]*$/, "", value)
      if (value !~ /^"[^"]+"$/) exit 2
      requires=substr(value, 2, length(value) - 2)
      requires_seen=1
      next
    }
    END {
      if (!name_seen || !requires_seen) exit 2
      print name "\t" requires
    }
  ' "$pyproject" 2>/dev/null)" \
    || contract_refusal "uv automatic adoption requires static project name and requires-python declarations"
  IFS=$'\t' read -r project_name project_requires <<<"$project_metadata"
  [ "$lock_requires" = "$project_requires" ] \
    || contract_refusal "uv.lock requires-python does not match pyproject.toml; regenerate it or pass --task NAME=COMMAND"
  uv_lock_has_package "$file" "$project_name" \
    || contract_refusal "uv.lock does not contain the declared project package '$project_name'; regenerate it or pass --task NAME=COMMAND"
}

uv_lock_has_package() {
  local file="$1" wanted="$2"
  awk -v wanted="$wanted" '
    function normalize(value) {
      value=tolower(value)
      gsub(/[._]+/, "-", value)
      return value
    }
    /^[[:space:]]*\[\[package\]\][[:space:]]*$/ { in_package=1; next }
    /^[[:space:]]*\[/ { in_package=0; next }
    in_package && /^[[:space:]]*name[[:space:]]*=/ {
      value=$0
      sub(/^[^=]*=[[:space:]]*/, "", value)
      sub(/[[:space:]]*$/, "", value)
      if (value ~ /^"[A-Za-z0-9][A-Za-z0-9._-]*"$/) {
        value=substr(value, 2, length(value) - 2)
        if (normalize(value) == normalize(wanted)) found=1
      }
    }
    END { exit !found }
  ' "$file"
}

verify_uv_lock_compatibility() {
  local directory="$1" output detail
  command -v uv >/dev/null 2>&1 \
    || contract_refusal "uv automatic adoption requires the declared uv tool to verify the lock offline; install uv or pass --task NAME=COMMAND"
  if output="$(cd "$directory" \
    && UV_NO_PROGRESS=1 UV_PYTHON_DOWNLOADS=never \
      uv lock --check --offline --no-config 2>&1)"; then
    return 0
  fi
  detail="$(printf '%s\n' "$output" | awk '
    NF {
      if (joined != "") joined=joined " "
      joined=joined $0
    }
    END { print substr(joined, 1, 300) }
  ')"
  contract_refusal "uv.lock is incompatible with pyproject.toml under offline lock verification${detail:+: $detail}; regenerate it or pass --task NAME=COMMAND"
}

python_project_has_dependency() {
  local file="$1" wanted="$2" include_dev="$3"
  awk -v wanted="$wanted" -v include_dev="$include_dev" '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }
    function contains_dependency(value, pattern) {
      pattern = "[\"\047][[:space:]]*" wanted "([<=>~![]|[\"\047])"
      return tolower(value) ~ pattern
    }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      section = $0
      sub(/^[[:space:]]*\[/, "", section)
      sub(/\][[:space:]]*$/, "", section)
      gsub(/[[:space:]"\047]/, "", section)
      in_dependencies = 0
      in_dev = 0
      next
    }
    {
      line = $0
      sub(/[[:space:]]*#.*/, "", line)
      if (section == "project") {
        if (!in_dependencies && line ~ /^[[:space:]]*dependencies[[:space:]]*=/) {
          in_dependencies = 1
        }
        if (in_dependencies && contains_dependency(line)) found = 1
        if (in_dependencies && line ~ /\]/) in_dependencies = 0
      } else if (section == "tool.poetry.dependencies") {
        key = trim(substr(line, 1, index(line, "=") - 1))
        gsub(/[\"\047]/, "", key)
        value = tolower(substr(line, index(line, "=") + 1))
        if (tolower(key) == wanted && value !~ /(^|[, {])optional[[:space:]]*=[[:space:]]*true([, }]|$)/) found = 1
      } else if (include_dev == "true" && section == "dependency-groups") {
        if (!in_dev && line ~ /^[[:space:]]*dev[[:space:]]*=/) in_dev = 1
        if (in_dev && contains_dependency(line)) found = 1
        if (in_dev && line ~ /\]/) in_dev = 0
      }
    }
    END { exit !found }
  ' "$file"
}

python_has_uv_dev_group() {
  local file="$1"
  awk '
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      section = $0
      sub(/^[[:space:]]*\[/, "", section)
      sub(/\][[:space:]]*$/, "", section)
      gsub(/[[:space:]"\047]/, "", section)
      next
    }
    section == "dependency-groups" && /^[[:space:]]*dev[[:space:]]*=/ { found=1 }
    END { exit !found }
  ' "$file"
}

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

tasks_for_python() {
  local directory="$1" target="$2" suffix="$3" prefix="python -m" found=false evidence=false
  if [ -f "$directory/pyproject.toml" ]; then
    validate_toml_document "$directory/pyproject.toml" pyproject.toml
  fi
  if [ -f "$directory/pyproject.toml" ] && grep -Eq '^\[tool\.poetry(\.|\])' "$directory/pyproject.toml" \
    && ! python_poetry_build_system_valid "$directory/pyproject.toml"; then
    contract_refusal "Python target '$target' declares Poetry metadata without a verified poetry-core build backend; pass --task NAME=COMMAND"
  fi
  if python_has_unverifiable_build_hook "$directory"; then
    contract_refusal "Python target '$target' declares a project build hook this portable compiler cannot verify offline; pass --task NAME=COMMAND"
  fi
  if python_has_environment_marker "$directory/pyproject.toml" "$directory/requirements.txt"; then
    contract_refusal "Python target '$target' contains an environment-marked dependency this portable compiler cannot verify; use unconditional locked dependencies or pass --task NAME=COMMAND"
  fi
  if python_has_remote_reference "$directory/pyproject.toml" "$directory/requirements.txt"; then
    contract_refusal "Python target '$target' contains a remote direct dependency reference or checkout-external source; use named dependencies from the offline lock source, or pass --task NAME=COMMAND"
  fi
  if [ -f "$directory/pyproject.toml" ]; then
    python_project_dependencies_valid "$directory/pyproject.toml" \
      || contract_refusal "Python target '$target' has a project dependency outside the supported named-requirement subset; pass --task NAME=COMMAND"
  fi
  if [ -f "$directory/requirements.txt" ]; then
    validate_requirements_document "$directory/requirements.txt"
  fi
  if [ -f "$directory/uv.lock" ]; then
    [ -f "$directory/pyproject.toml" ] \
      || contract_refusal "uv automatic adoption requires pyproject.toml compatibility facts"
    validate_uv_lock "$directory/uv.lock" "$directory/pyproject.toml"
    verify_uv_lock_compatibility "$directory"
    prefix="uv run --no-sync --no-config"
    if [ -f "$directory/pyproject.toml" ] && python_has_uv_dev_group "$directory/pyproject.toml"; then
      record_setup "$directory" "uv sync --no-config --offline --frozen --group dev"
    else
      record_setup "$directory" "uv sync --no-config --offline --frozen"
    fi
  elif [ -f "$directory/requirements.txt" ]; then
    record_setup "$directory" "python -m pip install --no-index -r requirements.txt"
  elif [ -f "$directory/pyproject.toml" ]; then
    if grep -Eq '^\[(project|build-system|tool\.poetry)\]' "$directory/pyproject.toml"; then
      record_setup "$directory" "python -m pip install --no-index --no-build-isolation -e ."
    else
      contract_refusal "Python target '$target' has tool configuration but no installable project or dependency declaration"
    fi
  fi
  evidence=false
  if [ -f "$directory/pyproject.toml" ] && grep -Eq '^\[tool\.ruff(\.|\])' "$directory/pyproject.toml"; then evidence=true; fi
  if python_checker_declared "$directory" ruff; then
    evidence=true
  elif [ "$evidence" = true ]; then
    contract_refusal "Python target '$target' configures ruff without an installed ruff dependency"
  fi
  if [ "$evidence" = true ]; then
    record_task "lint$suffix" "$target" "$prefix ruff check ."
    found=true
  fi
  evidence=false
  if [ -f "$directory/pyproject.toml" ] && grep -Eq '^\[tool\.mypy(\.|\])' "$directory/pyproject.toml"; then evidence=true; fi
  if python_checker_declared "$directory" mypy; then
    evidence=true
  elif [ "$evidence" = true ]; then
    contract_refusal "Python target '$target' configures mypy without an installed mypy dependency"
  fi
  if [ "$evidence" = true ] && ! python_has_tracked_source "$directory"; then
    contract_refusal "Python target '$target' has mypy evidence but no tracked regular Python source"
  fi
  if [ "$evidence" = true ]; then
    record_task "typecheck$suffix" "$target" "$prefix mypy ."
    found=true
  fi
  evidence=false
  if python_has_tracked_tests "$directory"; then evidence=true; fi
  if ! python_checker_declared "$directory" pytest && [ "$evidence" = true ]; then
    contract_refusal "Python target '$target' has pytest evidence without an installed pytest dependency"
  fi
  if [ "$evidence" = true ]; then
    record_task "test$suffix" "$target" "$prefix pytest"
    found=true
  fi
  [ "$found" = true ] || contract_refusal "Python target '$target' has no declared ruff, mypy, or pytest evidence; pass --task NAME=COMMAND"
}
