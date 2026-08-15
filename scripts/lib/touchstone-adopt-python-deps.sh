# shellcheck shell=bash
# shellcheck disable=SC2034 # globals are shared across sourced compiler modules

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
    normalized_section == "" {
      compact = $0
      sub(/[[:space:]]*#.*/, "", compact)
      gsub(/[[:space:]"\047]/, "", compact)
      if (compact ~ /^build-system[.](build-backend|backend-path)=/) unsafe=1
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
      return value ~ /^[A-Za-z0-9][A-Za-z0-9._-]*(\[[A-Za-z0-9._-]+([[:space:]]*,[[:space:]]*[A-Za-z0-9._-]+)*\])?([[:space:]]*(==|~=|!=|<=|>=|<|>)[[:space:]]*[0-9]+([.][0-9]+)*([[:space:]]*,[[:space:]]*(==|~=|!=|<=|>=|<|>)[[:space:]]*[0-9]+([.][0-9]+)*)*)?$/
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

python_has_uv_source_mapping() {
  local file="$1"
  awk '
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      section = $0
      sub(/^[[:space:]]*\[/, "", section)
      sub(/\][[:space:]]*$/, "", section)
      gsub(/[[:space:]"\047]/, "", section)
      if (section == "tool.uv.sources" || section ~ /^tool[.]uv[.]sources[.]/) found = 1
      next
    }
    section == "tool.uv" && /^[[:space:]]*sources[[:space:]]*=/ { found = 1 }
    section == "" && /^[[:space:]]*tool[.]uv[.]sources[[:space:]]*=/ { found = 1 }
    END { exit !found }
  ' "$file"
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
