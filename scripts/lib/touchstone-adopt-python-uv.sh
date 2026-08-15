# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared across sourced compiler modules

python_uv_version() {
  local output
  command -v uv >/dev/null 2>&1 \
    || contract_refusal "uv automatic adoption requires an exact supported uv runtime; install uv or pass --task NAME=COMMAND"
  output="$(uv --version 2>/dev/null)" \
    || contract_refusal "could not inspect the uv runtime version; pass --task NAME=COMMAND"
  printf '%s\n' "$output" | grep -Eq '^uv [0-9]+[.][0-9]+[.][0-9]+$' \
    || contract_refusal "uv automatic adoption requires a simple exact uv version, found '$output'; pass --task NAME=COMMAND"
  printf '%s\n' "$output"
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
